#!/bin/bash
# ntfy-notify.sh - send one push notification through ntfy, with dedupe.
#   ntfy-notify.sh [-t TITLE] [-p min|low|default|high|urgent] [-g TAGS] [-k KEY] [-A] MESSAGE
#
# The topic is read from $NTFY_TOPIC or from the file $NTFY_TOPIC_FILE
# (default /etc/church-monitoring/ntfy-topic). The topic is the only secret
# on public ntfy.sh, so the topic file must never be committed to git.
#
# Repeats of the same notification are suppressed for $NTFY_DEDUPE_SECONDS
# (default 1800 = 30 min), keyed on -k KEY if given, otherwise on the message
# text. Set NTFY_DEDUPE_SECONDS=0 to disable deduping.
#
# Automatic alerts (crashes, error logs, down checks) only fire while a
# church service is active, per the Church Calendar's service-restart
# schedule ($SERVICE_WINDOW_URL). Pass -A for an always-on alert (on-demand
# digests, the camera-reachability check) that should bypass this gate. If
# the schedule can't be reached or parsed, the gate fails open (alert sent)
# so a real outage is never silently swallowed by a calendar hiccup.
#
# A failed or suppressed notification never fails the caller.
set -uo pipefail

SERVER="${NTFY_SERVER:-https://ntfy.sh}"
TOPIC_FILE="${NTFY_TOPIC_FILE:-/etc/church-monitoring/ntfy-topic}"
DEDUPE_DIR="${NTFY_DEDUPE_DIR:-/var/tmp/church-monitoring-ntfy}"
DEDUPE_SECONDS="${NTFY_DEDUPE_SECONDS:-1800}"
SERVICE_WINDOW_URL="${SERVICE_WINDOW_URL:-http://liturgystream2:8000/api/service-restart-schedule}"
TITLE="church-monitoring" PRIORITY="default" TAGS="" KEY="" ALWAYS=0

in_service_window() {
    local json
    json=$(curl -s --connect-timeout 2 --max-time 4 "$SERVICE_WINDOW_URL" 2>/dev/null)
    [[ -n "$json" ]] || return 0
    python3 - "$json" <<'PY'
import json, sys
from datetime import datetime, timezone
try:
    data = json.loads(sys.argv[1])
    nr = data.get("next_restart")
    if not nr:
        sys.exit(1)
    start = datetime.fromisoformat(nr["restart_at"])
    end = datetime.fromisoformat(nr["block_end"])
    now = datetime.now(timezone.utc)
    sys.exit(0 if start <= now <= end else 1)
except Exception:
    sys.exit(0)
PY
}

while getopts "t:p:g:k:A" opt; do
    case "$opt" in
        t) TITLE="$OPTARG" ;;
        p) PRIORITY="$OPTARG" ;;
        g) TAGS="$OPTARG" ;;
        k) KEY="$OPTARG" ;;
        A) ALWAYS=1 ;;
        *) echo "usage: ntfy-notify.sh [-t title] [-p priority] [-g tags] [-k dedupe-key] [-A] message" >&2; exit 0 ;;
    esac
done
shift $((OPTIND - 1))
MESSAGE="${*:-}"
[[ -n "$MESSAGE" ]] || { echo "ntfy-notify: empty message" >&2; exit 0; }

if [[ "$ALWAYS" -ne 1 ]] && ! in_service_window; then
    echo "ntfy-notify: suppressed (no active service window)" >&2
    exit 0
fi

TOPIC="${NTFY_TOPIC:-}"
[[ -n "$TOPIC" || ! -r "$TOPIC_FILE" ]] || TOPIC="$(tr -d '[:space:]' <"$TOPIC_FILE")"
[[ "$TOPIC" =~ ^[A-Za-z0-9_-]{8,}$ ]] || { echo "ntfy-notify: no valid topic configured" >&2; exit 0; }

if [[ "$DEDUPE_SECONDS" -gt 0 ]] 2>/dev/null; then
    dedupe_key="${KEY:-$MESSAGE}"
    dedupe_hash=$(printf '%s' "$dedupe_key" | md5sum | cut -d' ' -f1)
    mkdir -p "$DEDUPE_DIR" 2>/dev/null || true
    marker="$DEDUPE_DIR/$dedupe_hash"
    now=$(date +%s)
    if [[ -f "$marker" ]]; then
        last=$(cat "$marker" 2>/dev/null || echo 0)
        if (( now - last < DEDUPE_SECONDS )); then
            echo "ntfy-notify: suppressed (duplicate within ${DEDUPE_SECONDS}s)" >&2
            exit 0
        fi
    fi
    echo "$now" > "$marker" 2>/dev/null || true
fi

args=(-fsS --max-time 10 -H "Priority: $PRIORITY" -d "$MESSAGE")
[[ -z "$TITLE" ]] || args+=(-H "Title: $TITLE")
[[ -z "$TAGS" ]] || args+=(-H "Tags: $TAGS")
curl "${args[@]}" "$SERVER/$TOPIC" >/dev/null || echo "ntfy-notify: delivery failed" >&2
exit 0
