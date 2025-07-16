#!/usr/bin/env bash

set -euo pipefail

STACK_FILE=$1
BASE=$2
SRC=$3
STACK=$4

latest=$(docker config ls --format '{{.Name}}' | grep -E "^${BASE}(_v[0-9]+)?$" | sort -V | tail -n1 || true)
if [[ $latest =~ _v([0-9]+)$ ]]; then
  ver=$((BASH_REMATCH[1] + 1))
else
  ver=1
fi
NEW="${BASE}_v${ver}"
docker config create "$NEW" "$SRC"

backup="${STACK_FILE}.bak.$(date +%s)"
cp "$STACK_FILE" "$backup"

tmp=$(mktemp)
awk -v base="$BASE" -v new="$NEW" '
  BEGIN { in_configs = 0 }
  /^[[:space:]]*configs:/     { in_configs = 1; print; next }
  /^[^[:space:]]/             { in_configs = 0 }

  in_configs && $0 ~ "^[[:space:]]+"base":" {
    sub(base ":", new ":")
  }

  $0 ~ "source:[[:space:]]*"base"$" {
    sub("source:[[:space:]]*"base, "source: " new)
  }

  { print }
' "$backup" > "$tmp"
mv "$tmp" "$STACK_FILE"

if docker stack deploy -c "$STACK_FILE" "$STACK"; then
  rm -f "$backup"
else
  mv "$backup" "$STACK_FILE"
  echo "deployment failed — stack file restored"
  exit 1
fi
