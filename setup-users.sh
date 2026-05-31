#!/bin/bash
# Idempotent user/group provisioning for Nextcloud.
# Run as: sudo ./setup-users.sh
#
# Prerequisites:
#   1. Stack is running (docker compose up -d)
#   2. .env is populated including BRAD_NEXTCLOUD_PAT
#   3. After creating the admin account, generate a PAT in the Nextcloud UI
#      and add it to .env as ADMIN_NEXTCLOUD_PAT, then re-run.
#
# Regular users receive email invites to set their own passwords.
# Only the admin account requires an interactive password on first run.
set -euo pipefail

HOMELAB_DIR="$(dirname "$0")"
ENV_FILE="${HOMELAB_DIR}/.env"
source "$ENV_FILE"

BASE="https://${NEXTCLOUD_DOMAIN}/ocs/v2.php/cloud"
AUTH="brad:${BRAD_NEXTCLOUD_PAT}"
ADMIN_AUTH="admin:${ADMIN_NEXTCLOUD_PAT:-}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

ocs_post() {
  local endpoint="$1"; shift
  curl -sf -X POST "${BASE}${endpoint}" \
    -u "$AUTH" -H "OCS-APIRequest: true" "$@"
}

ocs_delete() {
  local endpoint="$1"; shift
  curl -sf -X DELETE "${BASE}${endpoint}" \
    -u "$AUTH" -H "OCS-APIRequest: true" "$@"
}

admin_post() {
  local path="$1"; shift
  curl -sf -X POST "https://${NEXTCLOUD_DOMAIN}${path}" \
    -u "$ADMIN_AUTH" -H "OCS-APIRequest: true" "$@"
}

occ() {
  docker exec nextcloud-app php occ "$@"
}

# ---------------------------------------------------------------------------
# Password policy
# ---------------------------------------------------------------------------
log "Setting password policy..."
occ config:app:set password_policy minLength --value=15
occ config:app:set password_policy enforceUpperLowerCase --value=1
occ config:app:set password_policy enforceNumericCharacters --value=1
occ config:app:set password_policy enforceSpecialCharacters --value=1
occ config:app:set password_policy enforceNonCommonPassword --value=1

# ---------------------------------------------------------------------------
# Telemetry, federation, logging, default quota
# ---------------------------------------------------------------------------
log "Configuring system settings..."
occ app:disable survey_client
occ app:disable app_api
occ config:app:set files_sharing outgoing_server2server_share_enabled --value="no"
occ config:app:set files_sharing incoming_server2server_share_enabled --value="no"
occ config:system:set loglevel --value=2 --type=integer
occ config:app:set files default_quota --value="10 GB"
occ config:system:set default_phone_region --value="CA"
occ config:system:set maintenance_window_start --value=2 --type=integer

# ---------------------------------------------------------------------------
# Memories app
# ---------------------------------------------------------------------------
log "Installing Memories app..."
occ app:install memories
occ memories:index

# ---------------------------------------------------------------------------
# Sharing policy
# ---------------------------------------------------------------------------
log "Configuring sharing policy..."
# Enforce expiry on public links (30 days)
occ config:app:set core shareapi_enforce_expire_date --value="yes"
occ config:app:set core shareapi_expire_after_n_days --value="30"
# Prevent kids from creating public share links
occ config:app:set core shareapi_exclude_groups --value="yes"
occ config:app:set core shareapi_exclude_groups_list --value='["kids"]'

# ---------------------------------------------------------------------------
# 2FA — enforce for admin group (admin must set up TOTP in UI before this runs)
# ---------------------------------------------------------------------------
log "Enforcing 2FA for admin group..."
occ app:enable twofactor_totp
occ twofactorauth:enforce --group=admin

# ---------------------------------------------------------------------------
# Redis caching and file locking
# ---------------------------------------------------------------------------
log "Configuring Redis..."
occ config:system:set memcache.local --value='\OC\Memcache\APCu'
occ config:system:set memcache.distributed --value='\OC\Memcache\Redis'
occ config:system:set memcache.locking --value='\OC\Memcache\Redis'
occ config:system:set redis host --value='redis'
occ config:system:set redis port --value=6379 --type=integer
occ config:system:set redis password --value="${REDIS_PASSWORD}"

# ---------------------------------------------------------------------------
# Background jobs mode
# ---------------------------------------------------------------------------
log "Setting background jobs to cron mode..."
occ config:system:set backgroundjobs_mode --value="cron"

# ---------------------------------------------------------------------------
# SMTP (Gmail)
# ---------------------------------------------------------------------------
log "Configuring SMTP..."
occ config:system:set mail_smtpmode --value="smtp"
occ config:system:set mail_smtphost --value="smtp.gmail.com"
occ config:system:set mail_smtpport --value="587"
occ config:system:set mail_smtpsecure --value="tls"
occ config:system:set mail_smtpauth --value=1 --type=integer
occ config:system:set mail_smtpname --value="${GOOGLE_EMAIL}"
occ config:system:set mail_smtppassword --value="${GMAIL_APP_PASSWORD}"
occ config:system:set mail_from_address --value="${GOOGLE_EMAIL%%@*}"
occ config:system:set mail_domain --value="${GOOGLE_EMAIL##*@}"

# ---------------------------------------------------------------------------
# Groups
# ---------------------------------------------------------------------------
log "Creating groups..."
for group in family parents kids power_user; do
  ocs_post "/groups" -d "groupid=${group}" && log "  created: ${group}" || log "  already exists (skipped): ${group}"
done

# ---------------------------------------------------------------------------
# Admin account
# NOTE: After creating admin and logging in, generate a PAT and add
#       ADMIN_NEXTCLOUD_PAT to .env before continuing with group folder setup.
# ---------------------------------------------------------------------------
log "Creating admin user..."
echo -n "Password for 'admin': " && read -rs ADMIN_PASS && echo
ocs_post "/users" \
  --data-urlencode "userid=admin" \
  --data-urlencode "password=${ADMIN_PASS}" \
  --data-urlencode "email=${ACME_EMAIL}"
ocs_post "/users/admin/groups" -d "groupid=admin"
log "  admin created and added to admin group"
log "  ACTION REQUIRED: Log in as admin, generate a PAT, and add ADMIN_NEXTCLOUD_PAT to .env"

# ---------------------------------------------------------------------------
# brad — power_user, family, parents, sub-admin of all non-admin groups
# ---------------------------------------------------------------------------
log "Configuring brad..."
for group in power_user family parents; do
  ocs_post "/users/brad/groups" -d "groupid=${group}" || true
done
for group in parents kids family power_user; do
  ocs_post "/users/brad/subadmins" -d "groupid=${group}"
done

# ---------------------------------------------------------------------------
# patti — parent, family, no quota, email invite
# ---------------------------------------------------------------------------
log "Creating patti..."
ocs_post "/users" \
  --data-urlencode "userid=patti" \
  --data-urlencode "email=${PATTI_EMAIL}"
ocs_post "/users/patti/groups" -d "groupid=parents"
ocs_post "/users/patti/groups" -d "groupid=family"

# ---------------------------------------------------------------------------
# Kids — 100 GB quota, email invite
# ---------------------------------------------------------------------------
log "Creating kids accounts..."
declare -A KID_EMAILS=(
  [lucas]="${KID1_EMAIL}"
  [xavier]="${KID2_EMAIL}"
  [elliott]="${KID3_EMAIL}"
)

for kid in lucas xavier elliott; do
  ocs_post "/users" \
    --data-urlencode "userid=${kid}" \
    --data-urlencode "email=${KID_EMAILS[$kid]}" \
    --data-urlencode "quota=100 GB"
  ocs_post "/users/${kid}/groups" -d "groupid=kids"
  ocs_post "/users/${kid}/groups" -d "groupid=family"
  log "  ${kid} created"
done

# ---------------------------------------------------------------------------
# Group Folders
# Requires ADMIN_NEXTCLOUD_PAT to be set in .env
# ---------------------------------------------------------------------------
if [[ -z "${ADMIN_NEXTCLOUD_PAT:-}" ]]; then
  log "WARNING: ADMIN_NEXTCLOUD_PAT not set — skipping group folder setup."
  log "  Add it to .env and re-run to complete this step."
else
  log "Enabling Group Folders app..."
  occ app:enable groupfolders

  log "Creating group folders..."
  PARENTS_FOLDER_ID=$(occ groupfolders:create "Parents Shared")
  PHOTOS_FOLDER_ID=$(occ groupfolders:create "Family Photos")

  # Add groups then set full permissions (read+update+create+delete+share = 31)
  admin_post "/apps/groupfolders/folders/${PARENTS_FOLDER_ID}/groups" -d "group=parents"
  admin_post "/apps/groupfolders/folders/${PARENTS_FOLDER_ID}/groups/parents" -d "permissions=31"

  admin_post "/apps/groupfolders/folders/${PHOTOS_FOLDER_ID}/groups" -d "group=family"
  admin_post "/apps/groupfolders/folders/${PHOTOS_FOLDER_ID}/groups/family" -d "permissions=31"

  log "  Group folders created and configured"
fi

# ---------------------------------------------------------------------------
# Shared calendar
# Requires ADMIN_NEXTCLOUD_PAT to be set in .env
# ---------------------------------------------------------------------------
if [[ -z "${ADMIN_NEXTCLOUD_PAT:-}" ]]; then
  log "WARNING: ADMIN_NEXTCLOUD_PAT not set — skipping calendar setup."
else
  log "Enabling Calendar app and creating family calendar..."
  occ app:enable calendar
  occ dav:create-calendar admin family-calendar
  log "  ACTION REQUIRED: Log in as admin → Calendar → share 'family-calendar' with the 'family' group."
fi

# ---------------------------------------------------------------------------
# Background cron systemd timer
# ---------------------------------------------------------------------------
log "Installing Nextcloud cron timer..."
cp "${HOMELAB_DIR}/nextcloud-cron.service" /etc/systemd/system/
cp "${HOMELAB_DIR}/nextcloud-cron.timer" /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now nextcloud-cron.timer
log "  Cron timer enabled"

# ---------------------------------------------------------------------------
# Brute force whitelist — seed with current home IP
# ddns-update.sh keeps this in sync on IP changes
# ---------------------------------------------------------------------------
CURRENT_IP=$(cat /var/cache/ddns-vercel/last-ip 2>/dev/null || curl -sf https://ifconfig.me)
if [[ -n "$CURRENT_IP" ]]; then
  occ config:system:set auth.bruteforce.protection.whitelisted_ips 0 --value="$CURRENT_IP"
  log "  Brute force whitelist seeded with $CURRENT_IP"
fi

# ---------------------------------------------------------------------------
# Remove brad's admin rights (final step — must use admin credentials, not brad's)
# ---------------------------------------------------------------------------
log "Removing brad from admin group..."
curl -sf -X DELETE "${BASE}/users/brad/groups" \
  -u "$ADMIN_AUTH" -H "OCS-APIRequest: true" \
  -d "groupid=admin"
log "Done. Brad's admin rights removed."
log ""
log "Summary:"
log "  admin   → admin group (full admin)"
log "  brad    → power_user, family, parents (sub-admin of parents/kids/family/power_user)"
log "  patti   → parents, family (no quota, email invite sent)"
log "  lucas   → kids, family (100GB quota, email invite sent)"
log "  xavier  → kids, family (100GB quota, email invite sent)"
log "  elliott → kids, family (100GB quota, email invite sent)"
log ""
log "Group Folders:"
log "  'Parents Shared' → parents group (full permissions)"
log "  'Family Photos'  → family group (full permissions)"
log ""
log "Shared Calendar: 'family-calendar' (owned by admin — share manually via Calendar UI)"
