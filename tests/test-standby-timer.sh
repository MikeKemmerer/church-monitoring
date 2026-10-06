#!/usr/bin/env bash
# Offline tests for the standby-timer helper, CGI and collector block.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$ROOT/client/church-monitoring-standby-timer"
CGI="$ROOT/client/standby-timer.cgi"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
check() {
    local name="$1"; shift
    if "$@"; then pass=$((pass + 1)); echo "ok   $name"; else fail=$((fail + 1)); echo "FAIL $name"; fi
}

export CHURCH_MONITORING_STANDBY_DIR="$TMP/run"
export CHURCH_MONITORING_COLLECTOR="$TMP/collector"
printf '#!/usr/bin/env bash\ntouch "%s/collected"\n' "$TMP" > "$TMP/collector"
chmod +x "$TMP/collector"
mkdir -p "$TMP/run"

write_state() { # state base adjust remaining_seconds updated_offset
    local now; now=$(date +%s)
    jq -n --arg state "$1" --argjson base "$2" --argjson adj "$3" \
        --argjson deadline "$((now + $4))" --argjson updated "$((now - $5))" \
        '{state:$state, failover_started:0, base_minutes:$base, adjust_minutes:$adj,
          deadline:$deadline, fired_at:null, updated:$updated, unit_seconds:60}' > "$TMP/run/standby.json"
    rm -f "$TMP/run/standby-adjust"
}
adjust_value() { cat "$TMP/run/standby-adjust"; }
state_field() { jq -r ".$1" "$TMP/run/standby.json"; }

# plus adds 30 minutes
write_state counting 60 0 3000 1
out=$("$HELPER" plus)
check "plus writes adjust 30" test "$(adjust_value)" = "30"
check "plus patches state adjust" test "$(state_field adjust_minutes)" = "30"
check "plus reports remaining ~4800s" test "$(jq -r '.remaining_seconds' <<<"$out")" -ge 4795
check "plus refreshes collector" test -f "$TMP/collected"

# minus subtracts and may go negative
write_state counting 60 0 5400 1
"$HELPER" minus >/dev/null
check "minus writes adjust -30" test "$(adjust_value)" = "-30"

# minus refused when under 5 minutes would remain
write_state counting 60 0 1500 1
check "minus refused near deadline" bash -c "! '$HELPER' minus 2>/dev/null"
check "refusal leaves no adjust file" test ! -e "$TMP/run/standby-adjust"

# reset returns to zero
write_state counting 60 30 5400 1
"$HELPER" reset >/dev/null
check "reset writes 0" test "$(adjust_value)" = "0"
check "reset moves deadline back 1800s" test "$(( $(state_field deadline) - $(date +%s) ))" -le 3605

# cap at 12 hours total
write_state counting 60 660 3000 1
check "plus refused above 12 hours" bash -c "! '$HELPER' plus 2>/dev/null"

# only while counting
write_state fired 60 0 0 1
check "refused when fired" bash -c "! '$HELPER' plus 2>/dev/null"
write_state idle 60 0 0 1
check "refused when idle" bash -c "! '$HELPER' plus 2>/dev/null"

# stale kiosk
write_state counting 60 0 3000 300
check "refused when state is stale" bash -c "! '$HELPER' plus 2>/dev/null"

# bad action and missing state file
check "rejects unknown action" bash -c "! '$HELPER' bogus 2>/dev/null"
rm -f "$TMP/run/standby.json"
check "refused with no state file" bash -c "! '$HELPER' plus 2>/dev/null"

# CGI wraps the helper through a sudo stub
mkdir -p "$TMP/bin"
printf '#!/usr/bin/env bash\nshift\nexec "%s" "$@"\n' "$HELPER" > "$TMP/bin/sudo"
chmod +x "$TMP/bin/sudo"
write_state counting 60 0 3000 1
cgi_out=$(PATH="$TMP/bin:$PATH" QUERY_STRING="action=plus" bash "$CGI" | tail -n +3)
check "cgi applied" test "$(jq -r '.result' <<<"$cgi_out")" = "applied"
check "cgi bad action" test -n "$(jq -r '.error // empty' <<<"$(QUERY_STRING='action=nope' bash "$CGI" | tail -n +3)")"
write_state fired 60 0 0 1
cgi_out=$(PATH="$TMP/bin:$PATH" QUERY_STRING="action=plus" bash "$CGI" | tail -n +3)
check "cgi failed result" test "$(jq -r '.result' <<<"$cgi_out")" = "failed"

# collector block
awk '/^get_standby_timer_info\(\) \{/,/^}/' "$ROOT/client/collect.sh" > "$TMP/fn.sh"
export STANDBY_STATE_FILE="$TMP/run/standby.json"
# shellcheck disable=SC1091
source "$TMP/fn.sh"
write_state counting 60 30 2400 5
info=$(get_standby_timer_info)
check "collector counting state" test "$(jq -r .state <<<"$info")" = "counting"
check "collector remaining" test "$(jq -r .remaining_seconds <<<"$info")" -ge 2395
check "collector adjust" test "$(jq -r .adjust_minutes <<<"$info")" = "30"
write_state counting 60 0 2400 200
check "collector stale" test "$(jq -r .state <<<"$(get_standby_timer_info)")" = "stale"
check "collector stale has no remaining" test "$(jq -r .remaining_seconds <<<"$(get_standby_timer_info)")" = "null"
write_state fired 60 0 0 5
check "collector fired has no deadline" test "$(jq -r .deadline <<<"$(get_standby_timer_info)")" = "null"
rm -f "$STANDBY_STATE_FILE"
check "collector missing file is null" test "$(get_standby_timer_info)" = "null"
echo "not json" > "$STANDBY_STATE_FILE"
check "collector invalid json is null" test "$(get_standby_timer_info)" = "null"

echo
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
