#!/bin/bash
set -euo pipefail

ENV_FILE="$(dirname "$0")/.env"
source "$ENV_FILE"

STATE_FILE="/var/cache/donetick-health/state"
mkdir -p "$(dirname "$STATE_FILE")"
PREV_STATE=$(cat "$STATE_FILE" 2>/dev/null || echo "up")

HTTP_CODE=$(curl -sf -o /dev/null -w "%{http_code}" --max-time 15 \
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
    "https://${DONETICK_DOMAIN}/ returned HTTP ${HTTP_CODE}. Check: docker ps && dig +short ${DONETICK_DOMAIN}"
fi

exit 1
