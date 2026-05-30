#!/bin/bash
# Sync Garmin Connect activities to Wanderer. Run manually or via garmin-sync.timer.
set -euo pipefail

HOMELAB_DIR="$(dirname "$0")"
VENV_PYTHON="$HOMELAB_DIR/.venv/bin/python3"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

log "Starting Garmin → Wanderer sync..."
"$VENV_PYTHON" "$HOMELAB_DIR/garmin_sync.py"
log "Sync complete."
