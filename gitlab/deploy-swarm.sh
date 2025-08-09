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

info_log "➤ Step 2: Pulling image and updating stack files"

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
    backup_file="\$stack_file.backup.\$(date +%Y%m%d_%H%M%S)"
    cp "\$stack_file" "\$backup_file"
    echo "\$backup_file" > /tmp/backup_file_name
    echo "Backup created: \$backup_file"

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
    chmod +x deploy.sh || true
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
    cd "$REMOTE_STACK_PATH"
    if [ -f "/tmp/backup_file_name" ]; then
      backup_file=$(cat /tmp/backup_file_name)
      echo "Cleaning up backup: $backup_file"
      rm -f "$backup_file" /tmp/backup_file_name || true
    fi

    count=$(ls stack.yaml.backup.* 2>/dev/null | wc -l || echo "0")
    if [ "$count" -gt 3 ]; then
      echo "Cleaning up old backups..."
      ls -1t stack.yaml.backup.* | tail -n +4 | xargs rm -f || true
    fi

    exit 0
  else
    echo "✗ Deployment failed after $((max_attempts * 5)) seconds"
    docker service ps "$service_name" --no-trunc | head -10
    exit 1
  fi
EOF

deployment_status=$?

if [ $deployment_status -eq 0 ]; then
  info_log "✓ Deployment completed successfully and backups cleaned up"
else
  error_log "✗ Deployment failed or timed out"
  ssh "runner@$MANAGER_HOST" bash <<'EOF'
    if [ -f "/tmp/backup_file_name" ]; then
      echo "Preserving backup after failure:"
      cat /tmp/backup_file_name
      rm -f /tmp/backup_file_name
    fi
EOF
  exit 1
fi
