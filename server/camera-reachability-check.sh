#!/usr/bin/env bash
# camera-reachability-check.sh — scheduled (cron), read-only reachability
# check for a named device in server-config.json's devices[] list (default
# "Camera"; override with CAMERA_DEVICE_NAME). Runs around the clock,
# independent of whether a church service is active. Sends an ntfy alert (via -A, bypassing
# the service-window gate in ntfy-notify.sh) only when the camera is
# unreachable; dedupe in ntfy-notify.sh (default 1800s) keeps a sustained
# outage from re-alerting more than once per window. No alert is sent when
# the camera is reachable, and no recovery notice is sent.
set -uo pipefail

CONFIG="/etc/church-monitoring/server-config.json"
NTFY_BIN="/usr/local/bin/ntfy-notify.sh"
DEVICE_NAME="${CAMERA_DEVICE_NAME:-Camera}"

[[ -f "$CONFIG" ]] || { echo "missing $CONFIG" >&2; exit 1; }

DEVICE=$(jq -c --arg name "$DEVICE_NAME" '.devices[]? | select(.name == $name)' "$CONFIG" 2>/dev/null)
[[ -n "$DEVICE" ]] || { echo "device '$DEVICE_NAME' not found in $CONFIG" >&2; exit 1; }

HOST=$(echo "$DEVICE" | jq -r '.host')
CHECK=$(echo "$DEVICE" | jq -r '.check // empty')
PORT="${CHECK#http:}"

if [[ -z "$PORT" || ! "$PORT" =~ ^[0-9]+$ ]]; then
    echo "unsupported check '$CHECK' for device '$DEVICE_NAME'" >&2
    exit 1
fi

if curl -s -k --connect-timeout 3 --max-time 5 -o /dev/null "http://${HOST}:${PORT}/" 2>/dev/null; then
    exit 0
fi

"$NTFY_BIN" -A -t "Church A/V status" -p high -g camera \
    -k "camera-unreachable" "⚠️ ${DEVICE_NAME} (${HOST}) is not reachable"
