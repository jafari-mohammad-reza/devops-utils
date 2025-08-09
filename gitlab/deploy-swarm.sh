#!/usr/bin/env bash
set -euo pipefail

# --------- Argument parsing with env var fallback ---------
PROJECT="${1:-${PROJECT:-}}"
MANAGER_HOST="${2:-${TEST_SWARM_HOST:-${SWARM_HOST:-}}}"
STACK_NAME="${3:-${STACK_NAME:-}}"
REMOTE_STACK_PATH="${4:-${STACK_PATH:-}}"

usage() {
  echo "Usage: $0 <PROJECT> <MANAGER_HOST> <STACK_NAME> <REMOTE_STACK_PATH>" >&2
  echo "Or via env: PROJECT, TEST_SWARM_HOST|SWARM_HOST, STACK_NAME, STACK_PATH" >&2
}

[ -n "${PROJECT:-}" ] || { usage; echo "Missing PROJECT"; exit 1; }
[ -n "${MANAGER_HOST:-}" ] || { usage; echo "Missing MANAGER_HOST"; exit 1; }
[ -n "${STACK_NAME:-}" ] || { usage; echo "Missing STACK_NAME"; exit 1; }
[ -n "${REMOTE_STACK_PATH:-}" ] || { usage; echo "Missing REMOTE_STACK_PATH"; exit 1; }

log()  { printf "[%s] %s
" "$(date '+%F %T')" "$*"; }
fail() { printf "[%s] ERROR: %s
" "$(date '+%F %T')" "$*" >&2; exit 1; }

# --------- Load image tag from prep stage ---------
[ -f .built-image.txt ] || fail "'.built-image.txt' not found"
IMAGE_TAG="$(cat .built-image.txt)"
[ -n "$IMAGE_TAG" ] || fail "Image tag is empty"

log "Project: $PROJECT"
log "Manager: $MANAGER_HOST"
log "Stack:   $STACK_NAME"
log "Path:    $REMOTE_STACK_PATH"
log "Image:   $IMAGE_TAG"

SERVICE_NAME="${STACK_NAME}_${PROJECT}"

# --------- Ensure Docker auth on manager ---------
log "Syncing Docker auth to manager..."
ssh "runner@$MANAGER_HOST" "mkdir -p ~/.docker"
[ -f ~/.docker/config.json ] || fail "~/.docker/config.json not found locally. Run: docker login <registry>"
scp -q ~/.docker/config.json "runner@$MANAGER_HOST:~/.docker/config.json"

# --------- Rollback function ---------
rollback_deployment() {
  local previous_image="$1"
  log "ROLLBACK: Attempting to rollback to previous image: $previous_image"
  
  # Strip digest from image for rollback (Docker Swarm issue with digests)
  local rollback_image="${previous_image%@sha256:*}"
  log "Using image without digest for rollback: $rollback_image"
  
  ssh "runner@$MANAGER_HOST" \
    "PROJECT='$PROJECT' STACK_NAME='$STACK_NAME' REMOTE_STACK_PATH='$REMOTE_STACK_PATH' ROLLBACK_IMAGE='$rollback_image' SERVICE_NAME='$SERVICE_NAME' bash -s" <<'ROLLBACK_SSH'
set -euo pipefail

service_exists() {
  docker service inspect "$SERVICE_NAME" >/dev/null 2>&1
}

cd "$REMOTE_STACK_PATH"

if service_exists; then
  echo "Rolling back service '$SERVICE_NAME' to image: $ROLLBACK_IMAGE"
  docker service update --image "$ROLLBACK_IMAGE" "$SERVICE_NAME"
else
  echo "Service does not exist, restoring stack.yaml and redeploying..."
  if [ -f stack.yaml.backup ]; then
    cp stack.yaml.backup stack.yaml
    docker stack deploy -c stack.yaml "$STACK_NAME"
  else
    echo "No backup found, cannot rollback stack.yaml"
    exit 1
  fi
fi
ROLLBACK_SSH
}

# --------- Get previous image for rollback ---------
get_previous_image() {
  ssh "runner@$MANAGER_HOST" \
    "PROJECT='$PROJECT' REMOTE_STACK_PATH='$REMOTE_STACK_PATH' SERVICE_NAME='$SERVICE_NAME' bash -s" <<'GET_PREVIOUS_SSH'
set -euo pipefail

service_exists() {
  docker service inspect "$SERVICE_NAME" >/dev/null 2>&1
}

# Try to get current image from service
if service_exists; then
  current_image=$(docker service inspect "$SERVICE_NAME" --format '{{.Spec.TaskTemplate.ContainerSpec.Image}}' 2>/dev/null || echo "")
  # Strip digest for consistent comparison
  echo "${current_image%@sha256:*}"
else
  # Try to get from stack.yaml
  cd "$REMOTE_STACK_PATH" 2>/dev/null || { echo ""; exit 0; }
  if [ -f stack.yaml ] && command -v yq >/dev/null 2>&1; then
    yq -r ".services["$PROJECT"].image // """ stack.yaml 2>/dev/null || echo ""
  else
    echo ""
  fi
fi
GET_PREVIOUS_SSH
}

# --------- Deploy/update on manager ---------
log "Getting previous image for potential rollback..."
PREVIOUS_IMAGE=$(get_previous_image)
log "Previous image: ${PREVIOUS_IMAGE:-"none"}"

log "Deploying new image..."
if ! ssh "runner@$MANAGER_HOST" \
  "PROJECT='$PROJECT' STACK_NAME='$STACK_NAME' REMOTE_STACK_PATH='$REMOTE_STACK_PATH' IMAGE_TAG='$IMAGE_TAG' SERVICE_NAME='$SERVICE_NAME' bash -s" <<'DEPLOY_SSH'
set -euo pipefail

# Helper functions
service_exists() {
  docker service inspect "$SERVICE_NAME" >/dev/null 2>&1
}

# Pull image first
echo "Pulling image: $IMAGE_TAG"
if ! docker pull "$IMAGE_TAG"; then
  echo "Failed to pull image: $IMAGE_TAG" >&2
  exit 1
fi

# Navigate to stack directory
cd "$REMOTE_STACK_PATH"
if [ ! -f stack.yaml ]; then
  echo "stack.yaml not found in $REMOTE_STACK_PATH" >&2
  exit 1
fi

# Create backup
cp stack.yaml stack.yaml.backup

# Check for yq
if ! command -v yq >/dev/null 2>&1; then
  echo "yq not installed. Cannot update stack.yaml safely." >&2
  exit 1
fi

# Update stack.yaml
echo "Updating stack.yaml with new image: $IMAGE_TAG"
if ! yq -i ".services["$PROJECT\"].image = \"$IMAGE_TAG"" stack.yaml; then
  echo "Failed to update stack.yaml with yq" >&2
  cp stack.yaml.backup stack.yaml
  exit 1
fi

# Validate the update
img_now=$(yq -r ".services[\"$PROJECT"].image // """ stack.yaml 2>/dev/null || echo "")
if [ -z "$img_now" ] || [ "$img_now" != "$IMAGE_TAG" ]; then
  echo "Failed to set image for service '$PROJECT' in stack.yaml" >&2
  cp stack.yaml.backup stack.yaml
  exit 1
fi

echo "Stack.yaml updated successfully"

# Deploy based on service existence
if service_exists; then
  echo "Service '$SERVICE_NAME' exists. Updating image..."
  if ! docker service update --image "$IMAGE_TAG" "$SERVICE_NAME"; then
    echo "Service update failed" >&2
    exit 1
  fi
else
  echo "First deployment for '$SERVICE_NAME'. Deploying stack..."
  if ! docker stack deploy -c stack.yaml "$STACK_NAME"; then
    echo "Stack deployment failed" >&2
    exit 1
  fi
fi

echo "Deployment completed successfully"
DEPLOY_SSH
then
  log "Deployment failed!"
  if [ -n "$PREVIOUS_IMAGE" ]; then
    rollback_deployment "$PREVIOUS_IMAGE"
    fail "Deployment failed and rollback attempted"
  else
    fail "Deployment failed and no previous image available for rollback"
  fi
fi

# --------- Verify rollout ---------
log "Verifying rollout (5 attempts, 10s interval)..."
ATTEMPTS=5
SLEEP_SECS=10
ok=false

for i in $(seq 1 "$ATTEMPTS"); do
  rep=$(ssh "runner@$MANAGER_HOST" \
    "docker service ls --filter name='$SERVICE_NAME' --format '{{.Replicas}}' 2>/dev/null || echo 'NOTFOUND'")
  
  if [ "$rep" = "NOTFOUND" ]; then
    log "Service $SERVICE_NAME not found yet (attempt $i/$ATTEMPTS)"
  else
    run="${rep%/*}"
    des="${rep#*/}"
    log "Replicas: $run/$des (attempt $i/$ATTEMPTS)"
    if [ "$des" -gt 0 ] && [ "$run" -eq "$des" ]; then
      ok=true
      break
    fi
  fi
  [ "$i" -lt "$ATTEMPTS" ] && sleep "$SLEEP_SECS"
done

if [ "$ok" = true ]; then
  log "Deployment successful: all desired tasks are running."
  # Clean up backup file on success
  ssh "runner@$MANAGER_HOST" "rm -f '$REMOTE_STACK_PATH/stack.yaml.backup'" 2>/dev/null || true
  exit 0
else
  log "Deployment verification failed."
  
  # Show debugging info
  ssh "runner@$MANAGER_HOST" \
    "echo 'Service ls:' && docker service ls --filter name='$SERVICE_NAME' && echo && echo 'Service ps:' && docker service ps '$SERVICE_NAME' --no-trunc | head -20" 2>/dev/null || true
  
  # Attempt rollback
  if [ -n "$PREVIOUS_IMAGE" ]; then
    rollback_deployment "$PREVIOUS_IMAGE"
    fail "Deployment verification failed and rollback attempted"
  else
    fail "Deployment verification failed and no previous image available for rollback"
  fi
fi
