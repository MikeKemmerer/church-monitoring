#!/usr/bin/env bash
# screenshot.cgi — Captures the X11 display and serves a low-res JPEG.
# Requires scrot (preferred) or import (ImageMagick) and DISPLAY=:0.

TMPFILE="/tmp/church-monitoring-screenshot.jpg"
WIDTH=480
QUALITY=40

# Capture the display
export DISPLAY=:0
export XAUTHORITY=/home/pi/.Xauthority

if command -v scrot &>/dev/null; then
    scrot -q "$QUALITY" -o "$TMPFILE" 2>/dev/null
    CAPTURED=$?
elif command -v import &>/dev/null; then
    import -window root -resize "${WIDTH}x" -quality "$QUALITY" "$TMPFILE" 2>/dev/null
    CAPTURED=$?
else
    echo "Content-Type: application/json"
    echo ""
    echo '{"error":"no screenshot tool available (install scrot)"}'
    exit 0
fi

if [ $CAPTURED -ne 0 ] || [ ! -f "$TMPFILE" ]; then
    echo "Content-Type: application/json"
    echo ""
    echo '{"error":"screenshot capture failed"}'
    exit 0
fi

# Downscale if scrot was used (it captures full-res)
if command -v convert &>/dev/null; then
    convert "$TMPFILE" -resize "${WIDTH}x" -quality "$QUALITY" "$TMPFILE" 2>/dev/null || true
fi

# Serve as JPEG
echo "Content-Type: image/jpeg"
echo "Cache-Control: no-cache"
echo ""
cat "$TMPFILE"
