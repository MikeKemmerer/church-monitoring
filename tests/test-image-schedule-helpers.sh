#!/usr/bin/env bash
# Exercises the calendar-image sudo helpers against church-calendar's image_schedule.py in a
# throwaway folder. Needs a church-calendar checkout with image_schedule.py:
#   CALENDAR_SRC=/path/to/church-calendar tests/test-image-schedule-helpers.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLIENT="$HERE/../client"
CALENDAR_SRC="${CALENDAR_SRC:-$HERE/../../church-calendar}"
[[ -f "$CALENDAR_SRC/image_schedule.py" ]] || { echo "image_schedule.py not found in $CALENDAR_SRC" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/cal/images"
cp "$CALENDAR_SRC/image_schedule.py" "$TMP/cal/"
IMAGES="$TMP/cal/images"
SCHED=(python3 "$TMP/cal/image_schedule.py" --images-dir "$IMAGES")

PASS=0
check() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        PASS=$((PASS + 1))
    else
        echo "FAIL: $desc (expected '$expected', got '$actual')" >&2
        exit 1
    fi
}
state_of() { "${SCHED[@]}" --today "$2" list --read-only | jq -r --arg f "$1" '.images[] | select(.filename == $f) | .state'; }
png() { printf 'iVBORw0KGgo='; }

SALE="2026-12-20 Sale [auto-archive].png"
FOREVER="2099-12-31 Stewardship.png"

png | "$CLIENT/church-monitoring-write-calendar-image" "$IMAGES" "$SALE" \
    --mode scheduled --remove-after 2026-12-20 --show-from 2026-12-10 --auto-archive >/dev/null
check "scheduled upload hidden before start" scheduled "$(state_of "$SALE" 2026-12-05)"
check "scheduled upload active on start" active "$(state_of "$SALE" 2026-12-10)"
check "scheduled upload active on last day" active "$(state_of "$SALE" 2026-12-20)"
check "scheduled upload expired the day after" expired "$(state_of "$SALE" 2026-12-21)"

png | "$CLIENT/church-monitoring-write-calendar-image" "$IMAGES" "$FOREVER" --mode persistent >/dev/null
check "persistent upload never expires" persistent "$(state_of "$FOREVER" 2040-01-01)"

if png | "$CLIENT/church-monitoring-write-calendar-image" "$IMAGES" "2099-12-31 Bad.png" --mode weird 2>/dev/null; then
    check "invalid mode rejected" rejected accepted
fi
[[ ! -e "$IMAGES/2099-12-31 Bad.png" ]] || check "invalid mode wrote nothing" none written

"$CLIENT/church-monitoring-archive-calendar-image" "$IMAGES" "$SALE" >/dev/null
[[ -f "$IMAGES/archive/$SALE" && ! -e "$IMAGES/$SALE" ]] || check "archive moved the file" moved missing
"$CLIENT/church-monitoring-restore-calendar-image" "$IMAGES" "$SALE" --mode persistent >/dev/null
check "restore starts with the chosen dates, not the old ones" persistent "$(state_of "$SALE" 2030-01-01)"

"$CLIENT/church-monitoring-store-evergreen-image" "$IMAGES" "$FOREVER" >/dev/null
"$CLIENT/church-monitoring-activate-evergreen-image" "$IMAGES" "$FOREVER" \
    --mode scheduled --remove-after 2027-01-01 --auto-archive >/dev/null
check "evergreen activation uses the chosen dates" active "$(state_of "$FOREVER" 2026-12-30)"
"${SCHED[@]}" --today 2027-01-01 sweep
[[ -f "$IMAGES/$FOREVER" ]] || check "image kept on its last day" kept missing
"${SCHED[@]}" --today 2027-01-02 sweep
[[ -f "$IMAGES/archive/$FOREVER" && ! -e "$IMAGES/$FOREVER" ]] || check "image auto-archived the day after" archived missing

mkdir -p "$IMAGES/evergreen"
: > "$IMAGES/evergreen/Rollback.png"
mv "$TMP/cal/image_schedule.py" "$TMP/cal/image_schedule.py.off"
if "$CLIENT/church-monitoring-activate-evergreen-image" "$IMAGES" "Rollback.png" --mode persistent 2>/dev/null; then
    check "activation fails without a schedule module" failed succeeded
fi
[[ -f "$IMAGES/evergreen/Rollback.png" && ! -e "$IMAGES/Rollback.png" ]] || check "failed activation rolled back" rolled-back not-rolled-back

echo "OK ($PASS checks)"
