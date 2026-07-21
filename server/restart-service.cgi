#!/usr/bin/env bash
# restart-service.cgi — Proxies a service restart request to a client.
# Called by the dashboard with ?host=<client_name>&service=<service_name>

source /usr/local/lib/church-monitoring/auth-lib.sh
require_role contributor

echo "Content-Type: application/json"
echo ""

CONFIG="/etc/church-monitoring/server-config.json"
CERT="/etc/church-monitoring/ssl/server.crt"
KEY="/etc/church-monitoring/ssl/server.key"
CA="/etc/church-monitoring/ca/ca.crt"

extract_qs_candidate() {
    local src="$1"
    if [ -z "$src" ]; then
        printf ''
        return
    fi

    if [[ "$src" == *\?* ]]; then
        printf '%s' "${src#*\?}"
    else
        printf '%s' "$src"
    fi
}

resolve_raw_qs() {
    local candidate

    # Different Apache/CGI setups expose query data under different vars.
    for candidate in "$QUERY_STRING" "$REDIRECT_QUERY_STRING" "$REQUEST_URI" "$UNENCODED_URL" "$REQUEST"; do
        candidate=$(extract_qs_candidate "$candidate")
        if [ -n "$candidate" ] && echo "$candidate" | grep -q '='; then
            printf '%s' "$candidate"
            return
        fi
    done

    printf ''
}

RAW_QS=$(resolve_raw_qs)

# Parse and URL-decode a query-string key from RAW_QS.
url_decode() {
    local val="$1"
    val="${val//+/ }"
    printf '%b' "${val//%/\\x}"
}

parse_qs() {
    local key="$1"
    local raw
    raw=$(echo "$RAW_QS" | tr '&;' '\n' | grep "^${key}=" | cut -d= -f2- | head -1)
    [ -n "$raw" ] && url_decode "$raw"
}

TARGET=$(parse_qs "host")
SERVICE=$(parse_qs "service")

if [ -z "$TARGET" ]; then
    echo '{"error":"missing host parameter"}'
    exit 0
fi

if [ -z "$SERVICE" ]; then
    echo '{"error":"missing service parameter"}'
    exit 0
fi

# Sanitize host
TARGET_CLEAN=$(echo "$TARGET" | tr -cd 'a-zA-Z0-9._-')
if [ "$TARGET_CLEAN" != "$TARGET" ]; then
    echo '{"error":"invalid host parameter"}'
    exit 0
fi

# Sanitize service
SERVICE_CLEAN=$(echo "$SERVICE" | tr -cd 'a-zA-Z0-9._-')
if [ "$SERVICE_CLEAN" != "$SERVICE" ]; then
    echo '{"error":"invalid service name"}'
    exit 0
fi

if [ ! -f "$CONFIG" ]; then
    echo '{"error":"server-config.json not found"}'
    exit 0
fi

# Look up client
CLIENT=$(jq -c --arg name "$TARGET_CLEAN" '.clients[] | select(.name == $name)' "$CONFIG" 2>/dev/null)
if [ -z "$CLIENT" ]; then
    echo '{"error":"unknown client"}'
    exit 0
fi

HOST=$(echo "$CLIENT" | jq -r '.host')
PORT=$(echo "$CLIENT" | jq -r '.port')

DATA=$(curl -s --connect-timeout 5 --max-time 20 \
    --cert "$CERT" --key "$KEY" --cacert "$CA" -k \
    "https://${HOST}:${PORT}/cgi-bin/restart-service.cgi?service=${SERVICE_CLEAN}" 2>/dev/null) || true

if [ -z "$DATA" ] || ! echo "$DATA" | jq . &>/dev/null; then
    echo '{"error":"restart request failed or timed out"}'
    exit 0
fi

echo "$DATA"
