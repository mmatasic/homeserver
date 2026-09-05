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

# systemd starts services with no $HOME, and restic aborts outright when it
# cannot locate a cache directory. Interactive `sudo restic` works because sudo
# sets HOME=/root, so this breaks ONLY under the timer — the one context nobody
# is watching. Setting it explicitly also puts the cache where a root-run system
# service's cache belongs, and keeps the script correct under cron or a bare sh.
export RESTIC_CACHE_DIR=/var/cache/restic

DUMP_DIR=/var/backups/homeserver-dumps

# Offsite (Backblaze B2). Credentials and the repo URL live outside this public
# repository, root-only, exactly like the restic passphrase and the notifier
# settings. See scripts/b2-credentials-example.
OFFSITE_CONF=/root/.b2-credentials
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

# Compose v1 (`docker-compose`) and v2 (`docker compose`) are both in the wild:
# this server runs v1, while DISASTER_RECOVERY.md installs v2 on a fresh box.
# Detect instead of assuming. Assuming v2 is what made this script's first real
# run die with a misleading "is the stack up?" while 26 containers were healthy.
if docker compose version >/dev/null 2>&1; then
    COMPOSE=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE=(docker-compose)
else
    die "neither 'docker compose' nor 'docker-compose' is available"
fi
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

#############################################################################
# offsite mode — copy the services snapshots to Backblaze B2
#############################################################################
# Photos are deliberately NOT copied: 359 GiB offsite costs ~$2.50/month while
# the services set is ~$0.13. Revisit that if the photo library ever becomes
# the thing you would most regret losing.
#
# This reads the local repo, so it takes the same flock as the other modes —
# a `forget --prune` running locally while we copy would pull blobs out from
# under us.
if [[ "$MODE" == "offsite" ]]; then
    [[ -r "$OFFSITE_CONF" ]] || die "$OFFSITE_CONF not readable"
    # shellcheck source=/dev/null
    . "$OFFSITE_CONF"
    [[ -n "${OFFSITE_REPO:-}" ]]   || die "OFFSITE_REPO not set in $OFFSITE_CONF"
    [[ -n "${B2_ACCOUNT_ID:-}" ]]  || die "B2_ACCOUNT_ID not set in $OFFSITE_CONF"
    [[ -n "${B2_ACCOUNT_KEY:-}" ]] || die "B2_ACCOUNT_KEY not set in $OFFSITE_CONF"
    export B2_ACCOUNT_ID B2_ACCOUNT_KEY

    # Both repos use the same passphrase, so RESTIC_PASSWORD_FILE covers the
    # destination and --from-password-file covers the source. One secret to
    # protect, one secret to remember in a rebuild.
    log "copying services snapshots offsite"
    restic -r "$OFFSITE_REPO" \
        --from-repo "$RESTIC_REPOSITORY" \
        --from-password-file "$RESTIC_PASSWORD_FILE" \
        copy --tag services

    log "applying retention (offsite)"
    restic -r "$OFFSITE_REPO" forget --tag services "${RETENTION[@]}" --prune

    # Downloads all metadata from B2. Free: the allowance is 3x stored bytes
    # per month and this is a few hundred MB against ~87 GB of headroom.
    log "checking offsite repository"
    restic -r "$OFFSITE_REPO" check

    log "offsite copy complete"
    restic -r "$OFFSITE_REPO" snapshots --tag services --latest 1
    exit 0
fi

[[ "$MODE" == "services" ]] || die "unknown mode '$MODE' (use: services|photos|offsite)"

#############################################################################
# services mode
#############################################################################

# --- restart the stack no matter how this exits ----------------------------
STOPPED_SERVICES=""
restore_stack() {
    if [[ -n "$STOPPED_SERVICES" ]]; then
        log "restarting services"
        # shellcheck disable=SC2086
        "${COMPOSE[@]}" start $STOPPED_SERVICES \
            || log "WARNING: compose start failed — CHECK THE STACK MANUALLY"
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
# Asked of the daemon by compose label rather than through `compose ps`: the
# flags for filtering by status differ between v1 and v2, but the labels do not.
# stderr is deliberately NOT discarded here — discarding it is exactly what
# disguised a missing compose binary as "the stack is down".
PROJECT="$(basename "$COMPOSE_DIR")"
RUNNING="$(docker ps --filter "label=com.docker.compose.project=${PROJECT}" \
                     --format '{{.Label "com.docker.compose.service"}}' \
           | sort -u | grep -vx "$KEEP_UP" | tr '\n' ' ')" || true

if [[ -z "${RUNNING// /}" ]]; then
    die "no running services for compose project '${PROJECT}' — projects seen: $(docker ps --format '{{.Label "com.docker.compose.project"}}' | sort -u | tr '\n' ' ')"
fi

log "stopping services (keeping ${KEEP_UP} up)"
STOPPED_SERVICES="$RUNNING"
# shellcheck disable=SC2086
"${COMPOSE[@]}" stop $RUNNING

# --- 3. snapshot -----------------------------------------------------------
log "running restic backup"
restic backup --tag services --exclude-caches \
    --exclude-file "$EXCLUDES" \
    "$COMPOSE_DIR" "$DUMP_DIR"

# --- 4. bring the stack back immediately, before the slow maintenance ------
log "restarting services"
# shellcheck disable=SC2086
"${COMPOSE[@]}" start $RUNNING
STOPPED_SERVICES=""

# --- 5. retention and integrity (outage is already over) -------------------
log "applying retention (services)"
restic forget --tag services "${RETENTION[@]}" --prune

log "checking repository"
restic check

log "backup complete"
restic snapshots --tag services --latest 1
