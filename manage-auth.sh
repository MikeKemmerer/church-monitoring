#!/bin/bash
# manage-auth.sh — Manage dashboard authentication credentials.
# Run on the monitoring server.
set -e

HTPASSWD="/etc/church-monitoring/.htpasswd"

show_help() {
    cat <<'EOF'
Usage: manage-auth.sh [OPTIONS]

Manage HTTP basic auth credentials for the monitoring dashboard.

Options:
    --help    Show this help message

Interactive menu:
    1) Change a user's password
    2) Add a new user
    3) Remove a user
    4) List users
EOF
    exit 0
}

[[ "${1:-}" == "--help" ]] && show_help

if [[ $EUID -ne 0 ]]; then
    echo "This must be run as root (use sudo)." >&2
    exit 1
fi

if [[ ! -f "$HTPASSWD" ]]; then
    echo ".htpasswd not found. Has the server been installed?" >&2
    exit 1
fi

echo "=== Dashboard Auth Management ==="
echo ""
echo "1) Change a user's password"
echo "2) Add a new user"
echo "3) Remove a user"
echo "4) List users"
echo ""
read -r -p "Choice [1-4]: " CHOICE

case "$CHOICE" in
    1)
        read -r -p "Username: " USER
        if ! grep -q "^${USER}:" "$HTPASSWD"; then
            echo "User '$USER' not found." >&2
            exit 1
        fi
        while true; do
            read -r -s -p "New password: " PASS
            echo ""
            if [[ -z "$PASS" ]]; then
                echo "Password cannot be empty."
                continue
            fi
            read -r -s -p "Confirm password: " PASS2
            echo ""
            if [[ "$PASS" != "$PASS2" ]]; then
                echo "Passwords do not match. Try again."
                continue
            fi
            break
        done
        echo "$PASS" | htpasswd -i "$HTPASSWD" "$USER"
        echo "Password updated for '$USER'."
        ;;
    2)
        read -r -p "New username: " USER
        if grep -q "^${USER}:" "$HTPASSWD"; then
            echo "User '$USER' already exists." >&2
            exit 1
        fi
        while true; do
            read -r -s -p "Password: " PASS
            echo ""
            if [[ -z "$PASS" ]]; then
                echo "Password cannot be empty."
                continue
            fi
            read -r -s -p "Confirm password: " PASS2
            echo ""
            if [[ "$PASS" != "$PASS2" ]]; then
                echo "Passwords do not match. Try again."
                continue
            fi
            break
        done
        echo "$PASS" | htpasswd -i "$HTPASSWD" "$USER"
        echo "User '$USER' added."
        ;;
    3)
        read -r -p "Username to remove: " USER
        if ! grep -q "^${USER}:" "$HTPASSWD"; then
            echo "User '$USER' not found." >&2
            exit 1
        fi
        htpasswd -D "$HTPASSWD" "$USER"
        echo "User '$USER' removed."
        ;;
    4)
        echo ""
        echo "Current users:"
        awk -F: '{print "  - " $1}' "$HTPASSWD"
        ;;
    *)
        echo "Invalid choice." >&2
        exit 1
        ;;
esac
