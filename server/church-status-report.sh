#!/usr/bin/env bash
# church-status-report.sh — one-shot, read-only status digest for all monitored
# hosts/devices, pushed as a single ntfy notification. Reuses the same
# fetch-status.cgi / device-status.cgi logic (mTLS client certs), run locally
# as root so it needs no HTTP session/auth. Safe to run any time; it only reads.
set -uo pipefail

CONFIG="/etc/church-monitoring/server-config.json"
CERT="/etc/church-monitoring/ssl/server.crt"
KEY="/etc/church-monitoring/ssl/server.key"
CA="/etc/church-monitoring/ca/ca.crt"
NTFY_BIN="/usr/local/bin/ntfy-notify.sh"

[[ -f "$CONFIG" ]] || { echo "missing $CONFIG" >&2; exit 1; }

SUMMARY=""
BAD=0

while IFS= read -r client; do
    NAME=$(echo "$client" | jq -r '.name')
    HOST=$(echo "$client" | jq -r '.host')
    PORT=$(echo "$client" | jq -r '.port // empty')
    [[ -z "$PORT" ]] && continue

    DATA=$(curl -s --connect-timeout 3 --max-time 8 \
        --cert "$CERT" --key "$KEY" --cacert "$CA" -k \
        "https://${HOST}:${PORT}/cgi-bin/status.cgi" 2>/dev/null) || true

    if [[ -z "$DATA" ]] || ! echo "$DATA" | jq . >/dev/null 2>&1; then
        SUMMARY+=$'\n'"❌ $NAME: unreachable"
        BAD=1
        continue
    fi

    HDMI=$(echo "$DATA" | jq -r '.hdmi // "unknown"')
    TEMP=$(echo "$DATA" | jq -r '.temperature_c // empty')
    LINE="✅ $NAME: hdmi=$HDMI"
    [[ -n "$TEMP" ]] && LINE+=" temp=${TEMP}C"

    # Flag any service that is not active/running.
    BAD_SERVICES=$(echo "$DATA" | jq -r '
        [.services[]? | select(.type != "info" and (.status | test("^active$|^running"; "i") | not))
         | "\(.name)=\(.status)"] | join(", ")')
    if [[ -n "$BAD_SERVICES" ]]; then
        LINE="⚠️ $NAME: $BAD_SERVICES (hdmi=$HDMI)"
        BAD=1
    fi

    STANDBY_STATE=$(echo "$DATA" | jq -r '.standby_timer.state // empty')
    if [[ "$STANDBY_STATE" == "counting" ]]; then
        REMAIN=$(echo "$DATA" | jq -r '((.standby_timer.remaining_seconds // 0) / 60 | floor)')
        LINE+=" standby in ~${REMAIN}m"
    elif [[ "$STANDBY_STATE" == "stale" ]]; then
        LINE+=" standby-timer=STALE"
        BAD=1
    fi

    SUMMARY+=$'\n'"$LINE"
done < <(jq -c '.clients[]' "$CONFIG" 2>/dev/null)

while IFS= read -r device; do
    DNAME=$(echo "$device" | jq -r '.name')
    DCHECK=$(echo "$device" | jq -r '.check // empty')
    [[ -z "$DCHECK" ]] && continue
    DHOST=$(echo "$device" | jq -r '.host')
    case "$DCHECK" in
        tcp:*)
            DPORT="${DCHECK#tcp:}"
            if [[ "$DPORT" =~ ^[0-9]+$ ]] && timeout 3 bash -c "echo >/dev/tcp/$DHOST/$DPORT" 2>/dev/null; then
                SUMMARY+=$'\n'"✅ $DNAME: online"
            else
                SUMMARY+=$'\n'"❌ $DNAME: offline"
                BAD=1
            fi
            ;;
        http:*)
            DPORT="${DCHECK#http:}"
            if [[ "$DPORT" =~ ^[0-9]+$ ]] && curl -s -k --connect-timeout 3 --max-time 5 -o /dev/null "http://${DHOST}:${DPORT}/" 2>/dev/null; then
                SUMMARY+=$'\n'"✅ $DNAME: online"
            else
                SUMMARY+=$'\n'"❌ $DNAME: offline"
                BAD=1
            fi
            ;;
    esac
done < <(jq -c '.devices[]? // empty' "$CONFIG" 2>/dev/null)

SUMMARY="${SUMMARY#$'\n'}"
[[ -z "$SUMMARY" ]] && SUMMARY="(no clients/devices configured)"

echo "$SUMMARY"

if [[ "${1:-}" == "--notify" ]]; then
    PRIORITY="default"
    [[ "$BAD" -eq 1 ]] && PRIORITY="high"
    "$NTFY_BIN" -A -t "Church A/V status" -p "$PRIORITY" -k "church-status-$(date +%s)" "$SUMMARY"
fi
