#!/bin/bash
# generate-token.sh — Generates a new enrollment token for client onboarding.
# Run on the monitoring server.
set -e

TOKEN_DIR="/etc/church-monitoring/tokens"

show_help() {
    cat <<'EOF'
Usage: generate-token.sh [OPTIONS]

Generates a new single-use enrollment token for client onboarding.

Options:
    --help    Show this help message

Each token can only be used once. After a client enrolls with a token,
the token is automatically deleted.

Tokens are stored in /etc/church-monitoring/tokens/
EOF
    exit 0
}

[[ "${1:-}" == "--help" ]] && show_help

if [[ $EUID -ne 0 ]]; then
    echo "This must be run as root (use sudo)." >&2
    exit 1
fi

if [[ ! -d "$TOKEN_DIR" ]]; then
    echo "Token directory not found. Has the server been installed?" >&2
    exit 1
fi

TOKEN=$(head -c 32 /dev/urandom | base64 | tr -cd 'a-zA-Z0-9' | head -c 24)
touch "$TOKEN_DIR/$TOKEN"
chmod 600 "$TOKEN_DIR/$TOKEN"

echo "New enrollment token:"
echo ""
echo "  $TOKEN"
echo ""
echo "This token is single-use. Give it to the client installer."

# Show current token count
COUNT=$(find "$TOKEN_DIR" -type f | wc -l)
echo ""
echo "Active tokens: $COUNT"
