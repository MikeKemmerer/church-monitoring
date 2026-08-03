#!/usr/bin/env bash
# display-control.cgi - Enables or disables the configured X11 HDMI signal.

echo "Content-Type: application/json"
echo ""

ACTION=$(echo "$QUERY_STRING" | tr '&;' '\n' | grep '^action=' | cut -d= -f2- | head -1)

case "$ACTION" in
    on|off) ;;
    *)
        echo '{"error":"invalid action, use: on or off"}'
        exit 0
        ;;
esac

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
OUTPUT=$(sudo /usr/local/bin/church-monitoring-display-control "$ACTION" 2>&1)
RC=$?

if [[ "$RC" -eq 0 ]]; then
    printf '{"action":"%s","result":"applied","timestamp":"%s"}\n' "$ACTION" "$TIMESTAMP"
else
    printf '{"action":"%s","result":"failed","error":%s,"timestamp":"%s"}\n' \
        "$ACTION" "$(printf '%s' "$OUTPUT" | jq -Rs .)" "$TIMESTAMP"
fi