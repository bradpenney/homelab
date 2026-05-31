#!/bin/bash
set -euo pipefail

HOMELAB_DIR="/home/brad/homelab"
RCLONE_CONFIG="/home/brad/.config/rclone/rclone.conf"
ENV_FILE="${HOMELAB_DIR}/.env"
DUMP_FILE="/tmp/nextcloud-db-$(date +%Y-%m-%d).sql.gz"
BACKUP_DIR="nextcloud-crypt:old-versions"

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
  nextcloud | gzip > "$DUMP_FILE"

log "Disabling maintenance mode..."
docker exec nextcloud-app php occ maintenance:mode --off

trap 'rm -f "$DUMP_FILE"' EXIT

log "Uploading database dump..."
DUMP_NAME="nextcloud-dump-$(date +%Y-%m-%d).sql.gz"
rclone --config "$RCLONE_CONFIG" copyto "$DUMP_FILE" "nextcloud-crypt:db/${DUMP_NAME}"

log "Pruning old dumps (keeping 7 days)..."
rclone --config "$RCLONE_CONFIG" ls nextcloud-crypt:db \
  | awk '{print $2}' \
  | sort \
  | head -n -7 \
  | xargs -I{} rclone --config "$RCLONE_CONFIG" deletefile "nextcloud-crypt:db/{}" 2>/dev/null || true

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

log "Backing up Wanderer database (brief stop for SQLite consistency)..."
docker stop wanderer-db
cp "${HOMELAB_DIR}/wanderer-db/data.db" /tmp/wanderer-data.db
cp "${HOMELAB_DIR}/wanderer-db/data.db-wal" /tmp/wanderer-data.db-wal 2>/dev/null || true
docker start wanderer-db

rclone --config "$RCLONE_CONFIG" copyto /tmp/wanderer-data.db "nextcloud-crypt:wanderer-db/data.db"
rclone --config "$RCLONE_CONFIG" copyto /tmp/wanderer-data.db-wal "nextcloud-crypt:wanderer-db/data.db-wal" 2>/dev/null || true
rm -f /tmp/wanderer-data.db /tmp/wanderer-data.db-wal

log "Syncing Wanderer file storage (photos, GPX — safe while running)..."
rclone --config "$RCLONE_CONFIG" sync \
  "${HOMELAB_DIR}/wanderer-db/storage" \
  "nextcloud-crypt:wanderer-db/storage"

log "Syncing Wanderer uploads..."
rclone --config "$RCLONE_CONFIG" sync \
  "${HOMELAB_DIR}/wanderer-uploads" \
  "nextcloud-crypt:wanderer-uploads"

log "Backing up Garmin sync state..."
rclone --config "$RCLONE_CONFIG" copyto \
  "${HOMELAB_DIR}/garmin-sync-state.json" \
  "nextcloud-crypt:garmin-sync-state.json" 2>/dev/null || true

log "Backing up Claude workspace files..."
rclone --config "$RCLONE_CONFIG" copyto \
  "/home/brad/notes/CLAUDE.md" \
  "nextcloud-crypt:claude/CLAUDE.md"
rclone --config "$RCLONE_CONFIG" copyto \
  "/home/brad/notes/.claude/settings.local.json" \
  "nextcloud-crypt:claude/settings.local.json"
rclone --config "$RCLONE_CONFIG" copyto \
  "/home/brad/notes/credentials.json" \
  "nextcloud-crypt:claude/gcal-credentials.json"
rclone --config "$RCLONE_CONFIG" sync \
  "/home/brad/.claude/projects/-home-brad-notes/memory" \
  "nextcloud-crypt:claude/memory"

log "Backing up homelab secrets..."
rclone --config "$RCLONE_CONFIG" copyto \
  "${HOMELAB_DIR}/.env" \
  "nextcloud-crypt:homelab/dot-env"

log "Backup complete."
