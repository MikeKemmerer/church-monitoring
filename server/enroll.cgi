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

CA_DIR="/etc/church-monitoring/ca"
TOKEN_DIR="/etc/church-monitoring/tokens"
CONFIG="/etc/church-monitoring/server-config.json"
CERT_DIR="/etc/church-monitoring/signed-certs"

# CGI error helper — ensures valid CGI output on any failure
cgi_error() {
    local status="$1" msg="$2"
    echo "Status: $status"
    echo "Content-Type: application/json"
    echo ""
    echo "{\"error\":\"$msg\"}"
    exit 0
}

# Only POST
if [ "$REQUEST_METHOD" != "POST" ]; then
    cgi_error "405 Method Not Allowed" "POST required"
fi

# Parse query string
parse_qs() { echo "$QUERY_STRING" | tr '&' '\n' | grep "^$1=" | cut -d= -f2- | head -1; }

TOKEN=$(parse_qs "token")
CLIENT_HOST=$(parse_qs "hostname")
CLIENT_PORT=$(parse_qs "port")

# Validate inputs
if [ -z "$TOKEN" ]; then
    cgi_error "400 Bad Request" "missing token parameter"
fi

# Sanitize token to prevent path traversal
TOKEN_CLEAN=$(echo "$TOKEN" | tr -cd 'a-zA-Z0-9')
if [ "$TOKEN_CLEAN" != "$TOKEN" ] || [ -z "$TOKEN_CLEAN" ]; then
    cgi_error "400 Bad Request" "invalid token format"
fi

if [ -z "$CLIENT_HOST" ]; then
    cgi_error "400 Bad Request" "missing hostname parameter"
fi

CLIENT_PORT="${CLIENT_PORT:-8033}"

# Validate token exists
if [ ! -f "$TOKEN_DIR/$TOKEN_CLEAN" ]; then
    cgi_error "403 Forbidden" "invalid or expired enrollment token"
fi

# Read CSR from POST body
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT
cat > "$TMPDIR/client.csr"

# Validate CSR format
if ! openssl req -noout -verify -in "$TMPDIR/client.csr" 2>/dev/null; then
    cgi_error "400 Bad Request" "invalid CSR format"
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
    cgi_error "500 Internal Server Error" "failed to sign CSR"
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
echo "Content-Type: application/json"
echo ""
jq -n \
    --arg cert "$SIGNED_PEM" \
    --arg ca "$CA_PEM" \
    --arg hostname "$CLIENT_HOST" \
    '{"ok":true,"signed_cert":$cert,"ca_cert":$ca,"hostname":$hostname}'
