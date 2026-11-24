#!/usr/bin/env bash
# Offline tests for the standby-timer helper, CGI and collector block.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$ROOT/client/church-monitoring-standby-timer"
CGI="$ROOT/client/standby-timer.cgi"
TMP="$ROOT/.standby-test.$$"
mkdir "$TMP"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
check() {
    local name="$1"; shift
    if "$@"; then pass=$((pass + 1)); echo "ok   $name"; else fail=$((fail + 1)); echo "FAIL $name"; fi
}

export CHURCH_MONITORING_STANDBY_DIR="$TMP/run"
export CHURCH_MONITORING_COLLECTOR="$TMP/collector"
export CHURCH_MONITORING_STANDBY_DEFAULT_FILE="$TMP/default-minutes"
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

# Persistent settings are gated by the wrapper's capability, not just an old countdown.
write_state counting 60 0 3000 1
check "legacy wrapper cannot save settings" bash -c "! printf '90 0\n' | '$HELPER' settings 2>/dev/null"
enable_settings() {
    jq '. + {settings_version:1,default_minutes:60}' "$TMP/run/standby.json" > "$TMP/state.new"
    mv "$TMP/state.new" "$TMP/run/standby.json"
    : > "$TMP/run/standby.lock"
}
enable_settings
before=$(cat "$TMP/run/standby.json")
out=$(printf '90 0\n' | "$HELPER" settings)
check "save reports future only" test "$(jq -r '.current_applied' <<<"$out")" = false
check "save persists numeric default" test "$(cat "$CHURCH_MONITORING_STANDBY_DEFAULT_FILE")" = 90
check "save does not change current state" test "$(cat "$TMP/run/standby.json")" = "$before"
check "save does not change adjustment" test ! -e "$TMP/run/standby-adjust"
export STANDBY_DEFAULT_FILE="$CHURCH_MONITORING_STANDBY_DEFAULT_FILE"
check "collector reads saved default before next tick" test "$(jq -r .default_minutes <<<"$(get_standby_timer_info)")" = 90
for bad in 0 4 721 99999999999999 -1 5.5 05 banana; do
    check "rejects invalid minutes $bad" bash -c "! printf '%s 0\n' '$bad' | '$HELPER' settings 2>/dev/null"
done
out=$(printf '90 1\n' | "$HELPER" settings)
check "apply reports current applied" test "$(jq -r .current_applied <<<"$out")" = true
check "apply leaves base unchanged" test "$(state_field base_minutes)" = 60
check "apply uses adjustment against captured base" test "$(adjust_value)" = 30
"$HELPER" reset >/dev/null
check "reset restores current captured base not saved default" test "$(adjust_value)" = 0
check "reset does not alter future default" test "$(cat "$STANDBY_DEFAULT_FILE")" = 90

write_state counting 60 0 310 1
enable_settings
check "too late apply refused" bash -c "! printf '5 1\n' | '$HELPER' settings 2>/dev/null"
check "too late apply does not persist" test "$(cat "$STANDBY_DEFAULT_FILE")" = 90
check "too late apply leaves adjustment untouched" test ! -e "$TMP/run/standby-adjust"
for state in idle fired disabled; do
    write_state "$state" 60 0 0 1
    enable_settings
    check "$state apply refused" bash -c "! printf '100 1\n' | '$HELPER' settings 2>/dev/null"
    printf '100 0\n' | "$HELPER" settings >/dev/null
    check "$state can save future default" test "$(cat "$STANDBY_DEFAULT_FILE")" = 100
done
write_state counting 60 0 3000 200
enable_settings
check "stale apply refused" bash -c "! printf '120 1\n' | '$HELPER' settings 2>/dev/null"
check "stale apply does not persist" test "$(cat "$STANDBY_DEFAULT_FILE")" = 100
write_state counting 60 0 3000 1
enable_settings
cgi_out=$(PATH="$TMP/bin:$PATH" QUERY_STRING="action=settings&minutes=120&apply=0" bash "$CGI" | tail -n +3)
check "cgi saves future settings" test "$(jq -r .default_minutes <<<"$cgi_out")" = 120
for query in 'minutes=0&apply=0' 'minutes=90&apply=2' 'minutes=6.5&apply=0'; do
    cgi_out=$(QUERY_STRING="action=settings&$query" bash "$CGI" | tail -n +3)
    check "cgi rejects invalid settings $query" test -n "$(jq -r '.error // empty' <<<"$cgi_out")"
done

# Exercise the actual proxy with local auth/config/curl stubs.
cat >"$TMP/auth.sh" <<'EOF'
require_role() {
    [[ "$1" == contributor ]] || exit 1
    if [[ "${TEST_ROLE:-}" != contributor ]]; then
        echo '{"error":"forbidden"}'
        exit 0
    fi
}
EOF
printf '{"clients":[{"name":"kiosk","host":"192.0.2.1","port":8033}]}\n' >"$TMP/config.json"
sed -e "s|source /usr/local/lib/church-monitoring/auth-lib.sh|source \"$TMP/auth.sh\"|" \
    -e "s|CONFIG=\"/etc/church-monitoring/server-config.json\"|CONFIG=\"$TMP/config.json\"|" \
    "$ROOT/server/host-action.cgi" >"$TMP/proxy.cgi"
cat >"$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$CHURCH_MONITORING_STANDBY_DIR/proxy-args"
echo '{"result":"applied","default_minutes":120,"current_applied":false}'
EOF
chmod +x "$TMP/bin/curl"
proxy_out=$(PATH="$TMP/bin:$PATH" TEST_ROLE=contributor QUERY_STRING='host=kiosk&action=standby-timer&delta=settings&minutes=120&apply=0' bash "$TMP/proxy.cgi" | tail -n +3)
check "proxy contributor can save" test "$(jq -r .result <<<"$proxy_out")" = applied
check "proxy preserves certificate name connect-to" grep -q 'kiosk:8033:192.0.2.1:8033' "$TMP/run/proxy-args"
check "proxy forwards validated timeout and apply" grep -q 'https://kiosk:8033/cgi-bin/standby-timer.cgi?action=settings&minutes=120&apply=0' "$TMP/run/proxy-args"
rm "$TMP/run/proxy-args"
proxy_out=$(PATH="$TMP/bin:$PATH" TEST_ROLE=contributor QUERY_STRING='host=kiosk&action=standby-timer&delta=settings&minutes=0&apply=0' bash "$TMP/proxy.cgi" | tail -n +3)
check "proxy rejects zero before contacting client" test -n "$(jq -r '.error // empty' <<<"$proxy_out")"
check "invalid proxy settings make no request" test ! -e "$TMP/run/proxy-args"
proxy_out=$(PATH="$TMP/bin:$PATH" TEST_ROLE=user QUERY_STRING='host=kiosk&action=standby-timer&delta=settings&minutes=120&apply=0' bash "$TMP/proxy.cgi")
check "read-only role denied before proxy headers or request" test "$(jq -r .error <<<"$proxy_out")" = forbidden
check "read-only role makes no request" test ! -e "$TMP/run/proxy-args"
printf '#!/usr/bin/env bash\nexit 1\n' > "$TMP/collector"
cgi_out=$(PATH="$TMP/bin:$PATH" QUERY_STRING="action=settings&minutes=150&apply=0" bash "$CGI" | tail -n +3)
check "collector failure does not misreport a persisted save" test "$(jq -r .result <<<"$cgi_out")" = applied
check "save persists despite optional collector failure" test "$(cat "$STANDBY_DEFAULT_FILE")" = 150

echo
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
