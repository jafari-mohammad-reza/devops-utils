#!/usr/bin/env bash
set -euo pipefail

REGISTRY="$1"
PROJECT="$2"

echo "➤ Remote tags from Nexus..."
TAG_LIST=$(
  curl -s -u "$NEXUS_USERNAME:$NEXUS_PASSWORD" "http://$REGISTRY/v2/$PROJECT/tags/list" \
  | jq -r '.tags? // [] | .[]' \
  | grep -E '^[0-9]+\.[0-9]+\.0$' || true
)

if [[ -z "$TAG_LIST" ]]; then
  VERSION="1.0.0"
else
  LAST_MINOR=$(echo "$TAG_LIST" | sort -V | tail -n1 | cut -d. -f2)
  NEXT_MINOR=$((LAST_MINOR + 1))
  VERSION="1.${NEXT_MINOR}.0"
fi

IMAGE_TAG="${REGISTRY}/${PROJECT}:${VERSION}"

echo "➤ Building image: $IMAGE_TAG"
docker build -t "$IMAGE_TAG" .
docker push "$IMAGE_TAG"

echo "$IMAGE_TAG" > .built-image.txt
echo "✓ Done. Version: $VERSION"
