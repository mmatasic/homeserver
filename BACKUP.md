# Backup and Restore

Built 2026-09-04 on [restic](https://restic.net/). Replaces an earlier tar+gpg
system that never produced a single usable archive — see
[the post-mortem](#post-mortem-why-the-previous-system-produced-nothing) at the
bottom, because the failure modes it hit are worth not repeating.

> Site-specific values — IP addresses, the external hostname, the disk UUID and
> the repository ID — are deliberately not in this file. This repository is
> public. They live in `LOCAL.md`, which is gitignored.

---

## Overview

| | |
|---|---|
| Tool | restic, repository format v2 (compression enabled) |
| Repository | `/mnt/backup/restic` on a dedicated 1.8 TB USB disk |
| Encryption | Client-side AES-256. The passphrase is the only key |
| Runs as | **root** — required, see [why](#why-it-must-run-as-root) |
| Schedule | Photos 02:00, services 04:00, nightly via systemd timers |
| Retention | 7 daily, 4 weekly, 6 monthly, applied per tag |

Two independent backup groups, each with its own tag, timer and retention:

- **`services`** — everything under `/home/mmatasic/homeserver` plus fresh
  database dumps. Requires a short outage.
- **`photos`** — the Immich libraries on the NAS. No outage.

---

## What is backed up

**`services`** — the whole compose tree, which is where every service keeps its
state (`DATA` points at the repo directory itself). That includes:

- All 25 service configuration directories
- `nextcloud/` — the Nextcloud install *and* ~31 GB of user files
- `home-assistant/config/` — including `.storage`, which holds the entity and
  device registries. Losing those means re-pairing every Zigbee device.
- `zigbee2mqtt/` — including the Zigbee network key
- Two SQL dumps written fresh at the start of each run (below)

**`photos`** — `/mnt/data/Pictures` (Immich upload location) and
`/mnt/data/Pictures-old-lib` (external library).

## What is not backed up

| Excluded | Reason |
|---|---|
| The media library on the NAS | Re-acquirable. This is the deliberate scope decision that keeps the repo small |
| `immich-postgres/`, `db_data/` | Live database directories. A file-level copy of a running Postgres or MariaDB datadir is torn and cannot be restored — the SQL dumps are the real backup |
| `**/cache` | jellyfin/config/cache 3.2 GB, navidrome/cache 543 MB, Nextcloud per-user caches |
| `**/MediaCover` | lidarr 4.6 GB + radarr 1.8 GB of artwork. Regenerable, and it churns, so it would add delta to every snapshot |
| `**/Backups` | The \*arr apps' own internal backups — backing up backups |
| `**/logs`, `*.log` | Includes an 8 GB unrotated `nextcloud.log` |
| `pihole-FTL.db`, `gravity.db` | Query history and blocklists, both rebuilt on demand |

The exclusion list lives in [`scripts/restic-excludes.txt`](scripts/restic-excludes.txt).

Net effect: a 59 GB tree becomes a **35.4 GiB** snapshot, stored in **27.2 GiB**
after deduplication and compression.

---

## How consistency is handled

Three different problems, three different answers.

**PostgreSQL and MariaDB** are dumped hot, before anything stops, using each
container's own credentials read from inside the container. No downtime, and the
script never needs to read `.env`.

Both dumps are verified with `gzip -t` before the snapshot proceeds. A truncated
dump is worse than a missing one, because it looks like success.

> `docker exec` is called **without `-t`** in the dump commands. A TTY translates
> LF to CRLF and silently corrupts the gzip stream. Immich's own documentation
> gets this wrong.

**SQLite** — used by Sonarr, Radarr, Lidarr, Bazarr, Jellyfin, Navidrome,
Audiobookshelf, Actual, Jellyseerr and Home Assistant. Copying a live WAL-mode
database risks a torn snapshot, so the stack is stopped for the duration of the
snapshot. Since an incremental run reads almost nothing, the outage is well under
a minute; a full cold read of the whole tree is about 5 minutes.

**Pi-hole stays running.** It is the only service whose downtime is felt as a
LAN-wide DNS outage, and none of its state needs quiescing — the config is static
text and both of its SQLite databases are regenerable and already excluded.

---

## Schedule

```
02:00  homeserver-restic-photos.timer  →  photos, no outage
04:00  homeserver-restic.timer         →  services, brief outage
```

Both timers use `Persistent=true`, so a run missed while the server was off fires
on next boot rather than being skipped.

The two runs share a `flock`, so they can never overlap on the repository. Photos
go first because that run is far longer.

On failure, `OnFailure=backup-failure@%n.service` fires
[`scripts/notify-failure.sh`](scripts/notify-failure.sh). **Configure a channel in
that script and test it deliberately** — an untested failure notification is the
same as no notification, which is exactly how the old system stayed broken for
months.

---

## Daily operations

```bash
# did last night's runs work?
systemctl status homeserver-restic.service homeserver-restic-photos.service
systemctl list-timers 'homeserver-restic*'

# anything failed while you were away?
cat /var/lib/homeserver/backup-failures.log

# what is in the repository
sudo restic -r /mnt/backup/restic --password-file /root/.restic-password snapshots
sudo restic -r /mnt/backup/restic --password-file /root/.restic-password stats latest

# free space on the backup disk
df -h /mnt/backup

# run one now, by hand
sudo systemctl start homeserver-restic.service
journalctl -u homeserver-restic.service -f
```

---

## Restoring

### Browse snapshots as files

The easiest way to get one file back. Mounts every snapshot as a filesystem:

```bash
sudo mkdir -p /mnt/restic-browse
sudo restic -r /mnt/backup/restic --password-file /root/.restic-password \
  mount /mnt/restic-browse
```

Then `/mnt/restic-browse/snapshots/latest/` is a normal directory tree. Copy what
you need out with `cp`. Ctrl-C to unmount.

### Restore specific paths

```bash
sudo restic -r /mnt/backup/restic --password-file /root/.restic-password \
  restore latest --target /tmp/restore-test \
  --include /home/mmatasic/homeserver/home-assistant/config/.storage
```

Restores land *under* the target with their full original path, so the example
above produces
`/tmp/restore-test/home/mmatasic/homeserver/home-assistant/config/.storage`.
Always restore somewhere scratch first and diff before overwriting anything live.

### Restore a database

The dumps are inside the snapshot at `/var/backups/homeserver-dumps/`.

```bash
sudo restic -r /mnt/backup/restic --password-file /root/.restic-password \
  restore latest --target /tmp/dumps --include /var/backups/homeserver-dumps

cd /home/mmatasic/homeserver
D=/tmp/dumps/var/backups/homeserver-dumps

# Immich (PostgreSQL)
docker compose stop immich-server immich-machine-learning
gunzip -c "$D/immich-postgres.sql.gz" | docker exec -i immich_postgres \
    sh -c 'psql --username "$POSTGRES_USER" -v ON_ERROR_STOP=1 postgres'
docker compose start immich-server immich-machine-learning

# Nextcloud (MariaDB)
docker compose stop nextcloud
gunzip -c "$D/nextcloud-mariadb.sql.gz" | docker exec -i nextcloud_db \
    sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mariadb -u root'
docker compose start nextcloud

# Nextcloud only: reconcile the file cache with what is actually on disk
docker exec -u www-data nextcloud php occ maintenance:repair
docker exec -u www-data nextcloud php occ files:scan --all
```

> `-v ON_ERROR_STOP=1` is not optional. Without it `psql` prints errors and
> keeps going, leaving a half-restored database and exit status 0 — a restore
> that reports success while having failed.

The Immich dump is from `pg_dumpall --clean --if-exists`, so it drops and
recreates objects itself — restore it against the running server, not an empty one.

Full bare-metal recovery is in [DISASTER_RECOVERY.md](DISASTER_RECOVERY.md).

---

## Maintenance

```bash
# structural integrity — runs automatically after every backup
sudo restic -r /mnt/backup/restic --password-file /root/.restic-password check

# actually re-read and verify a tenth of the data
sudo restic -r /mnt/backup/restic --password-file /root/.restic-password \
  check --read-data-subset=1/10
```

That second one matters more here than it normally would. The USB enclosure uses
a JMicron bridge that does not pass SMART through, so there is **no health
telemetry from this disk at all**. Re-reading data and verifying it against
stored hashes is the only way bit rot surfaces as something other than a failed
restore. Worth running monthly.

---

## Design decisions

**Why restic.** Deduplicating, encrypted, single self-contained binary, and it
speaks local disk, SFTP, S3 and Backblaze B2 natively. borgmatic was the other
candidate and has nicer native database hooks, but its `ssh://` repositories
require Borg installed on the far end, and it has no native B2 or S3 support —
which would have blocked the offsite tier.

**Why not a GUI-driven tool.** Backrest is a good web UI over restic and can be
added later. It was not made the scheduler because this backup needs root *and*
control of the Docker stack; in a container that means mounting the Docker
socket, which is equivalent to giving a web UI root on the host. The scheduler
stays in systemd where the guards live. See the note in the README.

**Why the media library is excluded.** It is re-acquirable, it is the great
majority of the bytes, and including it would have forced a much larger offsite
tier. Photos are a different matter and *are* included — they are irreplaceable,
and RAID 1 on the NAS protects against a failed drive but not against deletion,
ransomware, or losing the NAS itself.

**Why the first snapshot was primed manually.** A cold first run moves hundreds
of gigabytes. Priming it with services running means the first *scheduled* run
has almost nothing left to transfer, so the outage is minutes rather than hours.
Those priming snapshots get forgotten by the first retention pass, but their data
blocks stay in the repository because later snapshots reference them — restic
deduplicates at blob level, not snapshot level, so nothing is re-read.

### Why it must run as root

`nextcloud/data` is owned by `www-data` and `home-assistant/config/.storage`
contains root-owned files. Measured directly:

| | as an unprivileged user | as root |
|---|---|---|
| `nextcloud/` | 1.2 GB | 39 GB |
| whole tree | ~19.5 GB | 59 GB |

**37.8 GB of user data is invisible to a non-root process.** An unprivileged
backup walks straight past it and reports success.

---

## Post-mortem: why the previous system produced nothing

Kept because each of these is a trap worth recognising again.

**1. It died on line 1 of every run.** All four scripts began with
`source .env` under `set -euo pipefail`:

```console
$ bash -c 'set -euo pipefail; source .env; echo OK'
.env: line 2: UID: readonly variable
exit 1          # "OK" never prints
```

`UID` is readonly in bash, so sourcing aborted immediately. A second line,
`WG_PEERS=laptop, phone, pc`, would have broken it too — bash reads that as a
command called `phone,`. Both were leftovers from a removed WireGuard service and
have since been deleted from `.env`. Docker Compose was never affected; it uses
its own parser, not bash.

The current script **never sources `.env`**. Database credentials are read from
inside the containers instead, which removes the failure mode rather than
patching it.

**2. Nothing would have told you.** The systemd units had no `OnFailure=`, and
`verify-backup.sh` — the one thing that would have caught it — died the same way.
It failed every night for months in silence.

**3. It ran as the wrong user.** `User=mmatasic`, so even once fixed it would
have produced archives missing two thirds of the tree while reporting success.
That failure is worse than the one it actually had.

**4. The destination was the source.** `NAS_BACKUP_MOUNT` and `MEDIA` were both
`/mnt/data` — backups on the same NAS volume as the data they protected.

**5. No deduplication.** ~19.4 GB per run × 23 retained archives ≈ 300 GB of
near-identical tarballs.

---

## Open items

- **Offsite copy.** Everything currently lives in one building. Fire, theft or
  ransomware reaching the server takes both copies. Backblaze B2 is the intended
  destination; at this data volume the cost is a few dollars a month.

  When initialising the B2 repository, do it with
  `--copy-chunker-params --from-repo /mnt/backup/restic` so that `restic copy`
  deduplicates against the existing repository instead of re-chunking everything.
  That flag can only be set at init time.

- **Backrest**, if a web UI for browsing and restoring is wanted. Bind it to
  localhost only — it can read every file in the repository.

- **Restore drill.** Restoring one file proves the mechanism. Rebuilding a
  service from scratch proves the backup. Worth doing once, deliberately.
