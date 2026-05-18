#!/bin/bash
set -euo pipefail

ENV_FILE="$(dirname "$0")/.env"
CACHE_FILE="/var/cache/ddns-vercel/last-ip"

source "$ENV_FILE"

DOMAIN="${VERCEL_DOMAIN}"
RECORD_NAME="${VERCEL_RECORD}"

CURRENT_IP=$(curl -sf https://ifconfig.me)
if [[ -z "$CURRENT_IP" ]]; then
  echo "ERROR: Could not determine public IP" >&2
  exit 1
fi

mkdir -p "$(dirname "$CACHE_FILE")"
LAST_IP=$(cat "$CACHE_FILE" 2>/dev/null || echo "")

if [[ "$CURRENT_IP" == "$LAST_IP" ]]; then
  exit 0
fi

echo "IP changed: $LAST_IP -> $CURRENT_IP"

# Find existing record ID
RECORD_ID=$(curl -sf "https://api.vercel.com/v4/domains/${DOMAIN}/records" \
  -H "Authorization: Bearer ${VERCEL_TOKEN}" | \
  python3 -c "
import sys, json
records = json.load(sys.stdin).get('records', [])
match = next((r for r in records if r['name'] == '${RECORD_NAME}' and r['type'] == 'A'), None)
print(match['id'] if match else '')
")

# Delete old record if it exists
if [[ -n "$RECORD_ID" ]]; then
  curl -sf -X DELETE "https://api.vercel.com/v4/domains/${DOMAIN}/records/${RECORD_ID}" \
    -H "Authorization: Bearer ${VERCEL_TOKEN}" > /dev/null
fi

# Create new record
curl -sf -X POST "https://api.vercel.com/v4/domains/${DOMAIN}/records" \
  -H "Authorization: Bearer ${VERCEL_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{\"name\": \"${RECORD_NAME}\", \"type\": \"A\", \"value\": \"${CURRENT_IP}\", \"ttl\": 60}" > /dev/null

echo "$CURRENT_IP" > "$CACHE_FILE"
echo "DNS updated to $CURRENT_IP"

# Keep Nextcloud brute force whitelist in sync with home IP
docker exec nextcloud-app php occ config:system:set \
  auth.bruteforce.protection.whitelisted_ips 0 --value="$CURRENT_IP" 2>/dev/null || true
