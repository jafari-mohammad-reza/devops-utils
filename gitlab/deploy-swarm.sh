#!/usr/bin/env bash
set -euo pipefail

# Enable debug logging
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


if [ -f ~/.docker/config.json ]; then
    scp ~/.docker/config.json "runner@$MANAGER_HOST:~/.docker/config.json"
    info_log "✓ Docker config copied to manager host"
else
    error_log "Docker config.json not found locally. Please run 'docker login $REGISTRY' first"
    exit 1
fi

info_log "➤ Step 1: Pulling image and updating stack files"

ssh "runner@$MANAGER_HOST" bash <<EOF
  set -euo pipefail
  
  # Pull the image first
  echo "Pulling image: $IMAGE_TAG"
  if docker pull "$IMAGE_TAG"; then
    echo "✓ Image pulled successfully: $IMAGE_TAG"
  else
    echo "✗ Failed to pull image: $IMAGE_TAG"
    exit 1
  fi
  
  # Verify stack directory exists
  if [ ! -d "$REMOTE_STACK_PATH" ]; then
    echo "Stack directory not found: $REMOTE_STACK_PATH"
    exit 1
  fi
  
  # Change to stack directory
  cd "$REMOTE_STACK_PATH"
  echo "Working in directory: \$(pwd)"
  
  # Look specifically for stack.yaml file
  stack_file="stack.yaml"
  
  if [ -f "\$stack_file" ]; then
    echo "Found stack file: \$stack_file"
    
    # Create backup with timestamp
    backup_file="\$stack_file.backup.\$(date +%Y%m%d_%H%M%S)"
    cp "\$stack_file" "\$backup_file"
    echo "Backup created: \$backup_file"
    
    # Store backup filename for later cleanup
    echo "\$backup_file" > /tmp/backup_file_name
    
    # Update the image tag for the PROJECT service
    if grep -q "^ *$PROJECT:" "\$stack_file"; then
      echo "Updating service '$PROJECT' in \$stack_file"
      
      # Update image tag using sed
      sed -i '/^ *$PROJECT:\$/, /^ *[^:]*:/ {
        s|^\( *image: \).*|\1$IMAGE_TAG|
      }' "\$stack_file"
      
      # Verify the change was made
      if grep -q "$IMAGE_TAG" "\$stack_file"; then
        echo "✓ Image tag updated successfully in \$stack_file"
        echo "Updated service '$PROJECT' with image: $IMAGE_TAG"
      else
        echo "⚠ Image tag may not have been updated in \$stack_file"
      fi
    else
      echo "Service '$PROJECT' not found in \$stack_file"
      exit 1
    fi
  else
    echo "Stack file 'stack.yaml' not found in $REMOTE_STACK_PATH"
    exit 1
  fi
  
  # Execute deployment
  if [ -f "deploy.sh" ]; then
    echo "Found deploy.sh script, executing..."
    chmod +x deploy.sh 2>/dev/null || true
    
    export STACK_NAME="$STACK_NAME"
    export SERVICE_NAME="$PROJECT"
    export PROJECT="$PROJECT"
    export IMAGE_TAG="$IMAGE_TAG"
    export NODE="${NODE:-}"
    
    if [ -x "deploy.sh" ]; then
      ./deploy.sh
    else
      bash deploy.sh
    fi
  else
    echo "No deploy.sh found, performing standard docker stack deploy..."
    docker stack deploy -c "stack.yaml" "$STACK_NAME"
  fi
EOF

if [ $? -ne 0 ]; then
    error_log "Deployment failed"
    exit 1
fi

info_log "➤ Step 2: Watching rollout status..."

# Fixed rollout monitoring without UpdateStatus field
ssh "runner@$MANAGER_HOST" bash <<EOF
  set -euo pipefail
  
  echo "Waiting for deployment to start..."
  sleep 3
  
  max_attempts=10
  attempt=0
  deployment_success=false
  service_name="${STACK_NAME}_${PROJECT}"
  
  echo "Looking for service: \$service_name"
  
  while [ \$attempt -lt \$max_attempts ]; do
    echo "Checking deployment status (attempt \$((attempt + 1))/\$max_attempts)..."
    
    echo "Current stack services:"
    docker service ls --filter name="${STACK_NAME}_" --format 'table {{.Name}}\t{{.Replicas}}\t{{.Image}}'
    
    service_info=\$(docker service ls --filter name="\$service_name" --format '{{.Name}}|{{.Replicas}}' 2>/dev/null)
    
    if [ -n "\$service_info" ]; then
      service_name_found=\$(echo "\$service_info" | cut -d'|' -f1)
      replicas=\$(echo "\$service_info" | cut -d'|' -f2)
      
      echo "Service found: \$service_name_found"
      echo "Replicas: \$replicas"
      
      if echo "\$replicas" | grep -qE '^[0-9]+/[0-9]+\$'; then
        running=\$(echo "\$replicas" | cut -d'/' -f1)
        desired=\$(echo "\$replicas" | cut -d'/' -f2)
        
        echo "Running replicas: \$running/\$desired"
        
        if [ "\$running" = "\$desired" ] && [ "\$desired" -gt 0 ]; then
          echo "All replicas are running, checking task status..."
          
          task_states=\$(docker service ps "\$service_name" --filter desired-state=running --format '{{.CurrentState}}' --no-trunc | head -\$desired)
          
          running_tasks=\$(echo "\$task_states" | grep -c "Running" || echo "0")
          
          echo "Tasks in Running state: \$running_tasks/\$desired"
          
          if [ "\$running_tasks" = "\$desired" ]; then
            failed_tasks=\$(docker service ps "\$service_name" --filter desired-state=running --format '{{.CurrentState}}' | grep -E "(Failed|Rejected|Error)" | wc -l || echo "0")
            
            if [ "\$failed_tasks" = "0" ]; then
              echo "✓ All tasks are running successfully!"
              echo "Service \$service_name_found is healthy with \$replicas replicas"
              
              # Show final service details
              echo ""
              echo "Final service status:"
              docker service ls --filter name="\$service_name"
              echo ""
              echo "Service tasks:"
              docker service ps "\$service_name" --filter desired-state=running --format 'table {{.Name}}\t{{.CurrentState}}\t{{.Error}}' | head -5
              
              deployment_success=true
              break
            else
              echo "Found \$failed_tasks failed tasks, waiting for recovery..."
            fi
          else
            echo "Waiting for all tasks to reach Running state..."
            echo "Current task states:"
            echo "\$task_states" | head -3
          fi
        else
          echo "Waiting for all replicas to be ready (\$running/\$desired)..."
          
          # Show task details if not all replicas are ready
          echo "Current tasks:"
          docker service ps "\$service_name" --format 'table {{.Name}}\t{{.CurrentState}}\t{{.Error}}' | head -3
        fi
      else
        echo "Invalid replica format: \$replicas"
      fi
    else
      echo "Service '\$service_name' not found"
      echo "Available services in stack ${STACK_NAME}:"
      docker service ls --filter name="${STACK_NAME}_" --format '{{.Name}}' | head -5
    fi
    
    attempt=\$((attempt + 1))
    sleep 2
  done
  
  if [ "\$deployment_success" = "true" ]; then
    echo ""
    echo "✓ Deployment completed successfully!"
    
    # Clean up backup files on successful deployment
    cd "$REMOTE_STACK_PATH"
    if [ -f "/tmp/backup_file_name" ]; then
      backup_file=\$(cat /tmp/backup_file_name)
      if [ -f "\$backup_file" ]; then
        echo "Cleaning up backup file: \$backup_file"
        if rm "\$backup_file"; then
          echo "✓ Backup file removed successfully"
        else
          echo "⚠ Failed to remove backup file: \$backup_file"
        fi
      fi
      rm -f /tmp/backup_file_name
    fi
    
    # Clean up old backup files (keep only last 3)
    echo "Checking for old backup files..."
    backup_count=\$(ls -1 stack.yaml.backup.* 2>/dev/null | wc -l || echo "0")
    if [ "\$backup_count" -gt 3 ]; then
      echo "Found \$backup_count backup files, keeping only the 3 most recent ones"
      ls -1t stack.yaml.backup.* 2>/dev/null | tail -n +4 | xargs rm -f 2>/dev/null || true
      echo "✓ Old backup files cleaned up"
    fi
    
    exit 0
  else
    echo "✗ Deployment timeout after \$((max_attempts * 2)) seconds"
    echo "Final service status:"
    docker service ls --filter name="${STACK_NAME}_"
    
    echo ""
    echo "Service tasks:"
    docker service ps "\$service_name" --format 'table {{.Name}}\t{{.CurrentState}}\t{{.Error}}' | head -10
    
    exit 1
  fi
EOF

deployment_status=$?

if [ $deployment_status -eq 0 ]; then
    info_log "✓ Deployment completed successfully and backups cleaned up"
else
    error_log "✗ Deployment failed or timed out"
    
    # On failure, keep the backup for troubleshooting
    ssh "runner@$MANAGER_HOST" bash <<EOF
      if [ -f "/tmp/backup_file_name" ]; then
        backup_file=\$(cat /tmp/backup_file_name)
        echo "Deployment failed - backup file preserved: \$backup_file"
        rm -f /tmp/backup_file_name
      fi
EOF
    
    exit 1
fi
