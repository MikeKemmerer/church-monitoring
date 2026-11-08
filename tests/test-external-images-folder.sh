#!/usr/bin/env bash
# The images folder lives on a share, away from church-calendar's code: helpers, the list CGI and the
# collector must find image_schedule.py through calendar_app_path rather than the images folder's parent.
#   CALENDAR_SRC=/path/to/church-calendar tests/test-external-images-folder.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLIENT="$HERE/../client"
CALENDAR_SRC="${CALENDAR_SRC:-$HERE/../../church-calendar}"
[[ -f "$CALENDAR_SRC/image_schedule.py" ]] || { echo "image_schedule.py not found in $CALENDAR_SRC" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/opt/church-calendar" "$TMP/srv/posters/images"
cp "$CALENDAR_SRC/image_schedule.py" "$TMP/opt/church-calendar/"
printf 'import pathlib, sys\npathlib.Path(__file__).with_name("optimizer-args").write_text(" ".join(sys.argv[1:]))\n' \
    > "$TMP/opt/church-calendar/image_optimizer.py"
IMAGES="$TMP/srv/posters/images"
export CLIENT_CONFIG="$TMP/client-config.json"
printf '{"calendar_images_path":"%s","calendar_app_path":"%s"}' "$IMAGES" "$TMP/opt/church-calendar" > "$CLIENT_CONFIG"

PASS=0
check() {
    if [[ "$2" == "$3" ]]; then PASS=$((PASS + 1)); else echo "FAIL: $1 (expected '$2', got '$3')" >&2; exit 1; fi
}
png() { printf 'iVBORw0KGgo='; }
list_row() { bash "$CLIENT/list-calendar-images.cgi" | tail -n +3 | jq -c --arg f "$1" '.images[] | select(.filename == $f) | {state, show_from, remove_after, auto_archive, stale}'; }

png | "$CLIENT/church-monitoring-write-calendar-image" "$IMAGES" "2099-12-31 Banner.png" --mode persistent >/dev/null
check "upload applies the schedule through calendar_app_path" persistent \
    "$(python3 "$TMP/opt/church-calendar/image_schedule.py" --images-dir "$IMAGES" --today 2040-01-01 list --read-only | jq -r '.images[0].state')"
check "upload runs the optimizer for the share" "--images-dir $IMAGES" "$(cat "$TMP/opt/church-calendar/optimizer-args")"

mkdir -p "$TMP/opt/church-calendar/images/optimized"
printf 'webp' > "$TMP/opt/church-calendar/images/optimized/2099-12-31 Banner.png.webp"
check "list CGI takes previews from the calendar's own images folder" true \
    "$(bash "$CLIENT/list-calendar-images.cgi" | tail -n +3 | jq '.images[] | select(.filename == "2099-12-31 Banner.png") | .thumbnail | startswith("data:image/webp;base64,")')"

png | "$CLIENT/church-monitoring-write-calendar-image" "$IMAGES" "2026-12-20 Sale [auto-archive].png" \
    --mode scheduled --remove-after 2026-12-20 --show-from 2026-12-10 --auto-archive >/dev/null
check "list CGI merges schedule rows found through calendar_app_path" \
    '{"state":"scheduled","show_from":"2026-12-10","remove_after":"2026-12-20","auto_archive":true,"stale":false}' \
    "$(list_row "2026-12-20 Sale [auto-archive].png" | sed 's/"state":"\(scheduled\|active\|expired\)"/"state":"scheduled"/')"
check "list CGI reports a persistent image" persistent "$(list_row "2099-12-31 Banner.png" | jq -r .state)"
check "list CGI keeps one entry per image" 2 "$(bash "$CLIENT/list-calendar-images.cgi" | tail -n +3 | jq '.images | length')"

mkdir -p "$IMAGES/archive"
"$CLIENT/church-monitoring-archive-calendar-image" "$IMAGES" "2099-12-31 Banner.png" >/dev/null
"$CLIENT/church-monitoring-restore-calendar-image" "$IMAGES" "2099-12-31 Banner.png" --mode scheduled --remove-after 2027-06-01 >/dev/null
check "restore applies dates through calendar_app_path" 2027-06-01 "$(list_row "2099-12-31 Banner.png" | jq -r .remove_after)"

# Without calendar_app_path or a calendar service, the images folder's parent holds no code: list falls back to filenames
printf '{"calendar_images_path":"%s"}' "$IMAGES" > "$CLIENT_CONFIG"
check "list CGI falls back to filename dates when the code folder is unknown" null "$(list_row "2026-12-20 Sale [auto-archive].png" | jq -r .state)"
check "fallback keeps the filename date" 2026-12-20 "$(list_row "2026-12-20 Sale [auto-archive].png" | jq -r .remove_after)"

echo "OK ($PASS checks)"
