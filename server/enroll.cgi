#!/usr/bin/env bash
# enroll.cgi — Enrollment endpoint for client certificate signing.
# Accepts a CSR via POST body with token + hostname + port in query string.
# Validates the enrollment token, signs the CSR, returns signed cert + CA cert.
# The token is burned (deleted) after successful use.
#
# Usage from client installer:
#   curl -s -X POST \
#     "http://server:8080/cgi-bin/enroll.cgi?token=TOKEN&hostname=NAME&port=8033" \
#     --data-binary @client.csr

echo "Content-Type: application/json"

CA_DIR="/etc/church-monitoring/ca"
TOKEN_DIR="/etc/church-monitoring/tokens"
CONFIG="/etc/church-monitoring/server-config.json"
CERT_DIR="/etc/church-monitoring/signed-certs"

# Only POST
if [ "$REQUEST_METHOD" != "POST" ]; then
    echo "Status: 405 Method Not Allowed"
    echo ""
    echo '{"error":"POST required"}'
    exit 0
fi

# Parse query string
parse_qs() { echo "$QUERY_STRING" | tr '&' '\n' | grep "^$1=" | cut -d= -f2- | head -1; }

TOKEN=$(parse_qs "token")
CLIENT_HOST=$(parse_qs "hostname")
CLIENT_PORT=$(parse_qs "port")

# Validate inputs
if [ -z "$TOKEN" ]; then
    echo "Status: 400 Bad Request"
    echo ""
    echo '{"error":"missing token parameter"}'
    exit 0
fi

# Sanitize token to prevent path traversal
TOKEN_CLEAN=$(echo "$TOKEN" | tr -cd 'a-zA-Z0-9')
if [ "$TOKEN_CLEAN" != "$TOKEN" ] || [ -z "$TOKEN_CLEAN" ]; then
    echo "Status: 400 Bad Request"
    echo ""
    echo '{"error":"invalid token format"}'
    exit 0
fi

if [ -z "$CLIENT_HOST" ]; then
    echo "Status: 400 Bad Request"
    echo ""
    echo '{"error":"missing hostname parameter"}'
    exit 0
fi

CLIENT_PORT="${CLIENT_PORT:-8033}"

# Validate token exists
if [ ! -f "$TOKEN_DIR/$TOKEN_CLEAN" ]; then
    echo "Status: 403 Forbidden"
    echo ""
    echo '{"error":"invalid or expired enrollment token"}'
    exit 0
fi

# Read CSR from POST body
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT
cat > "$TMPDIR/client.csr"

# Validate CSR format
if ! openssl req -noout -verify -in "$TMPDIR/client.csr" 2>/dev/null; then
    echo "Status: 400 Bad Request"
    echo ""
    echo '{"error":"invalid CSR format"}'
    exit 0
fi

# Sign the CSR
mkdir -p "$CERT_DIR"
SERIAL=$(date +%s%N | sha256sum | head -c 16)
SIGNED_CERT="$CERT_DIR/${CLIENT_HOST}.crt"

if ! openssl x509 -req \
    -in "$TMPDIR/client.csr" \
    -CA "$CA_DIR/ca.crt" \
    -CAkey "$CA_DIR/ca.key" \
    -set_serial "0x$SERIAL" \
    -days 730 \
    -sha256 \
    -out "$SIGNED_CERT" 2>/dev/null; then
    echo "Status: 500 Internal Server Error"
    echo ""
    echo '{"error":"failed to sign CSR"}'
    exit 0
fi

# Burn the token
rm -f "$TOKEN_DIR/$TOKEN_CLEAN"

# Read certificates for response
SIGNED_PEM=$(cat "$SIGNED_CERT")
CA_PEM=$(cat "$CA_DIR/ca.crt")

# Add client to server config if not already present
if [ -f "$CONFIG" ]; then
    EXISTS=$(jq --arg h "$CLIENT_HOST" '.clients[] | select(.name == $h)' "$CONFIG" 2>/dev/null)
    if [ -z "$EXISTS" ]; then
        jq --arg name "$CLIENT_HOST" --arg host "$CLIENT_HOST" --argjson port "$CLIENT_PORT" \
            '.clients += [{"name":$name,"host":$host,"port":$port}]' \
            "$CONFIG" > "${CONFIG}.tmp"
        mv "${CONFIG}.tmp" "$CONFIG"
    fi
fi

# Return signed cert and CA cert
echo ""
jq -n \
    --arg cert "$SIGNED_PEM" \
    --arg ca "$CA_PEM" \
    --arg hostname "$CLIENT_HOST" \
    '{"ok":true,"signed_cert":$cert,"ca_cert":$ca,"hostname":$hostname}'
