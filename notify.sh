#!/bin/bash
set -euo pipefail

ENV_FILE="$(dirname "$0")/.env"
source "$ENV_FILE"

TITLE="${1:-Homelab Alert}"
MESSAGE="${2:-Something needs your attention on $(hostname)}"

curl -s \
  -H "Title: ${TITLE}" \
  -H "Priority: high" \
  -H "Tags: warning" \
  -d "${MESSAGE}" \
  "https://ntfy.sh/${NTFY_TOPIC}" > /dev/null
