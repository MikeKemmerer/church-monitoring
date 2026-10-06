#!/usr/bin/env bash
# display-control.cgi - Applies the configured display on/off strategy.

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

case "$RC" in
    0)
        printf '{"action":"%s","result":"applied","timestamp":"%s"}\n' "$ACTION" "$TIMESTAMP"
        ;;
    2)
        printf '{"action":"%s","result":"partial","warning":%s,"timestamp":"%s"}\n' \
            "$ACTION" "$(printf '%s' "$OUTPUT" | jq -Rs .)" "$TIMESTAMP"
        ;;
    *)
        printf '{"action":"%s","result":"failed","error":%s,"timestamp":"%s"}\n' \
            "$ACTION" "$(printf '%s' "$OUTPUT" | jq -Rs .)" "$TIMESTAMP"
        ;;
esac