#!/usr/bin/env bash
# status.cgi — Serves system/service status as JSON.
# Installed on each monitored host. Returns data collected by collect.sh.
# Pass ?refresh=1 to run a fresh collection before serving.

echo "Content-Type: application/json"
echo ""

CACHE="/var/cache/church-monitoring/status.json"
COLLECTOR="/usr/local/bin/church-monitoring-collect"

# Run fresh collection if requested. Kick it off in the background and serve
# the current cache immediately so the HTTP response never blocks on a slow
# collection (which could otherwise exceed the server's fetch timeout). The
# freshly collected data is served on the next request.
if echo "$QUERY_STRING" | grep -q 'refresh=1'; then
    if [ -x "$COLLECTOR" ]; then
        "$COLLECTOR" >/dev/null 2>&1 &
    fi
fi

if [ -f "$CACHE" ]; then
    if [ -x /usr/local/bin/church-monitoring-streaming ]; then
        # Re-evaluate source timestamps; reading the five-minute host cache is not freshness.
        /usr/local/bin/church-monitoring-streaming merge < "$CACHE"
    else
        cat "$CACHE"
    fi
else
    if [ -x /usr/local/bin/church-monitoring-streaming ]; then
        echo '{"error":"no cached data available","timestamp":null}' | /usr/local/bin/church-monitoring-streaming merge
    else
        echo '{"error":"no cached data available","timestamp":null}'
    fi
fi
