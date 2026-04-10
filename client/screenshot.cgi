#!/usr/bin/env bash
# screenshot.cgi — Captures the X11 display and serves a low-res JPEG.
# Uses sudo to run church-screenshot.sh as the X display owner.

TMPFILE="/tmp/church-monitoring-screenshot-$$.jpg"
HELPER="/usr/local/bin/church-screenshot.sh"
WIDTH=480
QUALITY=40

json_error() {
    echo "Content-Type: application/json"
    echo ""
    echo "{\"error\":\"$1\"}"
    exit 0
}

# Detect the user who owns the graphical session (seat0)
DISP_USER=""
if command -v loginctl &>/dev/null; then
    DISP_USER=$(loginctl list-sessions --no-legend 2>/dev/null | while read -r sid rest; do
        type=$(loginctl show-session "$sid" -p Type --value 2>/dev/null)
        if [ "$type" = "x11" ] || [ "$type" = "wayland" ]; then
            loginctl show-session "$sid" -p Name --value 2>/dev/null
            break
        fi
    done)
fi
# Fallback: owner of the X socket
if [ -z "$DISP_USER" ] && [ -e /tmp/.X11-unix/X0 ]; then
    DISP_USER=$(stat -c '%U' /tmp/.X11-unix/X0 2>/dev/null)
fi
if [ -z "$DISP_USER" ]; then
    json_error "no graphical session found"
fi

if [ ! -x "$HELPER" ]; then
    json_error "screenshot helper not installed"
fi

# Capture via sudo as the display owner
sudo -u "$DISP_USER" "$HELPER" "$QUALITY" "$TMPFILE" 2>/dev/null
CAPTURED=$?

if [ $CAPTURED -ne 0 ] || [ ! -s "$TMPFILE" ]; then
    rm -f "$TMPFILE" 2>/dev/null
    json_error "screenshot capture failed"
fi

# Downscale with convert if available
if command -v convert &>/dev/null; then
    convert "$TMPFILE" -resize "${WIDTH}x" -quality "$QUALITY" "$TMPFILE" 2>/dev/null || true
fi

# Serve as JPEG
echo "Content-Type: image/jpeg"
echo "Cache-Control: no-cache"
echo ""
cat "$TMPFILE"
rm -f "$TMPFILE" 2>/dev/null
