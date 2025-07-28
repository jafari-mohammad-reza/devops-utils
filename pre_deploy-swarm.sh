#!/usr/bin/env bash
set -euo pipefail

# Enable debug logging
DEBUG=${DEBUG:-false}
debug_log() {
    if [ "$DEBUG" = "true" ]; then
        echo "[DEBUG $(date '+%Y-%m-%d %H:%M:%S')] $1"
    fi
}

info_log() {
    echo "[INFO $(date '+%Y-%m-%d %H:%M:%S')] $1"
}

error_log() {
    echo "[ERROR $(date '+%Y-%m-%d %H:%M:%S')] $1" >&2
}

MANAGER_HOST="$1"

info_log "Setting up SSH for deployment to $MANAGER_HOST"

# Ensure SSH directory exists
mkdir -p ~/.ssh
chmod 700 ~/.ssh

debug_log "SSH directory created/verified"

# Verify private key is available
if [ ! -f ~/.ssh/id_rsa ]; then
    error_log "Private key not found at ~/.ssh/id_rsa"
    exit 1
fi

# Ensure correct permissions
chmod 600 ~/.ssh/id_rsa
debug_log "Private key permissions set to 600"

chown root:root ~/.ssh/config
# Test if key is valid
if ! ssh-keygen -l -f ~/.ssh/id_rsa >/dev/null 2>&1; then
    error_log "Invalid private key format"
    exit 1
fi

debug_log "Private key validation passed"

# Add the manager to known hosts to avoid host authenticity prompts
info_log "Adding $MANAGER_HOST to known hosts"
if ! ssh-keyscan -H "$MANAGER_HOST" >> ~/.ssh/known_hosts 2>/dev/null; then
    error_log "Failed to add $MANAGER_HOST to known hosts"
    exit 1
fi

debug_log "Known hosts updated"

# Test SSH connection
info_log "Testing SSH connection to runner@$MANAGER_HOST"
if ssh -o ConnectTimeout=10 -o BatchMode=yes "runner@$MANAGER_HOST" "echo 'SSH connection successful'" >/dev/null 2>&1; then
    info_log "✓ SSH setup complete for $MANAGER_HOST"
else
    error_log "✗ SSH connection test failed"
    exit 1
fi
