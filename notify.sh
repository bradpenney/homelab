#!/bin/bash
#
# ntfy notifier for homelab units.
#
# FIXED 2026-08-31: this used `curl -s` with no `-f`. curl exits 0 on an HTTP
# 4xx/5xx, so a rejected or undeliverable notification looked exactly like a
# delivered one, and the caller's `set -e` never tripped. Broken alerting is
# indistinguishable from a quiet night. Now it fails loudly and echoes the
# message to the journal so the alert survives even when ntfy does not.
set -euo pipefail

ENV_FILE="$(dirname "$0")/.env"
source "$ENV_FILE"

TITLE="${1:-Homelab Alert}"
MESSAGE="${2:-Something needs your attention on $(hostname)}"
PRIORITY="${3:-high}"

if ! curl -fsS --max-time 20 \
  -H "Title: ${TITLE}" \
  -H "Priority: ${PRIORITY}" \
  -H "Tags: warning" \
  -d "${MESSAGE}" \
  "https://ntfy.sh/${NTFY_TOPIC}" > /dev/null; then
    echo "notify: DELIVERY FAILED - ${TITLE}: ${MESSAGE}" >&2
    exit 1
fi
