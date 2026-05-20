#!/usr/bin/env bash
# mode-switch.cgi â€” Switches between VLC (live stream) and Midori (calendar) modes.
# Accepts ?mode=vlc|midori
# Only meaningful on hosts running videokiosk2.

echo "Content-Type: application/json"
echo ""

MODE=$(echo "$QUERY_STRING" | tr '&;' '\n' | grep "^mode=" | cut -d= -f2- | head -1)
MODE_CLEAN=$(echo "$MODE" | tr -cd 'a-zA-Z0-9')

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

case "$MODE_CLEAN" in
    vlc)
        OUTPUT=$(sudo /bin/systemctl restart videokiosk2 2>&1)
        RC=$?
        if [ $RC -eq 0 ]; then
            STATE=$(systemctl is-active videokiosk2 2>/dev/null || echo "unknown")
            echo "{\"result\":\"switched\",\"mode\":\"vlc\",\"service_state\":\"$STATE\",\"timestamp\":\"$TIMESTAMP\"}"
        else
            echo "{\"result\":\"failed\",\"mode\":\"vlc\",\"error\":$(echo "$OUTPUT" | jq -Rs .),\"timestamp\":\"$TIMESTAMP\"}"
        fi
        ;;
    midori)
        OUTPUT=$(sudo /usr/local/bin/church-monitoring-mode-midori 2>&1)
        RC=$?
        if [ $RC -eq 0 ]; then
            STATE=$(systemctl is-active videokiosk2 2>/dev/null || echo "unknown")
            echo "{\"result\":\"switched\",\"mode\":\"midori\",\"service_state\":\"$STATE\",\"timestamp\":\"$TIMESTAMP\"}"
        else
            echo "{\"result\":\"failed\",\"mode\":\"midori\",\"error\":$(echo "$OUTPUT" | jq -Rs .),\"timestamp\":\"$TIMESTAMP\"}"
        fi
        ;;
    *)
        echo '{"error":"invalid mode â€” use: vlc or midori"}'
        ;;
esac
