#!/bin/bash
#
# DNS health check. Two independent checks, both of which alert BEFORE an
# outage rather than after one:
#
#   1. DDNS DRIFT  - does the record DDNS publishes still match our public IP?
#   2. TOKEN AGE   - is the Cloudflare API token about to expire?
#
# WHY CHECK 2 EXISTS (added 2026-08-31): the Cloudflare token expired at
# 2026-08-31T23:59:59Z. Nothing warned. The first sign was ddns-cloudflare
# failing nine minutes later with a JSONDecodeError traceback, because the
# updater pipes curl output straight into json.load and a 403 body is not JSON.
# While the token is dead, DDNS silently stops tracking the public IP AND every
# DNS repair is blocked -- so an unrelated outage becomes unfixable at the same
# moment. An expiring credential is a scheduled outage; it needs a warning on
# the calendar, not a post-mortem.
#
# RETARGETED 2026-08-31: this watched "${VERCEL_RECORD}.${VERCEL_DOMAIN}", a
# leftover from the Vercel era. DDNS now publishes DDNS_RECORD (origin.*), and
# the user-facing names are CNAMEs onto it. Watching the CNAME only proved the
# chain by accident; we now check the record DDNS actually writes.
#
# EXIT SEMANTICS: exit 0 means THE CHECK RAN, whether or not it found a fault --
# faults are reported by notification, not by exit code. A non-zero exit means
# the checker itself malfunctioned, which is what OnFailure= is wired to. If a
# detected fault also exited non-zero, OnFailure would double-alert and a broken
# checker would be indistinguishable from a working one that found something.

set -euo pipefail

ENV_FILE="$(dirname "$0")/.env"
source "$ENV_FILE"

# Overridable so the alert paths can be exercised without paging anyone.
NOTIFY="${NOTIFY:-$(dirname "$0")/notify.sh}"
# systemd sets CACHE_DIRECTORY via CacheDirectory=; fall back for manual runs.
CACHE="${CACHE_DIRECTORY:-/var/cache/dns-health}"
mkdir -p "$CACHE"

STATE_FILE="$CACHE/state"
STRIKE_FILE="$CACHE/strikes"
TOKEN_STAMP="$CACHE/token-warned"

# Warn this many days before the token dies. 30 gives room to notice, mint a
# replacement, and roll it without touching anything under time pressure.
TOKEN_WARN_DAYS="${TOKEN_WARN_DAYS:-30}"

FQDN="${DDNS_RECORD:-origin.bradpenney.io}"
RC=0

notify() { /bin/bash "$NOTIFY" "$1" "$2" "${3:-high}"; }

# ---------------------------------------------------------------- check 2
# Runs first: if the token is dead, DDNS drift is a downstream symptom and the
# token is the thing worth waking up for.
check_token() {
  [[ -n "${CLOUDFLARE_TOKEN:-}" ]] || return 0

  local body
  # No -f: an expired token still answers 200 with a useful JSON body, and we
  # want to read that body rather than turn it into a bare exit code.
  body=$(curl -sS --max-time 15 \
    -H "Authorization: Bearer ${CLOUDFLARE_TOKEN}" \
    "https://api.cloudflare.com/client/v4/user/tokens/verify" 2>/dev/null) || return 0

  local parsed
  parsed=$(printf '%s' "$body" | python3 -c '
import sys, json, datetime
try:
    d = json.load(sys.stdin)
except Exception:
    print("INCONCLUSIVE 0"); raise SystemExit
r = d.get("result")
# A malformed/revoked/unknown token answers with success:false and result:null.
# That is a DEFINITIVE fault, not an inconclusive read -- an earlier version
# called .get() on that None, threw, and the caller scored it HEALTHY.
if not isinstance(r, dict):
    errs = d.get("errors") or []
    msg = (errs[0].get("message") if errs and isinstance(errs[0], dict) else "") or "rejected"
    print(f"invalid:{msg.replace(chr(32), chr(95))} 0"); raise SystemExit
status = r.get("status", "unknown")
exp = r.get("expires_on")
if not exp:
    print(f"{status} -1")            # -1 = no expiry set
    raise SystemExit
e = datetime.datetime.fromisoformat(exp.replace("Z", "+00:00"))
days = (e - datetime.datetime.now(datetime.timezone.utc)).days
print(f"{status} {days}")
' 2>/dev/null) || return 0

  local status days
  read -r status days <<<"$parsed"
  [[ "$status" == "INCONCLUSIVE" ]] && return 0

  # Alert at most once a day so a 15-minute timer does not become a pager storm.
  local today; today=$(date +%F)
  local warned; warned=$(cat "$TOKEN_STAMP" 2>/dev/null || echo "")

  # "invalid:Some_Message" -> "Some Message"; a bare status -> itself.
  local reason="${status#invalid:}"; reason="${reason//_/ }"

  if [[ "$status" != "active" ]]; then
    if [[ "$warned" != "$today" ]]; then
      echo "$today" > "$TOKEN_STAMP"
      notify "Cloudflare Token PROBLEM" \
        "The Cloudflare API token is not usable: ${reason}. DDNS cannot update ${FQDN} and no DNS record can be repaired until it is replaced. Mint a new token (Zone:Read + Zone:DNS:Edit on bradpenney.io) into ~/homelab/.env, then: systemctl start ddns-cloudflare.service"
    fi
    return 1
  fi

  if (( days >= 0 && days <= TOKEN_WARN_DAYS )); then
    if [[ "$warned" != "$today" ]]; then
      echo "$today" > "$TOKEN_STAMP"
      notify "Cloudflare Token Expires in ${days}d" \
        "The Cloudflare API token expires in ${days} day(s). When it lapses, DDNS stops tracking the public IP and DNS repairs are blocked. Replace it before then: mint Zone:Read + Zone:DNS:Edit on bradpenney.io into ~/homelab/.env." "default"
    fi
    return 1
  fi

  rm -f "$TOKEN_STAMP"
  return 0
}

# ---------------------------------------------------------------- check 1
check_ddns_drift() {
  local prev_state; prev_state=$(cat "$STATE_FILE" 2>/dev/null || echo "up")

  local public_ip
  public_ip=$(curl -sf --max-time 15 https://api.ipify.org 2>/dev/null \
           || curl -sf --max-time 15 https://ifconfig.me 2>/dev/null || echo "")

  # No internet == inconclusive, not a DNS fault. Leave state untouched.
  [[ -n "$public_ip" ]] || return 0

  local dns_ip
  dns_ip=$(dig +short A "$FQDN" @1.1.1.1 2>/dev/null | grep -E '^[0-9.]+$' | tail -1)
  [[ -n "$dns_ip" ]] || dns_ip=$(dig +short A "$FQDN" @8.8.8.8 2>/dev/null | grep -E '^[0-9.]+$' | tail -1)

  if [[ "$dns_ip" == "$public_ip" ]]; then
    echo 0 > "$STRIKE_FILE"
    if [[ "$prev_state" == "down" ]]; then
      notify "DNS Recovered" "${FQDN} now resolves to ${dns_ip} (matches public IP)" "default"
    fi
    echo "up" > "$STATE_FILE"
    return 0
  fi

  # DDNS republishes every ~6min; require two consecutive strikes so a normal
  # propagation window after an IP change does not page us.
  local strikes=$(( $(cat "$STRIKE_FILE" 2>/dev/null || echo 0) + 1 ))
  echo "$strikes" > "$STRIKE_FILE"
  (( strikes >= 2 )) || return 0

  if [[ "$prev_state" != "down" ]]; then
    echo "down" > "$STATE_FILE"
    notify "DNS Stale" \
      "${FQDN} resolves to '${dns_ip:-NXDOMAIN/no A record}' but public IP is ${public_ip}. DDNS may be failing. Check: systemctl status ddns-cloudflare.timer && journalctl -u ddns-cloudflare.service -n 20"
  fi
  return 1
}

check_token      || RC=1
check_ddns_drift || RC=1

# RC is informational only -- it records that something was reported, and lands
# in the journal. See EXIT SEMANTICS above for why it is not the exit code.
if (( RC != 0 )); then
  echo "dns-health: fault(s) reported via ${NOTIFY}"
fi
exit 0
