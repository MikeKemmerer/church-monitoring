#!/bin/bash
# uninstall.sh — Removes the church-monitoring server installation.
# Run as root. Installed packages are left in place.
set -e

CONF_DIR="/etc/church-monitoring"
WEB_ROOT="/var/www/church-monitoring"
CGI_DIR="/usr/lib/cgi-bin/church-monitoring-server"
LEGACY_CGI_DIR="/usr/lib/cgi-bin/church-monitoring"
VHOST="/etc/apache2/sites-available/church-monitoring-server.conf"

show_help() {
    cat <<'EOF'
Usage: server/uninstall.sh [OPTIONS]

Removes the church-monitoring server (dashboard, CGIs, certificates, config).
Installed packages (apache2, openssl, jq) are NOT removed.

Options:
    --help    Show this help message
    --force   Skip confirmation prompt
EOF
    exit 0
}

FORCE=0
[[ "${1:-}" == "--help" ]] && show_help
[[ "${1:-}" == "--force" ]] && FORCE=1

if [[ $EUID -ne 0 ]]; then
    echo "This must be run as root (use sudo)." >&2
    exit 1
fi

if [[ $FORCE -eq 0 ]]; then
    echo "This will remove the church-monitoring server installation:"
    echo "  - Apache vhost and site config"
    echo "  - Dashboard files ($WEB_ROOT)"
    echo "  - CGI scripts ($CGI_DIR)"
    echo "  - Certificates, CA, tokens ($CONF_DIR)"
    echo "  - Admin scripts (generate-token.sh, sign-csr.sh, manage-auth.sh)"
    echo ""
    read -r -p "Are you sure? [y/N]: " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy] ]]; then
        echo "Aborted."
        exit 0
    fi
fi

echo "=== Uninstalling Church Monitoring Server ==="

# Disable and remove Apache vhost
if [[ -f "$VHOST" ]]; then
    echo "Disabling Apache site..."
    a2dissite church-monitoring-server.conf >/dev/null 2>&1 || true
    rm -f "$VHOST"
fi

# Remove Listen directive from ports.conf
if [[ -f "$CONF_DIR/server-config.json" ]]; then
    PORT=$(jq -r '.port // empty' "$CONF_DIR/server-config.json" 2>/dev/null || true)
    if [[ -n "$PORT" ]]; then
        sed -i "/^Listen ${PORT}$/d" /etc/apache2/ports.conf 2>/dev/null || true
    fi
fi

# Reload Apache
systemctl reload apache2 2>/dev/null || true

# Remove web root
if [[ -d "$WEB_ROOT" ]]; then
    echo "Removing dashboard files..."
    rm -rf "$WEB_ROOT"
fi

# Remove CGI scripts
if [[ -d "$CGI_DIR" ]]; then
    echo "Removing CGI scripts..."
    rm -rf "$CGI_DIR"
fi

if [[ -d "$LEGACY_CGI_DIR" ]]; then
    echo "Removing legacy CGI directory..."
    rm -rf "$LEGACY_CGI_DIR"
fi

# Remove admin scripts
echo "Removing admin scripts..."
rm -f /usr/local/bin/generate-token.sh
rm -f /usr/local/bin/sign-csr.sh
rm -f /usr/local/bin/manage-auth.sh

# Remove config directory (CA, certs, tokens, config)
if [[ -d "$CONF_DIR" ]]; then
    echo "Removing configuration and certificates..."
    rm -rf "$CONF_DIR"
fi

echo ""
echo "=============================================="
echo "  Server uninstall complete."
echo "=============================================="
echo ""
echo "Installed packages were left in place."
echo "Enrolled clients still have their certificates but will"
echo "no longer be able to reach the dashboard."
