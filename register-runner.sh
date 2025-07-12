# register-runner.sh
#!/bin/bash

PROJECT_NAME=$1          
GITLAB_URL=$2            
REGISTRATION_TOKEN=$3    

if [ -z "$PROJECT_NAME" ] || [ -z "$GITLAB_URL" ] || [ -z "$REGISTRATION_TOKEN" ]; then
  echo "Usage: ./register-runner.sh <project-name> <gitlab-url> <registration-token>"
  exit 1
fi

docker run --rm -t \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$(pwd)/config:/etc/gitlab-runner" \
  gitlab/gitlab-runner:alpine register \
  --non-interactive \
  --docker-helper-image registry-helper-image  \
  --executor "docker" \
  --docker-pull-policy "if-not-present" \
  --docker-image "docker:20.10.16" \
  --url "$GITLAB_URL" \
  --registration-token "$REGISTRATION_TOKEN" \
  --description "$PROJECT_NAME-runner" \
  --tag-list "$PROJECT_NAME" \
  --run-untagged="false" \
  --locked="true"

echo "[+] Runner registered for $PROJECT_NAME"
