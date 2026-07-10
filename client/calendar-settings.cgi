#!/usr/bin/env bash
# calendar-settings.cgi - Pushes church-calendar display settings (theme,
# font, slide speed, margins) to the Midori kiosk session and switches the
# kiosk into Midori mode so the change is visible immediately.
# Accepts any combination of ?theme=&font=&speed=&margins=
# Only meaningful on hosts running videokiosk2.

echo "Content-Type: application/json"
echo ""

get_param() {
    local key="$1"
    echo "$QUERY_STRING" | tr '&;' '\n' | grep "^${key}=" | cut -d= -f2- | head -1
}

clean() {
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

RAW_THEME=$(get_param "theme")
RAW_FONT=$(get_param "font")
RAW_SPEED=$(get_param "speed")
RAW_MARGINS=$(get_param "margins")

THEME=$(clean "$RAW_THEME")
FONT=$(clean "$RAW_FONT")
SPEED=$(clean "$RAW_SPEED")
MARGINS=$(clean "$RAW_MARGINS")

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

[ -z "$THEME" ] && THEME="-"
[ -z "$FONT" ] && FONT="-"
[ -z "$SPEED" ] && SPEED="-"
[ -z "$MARGINS" ] && MARGINS="-"

if [ "$THEME" = "-" ] && [ "$FONT" = "-" ] && [ "$SPEED" = "-" ] && [ "$MARGINS" = "-" ]; then
    echo '{"error":"no settings provided - use theme, font, speed, and/or margins"}'
    exit 0
fi

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

OUTPUT=$(sudo -u pi /usr/local/bin/church-monitoring-set-calendar-settings "$THEME" "$FONT" "$SPEED" "$MARGINS" 2>&1)
RC=$?

if [ $RC -eq 0 ]; then
    echo "{\"result\":\"applied\",\"theme\":\"$THEME\",\"font\":\"$FONT\",\"speed\":\"$SPEED\",\"margins\":\"$MARGINS\",\"timestamp\":\"$TIMESTAMP\"}"
else
    echo "{\"result\":\"failed\",\"error\":$(echo "$OUTPUT" | jq -Rs .),\"timestamp\":\"$TIMESTAMP\"}"
fi
