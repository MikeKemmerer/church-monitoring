#!/usr/bin/env bash
# standby-timer.cgi - Adjusts the current countdown or saves a future timeout.

echo "Content-Type: application/json"
echo ""

ACTION=$(echo "$QUERY_STRING" | tr '&;' '\n' | grep '^action=' | cut -d= -f2- | head -1)

case "$ACTION" in
    plus|minus|reset) ;;
    settings)
        MINUTES=$(echo "$QUERY_STRING" | tr '&;' '\n' | grep '^minutes=' | cut -d= -f2- | head -1)
        APPLY=$(echo "$QUERY_STRING" | tr '&;' '\n' | grep '^apply=' | cut -d= -f2- | head -1)
        if [[ ! "$MINUTES" =~ ^[1-9][0-9]{0,2}$ || "$MINUTES" -lt 5 || "$MINUTES" -gt 720 || ! "$APPLY" =~ ^[01]$ ]]; then
            echo '{"error":"Timeout must be 5 to 720 whole minutes; apply must be 0 or 1"}'
            exit 0
        fi
        ;;
    *)
        echo '{"error":"invalid action, use: plus, minus, reset or settings"}'
        exit 0
        ;;
esac

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
if [[ "$ACTION" == settings ]]; then
    OUTPUT=$(printf '%s %s\n' "$MINUTES" "$APPLY" | sudo /usr/local/bin/church-monitoring-standby-timer settings 2>&1)
else
    OUTPUT=$(sudo /usr/local/bin/church-monitoring-standby-timer "$ACTION" 2>&1)
fi
RC=$?

if [ "$RC" -eq 0 ] && echo "$OUTPUT" | jq -e . >/dev/null 2>&1; then
    printf '%s' "$OUTPUT" | jq -c --arg action "$ACTION" --arg ts "$TIMESTAMP" \
        '{action: $action, result: "applied", timestamp: $ts} + .'
else
    printf '{"action":"%s","result":"failed","error":%s,"timestamp":"%s"}\n' \
        "$ACTION" "$(printf '%s' "$OUTPUT" | jq -Rs .)" "$TIMESTAMP"
fi
