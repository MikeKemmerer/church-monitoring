#!/usr/bin/env bash
# status.cgi — Serves system/service status as JSON.
# Installed on each monitored host. Returns data collected by collect.sh.
# Pass ?refresh=1 to run a fresh collection before serving.

echo "Content-Type: application/json"
echo ""

CACHE="/var/cache/church-monitoring/status.json"
COLLECTOR="/usr/local/bin/church-monitoring-collect"

# Run fresh collection if requested
if echo "$QUERY_STRING" | grep -q 'refresh=1'; then
    if [ -x "$COLLECTOR" ]; then
        "$COLLECTOR" 2>/dev/null || true
    fi
fi

if [ -f "$CACHE" ]; then
    cat "$CACHE"
else
    echo '{"error":"no cached data available","timestamp":null}'
fi
