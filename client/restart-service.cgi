#!/usr/bin/env bash
# restart-service.cgi — Restarts a systemd service on this client.
# Accepts ?service=<name> via query string.
# Only allows services listed in the client config (systemd type).

echo "Content-Type: application/json"
echo ""

CONFIG="/etc/church-monitoring/client-config.json"

if [ ! -f "$CONFIG" ]; then
    echo '{"error":"client config not found"}'
    exit 0
fi

# Parse service name from query string
SERVICE=$(echo "$QUERY_STRING" | tr '&' '\n' | grep "^service=" | cut -d= -f2- | head -1)

if [ -z "$SERVICE" ]; then
    echo '{"error":"missing service parameter"}'
    exit 0
fi

# Sanitize: alphanumeric, dash, underscore, dot only
SERVICE_CLEAN=$(echo "$SERVICE" | tr -cd 'a-zA-Z0-9._-')
if [ "$SERVICE_CLEAN" != "$SERVICE" ]; then
    echo '{"error":"invalid service name"}'
    exit 0
fi

# Verify this service is in the config as a systemd monitor
MATCH=$(jq -r --arg svc "$SERVICE_CLEAN" \
    '.monitors[] | select(.name == $svc and .type == "systemd") | .name' \
    "$CONFIG" 2>/dev/null)

if [ -z "$MATCH" ]; then
    echo '{"error":"service not in config or not a systemd service"}'
    exit 0
fi

# Restart via sudo
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
OUTPUT=$(sudo /bin/systemctl restart "$SERVICE_CLEAN" 2>&1)
RC=$?

if [ $RC -eq 0 ]; then
    # Brief pause then check status
    sleep 1
    STATE=$(systemctl is-active "$SERVICE_CLEAN" 2>/dev/null || echo "unknown")
    echo "{\"service\":\"$SERVICE_CLEAN\",\"result\":\"restarted\",\"state\":\"$STATE\",\"timestamp\":\"$TIMESTAMP\"}"
else
    echo "{\"service\":\"$SERVICE_CLEAN\",\"result\":\"failed\",\"error\":$(echo "$OUTPUT" | jq -Rs .),\"timestamp\":\"$TIMESTAMP\"}"
fi
