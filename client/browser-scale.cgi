#!/usr/bin/env bash
# browser-scale.cgi - Sets the Falkon UI scale used by videokiosk2.

echo "Content-Type: application/json"
echo ""

SCALE=$(echo "$QUERY_STRING" | tr '&;' '\n' | grep '^scale=' | cut -d= -f2- | head -1)

case "$SCALE" in
    1|1.25|1.5|1.75|2|2.5|3|4) ;;
    *)
        echo '{"error":"invalid scale"}'
        exit 0
        ;;
esac

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
OUTPUT=$(sudo /usr/local/bin/church-monitoring-set-browser-scale "$SCALE" 2>&1)
RC=$?

if [ "$RC" -eq 0 ]; then
    echo "{\"result\":\"applied\",\"scale\":\"$SCALE\",\"timestamp\":\"$TIMESTAMP\"}"
else
    echo "{\"result\":\"failed\",\"error\":$(echo "$OUTPUT" | jq -Rs .),\"timestamp\":\"$TIMESTAMP\"}"
fi