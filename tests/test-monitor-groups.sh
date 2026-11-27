#!/usr/bin/env bash
# Offline collector/digest fixtures. Scratch files stay inside this checkout.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$ROOT/.test-monitor-groups-$$"
mkdir -p "$WORK/bin"
trap 'rm -rf "$WORK"' EXIT
awk '/^collect_monitor_group\(\) \{/,/^}/' "$ROOT/client/collect.sh" > "$WORK/functions.sh"
awk '/^monitor_digest_services\(\) \{/,/^}/' "$ROOT/server/church-status-report.sh" >> "$WORK/functions.sh"
source "$WORK/functions.sh"
cat > "$WORK/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CALLS"
case "$2" in
    good) echo active ;;
    transitioning) echo activating ;;
    down) echo failed; exit 3 ;;
    *) exit 3 ;;
esac
EOF
cat > "$WORK/bin/pgrep" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CALLS"
[[ "${*: -1}" == "worker" ]] && { echo 2; exit; }
exit 1
EOF
cat > "$WORK/bin/ps" <<'EOF'
#!/usr/bin/env bash
echo 'fixture worker --serve'
EOF
chmod +x "$WORK/bin/"*
export PATH="$WORK/bin:$PATH" CALLS="$WORK/calls"
group='{"name":"workers","label":"Workers","type":"group","children":[
 {"name":"good","type":"systemd"},{"name":"transitioning","type":"systemd"},
 {"name":"down","label":"Failed unit","type":"systemd"},{"name":"worker","type":"process"}]}'
result=$(collect_monitor_group "$group" "[$group]")
jq -e '.severity == "error" and .reason == "Failed unit: failed" and
    .children[0].severity == "ok" and .children[1].severity == "warning" and
    .children[3].status == "running (2)"' <<<"$result" >/dev/null
digest=$(monitor_digest_services <<<"{\"services\":[$result]}")
[[ "$digest" == 'Workers=error (Failed unit: failed)' ]]
[[ -z "$(monitor_digest_services <<< '{"services":[{"name":"healthy","type":"group","severity":"ok","children":[{"name":"child","severity":"ok","status":"active"}]}]}')" ]]
[[ "$(monitor_digest_services <<< '{"services":[{"name":"flat","type":"systemd","status":"inactive"},{"name":"g","type":"group","severity":"warning","children":[{"name":"bad","severity":"error","reason":"broken"}]}]}')" == 'flat=inactive, g=error (bad: broken)' ]]
reject() {
    : > "$CALLS"
    local value
    value=$(collect_monitor_group "$1" "${2:-[$1]}")
    jq -e '.severity == "error" and .children == []' <<<"$value" >/dev/null
    [[ ! -s "$CALLS" ]]
}
reject '{"name":"empty","type":"group","children":[]}'
reject '{"name":"nested","type":"group","children":[{"name":"child","type":"group","children":[{"name":"good","type":"systemd"}]}]}'
reject '{"name":"duplicate","type":"group","children":[{"name":"good","type":"systemd"},{"name":"good","type":"process"}]}'
reject '{"name":"invalid","type":"group","children":[{"name":"--help","type":"systemd"}]}'
reject '{"name":"invalid","type":"group","children":[{"name":"good\n","type":"systemd"}]}'
reject '{"name":"invalid","type":"group","children":[{"name":"$(touch injected)","type":"systemd"}]}'
reject '{"name":"invalid","type":"group","children":[{"name":"good","type":"systemd","provider":"unknown"}]}'
reject '{"name":"invalid","type":"group","children":[{"name":"good","type":"shell","command":"touch injected"}]}'
reject '{"name":"provider","type":"group","provider":"yt-streamer","children":[{"name":"good","type":"systemd"}]}'
reject '{"name":"invalid","type":"group","children":"not-an-array"}'
reject '{"type":"group","children":[{"name":"good","type":"systemd"}]}'
reject '{"name":"invalid","label":"","type":"group","children":[{"name":"good","type":"systemd"}]}'
reject "$group" "[$group,{\"name\":\"good\",\"type\":\"systemd\"}]"
reject '{"name":"g","type":"group","children":[{"name":"good","type":"systemd"},{"name":"regex","type":"process","match":"["}]}'
result=$(collect_monitor_group '{"name":"g","type":"group","children":[{"name":"unknown","type":"systemd"}]}' \
    '[{"name":"g","type":"group","children":[{"name":"unknown","type":"systemd"}]}]')
jq -e '.severity == "unknown"' <<<"$result" >/dev/null
result=$(collect_monitor_group '{"name":"g","type":"group","children":[{"name":"regex","type":"process","match":"worker --serve"}]}' \
    '[{"name":"g","type":"group","children":[{"name":"regex","type":"process","match":"worker --serve"}]}]')
jq -e '.severity == "ok"' <<<"$result" >/dev/null

# Exercise the real mixed collector assembly, including unchanged flat kiosk checks.
CONFIG="$WORK/config.json"
printf '{"monitors":[{"name":"vlc","type":"process"},{"name":"browser","type":"process"},%s]}\n' "$group" > "$CONFIG"
get_kiosk_browser_info() { echo null; }
get_software_versions() { echo '[]'; }
get_service_versions() { echo '[]'; }
notify() { :; }
awk '/^BROWSER_INFO=\$\(get_kiosk_browser_info/{on=1}
     /    # Optional informational check:/{on=0}
     on{print}' "$ROOT/client/collect.sh" > "$WORK/assembly.sh"
echo fi >> "$WORK/assembly.sh"
source "$WORK/assembly.sh"
jq -e 'length == 3 and .[0].status == "not running" and .[1].status == "not running" and
    .[2].type == "group" and .[2].severity == "error"' <<<"$SERVICES" >/dev/null

# The restart endpoint must continue to authorize only top-level systemd monitors.
awk '/^MATCH=\$\(jq/,/    "\$CONFIG" 2>\/dev\/null\)/' "$ROOT/client/restart-service.cgi" > "$WORK/authorization.sh"
SERVICE_CLEAN=down
source "$WORK/authorization.sh"
[[ -z "$MATCH" ]]
echo 'OK monitor group collector, validation, digest, mixed assembly and restart authorization fixtures'
