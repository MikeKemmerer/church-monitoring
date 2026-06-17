#!/usr/bin/env bash
# backup.cgi — Triggers a disaster-recovery backup of this host's app configs.
# Runs church-monitoring-backup as root via sudo and returns its JSON summary.
# Apache enforces mutual TLS, so only enrolled servers can reach this endpoint.

echo "Content-Type: application/json"
echo ""

HELPER="/usr/local/bin/church-monitoring-backup"

if [ ! -x "$HELPER" ]; then
    echo '{"ok":false,"error":"backup helper not installed"}'
    exit 0
fi

# The helper always prints valid JSON (success or error) and exits 0.
sudo "$HELPER" 2>/dev/null || echo '{"ok":false,"error":"backup helper failed"}'
