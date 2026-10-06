#!/usr/bin/env bash
# collect.sh — Collects system metrics and service status, writes cache JSON.
# Run by cron every 5 minutes on each monitored host.

set -euo pipefail

CONFIG="/etc/church-monitoring/client-config.json"
CACHE="/var/cache/church-monitoring/status.json"
CACHE_DIR="/var/cache/church-monitoring"
LOCK="$CACHE_DIR/.collect.lock"
SLOW_CACHE_DIR="$CACHE_DIR/slow-metrics"

DEFAULT_SLOW_TTL=43200
COLLECTOR_VERSION_PATH="/usr/local/share/church-monitoring/VERSION"

NTFY_BIN="$(dirname "${BASH_SOURCE[0]}")/ntfy-notify.sh"
notify() {
    [[ -x "$NTFY_BIN" ]] && "$NTFY_BIN" -t "church-monitoring ($(hostname))" "$@" &
    return 0
}
trap 'notify -p high -k "collect-failed:$(hostname)" "collect.sh failed on $(hostname) (line $LINENO)"' ERR

get_display_control_info() {
    local strategy

    strategy=$(jq -r '.display_control.strategy // empty' "$CONFIG" 2>/dev/null || echo "")
    case "$strategy" in
        hdmi_signal)
            jq -n '{strategy:"hdmi_signal", label:"Display (HDMI signal)", on_label:"Send signal", off_label:"Stop signal"}'
            ;;
        bluetooth_hid)
            jq -n '{strategy:"bluetooth_hid", label:"TV + HDMI", on_label:"Power + signal on", off_label:"Standby + signal off"}'
            ;;
        *)
            echo "null"
            ;;
    esac
}

get_bluetooth_hid_info() {
    local strategy service_state exec_start hid_script response status remote_address

    strategy=$(jq -r '.display_control.strategy // empty' "$CONFIG" 2>/dev/null || echo "")
    [[ "$strategy" == "bluetooth_hid" ]] || { echo "null"; return; }

    service_state=$(systemctl is-active videokiosk2-firetv-hid.service 2>/dev/null || echo "inactive")
    status="unavailable"
    remote_address=""
    if [[ "$service_state" == "active" ]]; then
        exec_start=$(systemctl show videokiosk2-firetv-hid.service -p ExecStart --value 2>/dev/null || echo "")
        hid_script=$(sed -n 's/.*path=\([^ ;]*firetv-hid\.py\).*/\1/p' <<<"$exec_start" | head -1)
        [[ -x "$hid_script" ]] || hid_script="/opt/videokiosk2/firetv-hid.py"
        response=$(timeout 3 "$hid_script" send status 2>/dev/null || echo "error")
        case "$response" in
            connected\ *)
                status="connected"
                remote_address="${response#connected }"
                ;;
            waiting) status="waiting" ;;
            *) status="error" ;;
        esac
    elif [[ "$service_state" == "inactive" || "$service_state" == "failed" ]]; then
        status="$service_state"
    fi

    jq -n \
        --arg status "$status" \
        --arg service "$service_state" \
        --arg remote_address "$remote_address" \
        '{status:$status, service:$service} + (if $remote_address == "" then {} else {remote_address:$remote_address} end)'
}

get_standby_timer_info() {
    local file="${STANDBY_STATE_FILE:-/run/videokiosk2/standby.json}" now
    [ -r "$file" ] || { echo "null"; return 0; }
    now=$(date +%s)
    # A counting state that has not been refreshed for 2 minutes means the wrapper stopped.
    jq -c --argjson now "$now" '
        . as $s
        | (if $s.state == "counting" and ($now - ($s.updated // 0)) > 120 then "stale" else $s.state end) as $state
        | {state: $state,
           base_minutes: $s.base_minutes,
           adjust_minutes: ($s.adjust_minutes // 0),
           failover_started: $s.failover_started,
           deadline: (if $state == "counting" then $s.deadline else null end),
           remaining_seconds: (if $state == "counting" and $s.deadline != null then ([$s.deadline - $now, 0] | max) else null end),
           min_remaining_seconds: 300,
           collected_epoch: $now}' "$file" 2>/dev/null || echo "null"
}

get_display_signal_info() {
    local output kiosk_user kiosk_home runuser_path xauthority xrandr_output connector_line
    local connection mode signal

    output=$(jq -r '.display_control.output // empty' "$CONFIG" 2>/dev/null || echo "")
    [[ "$output" =~ ^[A-Za-z0-9._-]+$ ]] || return 1

    kiosk_user=$(systemctl show videokiosk2.service -p User --value 2>/dev/null || echo "")
    [[ "$kiosk_user" =~ ^[a-z_][a-z0-9_-]*$ ]] || return 1
    kiosk_home=$(getent passwd "$kiosk_user" | cut -d: -f6)
    [[ -n "$kiosk_home" ]] || return 1
    runuser_path="/usr/sbin/runuser"
    if [[ ! -x "$runuser_path" ]]; then
        runuser_path=$(command -v runuser 2>/dev/null || echo "")
    fi
    [[ -x "$runuser_path" ]] || return 1
    xauthority="$kiosk_home/.Xauthority"

    xrandr_output=$("$runuser_path" -u "$kiosk_user" -- env DISPLAY=:0 XAUTHORITY="$xauthority" xrandr --query 2>/dev/null || echo "")
    [[ -n "$xrandr_output" ]] || return 1
    connector_line=$(printf '%s\n' "$xrandr_output" | awk -v output="$output" '$1 == output && ($2 == "connected" || $2 == "disconnected") { print; exit }')
    [[ -n "$connector_line" ]] || return 1

    connection=$(awk '{ print $2 }' <<<"$connector_line")
    mode=$(sed -nE 's/^[^[:space:]]+[[:space:]]+connected[[:space:]]+([0-9]+x[0-9]+[^[:space:]]*).*/\1/p' <<<"$connector_line")
    if [[ "$connection" == "connected" && -n "$mode" ]]; then
        signal="active"
    elif [[ "$connection" == "connected" ]]; then
        signal="off"
    else
        signal="disconnected"
    fi

    jq -n --arg output "$output" --arg connection "$connection" --arg signal "$signal" --arg mode "$mode" \
        '{output:$output, connection:$connection, signal:$signal} + (if $mode == "" then {} else {mode:$mode} end)'
}

get_display_signal_unavailable() {
    local output

    output=$(jq -r '.display_control.output // empty' "$CONFIG" 2>/dev/null || echo "")
    [[ "$output" =~ ^[A-Za-z0-9._-]+$ ]] || return 1

    jq -n --arg output "$output" \
        '{output:$output, connection:"unknown", signal:"unavailable"}'
}

get_software_versions() {
    local monitoring_versions='{}'
    local kiosk_version='null'
    local collector_version=''

    if [[ -r /etc/church-monitoring/installed-version.json ]]; then
        monitoring_versions=$(jq -c '.roles // {}' /etc/church-monitoring/installed-version.json 2>/dev/null || echo '{}')
    fi
    if [[ -r /etc/videokiosk2/installed-version.json ]]; then
        kiosk_version=$(jq -c '.' /etc/videokiosk2/installed-version.json 2>/dev/null || echo 'null')
    fi
    if [[ -r "$COLLECTOR_VERSION_PATH" ]]; then
        collector_version=$(tr -d '\r\n' < "$COLLECTOR_VERSION_PATH")
    fi
    if [[ -n "$collector_version" ]]; then
        monitoring_versions=$(jq -c \
            --arg version "$collector_version" \
            'if .client == null then . + {client:{version:$version, tag:("v" + $version), commit:"unknown", installed_at:"unknown"}} else . end' \
            <<<"$monitoring_versions")
    fi

    jq -n --argjson monitoring "$monitoring_versions" --argjson kiosk "$kiosk_version" \
        '{church_monitoring: $monitoring} + (if $kiosk == null then {} else {videokiosk2: $kiosk} end)'
}

append_version() {
    local versions="$1"
    local label="$2"
    local value="$3"
    local detail="$4"

    jq -c \
        --arg lbl "$label" \
        --arg value "$value" \
        --arg detail "$detail" \
        '. + [{label:$lbl, value:$value, detail:$detail}]' <<<"$versions"
}

get_package_version() {
    dpkg-query -W -f='${Version}' "$1" 2>/dev/null || true
}

get_service_versions() {
    local name="$1"
    local type="$2"
    local software_versions="$3"
    local browser_info="$4"
    local versions='[]'
    local package_name package_version role installed release detail
    local manifest_name manifest_path working_directory git_revision git_commit

    case "$name" in
        apache2|apache2.service)
            package_version=$(get_package_version apache2)
            [[ -n "$package_version" ]] && versions=$(append_version "$versions" "Apache" "$package_version" "Debian package: apache2")
            while IFS= read -r role; do
                installed=$(jq -c --arg role "$role" '.church_monitoring[$role]' <<<"$software_versions")
                release=$(jq -r '.tag // (if .version then "v" + .version else "unknown" end)' <<<"$installed")
                detail="Church Monitoring $role; commit $(jq -r '.commit // "unknown"' <<<"$installed"); installed $(jq -r '.installed_at // "unknown"' <<<"$installed")"
                versions=$(append_version "$versions" "CM $role" "$release" "$detail")
            done < <(jq -r '.church_monitoring // {} | keys[]' <<<"$software_versions")
            ;;
        videokiosk2|videokiosk2.service|videokiosk2-scheduler|videokiosk2-scheduler.service|videokiosk2-firetv-hid|videokiosk2-firetv-hid.service)
            installed=$(jq -c '.videokiosk2 // null' <<<"$software_versions")
            if [[ "$installed" != "null" ]]; then
                release=$(jq -r '.tag // (if .version then "v" + .version else "unknown" end)' <<<"$installed")
                detail="videokiosk2; commit $(jq -r '.commit // "unknown"' <<<"$installed"); installed $(jq -r '.installed_at // "unknown"' <<<"$installed")"
                versions=$(append_version "$versions" "Kiosk" "$release" "$detail")
            fi
            ;;
        vlc)
            package_version=$(get_package_version vlc)
            [[ -n "$package_version" ]] && versions=$(append_version "$versions" "VLC" "$package_version" "Debian package: vlc")
            ;;
        browser|midori|falkon)
            package_name=$(jq -r '.type // empty' <<<"$browser_info")
            [[ "$name" == "midori" || "$name" == "falkon" ]] && package_name="$name"
            if [[ "$package_name" == "midori" || "$package_name" == "falkon" ]]; then
                package_version=$(get_package_version "$package_name")
                [[ -n "$package_version" ]] && versions=$(append_version "$versions" "${package_name^}" "$package_version" "Debian package: $package_name")
            fi
            ;;
    esac

    if [[ $(jq 'length' <<<"$versions") -eq 0 && "$type" == "systemd" ]]; then
        manifest_name="${name%.service}"
        manifest_path="/etc/$manifest_name/installed-version.json"
        if [[ -r "$manifest_path" ]]; then
            installed=$(jq -c '.' "$manifest_path" 2>/dev/null || echo 'null')
            if [[ "$installed" != "null" ]]; then
                release=$(jq -r '.tag // (if .version then "v" + .version else "unknown" end)' <<<"$installed")
                detail="$manifest_name; commit $(jq -r '.commit // "unknown"' <<<"$installed"); installed $(jq -r '.installed_at // "unknown"' <<<"$installed")"
                versions=$(append_version "$versions" "App" "$release" "$detail")
            fi
        fi
    fi

    if [[ $(jq 'length' <<<"$versions") -eq 0 && "$type" == "systemd" ]]; then
        working_directory=$(systemctl show "$name" -p WorkingDirectory --value 2>/dev/null || true)
        if [[ -n "$working_directory" && -d "$working_directory/.git" ]]; then
            git_revision=$(git -c safe.directory="$working_directory" -C "$working_directory" describe --tags --always 2>/dev/null || true)
            git_commit=$(git -c safe.directory="$working_directory" -C "$working_directory" rev-parse HEAD 2>/dev/null || true)
            if [[ -n "$git_revision" ]]; then
                versions=$(append_version "$versions" "Git" "$git_revision" "Working directory: $working_directory; commit ${git_commit:-unknown}")
            fi
        fi
    fi

    if [[ $(jq 'length' <<<"$versions") -eq 0 && ( "$type" == "systemd" || "$type" == "process" ) ]]; then
        package_name="${name%.service}"
        package_version=$(get_package_version "$package_name")
        if [[ -n "$package_version" ]]; then
            versions=$(append_version "$versions" "$package_name" "$package_version" "Debian package: $package_name")
        else
            versions=$(append_version "$versions" "Version" "unknown" "No package or application release manifest was found")
        fi
    fi

    printf '%s\n' "$versions"
}

get_config_ttl() {
    local key="$1"
    local default_ttl="$2"
    local ttl

    ttl=$(jq -r --arg key "$key" '.slow_metric_ttl_seconds[$key] // empty' "$CONFIG" 2>/dev/null || echo "")
    if [[ "$ttl" =~ ^[0-9]+$ ]] && [ "$ttl" -gt 0 ]; then
        echo "$ttl"
    else
        echo "$default_ttl"
    fi
}

load_slow_metric() {
    local metric_name="$1"
    local ttl_seconds="$2"
    local refresh_fn="$3"
    local metric_file="$SLOW_CACHE_DIR/${metric_name}.json"
    local now_epoch
    local modified_epoch
    local age_seconds
    local refreshed_json

    now_epoch=$(date +%s)

    if [ -f "$metric_file" ]; then
        modified_epoch=$(stat -c %Y "$metric_file" 2>/dev/null || echo "0")
        age_seconds=$((now_epoch - modified_epoch))
        if [ "$age_seconds" -lt "$ttl_seconds" ]; then
            cat "$metric_file"
            return 0
        fi
    fi

    if refreshed_json=$("$refresh_fn"); then
        printf '%s\n' "$refreshed_json" > "${metric_file}.tmp"
        mv "${metric_file}.tmp" "$metric_file"
        cat "$metric_file"
        return 0
    fi

    if [ -f "$metric_file" ]; then
        cat "$metric_file"
        return 0
    fi

    return 1
}

refresh_tls_cert_metric() {
    local cert_path
    local checked_at
    local cert_days_json="null"
    local cert_expiry_utc=""
    local exp_raw
    local exp_epoch
    local now_epoch

    cert_path=$(jq -r '.cert_path // empty' "$CONFIG" 2>/dev/null || echo "")
    [ -z "$cert_path" ] && cert_path="/etc/church-monitoring/ssl/agent.crt"
    checked_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    if [ -f "$cert_path" ]; then
        exp_raw=$(openssl x509 -enddate -noout -in "$cert_path" 2>/dev/null | cut -d= -f2 || echo "")
        if [ -n "$exp_raw" ]; then
            cert_expiry_utc=$(date -u -d "$exp_raw" +"%Y-%m-%d %H:%M:%S UTC" 2>/dev/null || echo "")
            exp_epoch=$(date -d "$exp_raw" +%s 2>/dev/null || echo "")
            now_epoch=$(date +%s)
            if [[ "$exp_epoch" =~ ^[0-9]+$ ]]; then
                cert_days_json=$(( (exp_epoch - now_epoch) / 86400 ))
            fi
        fi
    fi

    jq -n \
        --arg checked_at "$checked_at" \
        --arg cert_expires_utc "$cert_expiry_utc" \
        --argjson cert_days "$cert_days_json" \
        '{
            checked_at: $checked_at,
            cert_days: $cert_days,
            cert_expires_utc: (if $cert_expires_utc == "" then null else $cert_expires_utc end)
        }'
}

refresh_tailscale_metric() {
    local checked_at
    local status="unavailable"
    local key_expiry_utc=""
    local key_days_json="null"
    local key_expired_json="null"
    local raw
    local key_expiry_raw
    local key_expired_raw
    local exp_epoch
    local now_epoch

    checked_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    if command -v tailscale &>/dev/null; then
        raw=$(tailscale status --json 2>/dev/null || echo "")
        if [ -n "$raw" ]; then
            status="ok"
            key_expiry_raw=$(echo "$raw" | jq -r '.Self.KeyExpiry // empty' 2>/dev/null || echo "")
            key_expired_raw=$(echo "$raw" | jq -r '.Self.Expired // empty' 2>/dev/null || echo "")

            if [ -n "$key_expiry_raw" ]; then
                key_expiry_utc=$(date -u -d "$key_expiry_raw" +"%Y-%m-%d %H:%M:%S UTC" 2>/dev/null || echo "")
                exp_epoch=$(date -d "$key_expiry_raw" +%s 2>/dev/null || echo "")
                now_epoch=$(date +%s)
                if [[ "$exp_epoch" =~ ^[0-9]+$ ]]; then
                    key_days_json=$(( (exp_epoch - now_epoch) / 86400 ))
                fi
            fi

            if [ "$key_expired_raw" = "true" ] || [ "$key_expired_raw" = "false" ]; then
                key_expired_json="$key_expired_raw"
            fi
        else
            status="error"
        fi
    fi

    jq -n \
        --arg checked_at "$checked_at" \
        --arg status "$status" \
        --arg key_expires_utc "$key_expiry_utc" \
        --argjson key_days "$key_days_json" \
        --argjson key_expired "$key_expired_json" \
        '{
            checked_at: $checked_at,
            tailscale_status: $status,
            tailscale_key_days: $key_days,
            tailscale_key_expires_utc: (if $key_expires_utc == "" then null else $key_expires_utc end),
            tailscale_key_expired: $key_expired
        }'
}

refresh_apt_metric() {
    local checked_at
    local apt_update_days="null"
    local apt_update_utc=""
    local apt_upgrade_days="null"
    local apt_upgrade_utc=""
    local mtime_epoch
    local now_epoch
    local upgrade_end

    checked_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    now_epoch=$(date +%s)

    # Last apt update: mtime of the package lists cache file
    local lists_cache="/var/cache/apt/pkgcache.bin"
    if [ -f "$lists_cache" ]; then
        mtime_epoch=$(stat -c %Y "$lists_cache" 2>/dev/null || echo "")
        if [[ "$mtime_epoch" =~ ^[0-9]+$ ]]; then
            apt_update_days=$(( (now_epoch - mtime_epoch) / 86400 ))
            apt_update_utc=$(date -u -d "@$mtime_epoch" +"%Y-%m-%d %H:%M:%S UTC" 2>/dev/null || echo "")
        fi
    fi

    # Last apt upgrade: End-Date following an Upgrade: line in history.log
    local history_log="/var/log/apt/history.log"
    if [ -f "$history_log" ]; then
        upgrade_end=$(awk '
            /^Upgrade:/ { found=1 }
            /^End-Date:/ && found { last=$0; found=0 }
            END { print last }
        ' "$history_log" 2>/dev/null || echo "")
        if [ -n "$upgrade_end" ]; then
            local raw_date upg_epoch
            raw_date=$(echo "$upgrade_end" | sed 's/^End-Date: //')
            upg_epoch=$(date -d "$raw_date" +%s 2>/dev/null || echo "")
            if [[ "$upg_epoch" =~ ^[0-9]+$ ]]; then
                apt_upgrade_days=$(( (now_epoch - upg_epoch) / 86400 ))
                apt_upgrade_utc=$(date -u -d "@$upg_epoch" +"%Y-%m-%d %H:%M:%S UTC" 2>/dev/null || echo "")
            fi
        fi
    fi

    jq -n \
        --arg checked_at "$checked_at" \
        --argjson apt_update_days "$apt_update_days" \
        --arg apt_update_utc "$apt_update_utc" \
        --argjson apt_upgrade_days "$apt_upgrade_days" \
        --arg apt_upgrade_utc "$apt_upgrade_utc" \
        '{
            checked_at: $checked_at,
            apt_update_days: $apt_update_days,
            apt_update_utc: (if $apt_update_utc == "" then null else $apt_update_utc end),
            apt_upgrade_days: $apt_upgrade_days,
            apt_upgrade_utc: (if $apt_upgrade_utc == "" then null else $apt_upgrade_utc end)
        }'
}

refresh_firmware_metric() {
    local checked_at
    local firmware_age_days="null"
    local firmware_date_utc=""
    local fw_raw fw_epoch now_epoch

    checked_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    now_epoch=$(date +%s)

    # Pi firmware version date from vcgencmd
    if command -v vcgencmd &>/dev/null; then
        fw_raw=$(vcgencmd version 2>/dev/null | head -1 || echo "")
        if [ -n "$fw_raw" ]; then
            fw_epoch=$(date -d "$fw_raw" +%s 2>/dev/null || echo "")
            if [[ "$fw_epoch" =~ ^[0-9]+$ ]]; then
                firmware_age_days=$(( (now_epoch - fw_epoch) / 86400 ))
                firmware_date_utc=$(date -u -d "@$fw_epoch" +"%Y-%m-%d %H:%M:%S UTC" 2>/dev/null || echo "")
            fi
        fi
    fi

    jq -n \
        --arg checked_at "$checked_at" \
        --argjson firmware_age_days "$firmware_age_days" \
        --arg firmware_date_utc "$firmware_date_utc" \
        '{
            checked_at: $checked_at,
            firmware_age_days: $firmware_age_days,
            firmware_date_utc: (if $firmware_date_utc == "" then null else $firmware_date_utc end)
        }'
}

get_hosts_ip() {
    local hostname="$1"
    awk -v host="$hostname" '
        $1 !~ /^#/ {
            for (i = 2; i <= NF; i++) {
                if ($i == host) {
                    print $1
                    exit
                }
            }
        }
    ' /etc/hosts 2>/dev/null
}

get_mac_for_ip() {
    local ip="$1"
    local mac=""

    if command -v ip >/dev/null 2>&1; then
        mac=$(ip neigh show "$ip" 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "lladdr") {print $(i+1); exit}}')
    fi

    if [ -z "$mac" ] && command -v arp >/dev/null 2>&1; then
        mac=$(arp -n "$ip" 2>/dev/null | awk '/ at / {for (i = 1; i <= NF; i++) if ($i == "at") {print $(i+1); exit}}')
    fi

    echo "$mac" | tr 'A-F' 'a-f'
}

get_kiosk_browser_info() {
    local kiosk_config="/etc/videokiosk2/local.conf"
    local kiosk_user kiosk_home
    local browser_type="${FAILOVER_BROWSER:-}"
    local browser_scale="${BROWSER_SCALE:-1}"

    if [ ! -r "$kiosk_config" ]; then
        kiosk_user=$(systemctl show videokiosk2.service -p User --value 2>/dev/null || true)
        kiosk_home=$(getent passwd "$kiosk_user" 2>/dev/null | cut -d: -f6)
        if [[ -n "$kiosk_home" && -r "$kiosk_home/local.conf" ]]; then
            kiosk_config="$kiosk_home/local.conf"
        fi
    fi

    if [ -r "$kiosk_config" ]; then
        # shellcheck source=/dev/null
        source "$kiosk_config"
    fi
    browser_type="${FAILOVER_BROWSER:-}"
    browser_scale="${BROWSER_SCALE:-1}"

    if [ "$browser_type" != "falkon" ] && [ "$browser_type" != "midori" ]; then
        if grep -q '^ID=raspbian\|Raspberry Pi OS' /etc/os-release 2>/dev/null; then
            browser_type="midori"
        else
            browser_type="falkon"
        fi
    fi

    case "$browser_scale" in
        1|1.25|1.5|1.75|2|2.5|3|4) ;;
        *) browser_scale="1" ;;
    esac

    jq -n --arg type "$browser_type" --arg scale "$browser_scale" \
        '{type: $type, scale: $scale}'
}

# Ensure cache directory exists
mkdir -p "$CACHE_DIR"
mkdir -p "$SLOW_CACHE_DIR"

# Prevent overlapping runs
exec 200>"$LOCK"
flock -n 200 || exit 0

# --- System Metrics ---

UPTIME_SEC=$(awk '{print int($1)}' /proc/uptime)
LOAD_1=$(awk '{print $1}' /proc/loadavg)
LOAD_5=$(awk '{print $2}' /proc/loadavg)
LOAD_15=$(awk '{print $3}' /proc/loadavg)

# Memory (MB)
MEM_TOTAL=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo)
MEM_AVAIL=$(awk '/MemAvailable/{printf "%d", $2/1024}' /proc/meminfo)
MEM_USED=$((MEM_TOTAL - MEM_AVAIL))

# Disk (MB, root partition)
read -r DISK_TOTAL DISK_USED DISK_AVAIL <<< \
    "$(df -BM --output=size,used,avail / | tail -1 | tr -d 'M')"

# CPU temperature
TEMP="null"
if command -v vcgencmd &>/dev/null; then
    RAW=$(vcgencmd measure_temp 2>/dev/null | grep -oP '[0-9.]+' || echo "")
    [ -n "$RAW" ] && TEMP="$RAW"
elif [ -f /sys/class/thermal/thermal_zone0/temp ]; then
    RAW=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo "0")
    TEMP=$(awk "BEGIN{printf \"%.1f\", $RAW/1000}")
fi

# Disk percentage
DISK_PCT=0
DISK_TOTAL_NUM="${DISK_TOTAL## }"
DISK_USED_NUM="${DISK_USED## }"
if [[ "$DISK_TOTAL_NUM" =~ ^[0-9]+$ ]] && [ "$DISK_TOTAL_NUM" -gt 0 ]; then
    DISK_PCT=$(awk "BEGIN{printf \"%.1f\", $DISK_USED_NUM * 100 / $DISK_TOTAL_NUM}")
fi

# Pi throttle state (hex string; empty if unavailable)
THROTTLE_HEX=""
if command -v vcgencmd &>/dev/null; then
    THROTTLE_HEX=$(vcgencmd get_throttled 2>/dev/null | grep -oP '0x[0-9a-fA-F]+' || echo "")
fi

# HDMI/display connection state
HDMI_STATE=""
HDMI_SOURCE=""
HDMI_RAW=""
if command -v tvservice &>/dev/null; then
    TVRAW=$(tvservice -s 2>/dev/null || echo "")
    if [ -n "$TVRAW" ]; then
        HDMI_SOURCE="tvservice"
        HDMI_RAW="$TVRAW"
        if echo "$TVRAW" | grep -qiE 'HDMI CEA|HDMI DMT|DVI'; then
            HDMI_STATE="connected"
        elif echo "$TVRAW" | grep -qi 'off\|no device\|TV is off'; then
            HDMI_STATE="disconnected"
        else
            HDMI_STATE="unknown"
        fi
    fi
fi

if [ -z "$HDMI_STATE" ]; then
    SYSFS_RAW=$(grep -H . /sys/class/drm/*/status 2>/dev/null || true)
    if [ -n "$SYSFS_RAW" ]; then
        HDMI_SOURCE="sysfs"
        # Ignore non-display virtual connectors (e.g., Writeback) for state and hover details.
        SYSFS_DISPLAY=$(echo "$SYSFS_RAW" | grep -E '/(card[0-9]+-(HDMI|DVI|DP|eDP)-[^/]+)/status:' || true)
        [ -z "$SYSFS_DISPLAY" ] && SYSFS_DISPLAY="$SYSFS_RAW"

        HDMI_RAW=$(echo "$SYSFS_DISPLAY" | \
            sed -E 's|/sys/class/drm/||; s|/status:|:|g' | tr '\n' ';' | sed 's/;$//')

        if echo "$SYSFS_DISPLAY" | grep -q ':connected'; then
            HDMI_STATE="connected"
        elif echo "$SYSFS_DISPLAY" | grep -q ':disconnected'; then
            HDMI_STATE="disconnected"
        else
            HDMI_STATE="unknown"
        fi
    fi
fi

if [ -z "$HDMI_STATE" ] && command -v xrandr &>/dev/null; then
    XRRAW=$(xrandr --query 2>/dev/null || echo "")
    if [ -n "$XRRAW" ]; then
        HDMI_SOURCE="xrandr"
        HDMI_RAW=$(echo "$XRRAW" | tr '\n' ';' | sed 's/;$//' | cut -c1-220)
        if echo "$XRRAW" | grep -q ' connected'; then
            HDMI_STATE="connected"
        else
            HDMI_STATE="disconnected"
        fi
    fi
fi

[ -z "$HDMI_STATE" ] && HDMI_STATE="unknown"

# Slow metrics (cached independently with longer TTLs)
CERT_TTL_SEC=$(get_config_ttl "cert_expiry" "$DEFAULT_SLOW_TTL")
TAILSCALE_TTL_SEC=$(get_config_ttl "tailscale_key_expiry" "$DEFAULT_SLOW_TTL")

CERT_METRIC_JSON=$(load_slow_metric "cert-expiry" "$CERT_TTL_SEC" refresh_tls_cert_metric || echo "{}")
TAILSCALE_METRIC_JSON=$(load_slow_metric "tailscale-key-expiry" "$TAILSCALE_TTL_SEC" refresh_tailscale_metric || echo "{}")

CERT_DAYS=$(echo "$CERT_METRIC_JSON" | jq -r '.cert_days // -1')
CERT_EXPIRY_UTC=$(echo "$CERT_METRIC_JSON" | jq -r '.cert_expires_utc // ""')
CERT_CHECKED_UTC=$(echo "$CERT_METRIC_JSON" | jq -r '.checked_at // ""')

TAILSCALE_STATUS=$(echo "$TAILSCALE_METRIC_JSON" | jq -r '.tailscale_status // "unavailable"')
TAILSCALE_KEY_DAYS=$(echo "$TAILSCALE_METRIC_JSON" | jq -r '.tailscale_key_days // -1')
TAILSCALE_KEY_EXPIRES_UTC=$(echo "$TAILSCALE_METRIC_JSON" | jq -r '.tailscale_key_expires_utc // ""')
TAILSCALE_KEY_EXPIRED=$(echo "$TAILSCALE_METRIC_JSON" | jq -r '.tailscale_key_expired // ""')
TAILSCALE_CHECKED_UTC=$(echo "$TAILSCALE_METRIC_JSON" | jq -r '.checked_at // ""')

APT_TTL_SEC=$(get_config_ttl "apt" "$DEFAULT_SLOW_TTL")
FIRMWARE_TTL_SEC=$(get_config_ttl "firmware_age" "86400")

APT_METRIC_JSON=$(load_slow_metric "apt" "$APT_TTL_SEC" refresh_apt_metric || echo "{}")
FIRMWARE_METRIC_JSON=$(load_slow_metric "firmware-age" "$FIRMWARE_TTL_SEC" refresh_firmware_metric || echo "{}")

APT_UPDATE_DAYS=$(echo "$APT_METRIC_JSON" | jq -r '.apt_update_days // -1')
APT_UPDATE_UTC=$(echo "$APT_METRIC_JSON" | jq -r '.apt_update_utc // ""')
APT_UPGRADE_DAYS=$(echo "$APT_METRIC_JSON" | jq -r '.apt_upgrade_days // -1')
APT_UPGRADE_UTC=$(echo "$APT_METRIC_JSON" | jq -r '.apt_upgrade_utc // ""')
APT_CHECKED_UTC=$(echo "$APT_METRIC_JSON" | jq -r '.checked_at // ""')

FIRMWARE_AGE_DAYS=$(echo "$FIRMWARE_METRIC_JSON" | jq -r '.firmware_age_days // -1')
FIRMWARE_DATE_UTC=$(echo "$FIRMWARE_METRIC_JSON" | jq -r '.firmware_date_utc // ""')
FIRMWARE_CHECKED_UTC=$(echo "$FIRMWARE_METRIC_JSON" | jq -r '.checked_at // ""')

# Backup age — days since the newest DR archive (cheap mtime check, no caching).
BACKUP_DIR=$(jq -r '.backup.dir // "/var/backups/church-monitoring"' "$CONFIG" 2>/dev/null || echo "/var/backups/church-monitoring")
BACKUP_WARN_DAYS=$(jq -r '.backup.warn_days // 7' "$CONFIG" 2>/dev/null || echo 7)
BACKUP_ERROR_DAYS=$(jq -r '.backup.error_days // 14' "$CONFIG" 2>/dev/null || echo 14)
[[ "$BACKUP_WARN_DAYS" =~ ^[0-9]+$ ]] || BACKUP_WARN_DAYS=7
[[ "$BACKUP_ERROR_DAYS" =~ ^[0-9]+$ ]] || BACKUP_ERROR_DAYS=14
BACKUP_AGE_DAYS=-1
BACKUP_LATEST_UTC=""
if [ -d "$BACKUP_DIR" ]; then
    NEWEST_BACKUP=$(ls -1t "$BACKUP_DIR"/backup-*.tar.gz 2>/dev/null | head -1 || echo "")
    if [ -n "$NEWEST_BACKUP" ] && [ -f "$NEWEST_BACKUP" ]; then
        BK_EPOCH=$(stat -c %Y "$NEWEST_BACKUP" 2>/dev/null || echo "")
        if [[ "$BK_EPOCH" =~ ^[0-9]+$ ]]; then
            BACKUP_AGE_DAYS=$(( ( $(date +%s) - BK_EPOCH ) / 86400 ))
            BACKUP_LATEST_UTC=$(date -u -d "@$BK_EPOCH" +"%Y-%m-%d %H:%M:%S UTC" 2>/dev/null || echo "")
        fi
    fi
fi

# Build normalized slow_metrics array
# Each entry: {id, label, value, status, tooltip}
# status: ok (gray) | warn (orange) | error (red) | unavailable (hidden)
SLOW_METRICS_JSON="[]"
_m() {
    SLOW_METRICS_JSON=$(echo "$SLOW_METRICS_JSON" | jq \
        --arg id "$1" --arg lbl "$2" --arg value "$3" \
        --arg status "$4" --arg tooltip "$5" \
        '. + [{"id":$id, "label":$lbl, "value":$value, "status":$status, "tooltip":$tooltip}]')
}

if [ "$CERT_DAYS" != "-1" ] && [[ "$CERT_DAYS" =~ ^-?[0-9]+$ ]]; then
    if [ "$CERT_DAYS" -lt 14 ]; then _S="error"
    elif [ "$CERT_DAYS" -lt 30 ]; then _S="warn"
    else _S="ok"; fi
    _m "cert_expiry" "Cert" "${CERT_DAYS}d" "$_S" \
        "Days until TLS cert expires. Expires: ${CERT_EXPIRY_UTC}. Last checked: ${CERT_CHECKED_UTC}"
fi

if [ "$TAILSCALE_STATUS" = "ok" ] && [ "$TAILSCALE_KEY_DAYS" != "-1" ] && [[ "$TAILSCALE_KEY_DAYS" =~ ^-?[0-9]+$ ]]; then
    if [ "$TAILSCALE_KEY_DAYS" -lt 3 ] || [ "$TAILSCALE_KEY_EXPIRED" = "true" ]; then _S="error"
    elif [ "$TAILSCALE_KEY_DAYS" -lt 14 ]; then _S="warn"
    else _S="ok"; fi
    _m "tailscale_key" "Tailscale" "${TAILSCALE_KEY_DAYS}d" "$_S" \
        "Days until Tailscale key expires. Expires: ${TAILSCALE_KEY_EXPIRES_UTC}. Expired: ${TAILSCALE_KEY_EXPIRED}. Last checked: ${TAILSCALE_CHECKED_UTC}"
elif [ "$TAILSCALE_STATUS" = "error" ]; then
    _m "tailscale_key" "Tailscale" "error" "error" \
        "tailscale status command failed. Last checked: ${TAILSCALE_CHECKED_UTC}"
fi

if [ "$APT_UPDATE_DAYS" != "-1" ] && [[ "$APT_UPDATE_DAYS" =~ ^[0-9]+$ ]]; then
    if [ "$APT_UPDATE_DAYS" -ge 30 ]; then _S="error"
    elif [ "$APT_UPDATE_DAYS" -ge 14 ]; then _S="warn"
    else _S="ok"; fi
    _m "apt_update" "Updated" "${APT_UPDATE_DAYS}d" "$_S" \
        "Days since apt update. Last: ${APT_UPDATE_UTC}. Last checked: ${APT_CHECKED_UTC}"
fi

if [ "$APT_UPGRADE_DAYS" != "-1" ] && [[ "$APT_UPGRADE_DAYS" =~ ^[0-9]+$ ]]; then
    if [ "$APT_UPGRADE_DAYS" -ge 90 ]; then _S="error"
    elif [ "$APT_UPGRADE_DAYS" -ge 30 ]; then _S="warn"
    else _S="ok"; fi
    _m "apt_upgrade" "Upgraded" "${APT_UPGRADE_DAYS}d" "$_S" \
        "Days since apt upgrade. Last: ${APT_UPGRADE_UTC}. Last checked: ${APT_CHECKED_UTC}"
fi

if [ "$FIRMWARE_AGE_DAYS" != "-1" ] && [[ "$FIRMWARE_AGE_DAYS" =~ ^[0-9]+$ ]]; then
    if [ "$FIRMWARE_AGE_DAYS" -ge 365 ]; then _S="error"
    elif [ "$FIRMWARE_AGE_DAYS" -ge 180 ]; then _S="warn"
    else _S="ok"; fi
    _m "firmware_age" "Firmware" "${FIRMWARE_AGE_DAYS}d" "$_S" \
        "Age of Pi firmware build. Built: ${FIRMWARE_DATE_UTC}. Last checked: ${FIRMWARE_CHECKED_UTC}"
fi

if [ "$BACKUP_AGE_DAYS" != "-1" ] && [[ "$BACKUP_AGE_DAYS" =~ ^[0-9]+$ ]]; then
    if [ "$BACKUP_AGE_DAYS" -ge "$BACKUP_ERROR_DAYS" ]; then _S="error"
    elif [ "$BACKUP_AGE_DAYS" -ge "$BACKUP_WARN_DAYS" ]; then _S="warn"
    else _S="ok"; fi
    _m "backed_up" "Backup" "${BACKUP_AGE_DAYS}d" "$_S" \
        "Days since last config backup. Latest: ${BACKUP_LATEST_UTC}"
else
    _m "backed_up" "Backup" "never" "error" \
        "No config backup found in ${BACKUP_DIR}"
fi

# Church-calendar image folder check (configurable via .calendar_images_path in client-config.json)
CAL_IMG_TOTAL=-1
CAL_IMG_STALE=-1
CAL_IMG_DIR=$(jq -r '.calendar_images_path // empty' "$CONFIG" 2>/dev/null || echo "")
[ -z "$CAL_IMG_DIR" ] && CAL_IMG_DIR="/var/www/html/church-calendar/images"
if [ -d "$CAL_IMG_DIR" ]; then
    TODAY=$(date +%Y-%m-%d)
    CAL_IMG_TOTAL=0
    CAL_IMG_STALE=0
    while IFS= read -r f; do
        CAL_IMG_TOTAL=$((CAL_IMG_TOTAL + 1))
        BASENAME=$(basename "$f")
        FILE_DATE=$(echo "$BASENAME" | grep -oP '^\d{4}-\d{2}-\d{2}' || echo "")
        if [ -n "$FILE_DATE" ] && [[ "$FILE_DATE" < "$TODAY" ]]; then
            CAL_IMG_STALE=$((CAL_IMG_STALE + 1))
        fi
    done < <(find "$CAL_IMG_DIR" -maxdepth 1 -type f 2>/dev/null || true)
fi

# --- Service/Process Checks ---

BROWSER_INFO=$(get_kiosk_browser_info || echo "null")
[[ -n "$BROWSER_INFO" ]] || BROWSER_INFO="null"
SOFTWARE_VERSIONS=$(get_software_versions)
SERVICES="[]"
if [ -f "$CONFIG" ]; then
    while IFS= read -r line; do
        NAME=$(echo "$line" | jq -r '.name')
        TYPE=$(echo "$line" | jq -r '.type')
        STATUS="unknown"
        VERSIONS="[]"

        if [ "$TYPE" = "systemd" ]; then
            STATUS=$(systemctl is-active "$NAME" 2>/dev/null || echo "inactive")
            if [ "$STATUS" != "active" ]; then
                notify -p high -k "service-down:$(hostname):$NAME" \
                    "$NAME is $STATUS on $(hostname)"
            fi
        elif [ "$TYPE" = "process" ]; then
            MATCH=$(echo "$line" | jq -r '.match // empty')
            if [ -n "$MATCH" ]; then
                # Regex match against full ps -ef output
                COUNT=$(ps -ef 2>/dev/null | grep -E "$MATCH" | grep -vc grep) || COUNT=0
            else
                COUNT=$(pgrep -xc "$NAME" 2>/dev/null) || COUNT=0
            fi
            if [ "$COUNT" -gt "0" ]; then
                STATUS="running ($COUNT)"
            else
                STATUS="not running"
                notify -p high -k "service-down:$(hostname):$NAME" \
                    "$NAME is not running on $(hostname)"
            fi
        fi

        VERSIONS=$(get_service_versions "$NAME" "$TYPE" "$SOFTWARE_VERSIONS" "$BROWSER_INFO")

        SERVICES=$(echo "$SERVICES" | jq \
            --arg n "$NAME" --arg t "$TYPE" --arg s "$STATUS" \
            --argjson versions "$VERSIONS" \
            '. + [{"name":$n,"type":$t,"status":$s,"versions":$versions}]')
    done < <(jq -c '.monitors[]' "$CONFIG" 2>/dev/null || true)

    # Optional informational check: verify encoder host mapping + MAC + connectivity.
    ENCODER_HOST=$(jq -r '.encoder_identity_check.host // empty' "$CONFIG" 2>/dev/null || echo "")
    ENCODER_EXPECTED_MAC=$(jq -r '.encoder_identity_check.expected_mac // empty' "$CONFIG" 2>/dev/null | tr 'A-F' 'a-f')
    ENCODER_PORT=$(jq -r '.encoder_identity_check.port // 8086' "$CONFIG" 2>/dev/null || echo "8086")

    if [ -n "$ENCODER_HOST" ] && [ -n "$ENCODER_EXPECTED_MAC" ]; then
        ENC_STATUS="fail"
        ENC_DETAIL=""
        ENCODER_IP=""

        if [[ "$ENCODER_HOST" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            ENCODER_IP="$ENCODER_HOST"
        else
            ENCODER_IP=$(get_hosts_ip "$ENCODER_HOST")
            if [ -z "$ENCODER_IP" ]; then
                ENC_DETAIL="hosts-missing"
            fi
        fi

        if [ -n "$ENCODER_IP" ]; then
            if ping -c 1 -W 1 "$ENCODER_IP" >/dev/null 2>&1; then
                ENCODER_MAC=$(get_mac_for_ip "$ENCODER_IP")
                if [ "$ENCODER_MAC" = "$ENCODER_EXPECTED_MAC" ]; then
                    if [[ "$ENCODER_PORT" =~ ^[0-9]+$ ]]; then
                        if timeout 3 bash -c "echo >/dev/tcp/$ENCODER_IP/$ENCODER_PORT" 2>/dev/null; then
                            ENC_STATUS="ok"
                            ENC_DETAIL="ip=$ENCODER_IP mac=$ENCODER_MAC tcp=$ENCODER_PORT"
                        else
                            ENC_DETAIL="tcp-fail ip=$ENCODER_IP mac=$ENCODER_MAC port=$ENCODER_PORT"
                        fi
                    else
                        ENC_STATUS="ok"
                        ENC_DETAIL="ip=$ENCODER_IP mac=$ENCODER_MAC"
                    fi
                elif [ -z "$ENCODER_MAC" ]; then
                    ENC_DETAIL="arp-missing ip=$ENCODER_IP"
                else
                    ENC_DETAIL="mac-mismatch ip=$ENCODER_IP got=$ENCODER_MAC"
                fi
            else
                # Explicitly fail when encoder is offline/unreachable.
                ENC_DETAIL="unreachable ip=$ENCODER_IP"
            fi
        fi

        SERVICES=$(echo "$SERVICES" | jq \
            --arg n "encoder_identity" --arg t "info" --arg s "$ENC_STATUS" --arg d "$ENC_DETAIL" \
            '. + [{"name":$n,"type":$t,"status":$s,"detail":$d}]')
        if [ "$ENC_STATUS" != "ok" ]; then
            notify -p high -k "encoder-down:$(hostname)" \
                "Encoder check failed on $(hostname): $ENC_DETAIL"
        fi
    fi
fi

# --- Build Output ---

HOSTNAME_VAL=$(jq -r '.hostname // empty' "$CONFIG" 2>/dev/null || hostname)
[ -z "$HOSTNAME_VAL" ] && HOSTNAME_VAL=$(hostname)
CEC_ENABLED=$(jq -r '.cec_enabled // false' "$CONFIG" 2>/dev/null || echo "false")
DISPLAY_CONTROL=$(get_display_control_info)
BLUETOOTH_HID=$(get_bluetooth_hid_info)
STANDBY_TIMER=$(get_standby_timer_info)
DISPLAY_SIGNAL=$(get_display_signal_info || get_display_signal_unavailable || echo "null")
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

jq -n \
    --arg hostname "$HOSTNAME_VAL" \
    --arg timestamp "$TIMESTAMP" \
    --argjson uptime "$UPTIME_SEC" \
    --argjson load1 "$LOAD_1" \
    --argjson load5 "$LOAD_5" \
    --argjson load15 "$LOAD_15" \
    --argjson mem_total "$MEM_TOTAL" \
    --argjson mem_used "$MEM_USED" \
    --argjson mem_avail "$MEM_AVAIL" \
    --argjson disk_total "${DISK_TOTAL## }" \
    --argjson disk_used "${DISK_USED## }" \
    --argjson disk_avail "${DISK_AVAIL## }" \
    --argjson disk_pct "$DISK_PCT" \
    --arg throttle_hex "$THROTTLE_HEX" \
    --arg hdmi "$HDMI_STATE" \
    --arg hdmi_source "$HDMI_SOURCE" \
    --arg hdmi_raw "$HDMI_RAW" \
    --argjson slow_metrics "$SLOW_METRICS_JSON" \
    --argjson cal_img_total "$CAL_IMG_TOTAL" \
    --argjson cal_img_stale "$CAL_IMG_STALE" \
    --argjson temp "$TEMP" \
    --argjson services "$SERVICES" \
    --argjson cec "$CEC_ENABLED" \
    --argjson browser "${BROWSER_INFO:-null}" \
    --argjson display_control "$DISPLAY_CONTROL" \
    --argjson bluetooth_hid "$BLUETOOTH_HID" \
    --argjson standby_timer "$STANDBY_TIMER" \
    --argjson display_signal "$DISPLAY_SIGNAL" \
    --argjson software_versions "$SOFTWARE_VERSIONS" \
    '{
        hostname: $hostname,
        timestamp: $timestamp,
        uptime_seconds: $uptime,
        load: {avg_1: $load1, avg_5: $load5, avg_15: $load15},
        memory: {total_mb: $mem_total, used_mb: $mem_used, available_mb: $mem_avail},
        disk: {total_mb: $disk_total, used_mb: $disk_used, available_mb: $disk_avail, pct: $disk_pct},
        temperature_c: $temp,
        throttle_hex: (if $throttle_hex == "" then null else $throttle_hex end),
        hdmi: (if $hdmi == "" then null else $hdmi end),
        hdmi_source: (if $hdmi_source == "" then null else $hdmi_source end),
        hdmi_raw: (if $hdmi_raw == "" then null else $hdmi_raw end),
        slow_metrics: $slow_metrics,
        calendar_images: (if $cal_img_total == -1 then null else {total: $cal_img_total, stale: $cal_img_stale} end),
        services: $services,
        browser: $browser,
        cec_enabled: $cec,
        display_control: $display_control,
        bluetooth_hid: $bluetooth_hid,
        standby_timer: $standby_timer,
        display_signal: $display_signal,
        software_versions: $software_versions
    }' > "${CACHE}.tmp"

mv "${CACHE}.tmp" "$CACHE"
chgrp www-data "$CACHE" 2>/dev/null || true
chmod 664 "$CACHE"
