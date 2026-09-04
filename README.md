# homeserver

Docker Compose stack for a self-hosted home server: media, photos, file sync, personal finance
and home automation, behind a single reverse proxy with automatic TLS.

> Configuration only. No secrets are committed — `.env` is git-ignored and every credential in
> `docker-compose.yml` is a `${VARIABLE}` reference. See [`.env-example`](.env-example).

## Services

### Media & library

| Service | What it does |
|---|---|
| Jellyfin | Film, TV and music server. Hardware transcoding via Intel iGPU (`/dev/dri`) |
| Navidrome | Music streaming (Subsonic API), with Last.fm scrobbling |
| Audiobookshelf | Audiobook and podcast server |
| Immich | Photo and video library — server, machine-learning worker, PostgreSQL, Redis |
| Beets | Music library tagging and organisation |

### Acquisition

| Service | What it does |
|---|---|
| Sonarr / Radarr / Lidarr | TV, film and music tracking and downloading |
| Bazarr | Subtitle auto-download for Sonarr and Radarr |
| Jackett | Indexer proxy feeding the \*arr stack |
| Transmission | BitTorrent client |
| Jellyseerr | Request front-end for Jellyfin users |

### Home automation

| Service | What it does |
|---|---|
| Home Assistant | Automation hub. Host networking, for mDNS and device discovery |
| Mosquitto | MQTT broker |
| Zigbee2MQTT | Zigbee coordinator bridge (network-attached adapter) |
| Matter Server | Matter/Thread device controller. Host networking |
| OpenThread Border Router | Thread border router over a USB RCP. Host networking |

### Infrastructure

| Service | What it does |
|---|---|
| SWAG | nginx reverse proxy, Let's Encrypt certificates, fail2ban |
| Pi-hole | Network-wide DNS and ad blocking |
| Nextcloud + MariaDB | File sync and share |
| Actual Budget | Personal finance |
| Heimdall | Application dashboard |

## Access model

Three patterns, deliberately:

| Pattern | Services | Notes |
|---|---|---|
| **Reverse proxy only** — no host port | Jellyfin, Navidrome, Immich, Actual, Nextcloud, Heimdall | Reached over HTTPS at a subdomain. SWAG resolves them **by container name** on the Compose network, so no port needs publishing |
| **LAN only** — host port published | Sonarr, Radarr, Lidarr, Jackett, Bazarr, Jellyseerr, Audiobookshelf, Transmission, Beets, Pi-hole admin, Zigbee2MQTT | Admin interfaces, reachable on the LAN only |
| **Host networking** | Home Assistant, Matter Server, OpenThread Border Router | Required for mDNS, Thread and Bluetooth |

Adding a service to the first group means dropping its `ports:` entry and adding a proxy conf to
SWAG — not binding it to `127.0.0.1`, which SWAG could not reach from its own container.

Each name in `SUBDOMAINS`/`EXTRA_DOMAINS` needs a matching `*.subdomain.conf` in SWAG's
`proxy-confs/`, or the certificate covers a hostname that serves nothing.

## Layout

```
docker-compose.yml          the stack
.env                        secrets and paths (git-ignored — copy from .env-example)
hwaccel.transcoding.yml     Immich hardware-transcoding profiles
<service>/                  per-service config directories (git-ignored)
scripts/                    backup, failure notification and git hooks
systemd/                    timer units for the nightly backups
home-assistant/config/      HA configuration — YAML is tracked, runtime state is not
```

`DATA` in `.env` points at wherever those per-service directories live; in the default layout that
is this repository's own directory. `MEDIA` points at the media library, typically a NAS mount.

## Getting started

```bash
git clone git@github.com:mmatasic/homeserver.git homeserver && cd homeserver

cp .env-example .env
chmod 600 .env
$EDITOR .env                 # fill in paths, domains and passwords

bash scripts/setup-hooks.sh  # pre-commit hook that blocks committing secrets

docker compose up -d
```

Several relative paths in `.env` (for example `DB_DATA_LOCATION`) resolve against the Compose file,
so run `docker compose` from the repository root.

## Common commands

```bash
docker compose up -d                    # start everything
docker compose up -d <service>          # start or recreate one service
docker compose stop                     # stop, keep containers
docker compose down                     # stop and remove containers
docker compose ps                       # status
docker compose logs -f <service>        # follow logs
docker compose pull && docker compose up -d   # update images and recreate
docker image prune -f                   # reclaim space from old images
```

## Documentation

| Doc | Covers |
|---|---|
| [BACKUP.md](BACKUP.md) | What is backed up and how, restore procedures, retention, design decisions |
| [DISASTER_RECOVERY.md](DISASTER_RECOVERY.md) | Recovery runbook — rebuilding from scratch, database restores, Zigbee network recovery |
| [otbr-commands.md](otbr-commands.md) | OpenThread Border Router setup commands |

Site-specific values (addresses, external hostname, disk identifiers) and security notes are kept out
of this repository on purpose — they describe live infrastructure.

## Backups

Nightly [restic](https://restic.net/) snapshots to a dedicated USB disk, in two groups: service
configuration plus database dumps at 04:00, and the Immich photo libraries at 02:00. Encrypted
client-side, deduplicated and compressed. The media library is deliberately excluded.

```bash
systemctl list-timers 'homeserver-restic*'    # schedule
sudo systemctl start homeserver-restic.service # run one now
```

The backup runs as root because a large share of the data — Nextcloud user files, Home Assistant's
`.storage` — is not readable otherwise. [BACKUP.md](BACKUP.md) covers restores and the reasoning.

## Notes

- Images are pinned loosely (`:latest` for most services). Pin major versions before relying on this
  for disaster recovery: Nextcloud refuses to skip a major version, and Immich needs sequential
  migrations.
- `PUID`/`PGID` are a linuxserver.io convention. Services not built on those images
  (Home Assistant, Mosquitto, Zigbee2MQTT, Pi-hole, Nextcloud, Jellyseerr, Actual) ignore them and
  write files as root.
