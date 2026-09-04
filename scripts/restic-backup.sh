#!/usr/bin/env bash
#
# restic-backup.sh — nightly backup of the homeserver into the restic repo
#                    on the USB disk at /mnt/backup.
#
# Usage:  restic-backup.sh [services|photos]        (default: services)
#
#   services  Dump both databases, stop the stack (except Pi-hole), snapshot
#             /home/mmatasic/homeserver + the dumps, restart. Short outage.
#   photos    Snapshot the Immich libraries on the NAS. No outage — Immich
#             only reads and writes those files, nothing needs quiescing.
#
# Runs as root. That is forced, not a preference: nextcloud/data and
# home-assistant/config/.storage are not readable as mmatasic, which is why
# the previous backup system produced nothing.
#
# This script deliberately never sources .env. Bash cannot source that file —
# UID is readonly, so `source .env` aborts immediately under `set -e`, which
# is what silently killed every run of the old scripts/backup.sh. Database
# credentials are read from inside the containers instead.

set -euo pipefail

### configuration ###########################################################
COMPOSE_DIR=/home/mmatasic/homeserver
BACKUP_MOUNT=/mnt/backup
NAS_MOUNT=/mnt/data

export RESTIC_REPOSITORY=/mnt/backup/restic
export RESTIC_PASSWORD_FILE=/root/.restic-password

DUMP_DIR=/var/backups/homeserver-dumps
EXCLUDES="${COMPOSE_DIR}/scripts/restic-excludes.txt"

# Left running during the outage: it is the LAN's DNS, and none of its state
# needs quiescing — the config is static text and both its SQLite databases
# are regenerable and already excluded.
KEEP_UP=pihole

PHOTO_PATHS=( "${NAS_MOUNT}/Pictures" "${NAS_MOUNT}/Pictures-old-lib" )

RETENTION=( --keep-daily 7 --keep-weekly 4 --keep-monthly 6 )
#############################################################################

MODE="${1:-services}"

log()  { printf '%s  %s\n' "$(date -Is)" "$*"; }
die()  { printf '%s  FATAL: %s\n' "$(date -Is)" "$*" >&2; exit 1; }

# --- guards ----------------------------------------------------------------
[[ $EUID -eq 0 ]] || die "must run as root"
command -v restic >/dev/null 2>&1 || die "restic not found in PATH"
[[ -s "$RESTIC_PASSWORD_FILE" ]] || die "$RESTIC_PASSWORD_FILE missing or empty"
[[ -r "$EXCLUDES" ]] || die "exclude file $EXCLUDES not readable"

# The USB disk is mounted nofail, so if it fails to enumerate at boot the
# server comes up happily with /mnt/backup as an empty directory on the OS
# SSD. Without this check the backup would quietly fill the root filesystem.
mountpoint -q "$BACKUP_MOUNT" \
    || die "$BACKUP_MOUNT is not mounted — refusing to write to the OS disk"

# One run at a time. Both modes share the repo, so serialise them.
exec 9>/var/lock/restic-backup.lock
flock -n 9 || die "another restic-backup run is already in progress"

cd "$COMPOSE_DIR" || die "cannot cd to $COMPOSE_DIR"

#############################################################################
# photos mode — no downtime
#############################################################################
if [[ "$MODE" == "photos" ]]; then
    mountpoint -q "$NAS_MOUNT" || die "$NAS_MOUNT is not mounted"
    for p in "${PHOTO_PATHS[@]}"; do
        [[ -d "$p" ]] || die "photo path $p does not exist"
    done

    log "backing up photo libraries"
    restic backup --tag photos --exclude-caches \
        --exclude-file "$EXCLUDES" "${PHOTO_PATHS[@]}"

    log "applying retention (photos)"
    restic forget --tag photos "${RETENTION[@]}" --prune

    log "checking repository"
    restic check

    log "photos backup complete"
    restic snapshots --tag photos --latest 1
    exit 0
fi

[[ "$MODE" == "services" ]] || die "unknown mode '$MODE' (use: services|photos)"

#############################################################################
# services mode
#############################################################################

# --- restart the stack no matter how this exits ----------------------------
STOPPED_SERVICES=""
restore_stack() {
    if [[ -n "$STOPPED_SERVICES" ]]; then
        log "restarting services"
        # shellcheck disable=SC2086
        docker compose start $STOPPED_SERVICES \
            || log "WARNING: 'docker compose start' failed — CHECK THE STACK MANUALLY"
    fi
}
trap restore_stack EXIT

# --- 1. dump the databases while they are still running --------------------
install -d -m 700 "$DUMP_DIR"
rm -f "${DUMP_DIR}"/*.sql.gz

log "dumping Immich postgres"
# No -t on docker exec: a TTY would translate LF to CRLF and corrupt the gzip
# stream. This is the classic way these dumps end up silently unrestorable.
docker exec immich_postgres sh -c \
    'pg_dumpall --clean --if-exists --username "$POSTGRES_USER"' \
    | gzip > "${DUMP_DIR}/immich-postgres.sql.gz"

log "dumping Nextcloud mariadb"
# --databases rather than --all-databases: the latter carries the mysql system
# database, so a restore overwrites users and grants — and with an unpinned
# mariadb:latest image that can mean system tables from one version landing in
# another. Nextcloud's DB user is recreated by the container entrypoint from
# MYSQL_USER/MYSQL_PASSWORD, so there is nothing lost by leaving it out.
docker exec nextcloud_db sh -c '
    if command -v mariadb-dump >/dev/null 2>&1; then DUMP=mariadb-dump; else DUMP=mysqldump; fi
    MYSQL_PWD="$MYSQL_ROOT_PASSWORD" "$DUMP" \
        --single-transaction --quick --databases nextcloud -u root' \
    | gzip > "${DUMP_DIR}/nextcloud-mariadb.sql.gz"

# A dump that exists but is truncated is worse than no dump, because it looks
# like success. Verify both are complete gzip streams before relying on them.
for f in "${DUMP_DIR}"/immich-postgres.sql.gz "${DUMP_DIR}"/nextcloud-mariadb.sql.gz; do
    [[ -s "$f" ]] || die "dump $f is empty"
    gzip -t "$f"  || die "dump $f is not a valid gzip stream"
    log "dump ok: $(basename "$f") ($(du -h "$f" | cut -f1))"
done

# --- 2. quiesce the stack --------------------------------------------------
# Only services that are actually running, so anything you deliberately
# stopped stays stopped when we start things back up.
RUNNING="$(docker compose ps --services --status running 2>/dev/null \
           | grep -vx "$KEEP_UP" | tr '\n' ' ' || true)"
[[ -n "${RUNNING// /}" ]] || die "no running services found — is the stack up?"

log "stopping services (keeping ${KEEP_UP} up)"
STOPPED_SERVICES="$RUNNING"
# shellcheck disable=SC2086
docker compose stop $RUNNING

# --- 3. snapshot -----------------------------------------------------------
log "running restic backup"
restic backup --tag services --exclude-caches \
    --exclude-file "$EXCLUDES" \
    "$COMPOSE_DIR" "$DUMP_DIR"

# --- 4. bring the stack back immediately, before the slow maintenance ------
log "restarting services"
# shellcheck disable=SC2086
docker compose start $RUNNING
STOPPED_SERVICES=""

# --- 5. retention and integrity (outage is already over) -------------------
log "applying retention (services)"
restic forget --tag services "${RETENTION[@]}" --prune

log "checking repository"
restic check

log "backup complete"
restic snapshots --tag services --latest 1
