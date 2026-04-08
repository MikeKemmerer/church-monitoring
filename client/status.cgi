#!/usr/bin/env bash
# status.cgi — Serves cached system/service status as JSON.
# Installed on each monitored host. Returns data collected by collect.sh.

echo "Content-Type: application/json"
echo ""

CACHE="/var/cache/church-monitoring/status.json"

if [ -f "$CACHE" ]; then
    cat "$CACHE"
else
    echo '{"error":"no cached data available","timestamp":null}'
fi
