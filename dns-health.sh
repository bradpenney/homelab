#!/bin/bash
set -euo pipefail

ENV_FILE="$(dirname "$0")/.env"
source "$ENV_FILE"

FQDN="${VERCEL_RECORD}.${VERCEL_DOMAIN}"
STATE_FILE="/var/cache/dns-health/state"
STRIKE_FILE="/var/cache/dns-health/strikes"
mkdir -p "$(dirname "$STATE_FILE")"
PREV_STATE=$(cat "$STATE_FILE" 2>/dev/null || echo "up")

# Same source ddns-update.sh publishes from, so we compare against its authority.
PUBLIC_IP=$(curl -sf --max-time 15 https://ifconfig.me 2>/dev/null || echo "")

# No internet == inconclusive, not a DNS fault. Leave state untouched.
if [[ -z "$PUBLIC_IP" ]]; then
  exit 0
fi

DNS_IP=$(dig +short A "$FQDN" @1.1.1.1 2>/dev/null | grep -E '^[0-9.]+$' | tail -1)
if [[ -z "$DNS_IP" ]]; then
  DNS_IP=$(dig +short A "$FQDN" @8.8.8.8 2>/dev/null | grep -E '^[0-9.]+$' | tail -1)
fi

if [[ "$DNS_IP" == "$PUBLIC_IP" ]]; then
  echo 0 > "$STRIKE_FILE"
  if [[ "$PREV_STATE" == "down" ]]; then
    echo "up" > "$STATE_FILE"
    /bin/bash "$(dirname "$0")/notify.sh" \
      "DNS Recovered" \
      "${FQDN} now resolves to ${DNS_IP} (matches public IP)"
  else
    echo "up" > "$STATE_FILE"
  fi
  exit 0
fi

# DDNS republishes every ~6min; require two consecutive strikes so a normal
# propagation window after an IP change doesn't page us.
STRIKES=$(( $(cat "$STRIKE_FILE" 2>/dev/null || echo 0) + 1 ))
echo "$STRIKES" > "$STRIKE_FILE"
if (( STRIKES < 2 )); then
  exit 0
fi

if [[ "$PREV_STATE" != "down" ]]; then
  echo "down" > "$STATE_FILE"
  /bin/bash "$(dirname "$0")/notify.sh" \
    "DNS Stale" \
    "${FQDN} resolves to '${DNS_IP:-NXDOMAIN/no A record}' but public IP is ${PUBLIC_IP}. DDNS may be failing. Check: systemctl status ddns-vercel.timer && journalctl -u ddns-vercel.service -n 20"
fi

exit 1
