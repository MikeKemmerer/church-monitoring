#!/bin/bash
# sign-csr.sh — Manually signs a Certificate Signing Request with the CA.
# Run on the monitoring server.
set -e

CA_DIR="/etc/church-monitoring/ca"
CERT_DIR="/etc/church-monitoring/signed-certs"

show_help() {
    cat <<'EOF'
Usage: sign-csr.sh <path-to-csr> [output-path]

Manually signs a CSR with the church-monitoring CA.

Arguments:
    path-to-csr    Path to the .csr file to sign
    output-path    Optional path for the signed certificate
                   (default: signed-certs/<CN>.crt)

Options:
    --help    Show this help message

The signed certificate is valid for 2 years (730 days).
EOF
    exit 0
}

[[ "${1:-}" == "--help" ]] && show_help

if [[ $EUID -ne 0 ]]; then
    echo "This must be run as root (use sudo)." >&2
    exit 1
fi

CSR_PATH="${1:-}"
OUTPUT_PATH="${2:-}"

if [[ -z "$CSR_PATH" ]]; then
    echo "Usage: sign-csr.sh <path-to-csr> [output-path]" >&2
    exit 1
fi

if [[ ! -f "$CSR_PATH" ]]; then
    echo "CSR file not found: $CSR_PATH" >&2
    exit 1
fi

if [[ ! -f "$CA_DIR/ca.key" ]]; then
    echo "CA not found. Has the server been installed?" >&2
    exit 1
fi

# Validate CSR
if ! openssl req -noout -verify -in "$CSR_PATH" 2>/dev/null; then
    echo "Invalid CSR format." >&2
    exit 1
fi

# Extract CN for filename
CN=$(openssl req -noout -subject -in "$CSR_PATH" 2>/dev/null | grep -oP 'CN\s*=\s*\K[^/,]+' | tr -cd 'a-zA-Z0-9._-')
if [[ -z "$CN" ]]; then
    CN="signed-$(date +%s)"
fi

if [[ -z "$OUTPUT_PATH" ]]; then
    mkdir -p "$CERT_DIR"
    OUTPUT_PATH="$CERT_DIR/${CN}.crt"
fi

SERIAL="0x$(date +%s%N | sha256sum | head -c 16)"

openssl x509 -req \
    -in "$CSR_PATH" \
    -CA "$CA_DIR/ca.crt" -CAkey "$CA_DIR/ca.key" \
    -set_serial "$SERIAL" \
    -days 730 -sha256 \
    -out "$OUTPUT_PATH" 2>/dev/null

chmod 644 "$OUTPUT_PATH"

echo "CSR signed successfully."
echo "Signed certificate: $OUTPUT_PATH"
echo "Valid for: 730 days (2 years)"
echo ""
echo "Subject: $(openssl x509 -noout -subject -in "$OUTPUT_PATH" 2>/dev/null)"
echo "Expires: $(openssl x509 -noout -enddate -in "$OUTPUT_PATH" 2>/dev/null)"
