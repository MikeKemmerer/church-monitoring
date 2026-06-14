#!/usr/bin/env bash
# backup-download.cgi — Proxies a backup-archive download to a specific client.
# Called by the dashboard with ?host=<client_name>
# Streams the gzip archive directly to the browser (or returns a JSON error).

CONFIG="/etc/church-monitoring/server-config.json"
CERT="/etc/church-monitoring/ssl/server.crt"
KEY="/etc/church-monitoring/ssl/server.key"
CA="/etc/church-monitoring/ca/ca.crt"

TARGET=$(echo "$QUERY_STRING" | tr '&;' '\n' | grep "^host=" | cut -d= -f2- | head -1)

json_error() {
    echo "Content-Type: application/json"
    echo ""
    echo "{\"error\":\"$1\"}"
    exit 0
}

if [ -z "$TARGET" ]; then
    json_error "missing host parameter"
fi

TARGET_CLEAN=$(echo "$TARGET" | tr -cd 'a-zA-Z0-9._-')
if [ "$TARGET_CLEAN" != "$TARGET" ]; then
    json_error "invalid host parameter"
fi

if [ ! -f "$CONFIG" ]; then
    json_error "server-config.json not found"
fi

CLIENT=$(jq -c --arg name "$TARGET_CLEAN" '.clients[] | select(.name == $name)' "$CONFIG" 2>/dev/null)
if [ -z "$CLIENT" ]; then
    json_error "unknown client"
fi

HOST=$(echo "$CLIENT" | jq -r '.host')
PORT=$(echo "$CLIENT" | jq -r '.port')

TMPFILE=$(mktemp /tmp/church-monitoring-proxy-backup-XXXXXX.tar.gz)
HEADERS=$(mktemp /tmp/church-monitoring-proxy-backup-hdr-XXXXXX)
cleanup() { rm -f "$TMPFILE" "$HEADERS"; }
trap cleanup EXIT

HTTP_CODE=$(curl -s --connect-timeout 5 --max-time 120 \
    --cert "$CERT" --key "$KEY" --cacert "$CA" -k \
    -D "$HEADERS" -o "$TMPFILE" -w "%{http_code}" \
    "https://${HOST}:${PORT}/cgi-bin/backup-download.cgi" 2>/dev/null) || true

if [ "$HTTP_CODE" != "200" ] || [ ! -s "$TMPFILE" ]; then
    json_error "backup archive unavailable"
fi

# The client returns JSON (not gzip) when no archive exists or on error.
if head -c 1 "$TMPFILE" | grep -q '{'; then
    echo "Content-Type: application/json"
    echo ""
    cat "$TMPFILE"
    exit 0
fi

# Preserve the client's download filename if it provided one.
FILENAME=$(grep -i '^Content-Disposition:' "$HEADERS" 2>/dev/null \
    | sed -n 's/.*filename="\([^"]*\)".*/\1/p' | head -1)
FILENAME=$(echo "$FILENAME" | tr -cd 'a-zA-Z0-9._-')
[ -z "$FILENAME" ] && FILENAME="backup-${TARGET_CLEAN}.tar.gz"

echo "Content-Type: application/gzip"
echo "Content-Disposition: attachment; filename=\"$FILENAME\""
echo "Cache-Control: no-cache"
echo ""
cat "$TMPFILE"
