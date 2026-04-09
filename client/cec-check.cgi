#!/usr/bin/env bash
# cec-check.cgi — On-demand CEC TV status check.
# Only runs when triggered from the server dashboard button.
# Requires cec-client and www-data in the 'video' group.

echo "Content-Type: application/json"
echo ""

CONFIG="/etc/church-monitoring/client-config.json"

CEC_ENABLED="false"
if [ -f "$CONFIG" ]; then
    CEC_ENABLED=$(jq -r '.cec_enabled // false' "$CONFIG" 2>/dev/null || echo "false")
fi

if [ "$CEC_ENABLED" != "true" ]; then
    echo '{"error":"CEC not enabled on this host"}'
    exit 0
fi

if ! command -v cec-client &>/dev/null; then
    echo '{"error":"cec-client not installed"}'
    exit 0
fi

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Query TV power status (timeout prevents hangs if adapter is busy)
TV_POWER="unknown"
CEC_OUTPUT=$(echo "pow 0" | timeout 5 cec-client -s -d 1 2>/dev/null || echo "")
if echo "$CEC_OUTPUT" | grep -q "power status: on"; then
    TV_POWER="on"
elif echo "$CEC_OUTPUT" | grep -q "power status: standby"; then
    TV_POWER="standby"
elif echo "$CEC_OUTPUT" | grep -q "power status: unknown"; then
    TV_POWER="unknown"
fi

# Query active HDMI input
HDMI_INPUT="unknown"
ADDR_OUTPUT=$(echo "ad" | timeout 5 cec-client -s -d 1 2>/dev/null || echo "")
ACTIVE=$(echo "$ADDR_OUTPUT" | grep -oP 'currently active source: \K[0-9.]+' || echo "")
if [ -n "$ACTIVE" ]; then
    HDMI_INPUT="$ACTIVE"
fi

printf '{"tv_power":"%s","hdmi_input":"%s","timestamp":"%s"}\n' \
    "$TV_POWER" "$HDMI_INPUT" "$TIMESTAMP"
