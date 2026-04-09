#!/bin/bash
# uninstall.sh — Removes the church-monitoring client/agent installation.
# Run as root. Installed packages are left in place.
set -e

CONF_DIR="/etc/church-monitoring"
CACHE_DIR="/var/cache/church-monitoring"
CGI_DIR="/usr/lib/cgi-bin/church-monitoring"
LOCK="/var/run/church-monitoring-collect.lock"
VHOST="/etc/apache2/sites-available/church-monitoring-client.conf"
CLIENT_PORT=8033

show_help() {
    cat <<'EOF'
Usage: client/uninstall.sh [OPTIONS]

Removes the church-monitoring agent (CGIs, cron, certificates, config).
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
    echo "This will remove the church-monitoring client installation:"
    echo "  - Apache vhost and site config"
    echo "  - CGI scripts ($CGI_DIR)"
    echo "  - Collector script and cron job"
    echo "  - Certificates and config ($CONF_DIR)"
    echo "  - Cached status data ($CACHE_DIR)"
    echo ""
    read -r -p "Are you sure? [y/N]: " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy] ]]; then
        echo "Aborted."
        exit 0
    fi
fi

echo "=== Uninstalling Church Monitoring Client ==="

# Remove cron job
echo "Removing cron job..."
if crontab -l 2>/dev/null | grep -q "church-monitoring-collect"; then
    crontab -l 2>/dev/null | grep -v "church-monitoring-collect" | crontab - 2>/dev/null || true
fi

# Disable and remove Apache vhost
if [[ -f "$VHOST" ]]; then
    echo "Disabling Apache site..."
    a2dissite church-monitoring-client.conf >/dev/null 2>&1 || true
    rm -f "$VHOST"
fi

# Remove Listen directive from ports.conf
sed -i "/^Listen ${CLIENT_PORT}$/d" /etc/apache2/ports.conf 2>/dev/null || true

# Reload Apache
systemctl reload apache2 2>/dev/null || true

# Remove CGI scripts
if [[ -d "$CGI_DIR" ]]; then
    echo "Removing CGI scripts..."
    rm -rf "$CGI_DIR"
fi

# Remove collector script
echo "Removing collector..."
rm -f /usr/local/bin/church-monitoring-collect

# Remove lock file
rm -f "$LOCK"

# Remove cached data
if [[ -d "$CACHE_DIR" ]]; then
    echo "Removing cached data..."
    rm -rf "$CACHE_DIR"
fi

# Remove config and certificates
if [[ -d "$CONF_DIR" ]]; then
    echo "Removing configuration and certificates..."
    rm -rf "$CONF_DIR"
fi

echo ""
echo "=============================================="
echo "  Client uninstall complete."
echo "=============================================="
echo ""
echo "Installed packages were left in place."
echo "The server still has this client in its config — it will"
echo "show as unreachable on the dashboard until removed."
