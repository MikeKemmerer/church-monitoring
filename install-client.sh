#!/bin/bash
# install-client.sh — Sets up a church-monitoring agent on a monitored host.
# Run as root on each host to be monitored.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF_DIR="/etc/church-monitoring"
SSL_DIR="$CONF_DIR/ssl"
CACHE_DIR="/var/cache/church-monitoring"
CGI_DIR="/usr/lib/cgi-bin/church-monitoring"
CLIENT_PORT=8033

# ── Help ──────────────────────────────────────────────────────────────
show_help() {
    cat <<'EOF'
Usage: install-client.sh [OPTIONS]

Sets up a church-monitoring agent on this host.

Options:
    --help          Show this help message
    --renew         Renew the agent certificate (re-enrolls with server)

The client installer will:
    1. Install required packages (apache2, openssl, jq)
    2. Generate a TLS certificate and enroll with the monitoring server
    3. Detect available services and prompt which to monitor
    4. Configure Apache on port 8033 with mutual TLS authentication
    5. Install status collection scripts and set up cron

Prerequisites:
    - The monitoring server must be installed first (install-server.sh)
    - You need the server address and an enrollment token

Monitored services (auto-detected, prompted for each):
    - apache2          Web server (systemd)
    - church-calendar  Calendar display server (systemd)
    - videokiosk2      Video kiosk v2 (systemd)
    - videokiosk       Video kiosk legacy (systemd)
    - vlc              VLC media player (process)
    - midori           Midori web browser (process)
    - CEC              TV power/input via CEC (on-demand only)

File locations:
    /etc/church-monitoring/              Configuration root
    /etc/church-monitoring/ssl/          Agent certificate and CA cert
    /etc/church-monitoring/client-config.json  Service configuration
    /var/cache/church-monitoring/         Cached status data
    /usr/lib/cgi-bin/church-monitoring/  CGI scripts
EOF
    exit 0
}

# ── Parse arguments ───────────────────────────────────────────────────
RENEW=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help) show_help ;;
        --renew) RENEW=1; shift ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# ── Require root ──────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    echo "This installer must be run as root (use sudo)." >&2
    exit 1
fi

# ── Install packages ─────────────────────────────────────────────────
install_packages() {
    local required=(apache2 openssl jq curl bc)
    local missing=()

    for pkg in "${required[@]}"; do
        if ! dpkg -s "$pkg" >/dev/null 2>&1; then
            missing+=("$pkg")
        fi
    done

    if [[ ${#missing[@]} -eq 0 ]]; then
        echo "All prerequisites already installed; skipping apt update/install."
    else
        echo "Missing packages: ${missing[*]}"
        echo "Installing..."
        apt-get update -y
        apt-get install -y "${missing[@]}"
    fi
}

# ── Prompt helper ────────────────────────────────────────────────────
ask_yn() {
    local prompt="$1" default="${2:-y}"
    local yn
    if [[ "$default" == "y" ]]; then
        read -r -p "  $prompt [Y/n]: " yn
        yn="${yn:-y}"
    else
        read -r -p "  $prompt [y/N]: " yn
        yn="${yn:-n}"
    fi
    [[ "$yn" =~ ^[Yy] ]]
}

echo "=== Church Monitoring Client Installer ==="
echo ""

# ── Step 1: Packages ─────────────────────────────────────────────────
echo "Step 1/6: Installing packages..."
install_packages

# ── Step 2: Server connection and enrollment ─────────────────────────
echo ""
echo "Step 2/6: Server enrollment..."
mkdir -p "$CONF_DIR" "$SSL_DIR" "$CACHE_DIR" "$CGI_DIR"

# Load existing config for --renew
if [[ $RENEW -eq 1 && -f "$CONF_DIR/client-config.json" ]]; then
    echo "  Renewal mode — reusing existing service configuration."
fi

read -r -p "  Server address (host or host:port) [e.g. 192.168.1.100:8080]: " SERVER_ADDR
if [[ -z "$SERVER_ADDR" ]]; then
    echo "  Server address is required." >&2
    exit 1
fi

# Add default port if not specified
if [[ "$SERVER_ADDR" != *:* ]]; then
    SERVER_ADDR="${SERVER_ADDR}:8080"
fi

read -r -p "  Enrollment token: " ENROLL_TOKEN
if [[ -z "$ENROLL_TOKEN" ]]; then
    echo "  Enrollment token is required." >&2
    exit 1
fi

# Determine this host's name
DEFAULT_HOSTNAME=$(hostname)
read -r -p "  Client hostname [$DEFAULT_HOSTNAME]: " CLIENT_HOSTNAME
CLIENT_HOSTNAME="${CLIENT_HOSTNAME:-$DEFAULT_HOSTNAME}"

# Generate agent key and CSR
echo "  Generating TLS certificate..."
openssl req -newkey rsa:2048 -nodes \
    -keyout "$SSL_DIR/agent.key" \
    -out "$SSL_DIR/agent.csr" \
    -subj "/CN=${CLIENT_HOSTNAME}" 2>/dev/null
chmod 600 "$SSL_DIR/agent.key"

# Enroll with server
echo "  Enrolling with server at $SERVER_ADDR..."
ENROLL_RESPONSE=$(curl -s -w "\n%{http_code}" -X POST \
    "http://${SERVER_ADDR}/cgi-bin/enroll.cgi?token=${ENROLL_TOKEN}&hostname=${CLIENT_HOSTNAME}&port=${CLIENT_PORT}" \
    --data-binary @"$SSL_DIR/agent.csr" 2>/dev/null) || true

HTTP_CODE=$(echo "$ENROLL_RESPONSE" | tail -1)
RESPONSE_BODY=$(echo "$ENROLL_RESPONSE" | sed '$d')

if [[ "$HTTP_CODE" != "200" ]]; then
    ERROR=$(echo "$RESPONSE_BODY" | jq -r '.error // empty' 2>/dev/null || echo "$RESPONSE_BODY")
    echo "  Enrollment failed (HTTP $HTTP_CODE): $ERROR" >&2
    echo "  Check the server address, token, and that the server is running." >&2
    exit 1
fi

# Extract certificates from response
echo "$RESPONSE_BODY" | jq -r '.signed_cert' > "$SSL_DIR/agent.crt"
echo "$RESPONSE_BODY" | jq -r '.ca_cert' > "$SSL_DIR/ca.crt"
rm -f "$SSL_DIR/agent.csr"
chmod 644 "$SSL_DIR/agent.crt" "$SSL_DIR/ca.crt"
echo "  Enrollment successful — certificates installed."

# ── Step 3: Service detection ────────────────────────────────────────
echo ""
echo "Step 3/6: Configuring service monitoring..."

MONITORS="[]"
CEC_ENABLED="false"

# Systemd services to check for
declare -A SERVICE_MAP=(
    ["apache2"]="Apache web server"
    ["church-calendar"]="Church calendar display"
    ["videokiosk2"]="Video kiosk v2"
    ["videokiosk"]="Video kiosk (legacy)"
)

for svc in apache2 church-calendar videokiosk2 videokiosk; do
    DESC="${SERVICE_MAP[$svc]}"
    if systemctl list-unit-files "${svc}.service" 2>/dev/null | grep -q "$svc"; then
        if ask_yn "Monitor ${svc} (${DESC})?" "y"; then
            MONITORS=$(echo "$MONITORS" | jq --arg n "$svc" '. + [{"name":$n,"type":"systemd"}]')
        fi
    fi
done

# Process checks
declare -A PROC_MAP=(
    ["vlc"]="VLC media player"
    ["midori"]="Midori web browser"
)

for proc in vlc midori; do
    DESC="${PROC_MAP[$proc]}"
    if command -v "$proc" &>/dev/null; then
        if ask_yn "Monitor ${proc} process (${DESC})?" "y"; then
            MONITORS=$(echo "$MONITORS" | jq --arg n "$proc" '. + [{"name":$n,"type":"process"}]')
        fi
    fi
done

# CEC
if command -v cec-client &>/dev/null; then
    if ask_yn "Enable CEC TV status check (on-demand only)?" "y"; then
        CEC_ENABLED="true"
        # Add www-data to video group for CEC access
        usermod -aG video www-data 2>/dev/null || true
    fi
fi

# Write client config (skip if --renew and config exists)
if [[ $RENEW -eq 0 ]] || [[ ! -f "$CONF_DIR/client-config.json" ]]; then
    jq -n \
        --arg hostname "$CLIENT_HOSTNAME" \
        --argjson monitors "$MONITORS" \
        --argjson cec "$CEC_ENABLED" \
        '{hostname:$hostname, monitors:$monitors, cec_enabled:$cec}' \
        > "$CONF_DIR/client-config.json"
    chmod 644 "$CONF_DIR/client-config.json"
    echo "  Configuration saved."
fi

# ── Step 4: Install CGI scripts ──────────────────────────────────────
echo ""
echo "Step 4/6: Installing CGI scripts..."

cp "$SCRIPT_DIR/client/status.cgi" "$CGI_DIR/status.cgi"
cp "$SCRIPT_DIR/client/cec-check.cgi" "$CGI_DIR/cec-check.cgi"
chmod 755 "$CGI_DIR"/*.cgi
chown -R www-data:www-data "$CGI_DIR"

# Install collect script
cp "$SCRIPT_DIR/client/collect.sh" /usr/local/bin/church-monitoring-collect
chmod 755 /usr/local/bin/church-monitoring-collect

echo "  CGI scripts and collector installed."

# ── Step 5: Apache vhost ─────────────────────────────────────────────
echo ""
echo "Step 5/6: Configuring Apache..."

VHOST="/etc/apache2/sites-available/church-monitoring-client.conf"

cat > "$VHOST" <<VHEOF
<VirtualHost *:${CLIENT_PORT}>
    ServerName ${CLIENT_HOSTNAME}

    SSLEngine on
    SSLCertificateFile ${SSL_DIR}/agent.crt
    SSLCertificateKeyFile ${SSL_DIR}/agent.key

    # Require client certificate signed by our CA
    SSLCACertificateFile ${SSL_DIR}/ca.crt
    SSLVerifyClient require
    SSLVerifyDepth 1

    ScriptAlias /cgi-bin/ ${CGI_DIR}/

    <Directory ${CGI_DIR}>
        Options +ExecCGI
        AddHandler cgi-script .cgi
        Require all granted
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/church-monitoring-error.log
    CustomLog \${APACHE_LOG_DIR}/church-monitoring-access.log combined
</VirtualHost>
VHEOF

# Ensure Apache listens on the client port
if ! grep -q "Listen $CLIENT_PORT" /etc/apache2/ports.conf 2>/dev/null; then
    echo "Listen $CLIENT_PORT" >> /etc/apache2/ports.conf
fi

# Enable required modules
a2enmod cgi >/dev/null 2>&1 || true
a2enmod ssl >/dev/null 2>&1 || true

# Enable site
a2ensite church-monitoring-client.conf >/dev/null 2>&1 || true

# Reload Apache
systemctl reload apache2

echo "  Apache configured on port $CLIENT_PORT with mutual TLS."

# ── Step 6: Cron setup ──────────────────────────────────────────────
echo ""
echo "Step 6/6: Setting up cron..."

CRON_LINE="*/5 * * * * /usr/local/bin/church-monitoring-collect"

# Add cron entry if not already present
if ! crontab -l 2>/dev/null | grep -q "church-monitoring-collect"; then
    (crontab -l 2>/dev/null || true; echo "$CRON_LINE") | crontab -
    echo "  Cron job added (every 5 minutes)."
else
    echo "  Cron job already exists — skipping."
fi

# Run initial collection
echo "  Running initial data collection..."
/usr/local/bin/church-monitoring-collect || true

echo ""
echo "=============================================="
echo "  Client installation complete!"
echo "=============================================="
echo ""
echo "Agent: https://${CLIENT_HOSTNAME}:${CLIENT_PORT}/"
echo "Status endpoint: /cgi-bin/status.cgi"
if [[ "$CEC_ENABLED" == "true" ]]; then
    echo "CEC endpoint: /cgi-bin/cec-check.cgi (on-demand)"
fi
echo ""
echo "Monitored services:"
echo "$MONITORS" | jq -r '.[] | "  - " + .name + " (" + .type + ")"'
echo ""
echo "Next: Verify on the dashboard that this client appears."
