#!/bin/bash
set -euo pipefail

HOMELAB_DIR="/home/brad/homelab"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

cd "$HOMELAB_DIR"

# `network-online.target` means an interface is configured, NOT that name
# resolution works. On 2026-08-27 and 2026-08-28 this ran ~15s after a reboot
# and every pull died with:
#     dial tcp: lookup registry-1.docker.io: no such host
# while systemd-resolved's stub (127.0.0.53) was still timing out. Wait for a
# resolver that actually answers before deciding anything is wrong.
log "Waiting for DNS to resolve the registry..."
for _ in $(seq 1 30); do
    if getent hosts registry-1.docker.io >/dev/null 2>&1; then
        break
    fi
    sleep 2
done
if ! getent hosts registry-1.docker.io >/dev/null 2>&1; then
    log "ERROR: registry-1.docker.io still unresolvable after 60s - aborting."
    exit 1
fi

log "Pulling latest Docker images..."
# Filter for display, but keep the full output: piping straight into grep
# discarded the one line that said WHY the pull failed, so the alert arrived
# with no cause attached and the unit journal showed only "Pulling".
pull_log=$(mktemp)
if docker compose pull >"$pull_log" 2>&1; then
    grep -E "Pulling|pulled|up to date|newer" "$pull_log" || true
    rm -f "$pull_log"
else
    rc=$?
    log "ERROR: 'docker compose pull' exited $rc. Full output follows:"
    cat "$pull_log"
    rm -f "$pull_log"
    exit "$rc"
fi

log "Restarting containers with updated images..."
docker compose up -d

log "Running Nextcloud upgrade (no-op if version unchanged)..."
docker exec nextcloud-app php occ upgrade --no-interaction 2>&1 | grep -v "^$" || true
docker exec nextcloud-app php occ maintenance:mode --off 2>/dev/null || true

log "Pruning old images..."
docker image prune -f

log "Update complete."
