#!/usr/bin/env bash
#
# Dynamic DNS for nextcloud.bradpenney.io -> this host's public IP.
#
# REWRITTEN 2026-08-25 for CLOUDFLARE. It previously targeted api.vercel.com,
# which stopped being authoritative when DNS migrated to Cloudflare (ADR-037).
# The old version kept running and kept reporting success while updating a zone
# nobody queries — so the authoritative record silently froze at whatever value
# the migration set. A public IP change would have taken Nextcloud offline with
# no warning and a green systemd unit.
#
# TWO DESIGN CHANGES FROM THE VERCEL VERSION:
#
#   1. NO IP CACHE FILE. The old script compared the current IP against a cached
#      value and exited early if unchanged. That means it only ever fixed drift
#      it caused itself: if the DNS record were changed, deleted, or restored
#      from a stale backup, the cache would still match and the script would
#      never correct it. Now it reads the ACTUAL record from Cloudflare every
#      run and reconciles against reality. One extra API call every 6 minutes is
#      a trivial price for a check that can actually detect drift.
#
#   2. PATCH, not DELETE-then-CREATE. The old flow deleted the record and
#      created a new one; a failure between the two left the hostname with no
#      record at all. PATCH is atomic.
#
# And it VERIFIES: after updating, it reads the record back and confirms the new
# value. An update that reports success without changing anything is the failure
# mode this whole homelab keeps rediscovering.

set -euo pipefail

ENV_FILE="$(dirname "$0")/.env"
source "$ENV_FILE"

: "${CLOUDFLARE_TOKEN:?CLOUDFLARE_TOKEN must be set in .env (needs Zone:DNS:Edit + Zone:Read)}"
ZONE_NAME="${DDNS_ZONE:-bradpenney.io}"
RECORD_FQDN="${DDNS_RECORD:-nextcloud.bradpenney.io}"
API="https://api.cloudflare.com/client/v4"
AUTH=(-H "Authorization: Bearer ${CLOUDFLARE_TOKEN}" -H "Content-Type: application/json")

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

CURRENT_IP=$(curl -sf --max-time 15 https://api.ipify.org || curl -sf --max-time 15 https://ifconfig.me || true)
if [[ ! "$CURRENT_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    log "ERROR: could not determine public IP (got '${CURRENT_IP}')"
    exit 1
fi

ZONE_ID=$(curl -sf "${API}/zones?name=${ZONE_NAME}" "${AUTH[@]}" \
    | python3 -c 'import sys,json; r=json.load(sys.stdin)["result"]; print(r[0]["id"] if r else "")')
[[ -n "$ZONE_ID" ]] || { log "ERROR: zone ${ZONE_NAME} not found (token scope?)"; exit 1; }

read -r RECORD_ID LIVE_IP <<<"$(curl -sf "${API}/zones/${ZONE_ID}/dns_records?type=A&name=${RECORD_FQDN}" "${AUTH[@]}" \
    | python3 -c 'import sys,json; r=json.load(sys.stdin)["result"]; print(r[0]["id"], r[0]["content"]) if r else print("", "")')"

if [[ -z "$RECORD_ID" ]]; then
    log "ERROR: no A record for ${RECORD_FQDN} in Cloudflare — refusing to create one blindly"
    exit 1
fi

# Reconcile against the ACTUAL record, not a local cache.
if [[ "$LIVE_IP" == "$CURRENT_IP" ]]; then
    exit 0
fi

log "IP drift detected: DNS says ${LIVE_IP}, we are ${CURRENT_IP} — updating"
curl -sf -X PATCH "${API}/zones/${ZONE_ID}/dns_records/${RECORD_ID}" "${AUTH[@]}" \
    -d "{\"content\":\"${CURRENT_IP}\"}" >/dev/null

# VERIFY the change landed. Do not trust the API's 200.
VERIFY=$(curl -sf "${API}/zones/${ZONE_ID}/dns_records/${RECORD_ID}" "${AUTH[@]}" \
    | python3 -c 'import sys,json; print(json.load(sys.stdin)["result"]["content"])')
if [[ "$VERIFY" != "$CURRENT_IP" ]]; then
    log "ERROR: update did NOT take effect — record still reads ${VERIFY}"
    exit 1
fi
log "DNS updated and verified: ${RECORD_FQDN} -> ${CURRENT_IP}"

docker exec nextcloud-app php occ config:system:set \
    auth.bruteforce.protection.whitelisted_ips 0 --value="$CURRENT_IP" 2>/dev/null || true
