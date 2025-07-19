#!/usr/bin/env bash
set -euo pipefail

MANAGER_HOST="$1"

mkdir -p ~/.ssh
echo "$SSH_PRIVATE_KEY" > ~/.ssh/id_rsa
chmod 600 ~/.ssh/id_rsa

# Add the manager to known hosts to avoid host authenticity prompts
ssh-keyscan -H "$MANAGER_HOST" >> ~/.ssh/known_hosts

echo "✓ SSH setup complete for $MANAGER_HOST"
