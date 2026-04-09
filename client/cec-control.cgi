#!/usr/bin/env bash
# cec-control.cgi — On-demand CEC TV control (power on, standby, set active input).
# Accepts action via query string: ?action=on|standby|active
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

# Parse action from query string
ACTION=$(echo "$QUERY_STRING" | tr '&' '\n' | grep "^action=" | cut -d= -f2- | head -1)

# Sanitize: allow only known actions
case "$ACTION" in
    on|standby|active) ;;
    *)
        echo '{"error":"invalid action, use: on, standby, active"}'
        exit 0
        ;;
esac

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
RESULT="unknown"

case "$ACTION" in
    on)
        # Power on TV (device 0 = TV)
        CEC_OUTPUT=$(echo "on 0" | timeout 8 cec-client -s -d 1 2>/dev/null || echo "")
        # Verify power state
        VERIFY=$(echo "pow 0" | timeout 5 cec-client -s -d 1 2>/dev/null || echo "")
        if echo "$VERIFY" | grep -q "power status: on"; then
            RESULT="on"
        elif echo "$VERIFY" | grep -q "power status: in transition"; then
            RESULT="turning on"
        else
            RESULT="sent"
        fi
        ;;
    standby)
        # Put TV in standby
        CEC_OUTPUT=$(echo "standby 0" | timeout 8 cec-client -s -d 1 2>/dev/null || echo "")
        # Verify power state
        VERIFY=$(echo "pow 0" | timeout 5 cec-client -s -d 1 2>/dev/null || echo "")
        if echo "$VERIFY" | grep -q "power status: standby"; then
            RESULT="standby"
        elif echo "$VERIFY" | grep -q "power status: in transition"; then
            RESULT="entering standby"
        else
            RESULT="sent"
        fi
        ;;
    active)
        # Set this device as the active source (makes TV switch to our HDMI input)
        CEC_OUTPUT=$(echo "as" | timeout 8 cec-client -s -d 1 2>/dev/null || echo "")
        RESULT="active source set"
        ;;
esac

printf '{"action":"%s","result":"%s","timestamp":"%s"}\n' \
    "$ACTION" "$RESULT" "$TIMESTAMP"
