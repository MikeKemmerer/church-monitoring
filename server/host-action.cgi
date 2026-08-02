#!/usr/bin/env bash
# host-action.cgi - Proxies host control actions to a specific client.
# Called by the dashboard with ?host=<client_name>&action=<action>[&param=value]
#
# Supported actions:
#   reboot             - reboots the client host
#   mode-switch&mode=vlc|browser - switches kiosk display mode
#   calendar-settings&theme=&font=&speed=&margins=  - pushes church-calendar
#     display settings to the browser kiosk session (any combination of the
#     four params; switches the kiosk into browser mode)
#   browser-scale&scale=1|1.25|1.5|1.75|2|2.5|3|4  - configures Falkon UI scaling

source /usr/local/lib/church-monitoring/auth-lib.sh
require_role contributor

echo "Content-Type: application/json"
echo ""

CONFIG="/etc/church-monitoring/server-config.json"
CERT="/etc/church-monitoring/ssl/server.crt"
KEY="/etc/church-monitoring/ssl/server.key"
CA="/etc/church-monitoring/ca/ca.crt"

extract_qs_candidate() {
    local src="$1"
    if [ -z "$src" ]; then
        printf ''
        return
    fi
    if [[ "$src" == *\?* ]]; then
        printf '%s' "${src#*\?}"
    else
        printf '%s' "$src"
    fi
}

resolve_raw_qs() {
    local candidate
    for candidate in "$QUERY_STRING" "$REDIRECT_QUERY_STRING" "$REQUEST_URI" "$UNENCODED_URL" "$REQUEST"; do
        candidate=$(extract_qs_candidate "$candidate")
        if [ -n "$candidate" ] && echo "$candidate" | grep -q '='; then
            printf '%s' "$candidate"
            return
        fi
    done
    printf ''
}

RAW_QS=$(resolve_raw_qs)

url_decode() {
    local val="$1"
    val="${val//+/ }"
    printf '%b' "${val//%/\\x}"
}

parse_qs() {
    local key="$1"
    local raw
    raw=$(echo "$RAW_QS" | tr '&;' '\n' | grep "^${key}=" | cut -d= -f2- | head -1)
    [ -n "$raw" ] && url_decode "$raw"
}

TARGET=$(parse_qs "host")
ACTION=$(parse_qs "action")

if [ -z "$TARGET" ]; then
    echo '{"error":"missing host parameter"}'
    exit 0
fi

if [ -z "$ACTION" ]; then
    echo '{"error":"missing action parameter"}'
    exit 0
fi

TARGET_CLEAN=$(echo "$TARGET" | tr -cd 'a-zA-Z0-9._-')
if [ "$TARGET_CLEAN" != "$TARGET" ]; then
    echo '{"error":"invalid host parameter"}'
    exit 0
fi

if [ ! -f "$CONFIG" ]; then
    echo '{"error":"server-config.json not found"}'
    exit 0
fi

CLIENT=$(jq -c --arg name "$TARGET_CLEAN" '.clients[] | select(.name == $name)' "$CONFIG" 2>/dev/null | head -1)
if [ -z "$CLIENT" ]; then
    echo '{"error":"unknown client"}'
    exit 0
fi

HOST=$(echo "$CLIENT" | jq -r '.host')
PORT=$(echo "$CLIENT" | jq -r '.port')

case "$ACTION" in
    reboot)
        ENDPOINT="/cgi-bin/reboot.cgi?guard=confirm"
        ;;
    mode-switch)
        MODE=$(parse_qs "mode")
        MODE_CLEAN=$(echo "$MODE" | tr -cd 'a-zA-Z0-9' | tr 'A-Z' 'a-z')
        if [ -z "$MODE_CLEAN" ]; then
            echo '{"error":"missing mode parameter (vlc or browser)"}'
            exit 0
        fi
        if [ "$MODE_CLEAN" != "vlc" ] && [ "$MODE_CLEAN" != "browser" ]; then
            echo '{"error":"invalid mode parameter (must be vlc or browser)"}'
            exit 0
        fi
        ENDPOINT="/cgi-bin/mode-switch.cgi?mode=${MODE_CLEAN}"
        ;;
    calendar-settings)
        clean_val() {
            echo "$1" | tr -cd 'a-zA-Z0-9-'
        }
        in_list() {
            local needle="$1" list="$2" item
            for item in $list; do
                [ "$item" = "$needle" ] && return 0
            done
            return 1
        }

        ALLOWED_THEMES="classic-gold modern-blue elegant-black liturgical-purple festive-red light"
        ALLOWED_FONTS="cinzel-lora roboto-open-sans playfair-source"
        ALLOWED_SPEEDS="12 18"

        RAW_THEME=$(parse_qs "theme")
        RAW_FONT=$(parse_qs "font")
        RAW_SPEED=$(parse_qs "speed")
        RAW_MARGINS=$(parse_qs "margins")

        THEME=$(clean_val "$RAW_THEME")
        FONT=$(clean_val "$RAW_FONT")
        SPEED=$(clean_val "$RAW_SPEED")
        MARGINS=$(clean_val "$RAW_MARGINS")

        if [ -n "$RAW_THEME" ] && ! in_list "$THEME" "$ALLOWED_THEMES"; then
            echo '{"error":"invalid theme"}'
            exit 0
        fi
        if [ -n "$RAW_FONT" ] && ! in_list "$FONT" "$ALLOWED_FONTS"; then
            echo '{"error":"invalid font"}'
            exit 0
        fi
        if [ -n "$RAW_SPEED" ] && ! in_list "$SPEED" "$ALLOWED_SPEEDS"; then
            echo '{"error":"invalid speed"}'
            exit 0
        fi
        if [ -n "$RAW_MARGINS" ] && [ "$MARGINS" != "0" ] && [ "$MARGINS" != "1" ]; then
            echo '{"error":"invalid margins (must be 0 or 1)"}'
            exit 0
        fi

        if [ -z "$THEME" ] && [ -z "$FONT" ] && [ -z "$SPEED" ] && [ -z "$MARGINS" ]; then
            echo '{"error":"no settings provided - use theme, font, speed, and/or margins"}'
            exit 0
        fi

        ENDPOINT="/cgi-bin/calendar-settings.cgi?theme=${THEME}&font=${FONT}&speed=${SPEED}&margins=${MARGINS}"
        ;;
    browser-scale)
        SCALE=$(parse_qs "scale")
        case "$SCALE" in
            1|1.25|1.5|1.75|2|2.5|3|4) ;;
            *)
                echo '{"error":"invalid browser scale"}'
                exit 0
                ;;
        esac
        ENDPOINT="/cgi-bin/browser-scale.cgi?scale=${SCALE}"
        ;;
    *)
        echo '{"error":"unknown action"}'
        exit 0
        ;;
esac

DATA=$(curl -s --connect-timeout 5 --max-time 20 \
    --cert "$CERT" --key "$KEY" --cacert "$CA" -k \
    "https://${HOST}:${PORT}${ENDPOINT}" 2>/dev/null) || true

if [ -z "$DATA" ]; then
    echo '{"error":"request to client timed out or failed"}'
    exit 0
fi

if ! echo "$DATA" | jq . &>/dev/null; then
    SNIP=$(echo "$DATA" | tr '\n\r' ' ' | cut -c1-180)
    echo "{\"error\":\"client returned non-JSON\",\"detail\":$(echo "$SNIP" | jq -Rs .)}"
    exit 0
fi

echo "$DATA"
