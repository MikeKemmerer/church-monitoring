#!/bin/bash
# install.sh — Sets up a church-monitoring agent on a monitored host.
# Run as root on each host to be monitored.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RELEASE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONF_DIR="/etc/church-monitoring"
SSL_DIR="$CONF_DIR/ssl"
CACHE_DIR="/var/cache/church-monitoring"
CGI_DIR="/usr/lib/cgi-bin/church-monitoring-client"
LEGACY_CGI_DIR="/usr/lib/cgi-bin/church-monitoring"
CLIENT_PORT=8033
VERSION_MANIFEST="$CONF_DIR/installed-version.json"

# ── Help ──────────────────────────────────────────────────────────────
show_help() {
    cat <<'EOF'
Usage: client/install.sh [OPTIONS]

Sets up a church-monitoring agent on this host.

Options:
    --help          Show this help message
    --renew         Renew the agent certificate (re-enrolls with server)
    --configure-apparmor  Configure Ubuntu Apache AppArmor in complain mode
    --update        Update config and CGI scripts only (keeps certs/enrollment)
    --config-choice E|I|N  Select existing, installer, or new config during --update

The client installer will:
    1. Install required packages (apache2, openssl, jq)
    2. Generate a TLS certificate and enroll with the monitoring server
    3. Detect available services and prompt which to monitor
    4. Configure Apache on port 8033 with mutual TLS authentication
    5. Install status collection scripts and set up cron

Prerequisites:
    - The monitoring server must be installed first (server/install.sh)
    - You need the server address and an enrollment token

Monitored services (auto-detected, prompted for each):
    - apache2          Web server (systemd)
    - church-calendar  Calendar display server (systemd)
    - videokiosk2      Video kiosk v2 (systemd)
    - vlc              VLC media player (process)
    - browser          Falkon, Midori, or system web browser (process)
    - CEC              TV power/input via CEC (on-demand only)

File locations:
    /etc/church-monitoring/              Configuration root
    /etc/church-monitoring/ssl/          Agent certificate and CA cert
    /etc/church-monitoring/client-config.json  Service configuration
    /var/cache/church-monitoring/         Cached status data
    /usr/lib/cgi-bin/church-monitoring-client/  CGI scripts
EOF
    exit 0
}

# ── Parse arguments ───────────────────────────────────────────────────
RENEW=0
UPDATE=0
CONFIGURE_APPARMOR=0
CONFIG_CHOICE_OVERRIDE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help) show_help ;;
        --renew) RENEW=1; shift ;;
        --configure-apparmor) CONFIGURE_APPARMOR=1; shift ;;
        --update) UPDATE=1; shift ;;
        --config-choice)
            CONFIG_CHOICE_OVERRIDE="${2:-}"
            [[ -n "$CONFIG_CHOICE_OVERRIDE" ]] || { echo "--config-choice requires E, I, or N." >&2; exit 1; }
            shift 2
            ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

if [[ -n "$CONFIG_CHOICE_OVERRIDE" ]]; then
    CONFIG_CHOICE_OVERRIDE=$(echo "$CONFIG_CHOICE_OVERRIDE" | tr '[:lower:]' '[:upper:]')
    [[ $UPDATE -eq 1 ]] || { echo "--config-choice requires --update." >&2; exit 1; }
    [[ "$CONFIG_CHOICE_OVERRIDE" =~ ^[EIN]$ ]] || { echo "--config-choice must be E, I, or N." >&2; exit 1; }
fi

# ── Require root ──────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    echo "This installer must be run as root (use sudo)." >&2
    exit 1
fi

write_version_manifest() {
    local release_file="$RELEASE_ROOT/RELEASE.json"
    local version tag commit installed_at existing

    version=$(tr -d '\r\n' < "$RELEASE_ROOT/VERSION" 2>/dev/null || echo "unknown")
    tag="v$version"
    commit=$(git -C "$RELEASE_ROOT" rev-parse HEAD 2>/dev/null || echo "unknown")
    if [[ -r "$release_file" ]]; then
        version=$(jq -r '.version // empty' "$release_file" 2>/dev/null || echo "$version")
        tag=$(jq -r '.tag // empty' "$release_file" 2>/dev/null || echo "$tag")
        commit=$(jq -r '.commit // empty' "$release_file" 2>/dev/null || echo "$commit")
    fi
    [[ -n "$version" ]] || version="unknown"
    [[ -n "$tag" ]] || tag="v$version"
    [[ -n "$commit" ]] || commit="unknown"
    installed_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    existing=$(jq -c '.' "$VERSION_MANIFEST" 2>/dev/null || echo '{}')

    printf '%s\n' "$existing" | jq \
        --arg version "$version" \
        --arg tag "$tag" \
        --arg commit "$commit" \
        --arg installed_at "$installed_at" \
        '.roles = ((.roles // {}) + {client: {version: $version, tag: $tag, commit: $commit, installed_at: $installed_at}})' \
        > "${VERSION_MANIFEST}.tmp"
    mv "${VERSION_MANIFEST}.tmp" "$VERSION_MANIFEST"
    chown root:root "$VERSION_MANIFEST"
    chmod 644 "$VERSION_MANIFEST"
    echo "  Installed client version: $tag ($commit)"
}

configure_apparmor_if_requested() {
    if [[ $CONFIGURE_APPARMOR -eq 1 ]]; then
        "$SCRIPT_DIR/../configure-apparmor.sh" --role client
    fi
}

# ── Install packages ─────────────────────────────────────────────────
install_packages() {
    local required=(apache2 openssl jq curl bc scrot)
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

if [[ $UPDATE -eq 1 ]]; then
    # ── Update mode: skip packages, enrollment, vhost, cron ──────────
    if [[ ! -d "$CONF_DIR" ]]; then
        echo "Error: no existing installation found at $CONF_DIR." >&2
        echo "Run a full install first (without --update)." >&2
        exit 1
    fi
    echo "Update mode — keeping certificates and enrollment."
    echo ""

    BUNDLED_CONFIG="$SCRIPT_DIR/config.json"
    CLIENT_HOSTNAME=$(jq -r '.hostname // empty' "$CONF_DIR/client-config.json" 2>/dev/null)
    CLIENT_HOSTNAME="${CLIENT_HOSTNAME:-$(hostname)}"
else

# ── Step 1: Packages ─────────────────────────────────────────────────
echo "Step 1/6: Installing packages..."
install_packages

# ── Step 2: Server connection and enrollment ─────────────────────────
echo ""
echo "Step 2/6: Server enrollment..."
mkdir -p "$CONF_DIR" "$SSL_DIR" "$CACHE_DIR" "$CGI_DIR"
chown root:www-data "$CACHE_DIR"
chmod 775 "$CACHE_DIR"

# Load existing config for --renew
if [[ $RENEW -eq 1 && -f "$CONF_DIR/client-config.json" ]]; then
    echo "  Renewal mode — reusing existing service configuration."
fi

read -r -p "  Server address (host or host:port) [e.g. server-ip:8080]: " SERVER_ADDR
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
BUNDLED_CONFIG="$SCRIPT_DIR/config.json"
if [[ -f "$BUNDLED_CONFIG" ]]; then
    DEFAULT_HOSTNAME=$(jq -r '.hostname // empty' "$BUNDLED_CONFIG" 2>/dev/null)
fi
DEFAULT_HOSTNAME="${DEFAULT_HOSTNAME:-$(hostname)}"
read -r -p "  Client hostname [$DEFAULT_HOSTNAME]: " CLIENT_HOSTNAME
CLIENT_HOSTNAME="${CLIENT_HOSTNAME:-$DEFAULT_HOSTNAME}"

# Generate agent key and CSR
echo "  Generating TLS certificate..."
openssl req -newkey rsa:2048 -nodes \
    -keyout "$SSL_DIR/agent.key" \
    -out "$SSL_DIR/agent.csr" \
    -subj "/CN=${CLIENT_HOSTNAME}" 2>/dev/null
chmod 600 "$SSL_DIR/agent.key"

# Enroll with server (HTTPS with self-signed cert)
echo "  Enrolling with server at $SERVER_ADDR..."
ENROLL_RESPONSE=$(curl -sk -w "\n%{http_code}" -X POST \
    "https://${SERVER_ADDR}/cgi-bin/enroll.cgi?token=${ENROLL_TOKEN}&hostname=${CLIENT_HOSTNAME}&port=${CLIENT_PORT}" \
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

fi  # end of full-install vs update-mode

# ── Step 3: Service detection ────────────────────────────────────────
echo ""
echo "Step 3/6: Configuring service monitoring..."

MONITORS="[]"
CEC_ENABLED="false"
DISPLAY_CONTROL_JSON="null"
EXISTING_CONFIG="$CONF_DIR/client-config.json"
SKIP_CONFIG=0

if [[ $UPDATE -eq 1 ]]; then
    # ── Update mode: ask how to handle config ────────────────────────
    HAS_EXISTING=0
    HAS_BUNDLED=0
    [[ -f "$EXISTING_CONFIG" ]] && HAS_EXISTING=1
    [[ -f "$BUNDLED_CONFIG" ]] && HAS_BUNDLED=1

    echo "  Service configuration options:"
    if [[ $HAS_EXISTING -eq 1 ]]; then
        EXISTING_COUNT=$(jq '.monitors | length' "$EXISTING_CONFIG" 2>/dev/null || echo "0")
        echo "    [E] Keep existing config ($EXISTING_COUNT monitors)"
    fi
    if [[ $HAS_BUNDLED -eq 1 ]]; then
        BUNDLED_COUNT=$(jq '.monitors | length' "$BUNDLED_CONFIG" 2>/dev/null || echo "0")
        echo "    [I] Use installer config.json as-is ($BUNDLED_COUNT monitors)"
    fi
    echo "    [N] New — prompt for each monitor"
    echo ""

    VALID_OPTS=""
    [[ $HAS_EXISTING -eq 1 ]] && VALID_OPTS="${VALID_OPTS}E/"
    [[ $HAS_BUNDLED -eq 1 ]] && VALID_OPTS="${VALID_OPTS}I/"
    VALID_OPTS="${VALID_OPTS}N"

    if [[ -n "$CONFIG_CHOICE_OVERRIDE" ]]; then
        CONFIG_CHOICE="$CONFIG_CHOICE_OVERRIDE"
        echo "  Using requested choice: $CONFIG_CHOICE"
    else
        read -r -p "  Choose [$VALID_OPTS]: " CONFIG_CHOICE
    fi
    CONFIG_CHOICE=$(echo "$CONFIG_CHOICE" | tr '[:lower:]' '[:upper:]')

    case "$CONFIG_CHOICE" in
        E)
            if [[ $HAS_EXISTING -eq 1 ]]; then
                echo "  Keeping existing configuration."
                SKIP_CONFIG=1
            else
                echo "  No existing config found." >&2
                exit 1
            fi
            ;;
        I)
            if [[ $HAS_BUNDLED -eq 1 ]]; then
                echo "  Using installer config.json."
                MONITORS=$(jq -c '.monitors' "$BUNDLED_CONFIG" 2>/dev/null || echo "[]")
                CEC_ENABLED=$(jq -r '.cec_enabled // false' "$BUNDLED_CONFIG" 2>/dev/null || echo "false")
                DISPLAY_CONTROL_JSON=$(jq -c '.display_control // null' "$BUNDLED_CONFIG" 2>/dev/null || echo "null")
                # Ensure www-data has video group for CEC
                if [[ "$CEC_ENABLED" == "true" ]]; then
                    usermod -aG video www-data 2>/dev/null || true
                fi
            else
                echo "  No bundled config.json found." >&2
                exit 1
            fi
            ;;
        N)
            # Fall through to the prompting logic below
            ;;
        *)
            echo "  Invalid choice." >&2
            exit 1
            ;;
    esac
fi

if [[ $SKIP_CONFIG -eq 0 && ("${CONFIG_CHOICE:-N}" == "N" || $UPDATE -eq 0) ]]; then
    # ── Prompt-based config (new install or N choice) ────────────────
    if [[ -f "$BUNDLED_CONFIG" ]]; then
        echo "  Found bundled config.json — using it as template."
        DISPLAY_CONTROL_JSON=$(jq -c '.display_control // null' "$BUNDLED_CONFIG" 2>/dev/null || echo "null")

        # Iterate over each monitor in the bundled config
        while IFS= read -r entry; do
            NAME=$(echo "$entry" | jq -r '.name')
            TYPE=$(echo "$entry" | jq -r '.type')
            MATCH=$(echo "$entry" | jq -r '.match // empty')

            # Build description for the prompt
            DESC="$NAME ($TYPE)"
            [[ -n "$MATCH" ]] && DESC="$NAME ($TYPE, match: $MATCH)"

            if ask_yn "Monitor ${DESC}?" "y"; then
                MONITORS=$(echo "$MONITORS" | jq --argjson e "$entry" '. + [$e]')
            fi
        done < <(jq -c '.monitors[]' "$BUNDLED_CONFIG" 2>/dev/null || true)

        # CEC — use bundled default
        BUNDLED_CEC=$(jq -r '.cec_enabled // false' "$BUNDLED_CONFIG" 2>/dev/null || echo "false")
        if [[ "$BUNDLED_CEC" == "true" ]]; then
            CEC_DEFAULT="y"
        else
            CEC_DEFAULT="n"
        fi
        if ask_yn "Enable CEC TV status check (on-demand only)?" "$CEC_DEFAULT"; then
            CEC_ENABLED="true"
            usermod -aG video www-data 2>/dev/null || true
        fi
    else
        echo "  No bundled config.json — auto-detecting services."

        # Systemd services to check for
        declare -A SERVICE_MAP=(
            ["apache2"]="Apache web server"
            ["church-calendar"]="Church calendar display"
            ["videokiosk2"]="Video kiosk v2"
        )

        for svc in apache2 church-calendar videokiosk2; do
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
            ["browser"]="Web browser (Falkon, Midori, or system browser)"
        )

        for proc in vlc browser; do
            DESC="${PROC_MAP[$proc]}"
            if [[ "$proc" == "browser" ]]; then
                command -v falkon &>/dev/null || command -v midori &>/dev/null || command -v x-www-browser &>/dev/null || continue
            elif ! command -v "$proc" &>/dev/null; then
                continue
            fi
            {
                if ask_yn "Monitor ${proc} process (${DESC})?" "y"; then
                    DEFAULT_MATCH=""
                    [[ "$proc" == "browser" ]] && DEFAULT_MATCH="falkon|midori|x-www-browser"
                    read -r -p "  Match regex in ps -ef${DEFAULT_MATCH:+ [$DEFAULT_MATCH]} (leave empty for exact name match): " PROC_MATCH
                    PROC_MATCH="${PROC_MATCH:-$DEFAULT_MATCH}"
                    if [[ -n "$PROC_MATCH" ]]; then
                        MONITORS=$(echo "$MONITORS" | jq --arg n "$proc" --arg m "$PROC_MATCH" \
                            '. + [{"name":$n,"type":"process","match":$m}]')
                    else
                        MONITORS=$(echo "$MONITORS" | jq --arg n "$proc" '. + [{"name":$n,"type":"process"}]')
                    fi
                fi
            }
        done

        # CEC
        if command -v cec-client &>/dev/null; then
            if ask_yn "Enable CEC TV status check (on-demand only)?" "y"; then
                CEC_ENABLED="true"
                usermod -aG video www-data 2>/dev/null || true
            fi
        fi
    fi
fi

# Calendar image management (optional) — lets the dashboard view/upload/
# delete church-calendar's flyer images on this host.
CALENDAR_IMAGES_PATH=""
discover_calendar_directory() {
    local calendar_dir
    calendar_dir=$(systemctl show church-calendar.service -p WorkingDirectory --value 2>/dev/null || true)
    if [[ -n "$calendar_dir" && "$calendar_dir" != "/" && -d "$calendar_dir" ]]; then
        printf '%s\n' "$calendar_dir"
    fi
}

if [[ $SKIP_CONFIG -eq 0 ]]; then
    CALENDAR_DIR=$(discover_calendar_directory || true)
    DEFAULT_CAL_IMAGES_PATH="${CALENDAR_DIR:+$CALENDAR_DIR/images}"
    DEFAULT_CAL_IMAGES_PATH="${DEFAULT_CAL_IMAGES_PATH:-/opt/church-calendar/images}"
    if [[ -f "$CONF_DIR/client-config.json" ]]; then
        EXISTING_CAL_PATH=$(jq -r '.calendar_images_path // empty' "$CONF_DIR/client-config.json" 2>/dev/null || echo "")
        [[ -n "$EXISTING_CAL_PATH" ]] && DEFAULT_CAL_IMAGES_PATH="$EXISTING_CAL_PATH"
    fi
    if ask_yn "Enable calendar image management (view/upload/delete flyer images from the dashboard)?" "n"; then
        read -r -p "  Path to church-calendar's images folder [default: $DEFAULT_CAL_IMAGES_PATH]: " CAL_IMAGES_INPUT
        CALENDAR_IMAGES_PATH="${CAL_IMAGES_INPUT:-$DEFAULT_CAL_IMAGES_PATH}"
    fi
fi

# Write client config
if [[ $SKIP_CONFIG -eq 0 ]]; then
    # Seed the `apps` array and default backup settings from the bundled example
    # so DR backup/restore knows what is installed on this host. The operator can
    # tune these afterwards in client-config.json.
    SEED_APPS="[]"
    SEED_BACKUP='{"dir":"/var/backups/church-monitoring","keep":5,"warn_days":7,"error_days":14}'
    if [[ -f "$SCRIPT_DIR/config.example.json" ]]; then
        SEED_APPS=$(jq -c '.apps // []' "$SCRIPT_DIR/config.example.json" 2>/dev/null || echo "[]")
        SEED_BACKUP=$(jq -c ".backup // $SEED_BACKUP" "$SCRIPT_DIR/config.example.json" 2>/dev/null || echo "$SEED_BACKUP")
    fi
    if [[ -n "${CALENDAR_DIR:-}" ]]; then
        SEED_APPS=$(echo "$SEED_APPS" | jq --arg config_path "$CALENDAR_DIR/config.json" \
            'map(if .name == "church-calendar" then .config_paths = [$config_path] else . end)')
    fi

    jq -n \
        --arg hostname "$CLIENT_HOSTNAME" \
        --argjson monitors "$MONITORS" \
        --argjson cec "$CEC_ENABLED" \
        --argjson display_control "$DISPLAY_CONTROL_JSON" \
        --argjson backup "$SEED_BACKUP" \
        --argjson apps "$SEED_APPS" \
        --arg calendar_images_path "$CALENDAR_IMAGES_PATH" \
        '{hostname:$hostname, monitors:$monitors, cec_enabled:$cec, backup:$backup, apps:$apps}
         + (if $display_control == null then {} else {display_control:$display_control} end)
         + (if $calendar_images_path == "" then {} else {calendar_images_path: $calendar_images_path} end)' \
        > "$CONF_DIR/client-config.json"
    chmod 644 "$CONF_DIR/client-config.json"
    echo "  Configuration saved."
elif [[ -f "$CONF_DIR/client-config.json" ]]; then
    # Keeping existing config: merge in backup/apps defaults if they are absent
    # so that DR backup/restore works immediately after an update.
    DEFAULT_BACKUP='{"dir":"/var/backups/church-monitoring","keep":5,"warn_days":7,"error_days":14}'
    DEFAULT_APPS="[]"
    if [[ -f "$SCRIPT_DIR/config.example.json" ]]; then
        DEFAULT_APPS=$(jq -c '.apps // []' "$SCRIPT_DIR/config.example.json" 2>/dev/null || echo "[]")
        DEFAULT_BACKUP=$(jq -c ".backup // $DEFAULT_BACKUP" "$SCRIPT_DIR/config.example.json" 2>/dev/null || echo "$DEFAULT_BACKUP")
    fi
    UPDATED=$(jq \
        --argjson dflt_backup "$DEFAULT_BACKUP" \
        --argjson dflt_apps "$DEFAULT_APPS" \
        'if .backup == null then . + {"backup": $dflt_backup} else . end
         | if .apps == null then . + {"apps": $dflt_apps} else . end
         | .monitors |= map(
             if .name == "midori" and .type == "process" then
                 .name = "browser" | .match = "falkon|midori|x-www-browser"
             else
                 .
             end
           )' \
        "$CONF_DIR/client-config.json" 2>/dev/null || cat "$CONF_DIR/client-config.json")
    echo "$UPDATED" > "$CONF_DIR/client-config.json"
    echo "  Existing configuration kept; backup/apps defaults and browser monitor migration applied where needed."
fi

# ── Step 4: Install CGI scripts ──────────────────────────────────────
echo ""
echo "Step 4/6: Installing CGI scripts..."

mkdir -p "$CGI_DIR"

REQUIRED_CGI=(
    status.cgi
    cec-check.cgi
    cec-control.cgi
    screenshot.cgi
    restart-service.cgi
    reboot.cgi
    mode-switch.cgi
    calendar-settings.cgi
    browser-scale.cgi
    display-control.cgi
    standby-timer.cgi
    list-calendar-images.cgi
    list-archived-calendar-images.cgi
    list-evergreen-images.cgi
    fetch-calendar-image.cgi
    upload-calendar-image.cgi
    archive-calendar-image.cgi
    restore-calendar-image.cgi
    store-evergreen-image.cgi
    activate-evergreen-image.cgi
    backup.cgi
    backup-download.cgi
)

for CGI_FILE in "${REQUIRED_CGI[@]}"; do
    if [[ ! -f "$SCRIPT_DIR/$CGI_FILE" ]]; then
        echo "Error: missing installer source file $SCRIPT_DIR/$CGI_FILE" >&2
        exit 1
    fi

    cp "$SCRIPT_DIR/$CGI_FILE" "$CGI_DIR/$CGI_FILE"
    # Normalize line endings to avoid '/usr/bin/env: bash\r' on Raspberry Pi.
    sed -i 's/\r$//' "$CGI_DIR/$CGI_FILE"
done

chmod 755 "$CGI_DIR"/*.cgi
chown -R www-data:www-data "$CGI_DIR"

for CGI_FILE in "${REQUIRED_CGI[@]}"; do
    if [[ ! -x "$CGI_DIR/$CGI_FILE" ]]; then
        echo "Error: failed to install executable CGI: $CGI_DIR/$CGI_FILE" >&2
        exit 1
    fi
done

# Remove retired action CGI endpoints.
rm -f "$CGI_DIR/restart-network.cgi" "$CGI_DIR/restart-display.cgi"
rm -f "$CGI_DIR/delete-calendar-image.cgi"

# Remove legacy shared CGI directory after migration.
if [[ -d "$LEGACY_CGI_DIR" && "$LEGACY_CGI_DIR" != "$CGI_DIR" ]]; then
    rm -rf "$LEGACY_CGI_DIR"
fi

# Install helper scripts
cp "$SCRIPT_DIR/church-screenshot.sh" /usr/local/bin/church-screenshot.sh
chmod 755 /usr/local/bin/church-screenshot.sh

# Allow www-data to run screenshot helper as the display user
echo "www-data ALL=(ALL) NOPASSWD: /usr/local/bin/church-screenshot.sh" \
    > /etc/sudoers.d/church-monitoring-screenshot
chmod 440 /etc/sudoers.d/church-monitoring-screenshot

# Install calendar settings helper.
cp "$SCRIPT_DIR/church-monitoring-set-calendar-settings" /usr/local/bin/church-monitoring-set-calendar-settings
sed -i 's/\r$//' /usr/local/bin/church-monitoring-set-calendar-settings
chmod 755 /usr/local/bin/church-monitoring-set-calendar-settings

# Allow www-data to run the calendar settings helper as the display user
echo "www-data ALL=(ALL) NOPASSWD: /usr/local/bin/church-monitoring-set-calendar-settings" \
    > /etc/sudoers.d/church-monitoring-calendar-settings
chmod 440 /etc/sudoers.d/church-monitoring-calendar-settings

# Install Falkon browser-scale helper.
cp "$SCRIPT_DIR/church-monitoring-set-browser-scale" /usr/local/bin/church-monitoring-set-browser-scale
sed -i 's/\r$//' /usr/local/bin/church-monitoring-set-browser-scale
chmod 755 /usr/local/bin/church-monitoring-set-browser-scale

echo "www-data ALL=(ALL) NOPASSWD: /usr/local/bin/church-monitoring-set-browser-scale" \
    > /etc/sudoers.d/church-monitoring-browser-scale
chmod 440 /etc/sudoers.d/church-monitoring-browser-scale

# Install the configured display-control helper.
cp "$SCRIPT_DIR/church-monitoring-display-control" /usr/local/bin/church-monitoring-display-control
sed -i 's/\r$//' /usr/local/bin/church-monitoring-display-control
chmod 755 /usr/local/bin/church-monitoring-display-control

echo "www-data ALL=(ALL) NOPASSWD: /usr/local/bin/church-monitoring-display-control on, /usr/local/bin/church-monitoring-display-control off" \
    > /etc/sudoers.d/church-monitoring-display-control
chmod 440 /etc/sudoers.d/church-monitoring-display-control

# Install the standby countdown adjustment helper.
cp "$SCRIPT_DIR/church-monitoring-standby-timer" /usr/local/bin/church-monitoring-standby-timer
sed -i 's/\r$//' /usr/local/bin/church-monitoring-standby-timer
chmod 755 /usr/local/bin/church-monitoring-standby-timer

echo "www-data ALL=(ALL) NOPASSWD: /usr/local/bin/church-monitoring-standby-timer plus, /usr/local/bin/church-monitoring-standby-timer minus, /usr/local/bin/church-monitoring-standby-timer reset" \
    > /etc/sudoers.d/church-monitoring-standby-timer
chmod 440 /etc/sudoers.d/church-monitoring-standby-timer

install_display_hooks() {
    local strategy kiosk_user kiosk_home hook action

    strategy=$(jq -r '.display_control.strategy // empty' "$CONF_DIR/client-config.json" 2>/dev/null || echo "")
    [[ "$strategy" == "hdmi_signal" ]] || return

    kiosk_user=$(systemctl show videokiosk2.service -p User --value 2>/dev/null || echo "")
    kiosk_home=$(getent passwd "$kiosk_user" | cut -d: -f6)
    if [[ -z "$kiosk_home" || ! -d "$kiosk_home" ]]; then
        echo "  HDMI display hooks skipped: kiosk user could not be determined."
        return
    fi

    for action in on off; do
        if [[ "$action" == "on" ]]; then
            hook="$kiosk_home/tvOn.sh"
        else
            hook="$kiosk_home/tvStandby.sh"
        fi
        if [[ -e "$hook" ]]; then
            echo "  Keeping existing display hook: $hook"
            continue
        fi
        cat > "$hook" <<EOF
#!/usr/bin/env bash
exec /usr/local/bin/church-monitoring-display-control $action
EOF
        chown "$kiosk_user:$kiosk_user" "$hook"
        chmod 755 "$hook"
        echo "  Installed HDMI display hook: $hook"
    done
}

install_display_hooks

# Install calendar image management helpers (write/archive/restore/store/
# activate as the church-calendar owner, then regenerate optimized/
# thumbnail derivatives)
for HELPER in church-monitoring-write-calendar-image church-monitoring-archive-calendar-image church-monitoring-restore-calendar-image church-monitoring-store-evergreen-image church-monitoring-activate-evergreen-image; do
    cp "$SCRIPT_DIR/$HELPER" "/usr/local/bin/$HELPER"
    sed -i 's/\r$//' "/usr/local/bin/$HELPER"
    chmod 755 "/usr/local/bin/$HELPER"
done

# Retire the old delete-based helper name (superseded by the archive helper).
rm -f /usr/local/bin/church-monitoring-delete-calendar-image

# Allow www-data to run the calendar image helpers as the display user
cat > /etc/sudoers.d/church-monitoring-calendar-images <<'SUDOEOF'
www-data ALL=(ALL) NOPASSWD: /usr/local/bin/church-monitoring-write-calendar-image
www-data ALL=(ALL) NOPASSWD: /usr/local/bin/church-monitoring-archive-calendar-image
www-data ALL=(ALL) NOPASSWD: /usr/local/bin/church-monitoring-restore-calendar-image
www-data ALL=(ALL) NOPASSWD: /usr/local/bin/church-monitoring-store-evergreen-image
www-data ALL=(ALL) NOPASSWD: /usr/local/bin/church-monitoring-activate-evergreen-image
SUDOEOF
chmod 440 /etc/sudoers.d/church-monitoring-calendar-images

# Allow www-data to restart systemd services
echo "www-data ALL=(root) NOPASSWD: /bin/systemctl restart *" \
    > /etc/sudoers.d/church-monitoring-restart
chmod 440 /etc/sudoers.d/church-monitoring-restart

# Install collect script
cp "$SCRIPT_DIR/collect.sh" /usr/local/bin/church-monitoring-collect
chmod 755 /usr/local/bin/church-monitoring-collect

# Install the ntfy alert helper collect.sh uses for health-check and error alerts
cp "$SCRIPT_DIR/ntfy-notify.sh" /usr/local/bin/ntfy-notify.sh
chmod 755 /usr/local/bin/ntfy-notify.sh
echo "    (set the alert topic with: echo YOUR_TOPIC | sudo tee /etc/church-monitoring/ntfy-topic)"

install -d -o root -g root -m 755 /usr/local/share/church-monitoring
install -o root -g root -m 644 "$RELEASE_ROOT/VERSION" /usr/local/share/church-monitoring/VERSION
write_version_manifest

# Install DR backup + restore scripts
cp "$SCRIPT_DIR/backup.sh" /usr/local/bin/church-monitoring-backup
sed -i 's/\r$//' /usr/local/bin/church-monitoring-backup
chmod 755 /usr/local/bin/church-monitoring-backup
if [ -f "$SCRIPT_DIR/restore.sh" ]; then
    cp "$SCRIPT_DIR/restore.sh" /usr/local/bin/church-monitoring-restore
    sed -i 's/\r$//' /usr/local/bin/church-monitoring-restore
    chmod 755 /usr/local/bin/church-monitoring-restore
fi

# Backup archive directory (root-only)
mkdir -p /var/backups/church-monitoring
chmod 700 /var/backups/church-monitoring

# Allow www-data to trigger a backup as root (restrict arguments)
cat > /etc/sudoers.d/church-monitoring-backup <<'SUDOEOF'
www-data ALL=(root) NOPASSWD: /usr/local/bin/church-monitoring-backup
www-data ALL=(root) NOPASSWD: /usr/local/bin/church-monitoring-backup --latest-path
www-data ALL=(root) NOPASSWD: /usr/local/bin/church-monitoring-backup --emit-latest
SUDOEOF
chmod 440 /etc/sudoers.d/church-monitoring-backup

# Install host-control helper scripts
for HELPER in church-monitoring-reboot-host church-monitoring-mode-browser; do
    if [ -f "$SCRIPT_DIR/$HELPER" ]; then
        cp "$SCRIPT_DIR/$HELPER" "/usr/local/bin/$HELPER"
        sed -i 's/\r$//' "/usr/local/bin/$HELPER"
        chmod 755 "/usr/local/bin/$HELPER"
    fi
done

# Remove retired helper scripts.
rm -f /usr/local/bin/church-monitoring-restart-network /usr/local/bin/church-monitoring-restart-display /usr/local/bin/church-monitoring-mode-midori

# Allow www-data to run host-control helpers as root
cat > /etc/sudoers.d/church-monitoring-actions <<'SUDOEOF'
www-data ALL=(root) NOPASSWD: /usr/local/bin/church-monitoring-reboot-host
www-data ALL=(root) NOPASSWD: /usr/local/bin/church-monitoring-mode-browser
SUDOEOF
chmod 440 /etc/sudoers.d/church-monitoring-actions

echo "  CGI scripts and collector installed."

if [[ $UPDATE -eq 1 ]]; then
    # Rewrite Apache vhost so ScriptAlias matches current CGI_DIR.
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

    a2enmod cgi >/dev/null 2>&1 || true
    a2enmod ssl >/dev/null 2>&1 || true
    a2ensite church-monitoring-client.conf >/dev/null 2>&1 || true

    # cgid uses a separate daemon under threaded MPMs. A graceful reload can
    # leave it unavailable after enabling or updating the CGI vhost.
    systemctl restart apache2
    configure_apparmor_if_requested

    ACTIVE_SCRIPTALIAS=$(grep -E "^[[:space:]]*ScriptAlias /cgi-bin/" "$VHOST" 2>/dev/null | awk '{print $3}' | head -1)
    if [[ "$ACTIVE_SCRIPTALIAS" != "${CGI_DIR}/" ]]; then
        echo "Warning: expected ScriptAlias ${CGI_DIR}/ but found ${ACTIVE_SCRIPTALIAS:-<none>}"
    fi

    echo ""
    echo "=============================================="
    echo "  Client update complete!"
    echo "=============================================="
    echo ""
    echo "Certificates and enrollment unchanged."
    echo "Updated: config, CGI scripts, collector, Apache vhost."
    echo "Active ScriptAlias: ${ACTIVE_SCRIPTALIAS:-<none>}"
    echo ""

    # Read final config for summary
    FINAL_CEC=$(jq -r '.cec_enabled // false' "$CONF_DIR/client-config.json" 2>/dev/null || echo "false")
    FINAL_MONITORS=$(jq -c '.monitors' "$CONF_DIR/client-config.json" 2>/dev/null || echo "[]")

    echo "Monitored services:"
    echo "$FINAL_MONITORS" | jq -r '.[] | "  - " + .name + " (" + .type + ")"'
    echo ""
    if [[ "$FINAL_CEC" == "true" ]]; then
        echo "CEC: enabled (on-demand check + control)"
    else
        echo "CEC: disabled"
    fi
    exit 0
fi

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

# Start the cgid daemon with the newly enabled module and vhost.
systemctl restart apache2
configure_apparmor_if_requested

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
echo ""
echo "Monitored services:"
echo "$MONITORS" | jq -r '.[] | "  - " + .name + " (" + .type + ")"'
echo ""
if [[ "$CEC_ENABLED" == "true" ]]; then
    echo "CEC: enabled (on-demand check + control)"
else
    echo "CEC: disabled"
fi
echo ""
echo "Next: Verify on the dashboard that this client appears."
