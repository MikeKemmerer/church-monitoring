#!/usr/bin/env bash
# fetch-status.cgi — Fetches status from all configured clients.
# Called by the dashboard JS. Uses the server's client cert to authenticate.
# Results are cached for 30 seconds. Clients are queried in parallel.

echo "Content-Type: application/json"
echo ""

CONFIG="/etc/church-monitoring/server-config.json"
CERT="/etc/church-monitoring/ssl/server.crt"
KEY="/etc/church-monitoring/ssl/server.key"
CA="/etc/church-monitoring/ca/ca.crt"
CACHE_DIR="/var/cache/church-monitoring"
CACHE_FILE="$CACHE_DIR/fetch-status.json"
CACHE_MAX_AGE=30

if [ ! -f "$CONFIG" ]; then
    echo '{"error":"server-config.json not found"}'
    exit 0
fi

# Parse query string for refresh flag
FORCE_REFRESH=0
echo "$QUERY_STRING" | tr '&' '\n' | grep -q '^refresh=1$' && FORCE_REFRESH=1

# Return cached result if fresh enough
if [ "$FORCE_REFRESH" -eq 0 ] && [ -f "$CACHE_FILE" ]; then
    AGE=$(( $(date +%s) - $(stat -c %Y "$CACHE_FILE") ))
    if [ "$AGE" -lt "$CACHE_MAX_AGE" ]; then
        cat "$CACHE_FILE"
        exit 0
    fi
fi

mkdir -p "$CACHE_DIR" 2>/dev/null

# Fetch all clients in parallel using temp files
TMPDIR=$(mktemp -d)
PIDS=""
INDEX=0

while IFS= read -r client; do
    NAME=$(echo "$client" | jq -r '.name')
    HOST=$(echo "$client" | jq -r '.host')
    PORT=$(echo "$client" | jq -r '.port // empty')

    [ -z "$PORT" ] && continue

    OUTFILE="$TMPDIR/${INDEX}_${NAME}"

    (
        DATA=$(curl -s --connect-timeout 3 --max-time 8 \
            --cert "$CERT" --key "$KEY" --cacert "$CA" -k \
            "https://${HOST}:${PORT}/cgi-bin/status.cgi?refresh=1" 2>/dev/null) || true

        if [ -z "$DATA" ] || ! echo "$DATA" | jq . &>/dev/null; then
            DATA=$(jq -n --arg name "$NAME" '{"error":"unreachable","hostname":$name}')
        fi

        echo "$DATA" | jq --arg name "$NAME" '. + {"client_name": $name}' > "$OUTFILE"
    ) &

    PIDS="$PIDS $!"
    INDEX=$((INDEX + 1))
done < <(jq -c '.clients[]' "$CONFIG" 2>/dev/null)

# Wait for all parallel fetches
for pid in $PIDS; do
    wait "$pid" 2>/dev/null
done

# Assemble results in order
RESULT="["
FIRST=1
for f in $(ls "$TMPDIR"/ 2>/dev/null | sort -n); do
    [ "$FIRST" -eq 1 ] && FIRST=0 || RESULT="$RESULT,"
    RESULT="$RESULT$(cat "$TMPDIR/$f")"
done
RESULT="$RESULT]"

rm -rf "$TMPDIR"

# Write cache
echo "$RESULT" > "$CACHE_FILE" 2>/dev/null || true
echo "$RESULT"
