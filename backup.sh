#!/bin/bash
set -euo pipefail

HOMELAB_DIR="/home/brad/homelab"
RCLONE_CONFIG="/home/brad/.config/rclone/rclone.conf"
ENV_FILE="${HOMELAB_DIR}/.env"
DUMP_FILE="/tmp/nextcloud-db-$(date +%Y-%m-%d).sql.gz"
BACKUP_DIR="nextcloud-crypt:old-versions"

source "$ENV_FILE"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# ---------------------------------------------------------------------------
# GUARDED SYNC — added 2026-08-25 after discovering this script had been
# faithfully backing up an empty directory for months.
#
# The `vault` sync pointed at /home/brad/notes/vault. The real content had moved
# to ~/Documents/notes, leaving 167 bytes behind. `rclone sync` of an empty
# source SUCCEEDS PERFECTLY — it simply mirrors emptiness — so the nightly job
# reported success every night while protecting nothing. 836 MB of notes were
# unprotected and nobody could have known from the job's output.
#
# Two independent protections, because they catch different failures:
#
#   1. REFUSE an absent or empty source. Catches a path that was renamed,
#      deleted, or whose mount did not come up.
#   2. --max-delete. Catches a source that is present but has lost most of its
#      contents; rclone aborts rather than propagating mass deletion to the
#      only remaining copy.
#
# ⚠️ After a DELIBERATE mass deletion (e.g. emptying the Nextcloud trash),
#    the next run trips protection 2 — which is correct. Override once with:
#        MAX_DELETE=99999 /home/brad/homelab/backup.sh
#
# Failures are recorded and the script continues, so one bad source does not
# skip every later backup. The exit status is non-zero so systemd still shows
# the run as failed.
MAX_DELETE="${MAX_DELETE:-500}"
FAILURES=0

sync_guarded() {
    local src="$1" dst="$2"
    shift 2
    if [[ ! -e "$src" ]]; then
        log "ERROR: source does not exist, REFUSING to sync: $src"
        FAILURES=$((FAILURES + 1))
        return 0
    fi
    if [[ -d "$src" ]] && [[ -z "$(find "$src" -mindepth 1 -print -quit 2>/dev/null)" ]]; then
        log "ERROR: source is EMPTY, REFUSING to sync (would mirror emptiness): $src"
        FAILURES=$((FAILURES + 1))
        return 0
    fi
    if ! rclone --config "$RCLONE_CONFIG" sync "$src" "$dst" \
            --max-delete "$MAX_DELETE" "$@"; then
        log "ERROR: sync FAILED (or hit --max-delete=$MAX_DELETE): $src -> $dst"
        FAILURES=$((FAILURES + 1))
    fi
    return 0
}
# ---------------------------------------------------------------------------


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
sync_guarded "${HOMELAB_DIR}/nextcloud-data" "nextcloud-crypt:data" \
  --exclude "*.part"

log "Syncing config directory..."
sync_guarded "${HOMELAB_DIR}/nextcloud-config/config" "nextcloud-crypt:config"

log "Syncing custom apps..."
sync_guarded "${HOMELAB_DIR}/nextcloud-config/custom_apps" "nextcloud-crypt:custom_apps"

log "Backing up Home Assistant (brief stop for SQLite consistency)..."
docker stop homeassistant
sync_guarded "${HOMELAB_DIR}/hass-config" "nextcloud-crypt:hass-config" \
  --exclude "home-assistant.log*" \
  --exclude "deps/**" \
  --exclude "tts/**"
docker start homeassistant

log "Backing up Wanderer database (brief stop for SQLite consistency)..."
docker stop wanderer-db
cp "${HOMELAB_DIR}/wanderer-db/data.db" /tmp/wanderer-data.db
cp "${HOMELAB_DIR}/wanderer-db/data.db-wal" /tmp/wanderer-data.db-wal 2>/dev/null || true
docker start wanderer-db

rclone --config "$RCLONE_CONFIG" copyto /tmp/wanderer-data.db "nextcloud-crypt:wanderer-db/data.db"
rclone --config "$RCLONE_CONFIG" copyto /tmp/wanderer-data.db-wal "nextcloud-crypt:wanderer-db/data.db-wal" 2>/dev/null || true
rm -f /tmp/wanderer-data.db /tmp/wanderer-data.db-wal

log "Syncing Wanderer file storage (photos, GPX — safe while running)..."
sync_guarded "${HOMELAB_DIR}/wanderer-db/storage" "nextcloud-crypt:wanderer-db/storage"

log "Syncing Wanderer uploads..."
# wanderer-uploads is NOT backed up, deliberately.
#
# It is bind-mounted to /app/uploads in the wanderer container, but Wanderer
# never persists anything there -- uploads are processed straight into
# PocketBase storage, which IS backed up above as wanderer-db/storage (515MB,
# 112 photos and GPX files). The directory has been empty since it was created
# and the remote copy has never existed: `rclone size` on it returns
# "directory not found".
#
# Backing it up was speculative when this line was written. On 2026-08-26 the
# empty-source guard correctly refused it and failed the whole run, which is the
# guard working -- but the right fix is to stop asking for something that was
# never meaningful, rather than to weaken the guard.
#
# The check below turns that assumption into an assertion: if the directory ever
# DOES fill up, Wanderer's behaviour has changed and this decision needs
# revisiting. It warns rather than failing, because content appearing here is a
# reason to look, not a reason to declare the backup broken.
if [ -d "${HOMELAB_DIR}/wanderer-uploads" ] && [ -n "$(ls -A "${HOMELAB_DIR}/wanderer-uploads" 2>/dev/null)" ]; then
  log "NOTICE: wanderer-uploads is no longer empty. Wanderer may have changed"
  log "        where it stores files -- check whether it now needs backing up."
fi

log "Backing up Donetick database (brief stop for SQLite consistency)..."
docker stop donetick
cp "${HOMELAB_DIR}/donetick-data/donetick.db" /tmp/donetick-data.db
cp "${HOMELAB_DIR}/donetick-data/donetick.db-wal" /tmp/donetick-data.db-wal 2>/dev/null || true
docker start donetick

rclone --config "$RCLONE_CONFIG" copyto /tmp/donetick-data.db "nextcloud-crypt:donetick-db/data.db"
rclone --config "$RCLONE_CONFIG" copyto /tmp/donetick-data.db-wal "nextcloud-crypt:donetick-db/data.db-wal" 2>/dev/null || true
rm -f /tmp/donetick-data.db /tmp/donetick-data.db-wal

log "Backing up Garmin sync state..."
rclone --config "$RCLONE_CONFIG" copyto \
  "${HOMELAB_DIR}/garmin-sync-state.json" \
  "nextcloud-crypt:garmin-sync-state.json" 2>/dev/null || true

# The ACTUAL notes tree. Added 2026-08-25 — 836 MB of slip-box (Zettelkasten)
# had no backup anywhere: not in Nextcloud, not here, no sync client. Its only
# second copy was a 3-month-old snapshot sitting in the Nextcloud trash, which
# was very nearly purged for taking up space.
log "Syncing notes (slip-box, gtd)..."
sync_guarded \
  "/home/brad/Documents/notes" \
  "nextcloud-crypt:notes"

# Kept for the Claude workspace scratch vault, which is legitimately tiny.
# NOT the second brain — see above. The two were confused for months.
log "Syncing Claude workspace vault..."
sync_guarded "/home/brad/notes/vault" "nextcloud-crypt:vault"

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
sync_guarded "/home/brad/.claude/projects/-home-brad-notes/memory" "nextcloud-crypt:claude/memory"

log "Backing up homelab secrets..."
rclone --config "$RCLONE_CONFIG" copyto \
  "${HOMELAB_DIR}/.env" \
  "nextcloud-crypt:homelab/dot-env"

# k0s cluster site configuration. Deliberately gitignored (it holds the LAN
# addresses, admin username and storage layout, so the substrate repo can
# be published without them) — which makes it the one file needed to rebuild
# the cluster that version control does NOT protect. Everything else in that
# repo is recoverable from GitHub; this isn't.
log "Backing up k0s cluster site config..."
rclone --config "$RCLONE_CONFIG" copyto \
  "/home/brad/notes/source_code/substrate/site.yml" \
  "nextcloud-crypt:homelab/k0s-site.yml"

# Traefik dynamic configuration. Gitignored because this repository is PUBLIC
# and these files describe the ingress topology — which host fronts the cluster,
# on which LAN address, and which hostnames are proxied.
#
# One of them is a SECURITY CONTROL: k8s-passthrough.yml carries the
# Cloudflare-only allowlist that makes proxying the public site meaningful
# (ADR-070). Without it, anyone who learns the origin address can connect
# straight past Cloudflare — and the loss would be silent, because the site
# keeps working perfectly for everyone else.
#
# acme.json is deliberately NOT backed up: it is key material, and certificates
# re-issue automatically from Let's Encrypt on a rebuild. Configuration cannot
# be regenerated; certificates can.
log "Backing up Traefik dynamic config (gitignored, holds the origin lock)..."
sync_guarded "${HOMELAB_DIR}/traefik-data/dynamic" "nextcloud-crypt:homelab/traefik-dynamic"

if (( FAILURES > 0 )); then
    log "Backup finished with $FAILURES FAILED source(s) — see ERROR lines above."
    log "A refused source means it was missing or empty; the remote copy was left"
    log "untouched rather than being overwritten with nothing."
    exit 1
fi
log "Backup complete."
