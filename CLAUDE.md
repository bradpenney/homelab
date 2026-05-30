# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A self-hosted homelab stack on a Fedora server, defined in a single `compose.yaml`. It runs:

- **Traefik v3** — reverse proxy with automatic Let's Encrypt TLS via HTTP challenge
- **Nextcloud 33** — file sync, backed by MariaDB
- **Home Assistant** — home automation, uses `network_mode: host` for local device discovery

Supporting automation lives in shell scripts and systemd units (not managed by Docker).

## Key operations

### Stack management
```bash
sudo docker compose up -d          # start all services
sudo docker compose up -d mariadb  # start only MariaDB (needed before DB restore)
sudo docker compose down
sudo docker compose logs -f
```

### Nextcloud occ commands
```bash
sudo docker exec nextcloud-app php occ <command>
sudo docker exec nextcloud-app php occ maintenance:mode --on
sudo docker exec nextcloud-app php occ maintenance:mode --off
sudo docker exec nextcloud-app php occ upgrade       # run after restoring an older dump
```

### Backup
```bash
sudo ./backup.sh   # manual run; requires rclone configured with gdrive + nextcloud-crypt remotes
```
Backup flow: enable maintenance mode → dump MariaDB → disable maintenance mode → upload dump + sync data/config/custom_apps to `nextcloud-crypt:` → prune dumps older than 7 days.

### DDNS
```bash
bash ./ddns-update.sh   # manual run; only updates DNS if public IP has changed
```
Caches last known IP at `/var/cache/ddns-vercel/last-ip`. Uses Vercel DNS API: deletes the existing A record and creates a new one.

On failure, `ddns-vercel.service` triggers `ddns-notify.service`, which pushes an ntfy.sh alert.

### Nextcloud health check
Polls `https://${NEXTCLOUD_DOMAIN}/status.php` every 10 minutes. Sends an ntfy.sh push on the first failure and again on recovery. State tracked at `/var/cache/nextcloud-health/state`.

```bash
sudo systemctl status nextcloud-health.timer
sudo systemctl start nextcloud-health.service   # force an immediate check
journalctl -u nextcloud-health.service -n 20
```

**TODO:** Add an external uptime monitor (e.g. UptimeRobot free tier) pointing at `https://nextcloud.bradpenney.io` to catch cases where the server itself is offline. The local health check cannot detect its own outage.

### Wanderer (trail journal)
Self-hosted trail journal at `https://trails.bradpenney.io`. Three containers: `wanderer-search` (Meilisearch), `wanderer-db` (PocketBase on localhost:8090), `wanderer` (SvelteKit web app). Signup is disabled — single-user only.

Health monitored by `wanderer-health.timer` every 10 minutes — sends ntfy alert on failure and recovery.

```bash
sudo systemctl status wanderer-health.timer
journalctl -u wanderer-health.service -n 20
```

### Garmin → Wanderer sync
Polls Garmin Connect every 30 minutes and pushes new activities as trails to Wanderer. Only syncs activities on or after `GARMIN_SYNC_START_DATE` in `.env`.

```bash
~/homelab/garmin-sync.sh             # manual run
journalctl -u garmin-sync.service -n 50
sudo systemctl status garmin-sync.timer
```

**First-time setup on a new machine:**
```bash
python3 -m venv .venv
.venv/bin/pip install -r gcal-requirements.txt
~/homelab/.venv/bin/python3 ~/homelab/garmin_sync.py   # interactive auth + token cache
sudo cp garmin-sync.{service,timer} /etc/systemd/system/
sudo cp garmin-sync-notify.service /etc/systemd/system/
sudo cp wanderer-health.{service,timer} /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now garmin-sync.timer
sudo systemctl enable --now wanderer-health.timer
```

Garmin tokens are cached in `.garmin-tokens/` (gitignored, per-machine). Sync state is in `garmin-sync-state.json` (gitignored). Activity type → Wanderer category mapping is in `CATEGORY_MAP` at the top of `garmin_sync.py` — add your SxS custom activity type there once you see it logged as unmapped.

### Google Calendar sync
Two-way sync between Google Calendar and Nextcloud Calendar, running as a systemd timer every 15 minutes.

Implemented in `~/notes/scripts/gcal_caldav_sync.py` using the Python `caldav` library.
Google is authenticated via OAuth2 Bearer token (same credentials as the `gcal` CLI).
Nextcloud is authenticated via `BRAD_NEXTCLOUD_PAT` from `.env`.
Conflict resolution: Google wins. Syncs the primary personal calendar only.
Deletion state is tracked in `~/.vdirsyncer/gcal_sync_state.json`.

```bash
~/homelab/gcal-sync.sh             # manual run
journalctl -u gcal-sync.service -n 50
sudo systemctl status gcal-sync.timer
```

**First-time setup on a new machine:**
```bash
python3 -m venv .venv
.venv/bin/pip install -r gcal-requirements.txt
# Populate .env with GOOGLE_EMAIL, GCAL_TOKEN_FILE, NEXTCLOUD_USERNAME, NEXTCLOUD_CALENDAR
# Re-authenticate Google if token.json doesn't exist (use the gcal auth script)
~/homelab/gcal-sync.sh             # test run
sudo cp gcal-sync.{service,timer} /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now gcal-sync.timer
```

**Google Cloud Console prerequisite:** The "Google Calendar CalDAV API" must be enabled in the Google Cloud project that issued `GCAL_TOKEN_FILE`. State is persisted at `~/.local/share/gcal-sync/state.json`.

### Systemd timers (production automation)
```bash
sudo systemctl status nextcloud-backup.timer   # daily at 3am
sudo systemctl status ddns-vercel.timer        # every 5 minutes
sudo systemctl status gcal-sync.timer          # every 15 minutes
sudo systemctl status nextcloud-health.timer   # every 10 minutes
journalctl -u nextcloud-backup.service -n 50
journalctl -u gcal-sync.service -n 50
journalctl -u nextcloud-health.service -n 20
```
On backup failure, `nextcloud-backup.service` triggers `nextcloud-backup-notify.service`.
On DDNS failure, `ddns-vercel.service` triggers `ddns-notify.service`.
Both call `notify.sh` to push an alert via ntfy.sh.

### Installing/updating timers after editing unit files
```bash
sudo cp ddns-vercel.{service,timer} /etc/systemd/system/
sudo cp ddns-notify.service /etc/systemd/system/
sudo cp nextcloud-backup{,-notify}.service nextcloud-backup.timer /etc/systemd/system/
sudo cp gcal-sync.{service,timer} /etc/systemd/system/
sudo cp nextcloud-health.{service,timer} /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now nextcloud-backup.timer
sudo systemctl enable --now ddns-vercel.timer
sudo systemctl enable --now gcal-sync.timer
sudo systemctl enable --now nextcloud-health.timer
```

### SELinux and shell scripts
All `.sh` files in this repo must have SELinux type `bin_t` for systemd services to execute them (default `user_home_t` is blocked). A persistent policy rule is in place:
```bash
# Already applied — only needed on a new machine or after restorecon wipes contexts
sudo semanage fcontext -a -t bin_t "/home/brad/homelab/.*\.sh"
sudo restorecon -v /home/brad/homelab/*.sh
```
All service `ExecStart` lines use `/bin/bash /path/to/script.sh` as a second layer of defence (bash itself is always executable; only read access on the script is needed).

### Docker vs Podman
This stack is managed exclusively via **Docker** (`sudo docker compose`). Fedora also ships Podman, which is a separate engine with its own container storage. Do **not** use `podman compose` or `podman run` for this stack — Podman's rootless containers share the same volume mount paths with `:Z` SELinux relabeling, which will corrupt the SELinux labels on shared volumes and break file access for the Docker containers.

## Configuration

All secrets live in `.env` (gitignored). See `.env.example` for required variables:
- `MYSQL_ROOT_PASSWORD`, `MYSQL_PASSWORD` — MariaDB credentials
- `VERCEL_TOKEN`, `VERCEL_DOMAIN`, `VERCEL_RECORD` — DDNS via Vercel API
- `ACME_EMAIL` — Let's Encrypt registration
- `NEXTCLOUD_DOMAIN` — used by Traefik routing labels and Nextcloud trusted domains
- `NTFY_TOPIC` — ntfy.sh topic for push notifications

## rclone remotes

Two remotes must exist in `~/.config/rclone/rclone.conf`:
- `gdrive` — Google Drive OAuth remote pointing to `nextcloud-backup/` folder
- `nextcloud-crypt` — crypt remote wrapping `gdrive:nextcloud-backup`, used by `backup.sh`

## Nextcloud MCP

The `aiquila` MCP server (for browsing/editing Nextcloud files from Claude Code) is configured in the `~/notes` project, not here. Set it up there when working on a new machine.

## Disaster recovery

Full restore procedure is documented in `RESTORE.md`. The key non-obvious steps are:
1. Start MariaDB alone first, restore the dump, then bring up the full stack.
2. Nextcloud data dir must be owned by `uid 33` (`www-data`).
3. `traefik-data/acme.json` must exist with `chmod 600` before Traefik starts.
