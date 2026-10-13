#!/usr/bin/env bash
#
# backup-diagnose.sh — collect everything needed to explain a failed backup
#                      run into one file.
#
# Usage:  sudo scripts/backup-diagnose.sh [since]      (default: yesterday)
#
#   since   Anything journalctl --since accepts: "yesterday", "2026-09-06",
#           "2 days ago", "-3h".
#
# Read-only: journal reads, df, and restic with --no-lock. It never touches the
# repository, the stack, or the backup disk.
#
# Writes to ${COMPOSE_DIR}/.backup-diagnose.out rather than only stdout,
# because that directory is NFS-exported to the workstation — so the report can
# be read from the machine you are sitting at without copying anything back.
# THE OUTPUT IS NOT PUBLISHABLE: it contains the hostname, LAN addresses,
# repository IDs and the offsite bucket. It is gitignored and blocked by the
# pre-commit hook. This repo is public.

set -uo pipefail   # deliberately not -e: a missing unit or an absent marker
                   # file must not abort the rest of the collection.

COMPOSE_DIR=/home/mmatasic/homeserver
OUT="${COMPOSE_DIR}/.backup-diagnose.out"
SINCE="${1:-yesterday}"

RESTIC=(restic -r /mnt/backup/restic --password-file /root/.restic-password)
export RESTIC_CACHE_DIR=/var/cache/restic

UNITS=(homeserver-restic.service
       homeserver-restic-photos.service
       homeserver-restic-offsite.service)

[[ $EUID -eq 0 ]] || { echo "must run as root (journal + /root/.restic-password)" >&2; exit 1; }

# Owned by root, but the point is to read it as mmatasic over the export.
exec > >(tee "$OUT") 2>&1
trap 'chmod 644 "$OUT"' EXIT

section() { printf '\n===== %s =====\n' "$*"; }

section "collected"
date -Is; hostname -s; echo "since: ${SINCE}"

# The one channel that cannot itself fail — check it before the journal.
section "failure marker log"
cat /var/lib/homeserver/backup-failures.log 2>&1

section "unit states"
systemctl status "${UNITS[@]}" --no-pager -l 2>&1

section "timers"
systemctl list-timers 'homeserver-restic*' --all --no-pager 2>&1

for u in "${UNITS[@]}"; do
    section "journal: ${u}"
    journalctl -u "$u" --since "$SINCE" --no-pager 2>&1
done

section "journal: notifier"
journalctl -t backup-failure --since "$SINCE" --no-pager 2>&1

# Both guards in restic-backup.sh are mount checks, so record what they saw.
section "mounts and free space"
mountpoint /mnt/backup; mountpoint /mnt/data
df -h /mnt/backup /var / 2>&1

# The USB enclosure is a JMicron bridge with no SMART passthrough: the kernel
# log is the only place a dropped disk shows up.
section "kernel: disk and usb errors"
journalctl -k --since "$SINCE" --no-pager 2>&1 \
    | grep -iE 'usb|sd[a-z]|ext4|i/o error|reset|disconnect' | tail -40

section "snapshots"
"${RESTIC[@]}" snapshots --no-lock 2>&1 | tail -40

# A lock left behind by a killed run is what makes every subsequent run fail.
section "repository locks"
"${RESTIC[@]}" list locks 2>&1 | tail -10
