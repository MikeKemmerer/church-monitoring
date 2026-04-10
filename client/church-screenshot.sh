#!/usr/bin/env bash
# church-screenshot.sh — Capture X11 display as the logged-in user.
# Called via sudo from screenshot.cgi. Do not run directly.
# Usage: church-screenshot.sh <quality> <output-path>

export DISPLAY=:0
export XAUTHORITY="$HOME/.Xauthority"

QUALITY="${1:-40}"
OUTPUT="${2:-/tmp/church-monitoring-screenshot.jpg}"

if command -v scrot &>/dev/null; then
    exec scrot -q "$QUALITY" -o "$OUTPUT"
elif command -v import &>/dev/null; then
    exec import -window root -quality "$QUALITY" "$OUTPUT"
else
    exit 1
fi
