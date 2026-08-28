#!/usr/bin/env bash
#
# Install the fixes from ADR-074:
#   1. a SCOPED kubeconfig for the nightly hypervisor update, replacing a stale
#      one that held credentials for a cluster that no longer exists
#   2. three systemd units whose failure notifications could never fire
#
# Idempotent: safe to re-run. Verifies before and after rather than assuming.
# Asks for sudo ONCE, up front, instead of prompting part-way through.
#
set -euo pipefail

HOMELAB="/home/brad/homelab"
STAGED_KUBECONFIG="${HOMELAB}/hypervisor-kubeconfig.new"
UNITS=(hypervisor-update.service hypervisor-update-notify.service
       ddns-cloudflare.service ddns-notify.service)

ok()   { printf '  \033[32m[ok]\033[0m   %s\n' "$*"; }
warn() { printf '  \033[33m[warn]\033[0m %s\n' "$*"; }
die()  { printf '  \033[31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }
step() { printf '\n\033[1m%s\033[0m\n' "$*"; }

step "Preflight"

[[ $EUID -ne 0 ]] || die "run as brad, not root — the script sudos only where it must"

for u in "${UNITS[@]}"; do
    [[ -f "${HOMELAB}/systemd/$u" ]] || die "missing ${HOMELAB}/systemd/$u"
done
ok "all ${#UNITS[@]} unit files staged"

# The kubeconfig step is skipped cleanly on a re-run, so this script can be run
# twice without failing or clobbering a good file with nothing.
INSTALL_KUBECONFIG=1
if [[ ! -f "$STAGED_KUBECONFIG" ]]; then
    if sudo test -f /etc/homelab/kubeconfig 2>/dev/null; then
        INSTALL_KUBECONFIG=0
        warn "no staged kubeconfig; leaving the installed one alone (already applied?)"
    else
        die "no staged kubeconfig at $STAGED_KUBECONFIG and none installed"
    fi
else
    # Prove it works BEFORE replacing the installed one. Installing a credential
    # that cannot authenticate would simply move the outage.
    n=$(KUBECONFIG="$STAGED_KUBECONFIG" kubectl get nodes --no-headers 2>/dev/null | wc -l)
    [[ "$n" -gt 0 ]] || die "the staged kubeconfig cannot reach the cluster — refusing to install it"
    who=$(KUBECONFIG="$STAGED_KUBECONFIG" kubectl auth whoami -o jsonpath='{.status.userInfo.username}' 2>/dev/null || echo unknown)
    ok "staged kubeconfig authenticates as '${who}' and sees ${n} nodes"
    [[ "$who" != "kubernetes-admin" ]] || die "that is the ADMIN credential — the whole point is that this job is scoped"
fi

step "Authenticating (one prompt)"
sudo -v || die "sudo required"

if [[ "$INSTALL_KUBECONFIG" == "1" ]]; then
    step "Installing the scoped kubeconfig"
    sudo install -D -m 600 -o root -g root "$STAGED_KUBECONFIG" /etc/homelab/kubeconfig
    ok "/etc/homelab/kubeconfig replaced (0600 root:root)"
    rm -f "$STAGED_KUBECONFIG"
    ok "staged copy removed — it contained a client certificate"
fi

step "Installing systemd units"
for u in "${UNITS[@]}"; do
    sudo install -m 644 -o root -g root "${HOMELAB}/systemd/$u" "/etc/systemd/system/$u"
    ok "$u"
done
sudo systemctl daemon-reload
ok "daemon-reload"

step "Verifying the notification paths actually registered"
# This is the whole point of the change. `OnFailure=` in the wrong section is
# silently ignored, so checking the FILE proves nothing — ask systemd.
fail=0
for u in hypervisor-update.service ddns-cloudflare.service; do
    v=$(systemctl show "$u" -p OnFailure --value 2>/dev/null)
    if [[ -z "$v" ]]; then
        printf '  \033[31m[FAIL]\033[0m %s: OnFailure is EMPTY — systemd ignored it\n' "$u" >&2
        fail=1
    else
        ok "$u -> $v"
    fi
done
[[ "$fail" -eq 0 ]] || die "a notification path did not register"

step "Clearing the stale failed state"
for u in hypervisor-update.service; do
    if [[ "$(systemctl is-failed "$u" 2>/dev/null)" == "failed" ]]; then
        sudo systemctl reset-failed "$u"
        ok "$u failed-state cleared (it will re-fail tonight if unfixed)"
    else
        ok "$u not in a failed state"
    fi
done

step "Done"
cat <<'EOT'
  Next, and deliberately NOT automatic — this applies five nights of pending
  updates and may reboot the host once the safety gates pass:

      sudo systemctl start hypervisor-update.service
      journalctl -u hypervisor-update.service -f

  Then confirm the whole picture:

      /home/brad/notes/source_code/substrate/.venv/bin/python3 \
        /home/brad/notes/source_code/substrate/posture-check.py
EOT
