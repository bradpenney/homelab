# Homelab

No subscriptions. No vendor lock-in. No cloud company reading your files.

This is a fully self-hosted personal stack running on a Fedora server at home — file sync, home automation, trail tracking, calendar, and online document editing. Everything is defined in a single `compose.yaml`, automated with systemd timers, and backed up nightly to encrypted Google Drive.

If you're thinking about running your own stack, this repo is a working reference. Copy what's useful, adapt what isn't.

## Stack

| Service | Image | Purpose |
|---------|-------|---------|
| [Traefik](https://traefik.io/) | `traefik:v3` | Reverse proxy — automatic TLS via Let's Encrypt DNS challenge (Vercel) |
| [Nextcloud](https://nextcloud.com/) | `nextcloud:33` | File sync, calendar, contacts, notes — replaces Google Drive and iCloud |
| [Collabora](https://www.collaboraonline.com/) | `collabora/code:latest` | Online document editing integrated with Nextcloud |
| [MariaDB](https://mariadb.org/) | `mariadb:lts` | Nextcloud database |
| [Redis](https://redis.io/) | `redis:alpine` | Nextcloud caching |
| [Home Assistant](https://www.home-assistant.io/) | `home-assistant:stable` | Home automation |
| [Wanderer](https://wanderer.to/) | `flomp/wanderer-web` | Self-hosted trail and activity tracking |
| [Meilisearch](https://www.meilisearch.com/) | `meilisearch:v1.36.0` | Full-text search backend for Wanderer |

## Architecture

All services share a Docker bridge network behind Traefik, which handles TLS termination and routes traffic by domain name. Home Assistant breaks this pattern intentionally — it needs host networking to discover local smart devices.

```
Internet
    |
  Traefik (443/80)
    |
    +-- nextcloud.yourdomain.com  --> Nextcloud --> MariaDB, Redis, Collabora
    +-- trails.yourdomain.com    --> Wanderer   --> PocketBase, Meilisearch
    +-- office.yourdomain.com    --> Collabora

Home Assistant  (host network — local device discovery)
```

## Automation

The stack runs itself. All recurring tasks are systemd timers — no cron, no external schedulers.

| Timer | Schedule | What it does |
|-------|----------|--------------|
| `nextcloud-backup.timer` | Daily 3am | Dumps MariaDB, syncs data/config/files to encrypted Google Drive |
| `homelab-update.timer` | Daily 4am | Pulls latest Docker images, restarts containers, runs `occ upgrade` |
| `nextcloud-cron.timer` | Every 5 min | Nextcloud background jobs |
| `ddns-vercel.timer` | Every 5 min | Updates DNS if your home IP changes |
| `gcal-sync.timer` | Every 15 min | Syncs Google Calendar to Nextcloud CalDAV |
| `garmin-sync.timer` | Every 30 min | Imports Garmin activities into Wanderer |
| `wanderer-health.timer` | Every 5 min | Restarts Wanderer containers if unhealthy |

## Setup

See [RESTORE.md](RESTORE.md) for the full disaster recovery runbook — it covers a complete rebuild from scratch including restoring from backup.

The short version:

```bash
# 1. Install Docker
sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
sudo systemctl enable --now docker

# 2. Clone and configure
git clone https://github.com/bradpenney/homelab.git
cd homelab
cp .env.example .env
# Fill in .env from your password manager

# 3. Start the stack
docker compose up -d
```

## Patching

Images update automatically every day at 4am. If an update breaks something, systemd reports the failure.

To update manually:

```bash
docker compose pull && docker compose up -d
docker image prune -f
```

Two images are pinned to specific versions — `nextcloud:33` and `meilisearch:v1.36.0`. They still receive patch updates within that version, but major version bumps require a manual change to `compose.yaml`.

## Repo Structure

```
compose.yaml              # All services — the whole stack in one file
.env.example              # Variable template — copy to .env, never commit .env
backup.sh                 # Nightly encrypted backup to Google Drive via rclone
update.sh                 # Daily Docker image update
notify.sh                 # ntfy push notification helper
garmin_sync.py            # Pulls Garmin activities and pushes to Wanderer
gcal_caldav_sync.py       # Syncs Google Calendar to Nextcloud CalDAV
ddns-update.sh            # Updates Vercel DNS when home IP changes
setup-users.sh            # One-time Nextcloud user and group provisioning
*.service / *.timer       # systemd units for all of the above
RESTORE.md                # Step-by-step rebuild guide
```

---

Part of the [bradpenney.io](https://bradpenney.io) ecosystem — a collection of learning sites and tools for platform engineers and developers.
