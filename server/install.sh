#!/bin/bash
# install.sh — Sets up the church-monitoring dashboard server.
# Run as root on the host that will serve the monitoring dashboard.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF_DIR="/etc/church-monitoring"
CA_DIR="$CONF_DIR/ca"
SSL_DIR="$CONF_DIR/ssl"
TOKEN_DIR="$CONF_DIR/tokens"
WEB_ROOT="/var/www/church-monitoring"
CGI_DIR="/usr/lib/cgi-bin/church-monitoring-server"
LEGACY_CGI_DIR="/usr/lib/cgi-bin/church-monitoring"
LIB_DIR="/usr/local/lib/church-monitoring"
DEFAULT_PORT=8080

# ── Help ──────────────────────────────────────────────────────────────
show_help() {
    cat <<'EOF'
Usage: server/install.sh [OPTIONS]

Sets up the church-monitoring dashboard server.

Options:
    --help          Show this help message
    --port NUM      Dashboard port (default: 8080)
    --renew-cert    Regenerate the server client certificate only
    --update        Update dashboard, CGI scripts, and admin tools only
                    (keeps CA, certs, config, auth, and port unchanged)

The server installer will:
    1. Install required packages (apache2, openssl, jq)
    2. Create a Certificate Authority (CA) for mutual TLS
    3. Generate a server client certificate (used to fetch from agents)
    4. Generate a self-signed TLS certificate for the dashboard
    5. Bootstrap the initial admin login account (role-based: user/
       contributor/admin), replacing HTTP Basic Auth with a proper login
       screen and per-account session cookies
    6. Set up the monitoring dashboard on the specified port
    7. Create the enrollment endpoint for client onboarding
    8. Generate the first enrollment token

After installation:
    - Access the dashboard at https://<host>:<port>/ (redirects to login.html)
    - Generate more enrollment tokens: sudo generate-token.sh
    - Manage dashboard users/roles/lockouts: log in as an admin and use the
      "Manage Users" panel (or the users.cgi API directly)
    - Sign CSRs manually: sudo sign-csr.sh <path-to-csr>

File locations:
    /etc/church-monitoring/              Configuration root
    /etc/church-monitoring/ca/           CA certificate and key
    /etc/church-monitoring/ssl/          Server client certificate
    /etc/church-monitoring/tokens/       Enrollment tokens
    /var/www/church-monitoring/          Dashboard web root
    /usr/lib/cgi-bin/church-monitoring-server/  CGI scripts
EOF
    exit 0
}

# ── Parse arguments ───────────────────────────────────────────────────
RENEW_CERT=0
UPDATE=0
PORT=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help) show_help ;;
        --port) PORT="$2"; shift 2 ;;
        --renew-cert) RENEW_CERT=1; shift ;;
        --update) UPDATE=1; shift ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# ── Require root ──────────────────────────────────────────────────────
require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "This installer must be run as root (use sudo)." >&2
        exit 1
    fi
}
require_root

# ── Renew cert only ──────────────────────────────────────────────────
if [[ $RENEW_CERT -eq 1 ]]; then
    echo "=== Renewing server client certificate ==="
    if [[ ! -f "$CA_DIR/ca.key" ]]; then
        echo "Error: CA not found at $CA_DIR. Run full install first." >&2
        exit 1
    fi
    openssl req -newkey rsa:2048 -nodes \
        -keyout "$SSL_DIR/server.key" \
        -out "$SSL_DIR/server.csr" \
        -subj "/CN=church-monitoring-server" 2>/dev/null
    openssl x509 -req \
        -in "$SSL_DIR/server.csr" \
        -CA "$CA_DIR/ca.crt" -CAkey "$CA_DIR/ca.key" \
        -set_serial "0x$(date +%s%N | sha256sum | head -c 16)" \
        -days 730 -sha256 \
        -out "$SSL_DIR/server.crt" 2>/dev/null
    rm -f "$SSL_DIR/server.csr"
    chown root:www-data "$SSL_DIR/server.key"
    chmod 640 "$SSL_DIR/server.key"
    chmod 644 "$SSL_DIR/server.crt"
    echo "Server certificate renewed. Valid for 2 years."
    echo "Restart Apache to use the new certificate: sudo systemctl restart apache2"
    exit 0
fi

# ── Install packages ─────────────────────────────────────────────────
install_packages() {
    local required=(apache2 openssl jq curl)
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

# ── Bootstrap the initial admin login account ────────────────────────
# Idempotent: does nothing if users.json already exists (preserves existing
# accounts across --update runs). Used by both the fresh-install and
# --update flows.
bootstrap_users_json() {
    if [[ -f "$CONF_DIR/users.json" ]]; then
        echo "  users.json already exists — leaving existing accounts unchanged."
        return
    fi

    echo "  No dashboard accounts configured yet. Create the initial admin account:"
    read -r -p "  Admin username [admin]: " INIT_USER
    INIT_USER="${INIT_USER:-admin}"
    while true; do
        read -r -s -p "  Admin password: " INIT_PASS
        echo ""
        if [[ ${#INIT_PASS} -lt 8 ]]; then
            echo "  Password must be at least 8 characters."
            continue
        fi
        read -r -s -p "  Confirm password: " INIT_PASS2
        echo ""
        if [[ "$INIT_PASS" != "$INIT_PASS2" ]]; then
            echo "  Passwords do not match. Try again."
            continue
        fi
        break
    done

    # shellcheck source=auth-lib.sh
    source "$SCRIPT_DIR/auth-lib.sh"
    INIT_HASH=$(printf '%s' "$INIT_PASS" | hash_password)
    jq -n --arg u "$INIT_USER" --arg h "$INIT_HASH" --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{"users":[{"username":$u,"password_hash":$h,"role":"admin","locked":false,"failed_attempts":0,"lockout_until":0,"created":$t,"last_login":null}]}' \
        > "$CONF_DIR/users.json"
    chmod 640 "$CONF_DIR/users.json"
    chown root:www-data "$CONF_DIR/users.json"
    echo "  Admin account '$INIT_USER' created."
}

echo "=== Church Monitoring Server Installer ==="
echo ""

if [[ $UPDATE -eq 1 ]]; then
    # ── Update mode: validate existing installation ───────────────
    echo "Update mode — verifying existing installation..."
    MISSING=""
    [[ ! -f "$CA_DIR/ca.crt" ]]              && MISSING="$MISSING  - CA certificate ($CA_DIR/ca.crt)\n"
    [[ ! -f "$CA_DIR/ca.key" ]]              && MISSING="$MISSING  - CA private key ($CA_DIR/ca.key)\n"
    [[ ! -f "$SSL_DIR/server.crt" ]]         && MISSING="$MISSING  - Server certificate ($SSL_DIR/server.crt)\n"
    [[ ! -f "$SSL_DIR/server.key" ]]         && MISSING="$MISSING  - Server private key ($SSL_DIR/server.key)\n"
    [[ ! -f "$SSL_DIR/dashboard.crt" ]]      && MISSING="$MISSING  - Dashboard certificate ($SSL_DIR/dashboard.crt)\n"
    [[ ! -f "$SSL_DIR/dashboard.key" ]]      && MISSING="$MISSING  - Dashboard private key ($SSL_DIR/dashboard.key)\n"
    [[ ! -f "$CONF_DIR/server-config.json" ]]&& MISSING="$MISSING  - Server configuration ($CONF_DIR/server-config.json)\n"

    if [[ -n "$MISSING" ]]; then
        echo "" >&2
        echo "Update cannot proceed — the following required files are missing:" >&2
        echo -e "$MISSING" >&2
        echo "A fresh installation is required. Run without --update to set up" >&2
        echo "the server from scratch." >&2
        exit 1
    fi

    PORT=$(jq -r '.port // empty' "$CONF_DIR/server-config.json" 2>/dev/null)
    PORT="${PORT:-$DEFAULT_PORT}"
    echo "  Installation verified (port $PORT)."
    echo ""

    echo "Checking dashboard login accounts..."
    bootstrap_users_json
    mkdir -p "$CONF_DIR/sessions"
    chmod 750 "$CONF_DIR/sessions"
    chown root:www-data "$CONF_DIR/sessions"
    echo ""

    # Install web files and scripts
    echo "Updating dashboard and CGI scripts..."

    mkdir -p "$CGI_DIR" "$LIB_DIR"

    cp "$SCRIPT_DIR/index.html" "$WEB_ROOT/index.html"
    cp "$SCRIPT_DIR/help.html" "$WEB_ROOT/help.html"
    cp "$SCRIPT_DIR/login.html" "$WEB_ROOT/login.html"
    chown -R www-data:www-data "$WEB_ROOT"

    cp "$SCRIPT_DIR/auth-lib.sh" "$LIB_DIR/auth-lib.sh"
    chmod 644 "$LIB_DIR/auth-lib.sh"
    chown root:root "$LIB_DIR/auth-lib.sh"

    cp "$SCRIPT_DIR/enroll.cgi" "$CGI_DIR/enroll.cgi"
    cp "$SCRIPT_DIR/login.cgi" "$CGI_DIR/login.cgi"
    cp "$SCRIPT_DIR/logout.cgi" "$CGI_DIR/logout.cgi"
    cp "$SCRIPT_DIR/whoami.cgi" "$CGI_DIR/whoami.cgi"
    cp "$SCRIPT_DIR/change-password.cgi" "$CGI_DIR/change-password.cgi"
    cp "$SCRIPT_DIR/users.cgi" "$CGI_DIR/users.cgi"
    cp "$SCRIPT_DIR/fetch-status.cgi" "$CGI_DIR/fetch-status.cgi"
    cp "$SCRIPT_DIR/fetch-cec.cgi" "$CGI_DIR/fetch-cec.cgi"
    cp "$SCRIPT_DIR/cec-control.cgi" "$CGI_DIR/cec-control.cgi"
    cp "$SCRIPT_DIR/fetch-screenshot.cgi" "$CGI_DIR/fetch-screenshot.cgi"
    cp "$SCRIPT_DIR/restart-service.cgi" "$CGI_DIR/restart-service.cgi"
    cp "$SCRIPT_DIR/device-status.cgi" "$CGI_DIR/device-status.cgi"
    cp "$SCRIPT_DIR/host-action.cgi" "$CGI_DIR/host-action.cgi"
    cp "$SCRIPT_DIR/backup.cgi" "$CGI_DIR/backup.cgi"
    cp "$SCRIPT_DIR/backup-download.cgi" "$CGI_DIR/backup-download.cgi"
    cp "$SCRIPT_DIR/fetch-calendar-images.cgi" "$CGI_DIR/fetch-calendar-images.cgi"
    cp "$SCRIPT_DIR/fetch-calendar-image-file.cgi" "$CGI_DIR/fetch-calendar-image-file.cgi"
    cp "$SCRIPT_DIR/upload-calendar-image.cgi" "$CGI_DIR/upload-calendar-image.cgi"
    cp "$SCRIPT_DIR/delete-calendar-image.cgi" "$CGI_DIR/delete-calendar-image.cgi"
    chmod 755 "$CGI_DIR"/*.cgi
    chown -R www-data:www-data "$CGI_DIR"

    # Remove legacy shared CGI directory after migration.
    if [[ -d "$LEGACY_CGI_DIR" && "$LEGACY_CGI_DIR" != "$CGI_DIR" ]]; then
        rm -rf "$LEGACY_CGI_DIR"
    fi

    cp "$SCRIPT_DIR/generate-token.sh" /usr/local/bin/generate-token.sh
    cp "$SCRIPT_DIR/sign-csr.sh" /usr/local/bin/sign-csr.sh
    chmod 755 /usr/local/bin/generate-token.sh /usr/local/bin/sign-csr.sh

    # Retire the old HTTP Basic Auth mechanism, now superseded by the
    # session-based login system (users.json + users.cgi).
    rm -f /usr/local/bin/manage-auth.sh
    rm -f "$CONF_DIR/.htpasswd"

    # Rewrite Apache vhost (port and paths may have changed in code)
    echo "Updating Apache configuration..."
    VHOST="/etc/apache2/sites-available/church-monitoring-server.conf"

    cat > "$VHOST" <<VHEOF
<VirtualHost *:${PORT}>
    ServerName church-monitoring

    SSLEngine on
    SSLCertificateFile ${SSL_DIR}/dashboard.crt
    SSLCertificateKeyFile ${SSL_DIR}/dashboard.key

    DocumentRoot ${WEB_ROOT}

    <Directory ${WEB_ROOT}>
        Options -Indexes
        AllowOverride None
        Require all granted
    </Directory>

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

    systemctl reload apache2

    CLIENTS=$(jq '.clients | length' "$CONF_DIR/server-config.json" 2>/dev/null || echo "0")

    echo ""
    echo "=============================================="
    echo "  Server update complete!"
    echo "=============================================="
    echo ""
    echo "Dashboard: https://$(hostname -I | awk '{print $1}'):${PORT}/"
    echo "Enrolled clients: $CLIENTS"
    echo ""
    echo "CA, certificates, and port unchanged. Existing dashboard accounts"
    echo "(users.json) preserved."
    echo "Updated: dashboard, CGI scripts, admin tools, Apache vhost."
    echo "Basic Auth (.htpasswd) has been retired in favor of the login screen —"
    echo "log in at https://<host>:${PORT}/login.html"
    exit 0
fi

# ── Prompt for port ──────────────────────────────────────────────────
if [[ -z "$PORT" ]]; then
    read -r -p "Dashboard port [default: $DEFAULT_PORT]: " PORT
    PORT="${PORT:-$DEFAULT_PORT}"
fi

if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [[ "$PORT" -lt 1 || "$PORT" -gt 65535 ]]; then
    echo "Invalid port: $PORT" >&2
    exit 1
fi

echo ""
echo "Step 1/8: Installing packages..."
install_packages

# ── Create directories ───────────────────────────────────────────────
echo "Step 2/8: Creating directories..."
mkdir -p "$CA_DIR" "$SSL_DIR" "$TOKEN_DIR" "$WEB_ROOT" "$CGI_DIR"
mkdir -p "$CONF_DIR/signed-certs"
chown root:www-data "$CA_DIR" "$TOKEN_DIR" "$SSL_DIR" "$CONF_DIR/signed-certs"
chmod 750 "$CA_DIR" "$SSL_DIR"
chmod 770 "$TOKEN_DIR" "$CONF_DIR/signed-certs"

# ── Create CA ─────────────────────────────────────────────────────────
echo "Step 3/8: Creating Certificate Authority..."
if [[ -f "$CA_DIR/ca.key" ]]; then
    echo "  CA already exists — skipping. Use openssl to regenerate manually if needed."
else
    openssl req -x509 -newkey rsa:2048 -nodes \
        -keyout "$CA_DIR/ca.key" \
        -out "$CA_DIR/ca.crt" \
        -days 3650 -sha256 \
        -subj "/CN=church-monitoring-ca" 2>/dev/null
    echo "  CA created (valid 10 years)."
fi
# Ensure CGI scripts can read CA files
chown root:www-data "$CA_DIR/ca.key" "$CA_DIR/ca.crt" 2>/dev/null
chmod 640 "$CA_DIR/ca.key"
chmod 644 "$CA_DIR/ca.crt"

# ── Create server client certificate ─────────────────────────────────
echo "Step 4/8: Creating server client certificate..."
if [[ -f "$SSL_DIR/server.crt" ]]; then
    echo "  Server cert already exists — skipping. Use --renew-cert to regenerate."
else
    openssl req -newkey rsa:2048 -nodes \
        -keyout "$SSL_DIR/server.key" \
        -out "$SSL_DIR/server.csr" \
        -subj "/CN=church-monitoring-server" 2>/dev/null
    openssl x509 -req \
        -in "$SSL_DIR/server.csr" \
        -CA "$CA_DIR/ca.crt" -CAkey "$CA_DIR/ca.key" \
        -set_serial "0x$(date +%s%N | sha256sum | head -c 16)" \
        -days 730 -sha256 \
        -out "$SSL_DIR/server.crt" 2>/dev/null
    rm -f "$SSL_DIR/server.csr"
    echo "  Server client certificate created (valid 2 years)."
fi
# Ensure CGI scripts can read server cert/key
if [[ -f "$SSL_DIR/server.key" ]]; then
    chown root:www-data "$SSL_DIR/server.key"
    chmod 640 "$SSL_DIR/server.key"
fi
[[ -f "$SSL_DIR/server.crt" ]] && chmod 644 "$SSL_DIR/server.crt"

# ── Create dashboard TLS certificate ─────────────────────────────────
echo "Step 5/8: Creating dashboard TLS certificate..."
DASH_CERT="$SSL_DIR/dashboard.crt"
DASH_KEY="$SSL_DIR/dashboard.key"
if [[ -f "$DASH_CERT" ]]; then
    echo "  Dashboard cert already exists — skipping."
else
    openssl req -x509 -newkey rsa:2048 -nodes \
        -keyout "$DASH_KEY" \
        -out "$DASH_CERT" \
        -days 3650 -sha256 \
        -subj "/CN=$(hostname)" 2>/dev/null
    echo "  Self-signed dashboard certificate created (valid 10 years)."
fi
chmod 600 "$DASH_KEY"
chmod 644 "$DASH_CERT"

# ── Dashboard login accounts ─────────────────────────────────────────
echo "Step 6/8: Configuring dashboard login..."
bootstrap_users_json
mkdir -p "$CONF_DIR/sessions"
chmod 750 "$CONF_DIR/sessions"
chown root:www-data "$CONF_DIR/sessions"

# ── Install web files ────────────────────────────────────────────────
echo "Step 7/8: Installing dashboard and CGI scripts..."

# Dashboard
cp "$SCRIPT_DIR/index.html" "$WEB_ROOT/index.html"
cp "$SCRIPT_DIR/help.html" "$WEB_ROOT/help.html"
cp "$SCRIPT_DIR/login.html" "$WEB_ROOT/login.html"
chown -R www-data:www-data "$WEB_ROOT"

mkdir -p "$LIB_DIR"
cp "$SCRIPT_DIR/auth-lib.sh" "$LIB_DIR/auth-lib.sh"
chmod 644 "$LIB_DIR/auth-lib.sh"
chown root:root "$LIB_DIR/auth-lib.sh"

# CGI scripts
cp "$SCRIPT_DIR/enroll.cgi" "$CGI_DIR/enroll.cgi"
cp "$SCRIPT_DIR/login.cgi" "$CGI_DIR/login.cgi"
cp "$SCRIPT_DIR/logout.cgi" "$CGI_DIR/logout.cgi"
cp "$SCRIPT_DIR/whoami.cgi" "$CGI_DIR/whoami.cgi"
cp "$SCRIPT_DIR/change-password.cgi" "$CGI_DIR/change-password.cgi"
cp "$SCRIPT_DIR/users.cgi" "$CGI_DIR/users.cgi"
cp "$SCRIPT_DIR/fetch-status.cgi" "$CGI_DIR/fetch-status.cgi"
cp "$SCRIPT_DIR/fetch-cec.cgi" "$CGI_DIR/fetch-cec.cgi"
cp "$SCRIPT_DIR/cec-control.cgi" "$CGI_DIR/cec-control.cgi"
cp "$SCRIPT_DIR/fetch-screenshot.cgi" "$CGI_DIR/fetch-screenshot.cgi"
cp "$SCRIPT_DIR/restart-service.cgi" "$CGI_DIR/restart-service.cgi"
cp "$SCRIPT_DIR/device-status.cgi" "$CGI_DIR/device-status.cgi"
cp "$SCRIPT_DIR/host-action.cgi" "$CGI_DIR/host-action.cgi"
cp "$SCRIPT_DIR/backup.cgi" "$CGI_DIR/backup.cgi"
cp "$SCRIPT_DIR/backup-download.cgi" "$CGI_DIR/backup-download.cgi"
cp "$SCRIPT_DIR/fetch-calendar-images.cgi" "$CGI_DIR/fetch-calendar-images.cgi"
cp "$SCRIPT_DIR/fetch-calendar-image-file.cgi" "$CGI_DIR/fetch-calendar-image-file.cgi"
cp "$SCRIPT_DIR/upload-calendar-image.cgi" "$CGI_DIR/upload-calendar-image.cgi"
cp "$SCRIPT_DIR/delete-calendar-image.cgi" "$CGI_DIR/delete-calendar-image.cgi"
chmod 755 "$CGI_DIR"/*.cgi
chown -R www-data:www-data "$CGI_DIR"

# Remove legacy shared CGI directory after migration.
if [[ -d "$LEGACY_CGI_DIR" && "$LEGACY_CGI_DIR" != "$CGI_DIR" ]]; then
    rm -rf "$LEGACY_CGI_DIR"
fi

# Ensure server-config.json is writable by CGI (enrollment adds clients)
if [[ -f "$CONF_DIR/server-config.json" ]]; then
    chown root:www-data "$CONF_DIR/server-config.json"
    chmod 660 "$CONF_DIR/server-config.json"
fi

# Admin scripts
cp "$SCRIPT_DIR/generate-token.sh" /usr/local/bin/generate-token.sh
cp "$SCRIPT_DIR/sign-csr.sh" /usr/local/bin/sign-csr.sh
chmod 755 /usr/local/bin/generate-token.sh /usr/local/bin/sign-csr.sh

# Initialize server config if not present
if [[ ! -f "$CONF_DIR/server-config.json" ]]; then
    echo '{"port":'"$PORT"',"clients":[]}' | jq '.' > "$CONF_DIR/server-config.json"
fi
chown root:www-data "$CONF_DIR/server-config.json"
chmod 660 "$CONF_DIR/server-config.json"

# ── Apache vhost ──────────────────────────────────────────────────────
echo "Step 8/8: Configuring Apache..."
VHOST="/etc/apache2/sites-available/church-monitoring-server.conf"

cat > "$VHOST" <<VHEOF
<VirtualHost *:${PORT}>
    ServerName church-monitoring

    SSLEngine on
    SSLCertificateFile ${SSL_DIR}/dashboard.crt
    SSLCertificateKeyFile ${SSL_DIR}/dashboard.key

    DocumentRoot ${WEB_ROOT}

    <Directory ${WEB_ROOT}>
        Options -Indexes
        AllowOverride None
        Require all granted
    </Directory>

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

# Ensure Apache listens on the port
if ! grep -q "Listen $PORT" /etc/apache2/ports.conf 2>/dev/null; then
    echo "Listen $PORT" >> /etc/apache2/ports.conf
fi

# Enable required modules
a2enmod cgi >/dev/null 2>&1 || true
a2enmod ssl >/dev/null 2>&1 || true

# Enable site
a2ensite church-monitoring-server.conf >/dev/null 2>&1 || true

# Reload Apache
systemctl reload apache2

# ── Generate first enrollment token ──────────────────────────────────
echo ""
FIRST_TOKEN=$(head -c 32 /dev/urandom | base64 | tr -cd 'a-zA-Z0-9' | head -c 24)
touch "$TOKEN_DIR/$FIRST_TOKEN"
chmod 600 "$TOKEN_DIR/$FIRST_TOKEN"

echo "=============================================="
echo "  Server installation complete!"
echo "=============================================="
echo ""
echo "Dashboard: https://$(hostname -I | awk '{print $1}'):${PORT}/ (redirects to login.html)"
echo ""
echo "Enrollment token for client setup:"
echo ""
echo "  $FIRST_TOKEN"
echo ""
echo "This token is single-use. Generate more with:"
echo "  sudo generate-token.sh"
echo ""
echo "CA public certificate (clients will receive this during enrollment):"
echo "------"
cat "$CA_DIR/ca.crt"
echo "------"
echo ""
echo "Next step: Run client/install.sh on each monitored host."
