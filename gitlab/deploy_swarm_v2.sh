#!/usr/bin/env bash
set -euo pipefail

info_log(){
    echo "[INFO $(date +%Y-%m-%d %H:%M:%S)] $1"
}

error_log() {
    echo "[ERROR $(date '+%Y-%m-%d %H:%M:%S')] $1" >&2
}

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

info_log "➤ Step 1: Checking authentication and pulling image"
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
EOF

info_log "➤ Step 3: Updating stack files"

PREV_IMAGE=$(ssh "runner@$MANAGER_HOST" bash <<EOF
  set -euo pipefail

  if [ ! -d "$REMOTE_STACK_PATH" ]; then
    echo "Stack directory not found: $REMOTE_STACK_PATH"
    exit 1
  fi

  cd "$REMOTE_STACK_PATH"
  stack_file="stack.yaml"

  if [ ! -f "\$stack_file" ]; then
    echo "Stack file not found: \$stack_file"
    exit 1
  fi

  if grep -q "^ *$PROJECT:" "\$stack_file"; then
    # Extract current image tag
    sed -n '/^ *$PROJECT:\$/,/^ *[^:]*:/ {
      /^ *image: / {
        s/^ *image: *//
        p
        q
      }
    }' "\$stack_file"
  else
    echo "Service '$PROJECT' not found in stack file"
    exit 1
  fi
EOF
)

if [ -z "$PREV_IMAGE" ]; then
    error_log "Failed to extract previous image tag"
    exit 1
fi

echo "Previous image: $PREV_IMAGE"

ssh "runner@$MANAGER_HOST" bash <<EOF
  set -euo pipefail

  cd "$REMOTE_STACK_PATH"
  stack_file="stack.yaml"

  echo "Updating service '$PROJECT' in \$stack_file"

  sed -i '/^ *$PROJECT:\$/, /^ *[^:]*:/ {
    s|^\( *image: \).*|\1$IMAGE_TAG|
  }' "\$stack_file"

  if grep -q "$IMAGE_TAG" "\$stack_file"; then
    echo "✓ Image tag updated in \$stack_file"
  else
    echo "⚠ Image tag may not have been updated"
    exit 1
  fi

  if [ -f "deploy.sh" ]; then
    bash deploy.sh
  else
    docker stack deploy "$STACK_NAME" -c "\$stack_file"
  fi
EOF

if [ $? -ne 0 ]; then
    error_log "Deployment failed"
    exit 1
fi

info_log "➤ Step 4: Verifying deployment"

deployment_success=$(ssh "runner@$MANAGER_HOST" bash <<EOF
  set -euo pipefail

  echo "Waiting for deployment to start..."
  sleep 10
  max_attempts=10
  attempt=0
  service_name="${STACK_NAME}_${PROJECT}"

  while [ \$attempt -lt \$max_attempts ]; do
    if docker service ps "\$service_name" --format '{{.CurrentState}}' 2>/dev/null | grep -q 'Running'; then
      echo "✓ Deployment verified"
      echo "true"
      exit 0
    fi
    echo "Waiting for service to be running..."
    attempt=\$((attempt + 1))
    sleep 5
  done

  echo "false"
  exit 1
EOF
)

if [ "$deployment_success" = "true" ]; then
    info_log "✓ Deployment completed successfully"
else
    error_log "✗ Deployment failed, rolling back to previous image"

    ssh "runner@$MANAGER_HOST" bash <<EOF
      set -euo pipefail
      cd "$REMOTE_STACK_PATH"
      stack_file="stack.yaml"

      sed -i '/^ *$PROJECT:\$/, /^ *[^:]*:/ {
        s|^\( *image: \).*|\1$PREV_IMAGE|
      }' "\$stack_file"

      if [ -f "deploy.sh" ]; then
        bash deploy.sh
      else
        docker stack deploy "$STACK_NAME" -c "\$stack_file"
      fi

      echo "Rolled back to previous image: $PREV_IMAGE"
EOF

    exit 1
fi
