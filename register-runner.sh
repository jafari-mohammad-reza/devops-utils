#!/bin/bash

PROJECT_NAME=$1
GITLAB_URL=$2
REGISTRATION_TOKEN=$3

if [ -z "$PROJECT_NAME" ] || [ -z "$GITLAB_URL" ] || [ -z "$REGISTRATION_TOKEN" ]; then
  echo "Usage: ./register-runner.sh <project-name> <gitlab-url> <registration-token>"
  exit 1
fi

# Absolute paths
DOCKER_CONFIG_PATH="$HOME/.docker/config.json"
SSH_KEY_PATH="$HOME/.ssh"

# Base docker command
DOCKER_CMD="docker run --rm -t"

# Always mount the Docker socket and config directory
DOCKER_CMD+=" -v /var/run/docker.sock:/var/run/docker.sock"
DOCKER_CMD+=" -v $(pwd)/config:/etc/gitlab-runner"

# Conditionally mount Docker config
if [ -f "$DOCKER_CONFIG_PATH" ]; then
  echo "✓ Mounting Docker config: $DOCKER_CONFIG_PATH"
  DOCKER_CMD+=" -v $DOCKER_CONFIG_PATH:/root/.docker/config.json:ro"
else
  echo "⚠️  Skipping Docker config mount (not found at $DOCKER_CONFIG_PATH)"
fi

# Conditionally mount SSH keys
if [ -d "$SSH_KEY_PATH" ]; then
  echo "✓ Mounting SSH keys: $SSH_KEY_PATH"
  DOCKER_CMD+=" -v $SSH_KEY_PATH:/root/.ssh:ro"
else
  echo "⚠️  Skipping SSH key mount (not found at $SSH_KEY_PATH)"
fi

# Finish command
DOCKER_CMD+=" gitlab/gitlab-runner:alpine register"
DOCKER_CMD+=" --non-interactive"
DOCKER_CMD+=" --docker-helper-image 2.189.5.183:9099/gitlab-runner-helper:x86_64-v18.1.1"
DOCKER_CMD+=" --executor docker"
DOCKER_CMD+=" --docker-pull-policy if-not-present"
DOCKER_CMD+=" --docker-image docker:20.10.16"
DOCKER_CMD+=" --url $GITLAB_URL"
DOCKER_CMD+=" --registration-token $REGISTRATION_TOKEN"
DOCKER_CMD+=" --description $PROJECT_NAME-runner"
DOCKER_CMD+=" --tag-list $PROJECT_NAME"
DOCKER_CMD+=" --run-untagged=false"
DOCKER_CMD+=" --locked=true"

# Run it
echo "🚀 Registering runner..."
eval "$DOCKER_CMD"

echo "[✓] Runner registered for $PROJECT_NAME"
