#!/usr/bin/env bash
#
# notify-failure.sh — invoked by backup-failure@.service via OnFailure= when a
# backup unit fails. Argument is the failed unit name.
#
# The old backup system had nothing like this. It died on every run for months
# and nobody found out, which made a silent failure worse than a loud one.
# Whatever channel you pick below, test it deliberately (see BACKUP.md).

set -uo pipefail   # deliberately not -e: a failing notifier must still fall
                   # through to the remaining channels and to the journal.

UNIT="${1:-unknown-unit}"
HOST="$(hostname -s)"
WHEN="$(date -Is)"
TAIL="$(journalctl -u "$UNIT" -n 25 --no-pager 2>/dev/null || echo '(journal unavailable)')"

BODY="${UNIT} FAILED on ${HOST} at ${WHEN}

${TAIL}"

# --- configuration ---------------------------------------------------------
# Both channel settings are secrets in practice: an HA token grants full API
# access, and an ntfy topic is readable by anyone who knows its name. THIS FILE
# IS TRACKED IN A PUBLIC REPO, so they must never be written here. They live in
# a root-only file outside the repo, the same convention as the restic
# passphrase in /root/.restic-password.
#
# Create it from scripts/backup-notify.conf-example:
#   sudo install -m 600 /dev/null /root/.backup-notify.conf
CONF=/root/.backup-notify.conf

NTFY_TOPIC=""
HA_URL=""
HA_TOKEN=""
HA_NOTIFY_SERVICE="notify.mobile_app_samsung_s23"

if [[ -r "$CONF" ]]; then
    # shellcheck source=/dev/null
    . "$CONF"
else
    logger -t backup-failure "no readable ${CONF} — journal and marker file only"
fi

# --- channel 1: ntfy -------------------------------------------------------
# Independent of this machine's own services, which is the point: it still
# reaches you when Home Assistant is the thing that is broken.
if [[ -n "$NTFY_TOPIC" ]]; then
    curl -fsS -m 20 \
        -H "Title: Backup failed on ${HOST}" \
        -H "Priority: high" \
        -H "Tags: rotating_light" \
        -d "$BODY" \
        "https://ntfy.sh/${NTFY_TOPIC}" >/dev/null \
        || logger -t backup-failure "ntfy notification failed"
fi

# --- channel 2: Home Assistant push ----------------------------------------
# Calls the notify service straight over the REST API. Home Assistant runs with
# network_mode: host, so 127.0.0.1:8123 reaches it from the host. Done this way
# rather than with a webhook trigger because a webhook needs its id stored in
# automations.yaml, which is public.
#
# python3 builds the payload: BODY is multi-line journal output and has to be
# JSON-escaped properly. python3 is part of the Ubuntu base system.
if [[ -n "$HA_URL" && -n "$HA_TOKEN" ]]; then
    SVC_PATH="$(printf '%s' "$HA_NOTIFY_SERVICE" | tr '.' '/')"
    PAYLOAD="$(python3 -c 'import json,sys; print(json.dumps({"title": sys.argv[1], "message": sys.argv[2]}))' \
        "Backup failed on ${HOST}" "$BODY" 2>/dev/null)"

    if [[ -n "$PAYLOAD" ]]; then
        curl -fsS -m 20 -X POST \
            -H "Authorization: Bearer ${HA_TOKEN}" \
            -H 'Content-Type: application/json' \
            -d "$PAYLOAD" \
            "${HA_URL}/api/services/${SVC_PATH}" >/dev/null \
            || logger -t backup-failure "HA notification failed"
    else
        logger -t backup-failure "HA notification skipped: could not build payload"
    fi
fi

# --- always: journal + marker file ----------------------------------------
# The marker is what to check when you want to know "did anything fail while I
# was away" without reading the journal. It is the one channel that cannot
# itself fail, so it stays even once the push channels work.
logger -t backup-failure "${UNIT} failed on ${HOST}"
mkdir -p /var/lib/homeserver
printf '%s  %s failed\n' "$WHEN" "$UNIT" >> /var/lib/homeserver/backup-failures.log

exit 0
