# Nextcloud Restore Runbook

Use this if the host machine dies and you need to rebuild from scratch.

## What you need before starting

- A fresh Fedora machine
- Your password manager (you need 5 secrets from it)
- Access to the git repo containing this stack

## Secrets required from password manager

| Secret | Used for |
|--------|----------|
| `MYSQL_ROOT_PASSWORD` | MariaDB root access |
| `MYSQL_PASSWORD` | Nextcloud DB user |
| `VERCEL_TOKEN` | DDNS updates |
| rclone encryption password | Decrypting Google Drive backup |
| rclone salt password | Decrypting Google Drive backup |

## Step 1 — Install Docker

```bash
sudo dnf -y install dnf-plugins-core
sudo dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo
sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
sudo systemctl enable --now docker
```

## Step 2 — Clone the repo and configure

```bash
git clone https://github.com/bradpenney/homelab.git homelab
cd homelab
cp .env.example .env
# Edit .env and fill in all values from your password manager
nano .env
```

## Step 3 — Install rclone and configure remotes

```bash
sudo dnf install rclone

# Set up Google Drive remote (requires browser authorization)
rclone config
# Choose: n (new remote) → name: gdrive → type: drive
# Follow OAuth prompts in browser
```

Then add the crypt remote using your saved passwords:

```bash
OBS1=$(rclone obscure "your-encryption-password")
OBS2=$(rclone obscure "your-salt-password")
rclone config create nextcloud-crypt crypt \
  remote=gdrive:nextcloud-backup \
  filename_encryption=standard \
  directory_name_encryption=true \
  password="$OBS1" \
  password2="$OBS2"
```

Verify you can see the backup:

```bash
rclone ls nextcloud-crypt:
```

## Step 4 — Restore data from Google Drive

```bash
mkdir -p ~/homelab/nextcloud-data ~/homelab/nextcloud-config ~/homelab/nextcloud-db

# Restore Nextcloud data and config
rclone sync nextcloud-crypt:data ~/homelab/nextcloud-data
mkdir -p ~/homelab/nextcloud-config/config ~/homelab/nextcloud-config/custom_apps
rclone sync nextcloud-crypt:config ~/homelab/nextcloud-config/config
rclone sync nextcloud-crypt:custom_apps ~/homelab/nextcloud-config/custom_apps

# List available dumps and download the most recent
rclone ls nextcloud-crypt:db
rclone copyto nextcloud-crypt:db/nextcloud-dump-YYYY-MM-DD.sql.gz /tmp/nextcloud-dump.sql.gz
```

## Step 5 — Set up Traefik data directory

```bash
mkdir -p ~/homelab/traefik-data
touch ~/homelab/traefik-data/acme.json
chmod 600 ~/homelab/traefik-data/acme.json
```

## Step 6 — Fix permissions

```bash
# Nextcloud runs as www-data (uid 33)
sudo chown -R 33:33 ~/homelab/nextcloud-data
sudo chown -R 33:33 ~/homelab/nextcloud-config
```

## Step 7 — Update router port forwarding

Log into your router and update the port forwarding rules to point to the new machine's LAN IP:

- TCP port 80 → new machine IP
- TCP port 443 → new machine IP

Find the new machine's LAN IP with:

```bash
ip addr show | grep "inet " | grep -v 127.0.0.1
```

## Step 8 — Start the stack and restore the database

```bash
cd ~/homelab

# Start only MariaDB first
sudo docker compose up -d mariadb

# Wait ~15 seconds for MariaDB to initialize, then restore the dump
source .env
zcat /tmp/nextcloud-dump.sql.gz | sudo docker exec -i nextcloud-db mariadb \
  -u root -p"${MYSQL_ROOT_PASSWORD}" \
  nextcloud

# Bring up the rest
sudo docker compose up -d
```

## Step 9 — Install DDNS, backup, and cron timers

```bash
chmod +x ~/homelab/ddns-update.sh ~/homelab/backup.sh ~/homelab/notify.sh

sudo mkdir -p /var/cache/ddns-vercel

sudo cp ~/homelab/ddns-vercel.service /etc/systemd/system/
sudo cp ~/homelab/ddns-vercel.timer /etc/systemd/system/
sudo cp ~/homelab/nextcloud-backup.service /etc/systemd/system/
sudo cp ~/homelab/nextcloud-backup.timer /etc/systemd/system/
sudo cp ~/homelab/nextcloud-backup-notify.service /etc/systemd/system/
sudo cp ~/homelab/nextcloud-cron.service /etc/systemd/system/
sudo cp ~/homelab/nextcloud-cron.timer /etc/systemd/system/

sudo systemctl daemon-reload
sudo systemctl enable --now ddns-vercel.timer
sudo systemctl enable --now nextcloud-backup.timer
sudo systemctl enable --now nextcloud-cron.timer
```

Test the notification to confirm ntfy is working:

```bash
sudo ~/homelab/notify.sh "Test" "ntfy is working on $(hostname)"
```

## Step 10 — Open firewall ports

```bash
sudo firewall-cmd --permanent --add-service=http
sudo firewall-cmd --permanent --add-service=https
sudo firewall-cmd --reload
```

## Step 11 — Run database migrations if needed

If Nextcloud shows an error about database schema or a maintenance banner, run:

```bash
sudo docker exec nextcloud-app php occ upgrade
sudo docker exec nextcloud-app php occ maintenance:mode --off
```

## Step 12 — Verify

- Visit `https://nextcloud.bradpenney.io` — should load with valid TLS
- Log in and confirm your files are present
- Check `sudo docker compose logs` for any errors

## Ongoing — Check backup health

The backup runs daily at 3am. To confirm it ran successfully:

```bash
# Check last run status
systemctl status nextcloud-backup.service

# Check logs for last run
journalctl -u nextcloud-backup.service -n 50

# Confirm files are reachable on Google Drive
rclone ls nextcloud-crypt:db
```

If the backup is failing, common causes:
- Google Drive OAuth token expired: run `rclone config reconnect gdrive:` and re-authorize
- Nextcloud container not running: `sudo docker compose up -d`
- Disk full: check with `df -h`
