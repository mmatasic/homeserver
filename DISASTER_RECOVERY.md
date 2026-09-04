# Disaster Recovery Runbook

Rewritten 2026-09-04 for the restic-based backup system. See
[BACKUP.md](BACKUP.md) for how the backups are made and what they contain.

> Site-specific values — IP addresses, the external hostname, the backup disk
> UUID — are in `LOCAL.md`, which is gitignored because this repository is
> public. Placeholders below are written as `<nas-ip>`, `<server-ip>` and so on.

---

## Before anything else

**You need the restic passphrase.** It is in your password manager under
*"restic — homeserver backup repo"*. Without it the repository is
cryptographically unrecoverable — there is no reset, no vendor, no support path.
A copy also lives at `/root/.restic-password` on the server, which is exactly the
machine you may no longer have.

Everything below assumes you have it.

---

## Step 0 — Fresh-system prerequisites

Everything in Scenario A assumes the list below is done. Work through it before
touching restic: several of these are painful to change once a restore has
already landed on disk.

### 0.1 What you must physically have

| Thing | Where it lives | If you don't have it |
|---|---|---|
| **restic passphrase** | password manager | The repository is unrecoverable. No reset, no vendor, no support path. |
| Backup disk | ext4, label `backup` | No data at all — git carries configuration only. |
| NAS powered and reachable | `<nas-ip>:/volume1/media/` | No media library, no Immich originals. |
| Thread/Zigbee USB stick | USB serial adapter | Zigbee and Thread devices stay offline. |
| Router admin access | — | No static lease, no 80/443 forward. |

**The git repository is a subset of the backup, not a complement to it.**
`.env`, `LOCAL.md`, Home Assistant's `.storage/`, HACS `custom_components/`,
`www/`, the Zigbee network key and every service data directory are gitignored
and exist *only* inside the restic repository.

### 0.2 OS install choices that are hard to undo

- **Ubuntu Server LTS**, minimal install.
- **Create the user with UID 1000 and GID 1000.** `.env` pins `UID=1000` /
  `GID=1000`, and nearly every container runs as `PUID`/`PGID` from those. A
  restore writes original numeric ownership, so a mismatch means every service
  fails on permissions. Check with `id -u; id -g` *before* restoring; fix with
  `usermod -u` / `groupmod -g` if wrong — never after.
- **Same username**, or `DATA=` in `.env` and every absolute path in the
  snapshot has to be rewritten. `mmatasic` is the path baked into the backup.
- **Set the timezone to match `TZ` in `.env`** (`sudo timedatectl set-timezone …`).
  `/etc/localtime` and `/etc/timezone` are bind-mounted read-only into Home
  Assistant, Zigbee2MQTT, MQTT and Immich — a wrong host clock silently
  propagates into automations and photo timestamps.
- **Static IP, or the old DHCP reservation.** Pi-hole is the LAN DNS server; if
  its address moves, every client on the network loses DNS.

### 0.3 Packages

```bash
sudo apt-get update
sudo apt-get install -y docker.io docker-compose-v2 nfs-common git curl bzip2
sudo systemctl enable --now docker
sudo usermod -aG docker "$USER" && newgrp docker
```

restic comes from upstream, not apt — see Scenario A step 4. The Ubuntu package
is 0.12.1, which predates repository format v2 and **cannot open this repo**.

### 0.4 Host services and kernel bits

**Free up port 53.** Pi-hole publishes `53:53/tcp` and `53:53/udp`, and Ubuntu's
`systemd-resolved` stub listener already holds it. Docker will fail to bind.

```bash
sudo mkdir -p /etc/systemd/resolved.conf.d
printf '[Resolve]\nDNSStubListener=no\n' \
  | sudo tee /etc/systemd/resolved.conf.d/no-stub.conf
sudo ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
sudo systemctl restart systemd-resolved
ss -ulnp | grep ':53 '          # must print nothing
```

Also needed:

- **dbus running** — `matter-server` bind-mounts `/run/dbus` for Bluetooth
  commissioning, and runs `apparmor:unconfined`.
- **`tun` module** — `otbr` uses `/dev/net/tun`. `lsmod | grep -w tun`, else
  `sudo modprobe tun` and add it to `/etc/modules`.
- **Bluetooth adapter** if you commission Matter devices over BLE.

### 0.5 Mounts, in this order

1. `/mnt/data` — the NFS media share. **Mount it before any container starts.**
   If it is missing, Docker happily creates empty directories at the mountpoint
   and Immich concludes the entire library has been deleted.
2. `/mnt/backup` — the restic disk, by UUID, with `nofail`.
3. `/var/backups/homeserver-dumps` — you do not create this; the restore puts it
   back at its absolute path.

### 0.6 Hardware to reconnect

- **Intel iGPU** → `/dev/dri/renderD128` and `/dev/dri/card0`. Declared under
  `devices:` for both `jellyfin` and `immich-server`; if the nodes are absent
  those two services refuse to start.
- **`/dev/ttyUSB0`** — the Thread RCP, opened at 460800 baud by `otbr`. Confirm
  with `ls -l /dev/serial/by-id/`; if it enumerated as `ttyUSB1`, fix the path
  rather than replugging until it matches.

### 0.7 Edit after the restore, before `docker compose up`

- **`OT_INFRA_IF=eno1`** in the `otbr` service is a hardcoded interface name.
  New hardware will almost certainly name its NIC something else. Run
  `ip -br link` and correct it, or Thread never forms a network.
- `DATA=/home/mmatasic/homeserver/` in `.env` — right only if the username and
  home directory are unchanged.
- The UUID and NAS address in `/etc/fstab`.

### 0.8 Not in any backup — recreate by hand

| | Recovery |
|---|---|
| `/root/.restic-password` | Paste from the password manager (Scenario A step 5). |
| `/etc/fstab` entries | Scenario A steps 2–3. |
| Static IP / netplan | Values are in `LOCAL.md`, which is itself inside the backup. |
| `model-cache` Docker volume | Immich ML models; re-downloaded automatically on first start. Bandwidth, not data loss. |
| Router port-forwards 80/443 | Configure on the router. |
| DuckDNS record | Updates itself once the container runs. |
| systemd timer units | In the repository; installed at Scenario A step 10. |

### 0.9 Verify before starting the stack

```bash
id -u; id -g                          # 1000 / 1000
timedatectl | grep 'Time zone'        # matches TZ in .env
findmnt /mnt/data /mnt/backup         # both present
ls -l /dev/dri/renderD128 /dev/ttyUSB0
ss -ulnp | grep ':53 '                # empty
ip -br link                           # NIC name matches OT_INFRA_IF
cd /home/mmatasic/homeserver && docker compose config >/dev/null \
  && echo "compose resolves — every .env variable is present"
```

That last check is the useful one: `docker compose config` fails loudly if any
variable the restore was supposed to bring back is missing.

---

## Scenario A — Server hardware failure, rebuild from scratch

Estimated 2–3 hours, most of it unattended restore.

### 1. Provision the OS

```bash
# Install Ubuntu Server LTS, then:
sudo apt-get update
sudo apt-get install -y docker.io docker-compose-v2 nfs-common git curl

sudo systemctl enable --now docker
sudo usermod -aG docker "$USER"
newgrp docker
```

Set the server's static IP, or restore its DHCP reservation on the router.

Reconnect the hardware the stack expects:

- USB serial adapter → Thread/Zigbee border router (`/dev/ttyUSB0`)
- Intel iGPU → `/dev/dri/renderD128`, `/dev/dri/card0`, used by Jellyfin and
  Immich for transcoding

### 2. Mount the NAS

```bash
sudo mkdir -p /mnt/data
echo '<nas-ip>:/volume1/media/ /mnt/data nfs defaults,_netdev,noatime,nofail 0 0' \
  | sudo tee -a /etc/fstab
sudo mount -a
findmnt /mnt/data
```

`nofail` matters — without it an unreachable NAS hangs the boot.

### 3. Attach and mount the backup disk

```bash
lsblk -o NAME,SIZE,FSTYPE,LABEL,UUID
# The disk is ext4, labelled "backup". Find its UUID, or use LOCAL.md.

sudo mkdir -p /mnt/backup
echo 'UUID=<backup-disk-uuid> /mnt/backup ext4 defaults,nofail,noatime,x-systemd.device-timeout=10 0 2' \
  | sudo tee -a /etc/fstab
sudo mount -a
mountpoint /mnt/backup
```

If it fails to enumerate, see [the USB notes](#appendix-usb-disk-quirks).

### 4. Install restic

```bash
cd /tmp
V=$(curl -fsSL https://api.github.com/repos/restic/restic/releases/latest \
      | grep -oP '"tag_name":\s*"v\K[^"]+')
curl -fsSLO "https://github.com/restic/restic/releases/download/v${V}/restic_${V}_linux_amd64.bz2"
curl -fsSLO "https://github.com/restic/restic/releases/download/v${V}/SHA256SUMS"
sha256sum --ignore-missing -c SHA256SUMS      # must print OK
bunzip2 -f "restic_${V}_linux_amd64.bz2"
sudo install -m 755 "restic_${V}_linux_amd64" /usr/local/bin/restic
restic version
```

Do not use the distro package — it is several major versions behind and predates
repository format v2.

### 5. Restore the passphrase file

```bash
sudo sh -c 'umask 077; cat > /root/.restic-password'
# paste the passphrase from your password manager, then Ctrl-D
sudo chmod 600 /root/.restic-password

# confirm the repository opens
sudo restic -r /mnt/backup/restic --password-file /root/.restic-password snapshots
```

### 6. Restore the whole tree

```bash
sudo restic -r /mnt/backup/restic --password-file /root/.restic-password \
  restore latest --tag services --target /
```

Restores land at their original absolute paths, so this puts everything back at
`/home/mmatasic/homeserver`. On a fresh machine that is what you want; on a
running one, restore to a scratch target and diff first.

```bash
sudo chown -R "$USER:$USER" /home/mmatasic/homeserver
cd /home/mmatasic/homeserver
```

> **`.env` comes from the backup, not from git.** It is gitignored, so the
> repository does not contain it — the restic snapshot is its only copy. It is
> encrypted at rest inside the repository.

### 7. Recreate the live database directories

These are excluded from the backup by design; they are rebuilt from the dumps.

```bash
mkdir -p immich-postgres db_data
docker compose up -d database nextcloud-db
sleep 30
```

### 8. Import the database dumps

```bash
D=/var/backups/homeserver-dumps        # restored in step 6

gunzip -c "$D/immich-postgres.sql.gz" | docker exec -i immich_postgres \
    sh -c 'psql --username "$POSTGRES_USER" postgres'

gunzip -c "$D/nextcloud-mariadb.sql.gz" | docker exec -i nextcloud_db \
    sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mariadb -u root'
```

### 9. Start everything

```bash
docker compose up -d
docker compose ps          # all should show running
```

### 10. Reinstall the backup timers

```bash
sudo cp systemd/homeserver-restic*.service systemd/homeserver-restic*.timer \
        systemd/backup-failure@.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now homeserver-restic.timer homeserver-restic-photos.timer
systemctl list-timers 'homeserver-restic*'

bash scripts/setup-hooks.sh     # git pre-commit secret guard
```

### 11. Verify

```bash
docker compose logs --tail 20 zigbee2mqtt   # "Zigbee2MQTT started!"
docker compose logs --tail 20 homeassistant # no errors
docker exec jellyseerr wget -qO- http://jellyfin:8096/System/Info/Public
```

Zigbee devices should reconnect on their own — the network key is in
`zigbee2mqtt/`, which the restore brought back.

---

## Scenario B — Photos lost or corrupted

```bash
sudo restic -r /mnt/backup/restic --password-file /root/.restic-password \
  snapshots --tag photos

sudo restic -r /mnt/backup/restic --password-file /root/.restic-password \
  restore <snapshot-id> --target /tmp/photo-restore \
  --include /mnt/data/Pictures
```

Verify under `/tmp/photo-restore` before copying anything back over the live
library. Immich regenerates thumbnails automatically once the originals return.

---

## Scenario C — A database is corrupt, server otherwise fine

See the database restore section of [BACKUP.md](BACKUP.md#restore-a-database).
To restore from a specific night rather than the latest:

```bash
sudo restic -r /mnt/backup/restic --password-file /root/.restic-password \
  snapshots --tag services

sudo restic -r /mnt/backup/restic --password-file /root/.restic-password \
  restore <snapshot-id> --target /tmp/dumps \
  --include /var/backups/homeserver-dumps
```

---

## Scenario D — The backup disk fails

The repository is gone; the live system is fine. Nothing is lost yet, but you are
running with no backups until this is fixed.

```bash
# new disk
sudo mkfs.ext4 -m 0 -L backup /dev/sdX1
# update the UUID in /etc/fstab, mount at /mnt/backup, then:
sudo restic -r /mnt/backup/restic --password-file /root/.restic-password \
  init --repository-version 2

# prime it with services running, so the first scheduled run is short
sudo restic -r /mnt/backup/restic --password-file /root/.restic-password \
  backup --tag services --exclude-caches \
  --exclude-file /home/mmatasic/homeserver/scripts/restic-excludes.txt \
  /home/mmatasic/homeserver
```

Record the new UUID in `LOCAL.md`.

---

## Scenario E — Single NAS drive failure

RAID 1 handles this. No server-side action. Replace the drive through the NAS
admin UI and let it rebuild.

RAID is not a backup: it survives a dead drive, not deletion, ransomware, or
losing the NAS. That is what the photo backups are for.

---

## Appendix: USB disk quirks

The backup enclosure uses a JMicron USB-to-ATA bridge that has failed to
enumerate before. Symptoms and what they mean:

```
usb 2-5: New USB device found, idVendor=152d ...   ← bridge is fine
scsi host6: usb-storage ...                        ← SCSI host created
usb 2-5: reset SuperSpeed USB device ×4            ← then resets
(no "Attached SCSI disk" line, no /dev/sdX)        ← drive never answered
```

The bridge enumerating while the drive stays silent means power or cable, not
driver. In order of likelihood: use a rear motherboard port rather than a front
panel header, reseat both ends of the cable, plug in both ends if it is a
Y-cable, or give the enclosure external power.

The bridge does not pass SMART through, so there is no health telemetry from this
disk. `restic check --read-data-subset=1/10` is the substitute — see
[BACKUP.md](BACKUP.md#maintenance).
