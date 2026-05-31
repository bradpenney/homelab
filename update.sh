#!/bin/bash
set -euo pipefail

HOMELAB_DIR="/home/brad/homelab"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

log "Pulling latest Docker images..."
cd "$HOMELAB_DIR"
docker compose pull 2>&1 | grep -E "Pulling|pulled|up to date|newer"

log "Restarting containers with updated images..."
docker compose up -d

log "Running Nextcloud upgrade (no-op if version unchanged)..."
docker exec nextcloud-app php occ upgrade --no-interaction 2>&1 | grep -v "^$" || true
docker exec nextcloud-app php occ maintenance:mode --off 2>/dev/null || true

log "Pruning old images..."
docker image prune -f

log "Update complete."
