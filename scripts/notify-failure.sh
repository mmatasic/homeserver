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

# --- channel 1: ntfy -------------------------------------------------------
# Set a long random topic and subscribe to it in the ntfy app. Topics on the
# public server are readable by anyone who knows the name, so treat it as
# unguessable-but-not-secret: fine for "a backup failed", never for contents.
NTFY_TOPIC=""     # e.g. hs-backup-9f3a1c7e2b

if [[ -n "$NTFY_TOPIC" ]]; then
    curl -fsS -m 20 \
        -H "Title: Backup failed on ${HOST}" \
        -H "Priority: high" \
        -H "Tags: rotating_light" \
        -d "$BODY" \
        "https://ntfy.sh/${NTFY_TOPIC}" >/dev/null \
        || logger -t backup-failure "ntfy notification failed"
fi

# --- channel 2: Home Assistant webhook -------------------------------------
# Alternative if you would rather keep it on your own infrastructure: create an
# automation with a webhook trigger, then set the URL here. Uses the container
# name over the docker network, so it works without a public hostname.
HA_WEBHOOK=""     # e.g. http://homeassistant:8123/api/webhook/<webhook-id>

if [[ -n "$HA_WEBHOOK" ]]; then
    curl -fsS -m 20 -X POST \
        -H 'Content-Type: application/json' \
        -d "$(printf '{"unit":"%s","host":"%s","when":"%s"}' "$UNIT" "$HOST" "$WHEN")" \
        "$HA_WEBHOOK" >/dev/null \
        || logger -t backup-failure "HA webhook notification failed"
fi

# --- always: journal + marker file ----------------------------------------
# The marker is what to check when you want to know "did anything fail while I
# was away" without reading the journal.
logger -t backup-failure "${UNIT} failed on ${HOST}"
mkdir -p /var/lib/homeserver
printf '%s  %s failed\n' "$WHEN" "$UNIT" >> /var/lib/homeserver/backup-failures.log

exit 0
