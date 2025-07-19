#!/usr/bin/env bash
set -euo pipefail

STACK_NAME="$1"         # e.g. iri
MANAGER_HOST="$2"       # e.g. 10.202.18.29
SERVICE_NAME="$3"       # e.g. iri-back
REMOTE_STACK_PATH="$4"  # e.g. /opt/stacks/stack.yaml

IMAGE_TAG=$(cat .built-image.txt)

echo "➤ Updating service '$SERVICE_NAME' image to '$IMAGE_TAG' in $REMOTE_STACK_PATH on $MANAGER_HOST"

ssh "docker@$MANAGER_HOST" bash <<EOF
  set -euo pipefail
  sed -i '/^ *$SERVICE_NAME:$/, /^ *[^:]*:/ {
    s|^\( *image: \).*|\1$IMAGE_TAG|
  }' "$REMOTE_STACK_PATH"
EOF

echo "➤ Deploying stack '$STACK_NAME' on $MANAGER_HOST"
ssh "docker@$MANAGER_HOST" "docker stack deploy -c '$REMOTE_STACK_PATH' $STACK_NAME"

echo "➤ Watching rollout status..."
ssh "docker@$MANAGER_HOST" <<'EOF'
  sleep 5
  while true; do
    status=$(docker service ls --format '{{.Name}} {{.UpdateStatus}}' | awk '{print $2}')
    case "$status" in
      completed) echo "✓ Deploy complete"; exit 0 ;;
      rollback_completed|paused|rollback_paused)
        echo "✗ Rollback or failure detected"; exit 1 ;;
      *) sleep 5 ;;
    esac
  done
EOF
