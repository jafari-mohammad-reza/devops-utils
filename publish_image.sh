#!/usr/bin/env bash
set -euo pipefail

REGISTRY="$1"
PROJECT="$2"

mkdir -p "${PNPM_CACHE_DIR:?Need PNPM_CACHE_DIR set}/.pnpm-store"

echo "➤ Remote tags from Nexus..."
TAG_LIST=$(
  curl -s -u "$NEXUS_USERNAME:$NEXUS_PASSWORD" \
    "http://${REGISTRY}/v2/${PROJECT}/tags/list" \
  | jq -r '.tags? // [] | .[]' \
  | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' || true
)

if [[ -z "$TAG_LIST" ]]; then
  echo "⚡️ No existing tags, starting at 1.0.0"
  VERSION="1.0.0"
else
  LATEST_TAG=$(echo "$TAG_LIST" | sort -V | tail -n1)
  MAJOR=$(cut -d. -f1 <<<"$LATEST_TAG")
  MINOR=$(cut -d. -f2 <<<"$LATEST_TAG")
  PATCH=$(cut -d. -f3 <<<"$LATEST_TAG")

  
  BRANCH="${CI_COMMIT_BRANCH:-$(git rev-parse --abbrev-ref HEAD)}"
  if [[ "$BRANCH" == "main" || "$BRANCH" == "master" ]]; then
    NEXT_MINOR=$((MINOR + 1))
    VERSION="${MAJOR}.${NEXT_MINOR}.0"
    echo "🔖 On '$BRANCH', bumping minor → $VERSION"
  else
    NEXT_PATCH=$((PATCH + 1))
    VERSION="${MAJOR}.${MINOR}.${NEXT_PATCH}"
    echo "🔖 On branch '$BRANCH', bumping patch → $VERSION"
  fi
fi

IMAGE_TAG="${REGISTRY}/${PROJECT}:${VERSION}"

echo "➤ Building image: $IMAGE_TAG"
docker build -t "$IMAGE_TAG" .
docker push "$IMAGE_TAG"

echo "$IMAGE_TAG" > .built-image.txt
echo "✓ Done. Version: $VERSION"
