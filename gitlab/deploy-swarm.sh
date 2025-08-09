#!/usr/bin/env bash
set -euo pipefail

# --------- Argument parsing with env var fallback ---------
PROJECT="${1:-${PROJECT:-}}"
MANAGER_HOST="${2:-${TEST_SWARM_HOST:-${SWARM_HOST:-}}}"
STACK_NAME="${3:-${STACK_NAME:-}}"
REMOTE_STACK_PATH="${4:-${STACK_PATH:-}}"

usage() {
  echo "Usage: $0 <PROJECT> <MANAGER_HOST> <STACK_NAME> <REMOTE_STACK_PATH>" >&2
  echo "Or provide via env: PROJECT, TEST_SWARM_HOST|SWARM_HOST, STACK_NAME, STACK_PATH" >&2
}

[ -n "${PROJECT:-}" ] || { usage; echo "Missing PROJECT"; exit 1; }
[ -n "${MANAGER_HOST:-}" ] || { usage; echo "Missing MANAGER_HOST"; exit 1; }
[ -n "${STACK_NAME:-}" ] || { usage; echo "Missing STACK_NAME"; exit 1; }
[ -n "${REMOTE_STACK_PATH:-}" ] || { usage; echo "Missing REMOTE_STACK_PATH"; exit 1; }

log()  { printf "[%s] %s\n" "$(date '+%F %T')" "$*"; }
fail() { printf "[%s] ERROR: %s\n" "$(date '+%F %T')" "$*" >&2; exit 1; }

# --------- Load image tag from prep stage ---------
[ -f .built-image.txt ] || fail "'.built-image.txt' not found"
IMAGE_TAG="$(cat .built-image.txt)"
[ -n "$IMAGE_TAG" ] || fail "Image tag is empty"

log "Project: $PROJECT"
log "Manager: $MANAGER_HOST"
log "Stack:   $STACK_NAME"
log "Path:    $REMOTE_STACK_PATH"
log "Image:   $IMAGE_TAG"

# --------- Ensure Docker auth on manager ---------
log "Syncing Docker auth to manager..."
ssh "runner@$MANAGER_HOST" "mkdir -p ~/.docker"
[ -f ~/.docker/config.json ] || fail "~/.docker/config.json not found locally. Run: docker login <registry>"
scp -q ~/.docker/config.json "runner@$MANAGER_HOST:~/.docker/config.json"

# --------- Deploy on manager ---------
log "Deploying service on manager..."
ssh "runner@$MANAGER_HOST" \
  "PROJECT='$PROJECT' STACK_NAME='$STACK_NAME' REMOTE_STACK_PATH='$REMOTE_STACK_PATH' IMAGE_TAG='$IMAGE_TAG' bash -s" <<'EOSSH'
set -euo pipefail

cd "$REMOTE_STACK_PATH"
[ -f stack.yaml ] || { echo "stack.yaml not found in $REMOTE_STACK_PATH" >&2; exit 1; }

echo "Pulling image: $IMAGE_TAG"
docker pull "$IMAGE_TAG" >/dev/null

tmpfile="$(mktemp)"
cp stack.yaml "${tmpfile}.bak"

# Replace the image line inside the PROJECT service block
sed -E "/^[[:space:]]*${PROJECT}:[[:space:]]*$/, /^[^[:space:]].*:/ s|^([[:space:]]*image:[[:space:]]*).*|\1${IMAGE_TAG}|" stack.yaml > "$tmpfile"

# Verify change
if ! grep -A 10 -E "^[[:space:]]*${PROJECT}:[[:space:]]*$" "$tmpfile" | grep -q -E "image:[[:space:]]*${IMAGE_TAG}"; then
  echo "Failed to update image for '${PROJECT}'" >&2
  exit 1
fi

mv "$tmpfile" stack.yaml
echo "Stack file updated."

echo "Deploying stack '$STACK_NAME'..."
docker stack deploy -c stack.yaml "$STACK_NAME" >/dev/null
sleep 3
EOSSH

# --------- Verify rollout ---------
log "Verifying rollout (5 attempts, 10s interval)..."
SERVICE_NAME="${STACK_NAME}_${PROJECT}"
ATTEMPTS=5
SLEEP_SECS=10
ok=false

check_status() {
  ssh "runner@$MANAGER_HOST" \
    "SERVICE_NAME='$SERVICE_NAME' bash -s" <<'EOF'
set -euo pipefail
name="$SERVICE_NAME"
rep=$(docker service ls --filter name="$name" --format '{{.Replicas}}' 2>/dev/null || true)
[ -n "$rep" ] || { echo "NOTFOUND"; exit 0; }
echo "$rep"
EOF
}

for i in $(seq 1 "$ATTEMPTS"); do
  rep="$(check_status)"
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
  exit 0
else
  log "Deployment did not reach running state."
  ssh "runner@$MANAGER_HOST" \
    "SERVICE_NAME='$SERVICE_NAME' bash -s" <<'EOF' || true
set -euo pipefail
name="$SERVICE_NAME"
echo "Service ls:"
docker service ls --filter name="$name" || true
echo
echo "Service ps (top 20):"
docker service ps "$name" --no-trunc | head -20 || true
EOF
  exit 1
fi
