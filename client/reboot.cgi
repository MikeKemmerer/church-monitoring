#!/usr/bin/env bash
# reboot.cgi â€” Safely reboots this host.
# Requires ?guard=confirm to prevent accidental invocation.

echo "Content-Type: application/json"
echo ""

GUARD=$(echo "$QUERY_STRING" | tr '&;' '\n' | grep "^guard=" | cut -d= -f2- | head -1)
if [ "$GUARD" != "confirm" ]; then
    echo '{"error":"missing or invalid guard parameter"}'
    exit 0
fi

HOSTNAME_VAL=$(hostname)
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
echo "{\"result\":\"rebooting\",\"hostname\":\"$HOSTNAME_VAL\",\"timestamp\":\"$TIMESTAMP\"}"

# Schedule reboot via helper (runs as root via sudo; brief delay lets response flush)
sudo /usr/local/bin/church-monitoring-reboot-host &
