#!/usr/bin/env bash
# standby-timer.cgi - Extends, shortens, or resets the kiosk standby countdown.

echo "Content-Type: application/json"
echo ""

ACTION=$(echo "$QUERY_STRING" | tr '&;' '\n' | grep '^action=' | cut -d= -f2- | head -1)

case "$ACTION" in
    plus|minus|reset) ;;
    *)
        echo '{"error":"invalid action, use: plus, minus or reset"}'
        exit 0
        ;;
esac

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
OUTPUT=$(sudo /usr/local/bin/church-monitoring-standby-timer "$ACTION" 2>&1)
RC=$?

if [ "$RC" -eq 0 ] && echo "$OUTPUT" | jq -e . >/dev/null 2>&1; then
    printf '%s' "$OUTPUT" | jq -c --arg action "$ACTION" --arg ts "$TIMESTAMP" \
        '{action: $action, result: "applied", timestamp: $ts} + .'
else
    printf '{"action":"%s","result":"failed","error":%s,"timestamp":"%s"}\n' \
        "$ACTION" "$(printf '%s' "$OUTPUT" | jq -Rs .)" "$TIMESTAMP"
fi
