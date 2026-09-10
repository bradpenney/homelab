#!/bin/bash
set -euo pipefail

ENV_FILE="$(dirname "$0")/.env"
source "$ENV_FILE"

STATE_FILE="/var/cache/wanderer-health/state"
mkdir -p "$(dirname "$STATE_FILE")"
PREV_STATE=$(cat "$STATE_FILE" 2>/dev/null || echo "up")

# Checks the CLUSTER INGRESS, not 127.0.0.1.
#
# Wanderer moved off this host to the k0s cluster 2026-09-09 (ADR-153), so
# loopback no longer serves it. And since trails.bradpenney.io is now behind
# Cloudflare with the ADR-070 origin lock, a request that does NOT arrive from
# Cloudflare is dropped by design -- which is exactly what a --resolve to
# 127.0.0.1 is. Left unchanged, this check fired "Wanderer Unreachable" within
# minutes of the lock landing, against a service that was serving 200 to the
# internet on every other path.
#
# THIS IS THE SECOND TIME. donetick-health.sh carries the same comment from
# 2026-09-06 and the same fix. A migration is not finished when traffic moves;
# every checker still aimed at the old location has to move with it.
#
# WHAT THIS DOES AND DOES NOT COVER, stated so nobody assumes otherwise:
# it proves the cluster is serving the app. It deliberately does NOT traverse
# Cloudflare or public DNS, so it stays useful during a WAN outage -- but it
# also will NOT notice a Cloudflare or DNS failure that takes the site down for
# everyone else. That is a separate check and does not exist yet.
CLUSTER_INGRESS="${CLUSTER_INGRESS:-192.168.2.206}"
HTTP_CODE=$(curl -sf -o /dev/null -w "%{http_code}" --max-time 15 \
  --resolve "${WANDERER_DOMAIN}:443:${CLUSTER_INGRESS}" \
  "https://${WANDERER_DOMAIN}/" 2>/dev/null || echo "000")

if [[ "$HTTP_CODE" == "200" ]]; then
  if [[ "$PREV_STATE" == "down" ]]; then
    echo "up" > "$STATE_FILE"
    /bin/bash "$(dirname "$0")/notify.sh" \
      "Wanderer Recovered" \
      "https://${WANDERER_DOMAIN} is back up (HTTP 200)"
  else
    echo "up" > "$STATE_FILE"
  fi
  exit 0
fi

if [[ "$PREV_STATE" != "down" ]]; then
  echo "down" > "$STATE_FILE"
  /bin/bash "$(dirname "$0")/notify.sh" \
    "Wanderer Unreachable" \
    "https://${WANDERER_DOMAIN}/ returned HTTP ${HTTP_CODE}. Check: kubectl -n wanderer get pods && dig +short ${WANDERER_DOMAIN} @192.168.2.207"
fi

exit 1
