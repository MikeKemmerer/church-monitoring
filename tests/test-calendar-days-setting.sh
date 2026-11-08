#!/usr/bin/env bash
# Checks the "days" calendar setting in the sudo helper (with stubbed systemctl/getent) and the
# client and server CGIs' validation (which stops before sudo or any network call).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$HERE/../client/church-monitoring-set-calendar-settings"
CLIENT_CGI="$HERE/../client/calendar-settings.cgi"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/home"

cat > "$TMP/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == "show" ]] && echo "kioskuser"
exit 0
EOF
cat > "$TMP/bin/getent" <<EOF
#!/usr/bin/env bash
echo "kioskuser:x:1000:1000::$TMP/home:/bin/bash"
EOF
chmod +x "$TMP/bin/systemctl" "$TMP/bin/getent"

CONF="$TMP/local.conf"
PASS=0
check() {
    if [[ "$2" == "$3" ]]; then PASS=$((PASS + 1)); else echo "FAIL: $1 (expected '$2', got '$3')" >&2; exit 1; fi
}
run_helper() { PATH="$TMP/bin:$PATH" VIDEOKIOSK2_CONFIG="$CONF" bash "$HELPER" "$@" >/dev/null; }
url() { sed -n 's/^BROWSER_URL="\(.*\)"$/\1/p' "$CONF"; }

echo 'BROWSER_URL="http://localhost:8000/?theme=light&speed=12#frag"' > "$CONF"

run_helper - - - - 7
check "days added, others kept, fragment kept" "http://localhost:8000/?theme=light&speed=12&days=7#frag" "$(url)"
run_helper - - - - 14
check "days replaced" "http://localhost:8000/?theme=light&speed=12&days=14#frag" "$(url)"
if run_helper not-a-theme - - - 5 2>/dev/null; then check "invalid theme rejected" rejected accepted; fi
run_helper light - - - -
check "days untouched when '-'" "http://localhost:8000/?speed=12&days=14&theme=light#frag" "$(url)"
run_helper - - 18 -
check "four-argument callers still work" "http://localhost:8000/?days=14&theme=light&speed=18#frag" "$(url)"

BEFORE="$(url)"
for bad in 0 -1 abc 5.5 1000 ""; do
    if run_helper - - - - "$bad" 2>/dev/null; then check "days=$bad rejected" rejected accepted; fi
    check "config untouched after days=$bad" "$BEFORE" "$(url)"
done

cgi() { QUERY_STRING="$1" bash "$CLIENT_CGI" | tail -n 1; }
check "client CGI rejects bad days" '{"error":"invalid days (must be a whole number from 1 to 999)"}' "$(cgi 'days=abc')"
check "client CGI rejects out-of-range days" '{"error":"invalid days (must be a whole number from 1 to 999)"}' "$(cgi 'days=0')"
check "client CGI wants some setting" '{"error":"no settings provided - use theme, font, speed, margins, and/or days"}' "$(cgi '')"

echo "OK ($PASS checks)"
