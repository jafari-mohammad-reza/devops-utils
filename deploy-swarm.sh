#!/bin/bash
set -e

STACK_NAME=$(basename "$PWD")
DIR=$(pwd)
CONFIG_FILE="$DIR/config.yaml"
STACK_FILE="$DIR/stack.yaml" # change this to you docker stack file name

echo "[+] Loading secrets from $CONFIG_FILE..."

while IFS=":" read -r name path; do
  name=$(echo "$name" | xargs)
  path=$(echo "$path" | xargs)

  if [[ -z "$name" || -z "$path" ]]; then
    continue  # skip empty lines
  fi

  full_path="$DIR/$path"

  if [[ ! -f "$full_path" ]]; then
    echo "[!] Secret file not found: $full_path"
    exit 1
  fi

  if docker secret ls --format '{{.Name}}' | grep -q "^$name$"; then
    echo "[-] Secret '$name' already exists, skipping."
  else
    echo "[+] Creating Docker secret '$name' from $path"
    docker secret create "$name" "$full_path"
  fi
done < "$CONFIG_FILE"

echo "[+] Deploying stack '$STACK_NAME' using $STACK_FILE"
docker stack deploy -c "$STACK_FILE" "$STACK_NAME"
