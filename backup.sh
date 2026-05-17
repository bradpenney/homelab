#!/bin/bash
set -euo pipefail

HOMELAB_DIR="/home/brad/homelab"
RCLONE_CONFIG="/home/brad/.config/rclone/rclone.conf"
ENV_FILE="${HOMELAB_DIR}/.env"
DUMP_FILE="/tmp/nextcloud-db-$(date +%Y-%m-%d).sql"

source "$ENV_FILE"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

log "Starting Nextcloud backup..."

# Maintenance mode only covers the DB dump for consistency
log "Enabling maintenance mode..."
docker exec nextcloud-app php occ maintenance:mode --on

# Database dump
log "Dumping database..."
docker exec nextcloud-db mariadb-dump \
  -u nextcloud \
  -p"${MYSQL_PASSWORD}" \
  nextcloud > "$DUMP_FILE"

log "Disabling maintenance mode..."
docker exec nextcloud-app php occ maintenance:mode --off

trap 'rm -f "$DUMP_FILE"' EXIT

log "Uploading database dump..."
rclone --config "$RCLONE_CONFIG" copyto "$DUMP_FILE" "nextcloud-crypt:db/nextcloud-dump.sql"

log "Syncing data directory..."
rclone --config "$RCLONE_CONFIG" sync \
  "${HOMELAB_DIR}/nextcloud-data" \
  "nextcloud-crypt:data" \
  --exclude "*.part"

log "Syncing config directory..."
rclone --config "$RCLONE_CONFIG" sync \
  "${HOMELAB_DIR}/nextcloud-config/config" \
  "nextcloud-crypt:config"

log "Syncing custom apps..."
rclone --config "$RCLONE_CONFIG" sync \
  "${HOMELAB_DIR}/nextcloud-config/custom_apps" \
  "nextcloud-crypt:custom_apps"

log "Backup complete."
