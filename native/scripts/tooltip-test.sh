#!/bin/zsh
# Regression test for the tooltip of the menu bar item.
#
# The window of a menu bar item belongs to the app, but the pointer over the
# menu bar never reaches it: the system handles the menu bar. The tooltip of
# the system therefore stays on the screen when the pointer moves to another
# application, and every refresh of the menu bar item armed it again, which let
# it jump to the current pointer position.
#
# The test runs the app with an isolated profile, puts the pointer on the icon
# and takes it away again. The app logs every change of the tooltip, so the
# test reads the log:
#   - the tooltip appears while the pointer rests on the icon,
#   - the tooltip disappears when the pointer leaves the icon,
#   - the tooltip does not come back when the menu bar item is refreshed (the
#     refresh runs every 10 s).
#
# The pointer of the user is moved for the run and put back afterwards. The
# test never opens a break and never covers a display: it only uses the menu
# bar. The icon of the app always sits in the menu bar of the display of the
# user, so the isolated run asks for the main display explicitly
# (CAESURA_NATIVE_TEST_MAIN_DISPLAY) — the app logs it.
#
# Usage: native/scripts/tooltip-test.sh [app-bundle] [--keep]

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP="$ROOT/native/dist/Caesura.app"
KEEP=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep) KEEP=1 ;;
    *) APP="$1" ;;
  esac
  shift
done

if [[ ! -x "$APP/Contents/MacOS/Caesura" ]]; then
  echo "Caesura.app is not built — run native/scripts/package-app.sh first" >&2
  exit 1
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/caesura-tooltip-XXXXXX")"
# Ownership marker for clean.sh: the canonical repo root proves this temporary
# directory belongs to this project's test runs.
printf '%s\n' "$ROOT" > "$WORK/.caesura-project"
FAILURES=0
CHECKS=0

cleanup() {
  stop_app
  if [[ $KEEP -eq 1 ]]; then
    echo "kept: $WORK"
  else
    rm -rf "$WORK"
  fi
}
trap cleanup EXIT

APP_PID=""
stop_app() {
  if [[ -n "$APP_PID" ]] && kill -0 "$APP_PID" 2>/dev/null; then
    kill "$APP_PID" 2>/dev/null || true
    wait "$APP_PID" 2>/dev/null || true
  fi
  APP_PID=""
}

check() {
  local label="$1"; shift
  CHECKS=$((CHECKS + 1))
  if "$@"; then
    echo "  PASS  $label"
  else
    echo "  FAIL  $label"
    FAILURES=$((FAILURES + 1))
  fi
}

# The helper that moves the pointer: it is built from the source of the
# repository, so the test never depends on a tool of the system.
MOVER="$WORK/mouse-move"
if ! swiftc -O -o "$MOVER" "$ROOT/native/scripts/mouse-move.swift" >/dev/null 2>&1; then
  echo "the pointer helper could not be built" >&2
  exit 1
fi

make_profile() {
  local dir="$1"
  mkdir -p "$dir"
  cat > "$dir/config.json" <<'JSON'
{
  "microbreak": true,
  "break": true,
  "microbreakDuration": 20000,
  "microbreakInterval": 600000,
  "breakDuration": 20000,
  "breakInterval": 2,
  "microbreakNotification": false,
  "breakNotification": false,
  "naturalBreaks": false,
  "monitorDnd": false,
  "silentNotifications": true,
  "notifyNewVersion": false,
  "checkNewVersion": false,
  "disableAppUpdateFeatures": true,
  "isFirstRun": false,
  "ideas": false,
  "breakHealthMode": false,
  "showTrayIcon": true,
  "language": "en",
  "openAtLogin": false,
  "_migratedOpenAtLogin": true
}
JSON
}

# The frame of the menu bar item, as the app logged it:
# "the menu bar item is at (x, y, width, height)". The frame of an icon that is
# not placed yet has no height and is ignored.
read_anchor() {
  grep -o "the menu bar item is at ([0-9.]*, [0-9.]*, [0-9.]*, [0-9.]*)" "$1" 2>/dev/null |
    sed -e 's/.*(//' -e 's/)//' -e 's/, / /g' |
    awk '$4 > 0 { print }' | tail -1
}

count_lines() {
  local count
  count=$(grep -c "$1" "$2" 2>/dev/null) || count=0
  echo "${count:-0}"
}

DATA="$WORK/profile"
make_profile "$DATA"
LOG="$DATA/caesura-native.log"
: > "$LOG"

echo "== work directory: $WORK"
echo "== app: $APP"

env CAESURA_NATIVE_TEST_MAIN_DISPLAY=1 "$APP/Contents/MacOS/Caesura" --data-dir "$DATA" \
  > "$WORK/stdout.log" 2>&1 &
APP_PID=$!

# The app needs a moment to place its icon in the menu bar.
ANCHOR=""
for _ in {1..40}; do
  ANCHOR="$(read_anchor "$LOG")"
  [[ -n "$ANCHOR" ]] && break
  sleep 0.5
done

if [[ -z "$ANCHOR" ]]; then
  echo "  FAIL  the app did not report the place of its menu bar item"
  echo "        (log: $LOG)"
  exit 1
fi
echo "== menu bar item: $ANCHOR"

# The frame of the icon is in the coordinate system of the screen with its
# origin in the bottom left corner; the pointer works with the origin in the
# top left corner.
SCREEN_HEIGHT="$("$MOVER" --screen)"
ICON_X=$(echo "$ANCHOR" | cut -d' ' -f1)
ICON_Y=$(echo "$ANCHOR" | cut -d' ' -f2)
ICON_W=$(echo "$ANCHOR" | cut -d' ' -f3)
ICON_H=$(echo "$ANCHOR" | cut -d' ' -f4)
TARGET_X=$(awk -v x="$ICON_X" -v w="$ICON_W" 'BEGIN {print int(x + w / 2)}')
TARGET_Y=$(awk -v y="$ICON_Y" -v h="$ICON_H" -v s="$SCREEN_HEIGHT" 'BEGIN {print int(s - y - h / 2)}')
echo "== pointer target: $TARGET_X,$TARGET_Y"

# The pointer of the user goes back to the place it was before the test.
POINTER_BEFORE="$("$MOVER" --print)"
restore_pointer() {
  [[ -n "$POINTER_BEFORE" ]] && "$MOVER" $POINTER_BEFORE >/dev/null 2>&1
}
trap 'restore_pointer; cleanup' EXIT

echo
echo "== the tooltip follows the pointer =="
"$MOVER" "$TARGET_X" "$TARGET_Y" >/dev/null
SHOWN=0
for _ in {1..20}; do
  SHOWN="$(count_lines "the menu bar tooltip is shown" "$LOG")"
  [[ "$SHOWN" -gt 0 ]] && break
  sleep 0.25
done
check "the tooltip appears while the pointer rests on the icon" test "$SHOWN" -gt 0

HIDDEN_BEFORE="$(count_lines "the menu bar tooltip is hidden" "$LOG")"
"$MOVER" 200 400 >/dev/null
HIDDEN=0
for _ in {1..20}; do
  HIDDEN="$(count_lines "the menu bar tooltip is hidden" "$LOG")"
  [[ "$HIDDEN" -gt "$HIDDEN_BEFORE" ]] && break
  sleep 0.25
done
check "the tooltip disappears when the pointer leaves the icon" test "$HIDDEN" -gt "$HIDDEN_BEFORE"

echo
echo "== the refresh of the menu bar item does not arm the tooltip again =="
SHOWN_BEFORE="$(count_lines "the menu bar tooltip is shown" "$LOG")"
sleep 12
SHOWN_AFTER="$(count_lines "the menu bar tooltip is shown" "$LOG")"
check "the tooltip stays away while the pointer is elsewhere" test "$SHOWN_AFTER" -eq "$SHOWN_BEFORE"

mkdir -p "$ROOT/native/verification/logs"
cp "$LOG" "$ROOT/native/verification/logs/tooltip-test.log" 2>/dev/null || true

echo
echo "== summary =="
echo "checks: $CHECKS, failures: $FAILURES"
if [[ $CHECKS -eq 0 ]]; then
  echo "TOOLTIP TEST FAILED (no check ran)"
  exit 1
fi
if [[ $FAILURES -gt 0 ]]; then
  echo "TOOLTIP TEST FAILED"
  exit 1
fi
echo "TOOLTIP TEST PASSED"
