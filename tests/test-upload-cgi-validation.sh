#!/usr/bin/env bash
# Validation-path check for client/upload-calendar-image.cgi (stops before the sudo helper,
# which is not installed in a dev checkout, so a valid request ends at "helper not installed").
set -uo pipefail
CGI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../client/upload-calendar-image.cgi"
B64='iVBORw0KGgo='

run() {
    local body="$1"
    printf '%s' "$body" | REQUEST_METHOD=POST CONTENT_LENGTH=${#body} bash "$CGI" | tail -n 1 | jq -r '.error // .result'
}
expect() {
    local desc="$1" want="$2" got="$3"
    if [[ "$got" == *"$want"* ]]; then echo "ok   $desc"; else echo "FAIL $desc: wanted '$want', got '$got'"; exit 1; fi
}

expect "no mode rejected" "mode must be" "$(run '{"filename":"2099-12-31 A.png","data_base64":"'$B64'"}')"
expect "persistent needs 2099 name" "2099" "$(run '{"filename":"2026-12-31 A.png","data_base64":"'$B64'","mode":"persistent"}')"
expect "persistent accepted" "helper not installed" "$(run '{"filename":"2099-12-31 A.png","data_base64":"'$B64'","mode":"persistent"}')"
expect "scheduled needs end date" "end date" "$(run '{"filename":"2026-12-20 A.png","data_base64":"'$B64'","mode":"scheduled"}')"
expect "scheduled name/date mismatch" "must match" "$(run '{"filename":"2026-12-21 A.png","data_base64":"'$B64'","mode":"scheduled","remove_after":"2026-12-20"}')"
expect "marker without flag rejected" "auto-archive marker" "$(run '{"filename":"2026-12-20 A [auto-archive].png","data_base64":"'$B64'","mode":"scheduled","remove_after":"2026-12-20"}')"
expect "flag without marker rejected" "auto-archive marker" "$(run '{"filename":"2026-12-20 A.png","data_base64":"'$B64'","mode":"scheduled","remove_after":"2026-12-20","auto_archive":true}')"
expect "scheduled accepted" "helper not installed" "$(run '{"filename":"2026-12-20 A [auto-archive].png","data_base64":"'$B64'","mode":"scheduled","remove_after":"2026-12-20","show_from":"2026-12-10","auto_archive":true}')"
expect "bad date rejected" "YYYY-MM-DD" "$(run '{"filename":"2026-12-20 A.png","data_base64":"'$B64'","mode":"scheduled","remove_after":"2026-12-20","show_from":"soon"}')"
echo "all upload CGI validation checks passed"
