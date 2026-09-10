#!/bin/bash
set -euo pipefail

ENV_FILE="$(dirname "$0")/.env"
source "$ENV_FILE"

STATE_FILE="/var/cache/donetick-health/state"
mkdir -p "$(dirname "$STATE_FILE")"
PREV_STATE=$(cat "$STATE_FILE" 2>/dev/null || echo "up")

# Checks the CLUSTER INGRESS, not 127.0.0.1.
#
# donetick moved off this host to the k0s cluster 2026-09-06 (ADR-135), so
# loopback no longer serves it. And since todo.bradpenney.io is now behind
# Cloudflare with the ADR-070 origin lock, a request that does NOT arrive from
# Cloudflare is dropped by design -- which is exactly what a --resolve to
# 127.0.0.1 is. This check reported "Donetick Unreachable" against a service
# that was serving 200 to the internet.
#
# WHAT THIS DOES AND DOES NOT COVER, stated so nobody assumes otherwise:
# it proves the cluster is serving the app. It deliberately does NOT traverse
# Cloudflare or public DNS, so it stays useful during a WAN outage -- but it
# also will NOT notice a Cloudflare or DNS failure that takes the site down for
# everyone else. That is a separate check and does not exist yet.
CLUSTER_INGRESS="${CLUSTER_INGRESS:-192.168.2.206}"
HTTP_CODE=$(curl -sf -o /dev/null -w "%{http_code}" --max-time 15 \
  --resolve "${DONETICK_DOMAIN}:443:${CLUSTER_INGRESS}" \
  "https://${DONETICK_DOMAIN}/" 2>/dev/null || echo "000")

if [[ "$HTTP_CODE" == "200" ]]; then
  if [[ "$PREV_STATE" == "down" ]]; then
    echo "up" > "$STATE_FILE"
    /bin/bash "$(dirname "$0")/notify.sh" \
      "Donetick Recovered" \
      "https://${DONETICK_DOMAIN} is back up (HTTP 200)"
  else
    echo "up" > "$STATE_FILE"
  fi
  exit 0
fi

if [[ "$PREV_STATE" != "down" ]]; then
  echo "down" > "$STATE_FILE"
  /bin/bash "$(dirname "$0")/notify.sh" \
    "Donetick Unreachable" \
    "https://${DONETICK_DOMAIN}/ returned HTTP ${HTTP_CODE}. Check: kubectl -n donetick get pods && dig +short ${DONETICK_DOMAIN} @192.168.2.207"
fi

exit 1
