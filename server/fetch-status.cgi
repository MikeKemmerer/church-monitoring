#!/usr/bin/env bash
# fetch-status.cgi — Fetches status from all configured clients.
# Called by the dashboard JS. Uses the server's client cert to authenticate.

echo "Content-Type: application/json"
echo ""

CONFIG="/etc/church-monitoring/server-config.json"
CERT="/etc/church-monitoring/ssl/server.crt"
KEY="/etc/church-monitoring/ssl/server.key"
CA="/etc/church-monitoring/ca/ca.crt"

if [ ! -f "$CONFIG" ]; then
    echo '{"error":"server-config.json not found"}'
    exit 0
fi

RESULT="[]"

while IFS= read -r client; do
    NAME=$(echo "$client" | jq -r '.name')
    HOST=$(echo "$client" | jq -r '.host')
    PORT=$(echo "$client" | jq -r '.port')

    DATA=$(curl -s --connect-timeout 5 --max-time 10 \
        --cert "$CERT" --key "$KEY" --cacert "$CA" \
        "https://${HOST}:${PORT}/cgi-bin/status.cgi" 2>/dev/null) || true

    if [ -z "$DATA" ] || ! echo "$DATA" | jq . &>/dev/null; then
        DATA=$(jq -n --arg name "$NAME" '{"error":"unreachable","hostname":$name}')
    fi

    RESULT=$(echo "$RESULT" | jq --arg name "$NAME" --argjson data "$DATA" \
        '. + [$data + {"client_name": $name}]')
done < <(jq -c '.clients[]' "$CONFIG" 2>/dev/null)

echo "$RESULT"
