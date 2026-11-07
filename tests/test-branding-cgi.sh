#!/usr/bin/env bash
# Checks server/branding.cgi defaults, overrides and length limit against a temporary config.
set -uo pipefail
CGI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../server/branding.cgi"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

run() { sed "s#/etc/church-monitoring/server-config.json#$1#" "$CGI" > "$TMP/b.cgi"; bash "$TMP/b.cgi" | tail -n 1; }
expect() {
    local desc="$1" want="$2" got="$3"
    if [[ "$got" == "$want" ]]; then echo "ok   $desc"; else echo "FAIL $desc: wanted '$want', got '$got'"; exit 1; fi
}

DEFAULT='{"title":"Church Monitoring","icon":"📡","organization":""}'
expect "missing config gives defaults" "$DEFAULT" "$(run "$TMP/none.json")"

echo '{"port":8080}' > "$TMP/a.json"
expect "no branding section gives defaults" "$DEFAULT" "$(run "$TMP/a.json")"

echo '{"branding":{"title":"Parish Watch","icon":"⛪","organization":"Example Parish"}}' > "$TMP/b.json"
expect "configured branding is used" '{"title":"Parish Watch","icon":"⛪","organization":"Example Parish"}' "$(run "$TMP/b.json")"

echo '{"branding":{"title":"Only Title"}}' > "$TMP/c.json"
expect "partial branding fills defaults" '{"title":"Only Title","icon":"📡","organization":""}' "$(run "$TMP/c.json")"

echo '{"branding":{"title":"","icon":5,"organization":null}}' > "$TMP/d.json"
expect "empty or non-string values fall back" "$DEFAULT" "$(run "$TMP/d.json")"

LONG=$(printf 'x%.0s' $(seq 1 200))
echo "{\"branding\":{\"title\":\"$LONG\"}}" > "$TMP/e.json"
expect "title is capped at 80 characters" "80" "$(run "$TMP/e.json" | jq -r '.title | length')"

echo "{not json" > "$TMP/f.json"
expect "invalid config gives defaults" "$DEFAULT" "$(run "$TMP/f.json")"
echo "all branding CGI checks passed"
