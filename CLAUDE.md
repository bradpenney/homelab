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
./ddns-update.sh   # manual run; only updates DNS if public IP has changed
```
Caches last known IP at `/var/cache/ddns-vercel/last-ip`. Uses Vercel DNS API: deletes the existing A record and creates a new one.

### Systemd timers (production automation)
```bash
sudo systemctl status nextcloud-backup.timer   # daily at 3am
sudo systemctl status ddns-vercel.timer        # every 5 minutes
journalctl -u nextcloud-backup.service -n 50
```
On backup failure, `nextcloud-backup.service` triggers `nextcloud-backup-notify.service`, which calls `notify.sh` to push an alert via ntfy.sh.

### Installing/updating timers after editing unit files
```bash
sudo cp ddns-vercel.{service,timer} /etc/systemd/system/
sudo cp nextcloud-backup{,-notify}.service nextcloud-backup.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now nextcloud-backup.timer
sudo systemctl enable --now ddns-vercel.timer
```

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

## Disaster recovery

Full restore procedure is documented in `RESTORE.md`. The key non-obvious steps are:
1. Start MariaDB alone first, restore the dump, then bring up the full stack.
2. Nextcloud data dir must be owned by `uid 33` (`www-data`).
3. `traefik-data/acme.json` must exist with `chmod 600` before Traefik starts.
