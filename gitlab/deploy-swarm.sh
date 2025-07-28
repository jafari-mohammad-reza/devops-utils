#!/usr/bin/env bash
set -euo pipefail

DEBUG=${DEBUG:-false}
debug_log() {
    if [ "$DEBUG" = "true" ]; then
        echo "[DEBUG $(date '+%Y-%m-%d %H:%M:%S')] $1"
    fi
}

info_log() {
    echo "[INFO $(date '+%Y-%m-%d %H:%M:%S')] $1"
}

error_log() {
    echo "[ERROR $(date '+%Y-%m-%d %H:%M:%S')] $1" >&2
}

# Validate arguments
if [ $# -ne 4 ]; then
    error_log "Usage: $0 <PROJECT> <MANAGER_HOST> <STACK_NAME> <REMOTE_STACK_PATH>"
    exit 1
fi

PROJECT="$1"
MANAGER_HOST="$2"
STACK_NAME="$3"
REMOTE_STACK_PATH="$4"

info_log "Starting deployment for project: $PROJECT"

if [ ! -f .built-image.txt ]; then
    error_log "Image tag file '.built-image.txt' not found"
    exit 1
fi

IMAGE_TAG=$(cat .built-image.txt)
if [ -z "$IMAGE_TAG" ]; then
    error_log "Image tag is empty"
    exit 1
fi

info_log "Image tag: $IMAGE_TAG"

REGISTRY=$(echo "$IMAGE_TAG" | cut -d'/' -f1)
info_log "Registry: $REGISTRY"

info_log "➤ Step 1: Checking authentication and pulling image"

info_log "Copying Docker authentication config to manager host..."
ssh "runner@$MANAGER_HOST" "mkdir -p ~/.docker"

if [ -f ~/.docker/config.json ]; then
    scp ~/.docker/config.json "runner@$MANAGER_HOST:~/.docker/config.json"
    info_log "✓ Docker config copied to manager host"
else
    error_log "Docker config.json not found locally. Please run 'docker login $REGISTRY' first"
    exit 1
fi

info_log "➤ Step 2: Getting current image and updating stack files"

# Get current image before deployment
PREVIOUS_IMAGE=$(ssh "runner@$MANAGER_HOST" bash <<EOF
  set -euo pipefail
  
  service_name="${STACK_NAME}_${PROJECT}"
  
  # Get current image from running service
  current_image=\$(docker service inspect "\$service_name" --format '{{.Spec.TaskTemplate.ContainerSpec.Image}}' 2>/dev/null || echo "")
  
  if [ -n "\$current_image" ]; then
    echo "\$current_image"
  else
    # Fallback: get from stack file
    cd "$REMOTE_STACK_PATH"
    if [ -f "stack.yaml" ]; then
      grep -A 20 "^ *$PROJECT:" stack.yaml | grep "^ *image:" | head -1 | sed 's/.*image: *//' || echo ""
    else
      echo ""
    fi
  fi
EOF
)

if [ -n "$PREVIOUS_IMAGE" ]; then
    info_log "Previous image: $PREVIOUS_IMAGE"
else
    info_log "No previous image found - this might be initial deployment"
fi

ssh "runner@$MANAGER_HOST" bash <<EOF
  set -euo pipefail

  echo "Pulling image: $IMAGE_TAG"
  if docker pull "$IMAGE_TAG"; then
    echo "✓ Image pulled successfully: $IMAGE_TAG"
  else
    echo "✗ Failed to pull image: $IMAGE_TAG"
    exit 1
  fi

  if [ ! -d "$REMOTE_STACK_PATH" ]; then
    echo "Stack directory not found: $REMOTE_STACK_PATH"
    exit 1
  fi

  cd "$REMOTE_STACK_PATH"
  stack_file="stack.yaml"

  if [ -f "\$stack_file" ]; then
    echo "Found stack file: \$stack_file"

    if grep -q "^ *$PROJECT:" "\$stack_file"; then
      echo "Updating service '$PROJECT' in \$stack_file"
      sed -i '/^ *$PROJECT:\$/, /^ *[^:]*:/ {
        s|^\( *image: \).*|\1$IMAGE_TAG|
      }' "\$stack_file"

      if grep -q "$IMAGE_TAG" "\$stack_file"; then
        echo "✓ Image tag updated in \$stack_file"
      else
        echo "⚠ Image tag may not have been updated"
      fi
    else
      echo "Service '$PROJECT' not found in stack file"
      exit 1
    fi
  else
    echo "Stack file not found in $REMOTE_STACK_PATH"
    exit 1
  fi

  if [ -f "deploy.sh" ]; then
    STACK_NAME="$STACK_NAME" PROJECT="$PROJECT" IMAGE_TAG="$IMAGE_TAG" bash deploy.sh
  else
    docker stack deploy -c "\$stack_file" "$STACK_NAME"
  fi
EOF

if [ $? -ne 0 ]; then
    error_log "Deployment failed"
    exit 1
fi

info_log "➤ Step 3: Watching rollout status..."

ssh "runner@$MANAGER_HOST" \
STACK_NAME="$STACK_NAME" \
PROJECT="$PROJECT" \
REMOTE_STACK_PATH="$REMOTE_STACK_PATH" \
PREVIOUS_IMAGE="$PREVIOUS_IMAGE" \
NEW_IMAGE="$IMAGE_TAG" \
bash <<'EOF'
  set -euo pipefail

  echo "Waiting for deployment to start..."
  sleep 5

  max_attempts=10
  attempt=0
  service_name="${STACK_NAME}_${PROJECT}"
  deployment_success=false

  echo "Monitoring service: $service_name"

  while [ $attempt -lt $max_attempts ]; do
    echo ""
    echo "Checking deployment status (attempt $((attempt + 1))/$max_attempts)..."

    service_info=$(docker service ls --filter name="$service_name" --format '{{.Name}}|{{.Replicas}}')

    if [ -z "$service_info" ]; then
      echo "Service $service_name not found"
      docker service ls --filter name="${STACK_NAME}_" --format '  {{.Name}}'
    else
      replicas=$(echo "$service_info" | cut -d'|' -f2)
      running=$(echo "$replicas" | cut -d'/' -f1)
      desired=$(echo "$replicas" | cut -d'/' -f2)

      echo "Replicas: $running/$desired"

      task_output=$(docker service ps "$service_name" --no-trunc --format '{{.Name}}\t{{.CurrentState}}\t{{.Error}}')
      echo -e "Task States:\n$task_output" | head -5

      running_tasks=$(echo "$task_output" | grep -cE 'Running ')
      failed_tasks=$(echo "$task_output" | grep -cE '(Failed|Rejected|Shutdown|Error)' || true)

      if [ "$running_tasks" -eq "$desired" ] && [ "$desired" -gt 0 ]; then
        echo "✓ All tasks are running"
        deployment_success=true
        break
      elif [ "$failed_tasks" -gt 0 ]; then
        echo "✗ $failed_tasks task(s) failed - waiting for recovery..."
      else
        echo "⏳ Waiting for all tasks to transition to running..."
      fi
    fi

    attempt=$((attempt + 1))
    sleep 5
  done

  if [ "$deployment_success" = "true" ]; then
    echo "✓ Deployment completed successfully!"
    exit 0
  else
    echo "✗ Deployment failed after $((max_attempts * 5)) seconds"
    docker service ps "$service_name" --no-trunc | head -10
    
    # Rollback to previous image if available
    if [ -n "$PREVIOUS_IMAGE" ] && [ "$PREVIOUS_IMAGE" != "$NEW_IMAGE" ]; then
      echo ""
      echo "🔄 Rolling back to previous image: $PREVIOUS_IMAGE"
      
      cd "$REMOTE_STACK_PATH"
      stack_file="stack.yaml"
      
      if [ -f "$stack_file" ]; then
        # Update stack file with previous image
        sed -i '/^ *'"$PROJECT"':$/, /^ *[^:]*:/ {
          s|^\( *image: \).*|\1'"$PREVIOUS_IMAGE"'|
        }' "$stack_file"
        
        echo "✓ Stack file reverted to previous image"
        
        # Redeploy with previous image
        if [ -f "deploy.sh" ]; then
          STACK_NAME="$STACK_NAME" PROJECT="$PROJECT" IMAGE_TAG="$PREVIOUS_IMAGE" bash deploy.sh
        else
          docker stack deploy -c "$stack_file" "$STACK_NAME"
        fi
        
        echo "🔄 Rollback deployment initiated"
        
        # Wait for rollback to complete
        rollback_attempts=5
        rollback_attempt=0
        
        while [ $rollback_attempt -lt $rollback_attempts ]; do
          echo "Checking rollback status (attempt $((rollback_attempt + 1))/$rollback_attempts)..."
          
          service_info=$(docker service ls --filter name="$service_name" --format '{{.Name}}|{{.Replicas}}')
          if [ -n "$service_info" ]; then
            replicas=$(echo "$service_info" | cut -d'|' -f2)
            running=$(echo "$replicas" | cut -d'/' -f1)
            desired=$(echo "$replicas" | cut -d'/' -f2)
            
            echo "Rollback replicas: $running/$desired"
            
            if [ "$running" -eq "$desired" ] && [ "$desired" -gt 0 ]; then
              echo "✓ Rollback completed successfully"
              break
            fi
          fi
          
          rollback_attempt=$((rollback_attempt + 1))
          sleep 10
        done
        
        if [ $rollback_attempt -eq $rollback_attempts ]; then
          echo "⚠ Rollback may not have completed fully, but service should recover"
        fi
        
      else
        echo "⚠ Cannot rollback: stack file not found"
      fi
    else
      echo "⚠ No previous image available for rollback"
    fi
    
    exit 1
  fi
EOF

deployment_status=$?

if [ $deployment_status -eq 0 ]; then
  info_log "✓ Deployment completed successfully"
else
  error_log "✗ Deployment failed"
  if [ -n "$PREVIOUS_IMAGE" ]; then
    info_log "🔄 Automatic rollback to previous image was attempted: $PREVIOUS_IMAGE"
  fi
  exit 1
fi
