#!/bin/bash
#
# Positive heartbeat for the nightly Nextcloud backup.
#
# WHY THIS EXISTS
#
# nextcloud-backup.service has had an OnFailure= notifier the whole time, and it
# reported nothing while the backup died on five nights out of six
# (2026-08-28..09-02). hypervisor-update.service rebooted the host mid-run, and
# systemd will not enqueue an OnFailure= job once a reboot transaction exists:
#
#   Failed to enqueue OnFailure=nextcloud-backup-notify.service job, ignoring:
#   Transaction for ... is destructive (local-fs-pre.target has 'stop' queued)
#
# So any failure caused by the machine going down also takes down the path that
# would report it. OnFailure= can describe some of the ways a backup failed; it
# can never establish that one SUCCEEDED. Silence is not evidence.
#
# This asserts the positive instead. backup.sh writes a stamp as its final act
# on a clean run; this checks the stamp is present and recent. Killed, never
# started, never scheduled, timer disabled, host powered off all collapse to the
# same observable -- stale -- which is the point. It does not care WHY.
#
# EXIT SEMANTICS (same contract as dns-health.sh)
#   0  the check ran. A stale backup is a finding, not a checker fault.
#   1  the checker itself broke -- including an alert it could not deliver.
#      That is what OnFailure=nextcloud-backup-heartbeat-notify.service is for.
set -uo pipefail

STAMP_FILE="${STAMP_FILE:-/var/lib/homelab/nextcloud-backup.stamp}"

# 26h, not 24h: the timer carries RandomizedDelaySec=10min and a run takes
# ~30min, so a healthy backup can legitimately land almost an hour later than
# the day before. 26h tolerates the jitter without tolerating a missed night.
MAX_AGE_HOURS="${MAX_AGE_HOURS:-26}"

NOTIFY="${NOTIFY:-$(dirname "$0")/notify.sh}"

alert() {
    local msg="$1"
    echo "backup-heartbeat: STALE - ${msg}" >&2
    if ! "$NOTIFY" "Nextcloud backup STALE" "${msg}" high; then
        echo "backup-heartbeat: ALERT UNDELIVERED - ${msg}" >&2
        exit 1
    fi
    exit 0
}

if [[ ! -f "$STAMP_FILE" ]]; then
    alert "No successful-backup stamp at ${STAMP_FILE}. The nightly Nextcloud backup has not completed cleanly since this check was installed."
fi

stamp="$(cat "$STAMP_FILE" 2>/dev/null || true)"

# A truncated or garbage stamp is a DEFINITIVE fault, not an inconclusive read.
# Treating an unparseable date as "probably fine" is how a check ends up
# confirming nothing while reporting green.
stamp_epoch="$(date -d "$stamp" +%s 2>/dev/null || true)"
if [[ -z "$stamp_epoch" ]]; then
    alert "Backup stamp at ${STAMP_FILE} is unreadable or malformed: '${stamp}'"
fi

age_hours=$(( ( $(date +%s) - stamp_epoch ) / 3600 ))

if (( age_hours < 0 )); then
    alert "Backup stamp at ${STAMP_FILE} is dated in the future (${stamp}) — the clock or the stamp is wrong."
fi

if (( age_hours >= MAX_AGE_HOURS )); then
    alert "Last clean Nextcloud backup was ${age_hours}h ago (limit ${MAX_AGE_HOURS}h), at ${stamp}. Check: journalctl -u nextcloud-backup.service"
fi

echo "backup-heartbeat: OK - last clean backup ${age_hours}h ago (${stamp})"
