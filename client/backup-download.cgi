#!/usr/bin/env bash
# backup-download.cgi — Streams the newest DR archive for this host.
# The archives are root-only (mode 600), so the helper cats the newest one to
# stdout via sudo. Apache enforces mutual TLS on this endpoint.

HELPER="/usr/local/bin/church-monitoring-backup"

json_error() {
    echo "Content-Type: application/json"
    echo ""
    echo "{\"ok\":false,\"error\":\"$1\"}"
    exit 0
}

if [ ! -x "$HELPER" ]; then
    json_error "backup helper not installed"
fi

# Resolve the archive name so we can set a sensible download filename.
LATEST_PATH=$(sudo "$HELPER" --latest-path 2>/dev/null || echo "")
if [ -z "$LATEST_PATH" ]; then
    json_error "no backup archive found"
fi
FILENAME=$(basename "$LATEST_PATH")

echo "Content-Type: application/gzip"
echo "Content-Disposition: attachment; filename=\"$FILENAME\""
echo "Cache-Control: no-cache"
echo ""

sudo "$HELPER" --emit-latest 2>/dev/null
