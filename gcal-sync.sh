#!/bin/bash
# Two-way sync between Google Calendar and Nextcloud Calendar.
# Run manually or via gcal-sync.timer.
set -euo pipefail

HOMELAB_DIR="$(dirname "$0")"
VENV_PYTHON="$HOMELAB_DIR/.venv/bin/python3"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

log "Starting Google Calendar <-> Nextcloud sync..."
"$VENV_PYTHON" "$HOMELAB_DIR/gcal_caldav_sync.py"
log "Sync complete."
