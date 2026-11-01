#!/bin/zsh
# Runtime smoke test for the native Caesura.app.
#
# Everything the app touches lives inside a temporary directory: the app is started
# with `--data-dir <temp>` so the user's real settings, logs and login item are never
# touched. No notification permission is requested (the temporary configuration
# switches silent notifications on), no login item is changed and nothing is
# installed into /Applications.
#
# The script asserts the expected log transitions of every CLI flow instead of only
# running the commands, and copies the screenshots and logs into
# native/verification/ so the evidence is durable.
#
# Usage: native/scripts/smoke-test.sh [--keep] [app-bundle]
#   --keep       keeps the temporary directory (for inspection)
#   [app-bundle] the bundle to test (default: native/dist/Caesura.app); a test
#                build staged outside native/dist can be verified in isolation

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP="$ROOT/native/dist/Caesura.app"
EVIDENCE="$ROOT/native/verification"
KEEP=0
for arg in "$@"; do
  case "$arg" in
    --keep) KEEP=1 ;;
    *) APP="$arg" ;;
  esac
done
CLI="$APP/Contents/MacOS/caesura-cli"

if [[ ! -x "$APP/Contents/MacOS/Caesura" ]]; then
  echo "Caesura.app is not built — run native/scripts/package-app.sh first" >&2
  exit 1
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/caesura-smoke-XXXXXX")"
# Ownership marker for clean.sh: the canonical repo root proves this temporary
# directory belongs to this project's test runs (a name prefix alone is not proof).
printf '%s\n' "$ROOT" > "$WORK/.caesura-project"
SHOTS="$WORK/shots"
mkdir -p "$SHOTS"
mkdir -p "$EVIDENCE/screenshots" "$EVIDENCE/logs"
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

stop_app() {
  if [[ -n "${APP_PID:-}" ]] && kill -0 "$APP_PID" 2>/dev/null; then
    kill "$APP_PID" 2>/dev/null || true
    wait "$APP_PID" 2>/dev/null || true
  fi
  APP_PID=""
}

# --- assertions ---------------------------------------------------------------

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

log_contains() {
  grep -q -- "$1" "$2"
}

log_lacks() {
  ! grep -q -- "$1" "$2"
}

# --- app lifecycle ------------------------------------------------------------

start_app() {
  local data_dir="$1"; shift
  LOG="$data_dir/caesura-native.log"
  : > "$LOG"
  env "$@" "$APP/Contents/MacOS/Caesura" --data-dir "$data_dir" &
  APP_PID=$!
  local waited=0
  while [[ $waited -lt 80 ]]; do
    if grep -q "initializing" "$LOG" 2>/dev/null; then break; fi
    sleep 0.1
    waited=$((waited + 1))
  done
  if ! kill -0 "$APP_PID" 2>/dev/null; then
    echo "the app exited during startup" >&2
    cat "$LOG" >&2
    exit 1
  fi
}

write_config() {
  local data_dir="$1"; shift
  mkdir -p "$data_dir"
  cat > "$data_dir/config.json"
}

patch_config() {
  python3 - "$1" "$2" <<'PY'
import json, sys
path = sys.argv[1]
patch = json.loads(sys.argv[2])
data = json.load(open(path))
data.update(patch)
json.dump(data, open(path, "w"), indent=2)
PY
}

# A configuration with long schedule intervals, so that only explicitly driven
# breaks happen during the test. The break lasts 20 s: the postponable window is
# 30 % = 6 s, which makes the allowed and the refused cases unambiguous.
BASE_CONFIG='{
  "microbreak": true,
  "break": true,
  "microbreakDuration": 20000,
  "microbreakInterval": 600000,
  "breakDuration": 20000,
  "breakInterval": 2,
  "microbreakNotification": false,
  "breakNotification": false,
  "allScreens": false,
  "screen": "1",
  "breakContentScreen": "1",
  "naturalBreaks": false,
  "monitorDnd": false,
  "silentNotifications": true,
  "notifyNewVersion": false,
  "checkNewVersion": false,
  "disableAppUpdateFeatures": true,
  "isFirstRun": false,
  "ideas": true,
  "breakHealthMode": false,
  "showTrayIcon": true,
  "language": "en",
  "openAtLogin": false,
  "_migratedOpenAtLogin": true
}'

echo "== work directory: $WORK"

# Preflight: the number of attached displays decides how many break windows the app
# creates. The count is only reported here — the assertions read the number from
# the log of the app itself, so they hold with one or with several displays.
DISPLAYS=$(system_profiler SPDisplaysDataType 2>/dev/null | grep -c "Display Type:")
echo "== displays attached: $DISPLAYS"

# ==============================================================================
echo
echo "== profile 1: mini/long/postpone/skip/pause/resume/toggle/reset =="
# ==============================================================================
DATA1="$WORK/data1"
printf '%s' "$BASE_CONFIG" | write_config "$DATA1"
start_app "$DATA1" CAESURA_SHOTS_DIR="$SHOTS"
sleep 1

echo "-- local CLI commands"
check "cli version" test "$("$CLI" --data-dir "$DATA1" version)" = "Caesura version 1.22.1"
check "cli help lists the commands" "$CLI" --data-dir "$DATA1" help | grep -q "caesura preferences"

echo "-- mini break"
"$CLI" --data-dir "$DATA1" mini
sleep 2
check "mini break started" log_contains "starting Mini break" "$LOG"
check "break window shown" log_contains "showing window" "$LOG"

echo "-- postpone inside the postponable window (30% of 20s = 6s)"
"$CLI" --data-dir "$DATA1" postpone
sleep 1
check "mini break postponed" log_contains "postponing Mini break" "$LOG"

echo "-- skip outside the postponable window"
"$CLI" --data-dir "$DATA1" mini
sleep 8
"$CLI" --data-dir "$DATA1" skip
sleep 1
check "mini break skipped" log_contains "finishing Mini break" "$LOG"

echo "-- long break with a custom title"
"$CLI" --data-dir "$DATA1" long --title "Smoke test long break" --text "Native runtime evidence"
sleep 2
check "long break started" log_contains "starting Long break" "$LOG"

echo "-- postpone is rejected after the postponable window"
sleep 6
"$CLI" --data-dir "$DATA1" postpone
sleep 1
check "postpone refused after the window" log_contains "cannot postpone break (source: cli)" "$LOG"

echo "-- skip ends the long break"
"$CLI" --data-dir "$DATA1" skip
sleep 1
check "long break skipped" log_contains "finishing Long break" "$LOG"

echo "-- finish is refused while the countdown runs"
"$CLI" --data-dir "$DATA1" mini
sleep 2
"$CLI" --data-dir "$DATA1" finish
sleep 1
check "finish refused without manual finish mode" \
  log_contains "break is not waiting for manual finish" "$LOG"

echo "-- pause / resume / toggle / reset"
"$CLI" --data-dir "$DATA1" pause
sleep 1
check "breaks paused" log_contains "pausing breaks for" "$LOG"
"$CLI" --data-dir "$DATA1" resume
sleep 1
check "breaks resumed" log_contains "resuming breaks" "$LOG"
"$CLI" --data-dir "$DATA1" toggle
sleep 1
check "toggle paused" log_contains "pausing breaks for" "$LOG"
"$CLI" --data-dir "$DATA1" toggle
sleep 1
check "toggle resumed" log_contains "resuming breaks" "$LOG"
"$CLI" --data-dir "$DATA1" reset
sleep 1
check "breaks reset" log_contains "resetting breaks" "$LOG"

echo "-- preferences window opens"
"$CLI" --data-dir "$DATA1" preferences
sleep 3
check "preferences window shown" log_contains "captured window shot" "$LOG"
# The app captures its own windows (they are on the secondary display, the display
# of the user is never captured).
check "own window capture of the preferences" \
  test -n "$(ls "$SHOTS" 2>/dev/null | grep '^preferences-' | head -1)"

echo "-- invalid input is rejected"
set +e
INVALID_OUT="$("$CLI" --data-dir "$DATA1" not-a-command 2>&1)"
INVALID_CODE=$?
set -e
check "invalid command exits with an error" test "$INVALID_CODE" -ne 0
check "invalid command prints a message" test -n "$INVALID_OUT"

cp "$LOG" "$EVIDENCE/logs/profile1-cli-flows.log"
stop_app

# ==============================================================================
echo
echo "== profile 2: strict mode =="
# ==============================================================================
DATA2="$WORK/data2"
printf '%s' "$BASE_CONFIG" | write_config "$DATA2"
patch_config "$DATA2/config.json" '{"microbreakStrictMode": true}'
start_app "$DATA2" CAESURA_SHOTS_DIR="$SHOTS"
sleep 1

echo "-- skip is refused in strict mode"
"$CLI" --data-dir "$DATA2" mini
sleep 3
"$CLI" --data-dir "$DATA2" skip
sleep 1
check "strict mode refuses skip" log_contains "cannot skip break (source: cli)" "$LOG"
check "strict mode keeps the break open" log_lacks "finishing Mini break" "$LOG"

echo "-- the strict break window is captured"
check "strict break window captured" log_contains "mini-break" "$LOG"
cp "$LOG" "$EVIDENCE/logs/profile2-strict-mode.log"
stop_app

# ==============================================================================
echo
echo "== profile 3: manual finish =="
# ==============================================================================
DATA3="$WORK/data3"
printf '%s' "$BASE_CONFIG" | write_config "$DATA3"
patch_config "$DATA3/config.json" '{"miniBreakManualFinish": true, "microbreakDuration": 6000}'
start_app "$DATA3" CAESURA_SHOTS_DIR="$SHOTS"
sleep 1

echo "-- the break waits for a manual finish"
"$CLI" --data-dir "$DATA3" mini
sleep 8
check "manual await phase entered" log_contains "entering manual finish phase" "$LOG"
check "the break is not closed automatically" log_lacks "finishing Mini break" "$LOG"
check "the manual await window is captured" log_contains "manual-await" "$LOG"
# The transition happens exactly once, even with several displays.
TRANSITIONS=$(grep -c "entering manual finish phase" "$LOG")
check "the manual await transition happens exactly once" test "$TRANSITIONS" -eq 1
# Every window with content shows the Finish button. The number of windows depends
# on the attached displays, so it is read from the log of the app itself.
SCREEN_COUNT=$(grep -o "showing window 1 of [0-9]\+" "$LOG" | head -1 | grep -o "[0-9]\+$")
SCREEN_COUNT=${SCREEN_COUNT:-1}
FINISH_SCREENS=$(grep -c "captured window shot .*manual-await" "$LOG")
check "every display shows the manual await window" test "$FINISH_SCREENS" -eq "$SCREEN_COUNT"
"$CLI" --data-dir "$DATA3" finish
sleep 1
check "manual finish completes the break" log_contains "finishing Mini break" "$LOG"
cp "$LOG" "$EVIDENCE/logs/profile3-manual-finish.log"
stop_app

# ==============================================================================
echo
echo "== profile 4: no welcome window, Chinese language and dark appearance =="
# ==============================================================================
DATA4="$WORK/data4"
printf '%s' "$BASE_CONFIG" | write_config "$DATA4"
patch_config "$DATA4/config.json" '{"isFirstRun": true, "language": "zh-CN", "themeSource": "dark"}'
start_app "$DATA4" CAESURA_SHOTS_DIR="$SHOTS"
sleep 4
# The welcome window is gone: the first run shows the toast under the menu bar
# icon (profile 8) and no window any more.
check "no welcome window is opened on the first run" log_lacks "welcome" "$LOG"
echo "-- a Chinese long break"
"$CLI" --data-dir "$DATA4" long
sleep 2
check "own window capture of the long break" \
  test -n "$(ls "$SHOTS" 2>/dev/null | grep '^long-break-' | head -1)"
cp "$LOG" "$EVIDENCE/logs/profile4-toast-zh-dark.log"
stop_app

# ==============================================================================
echo
echo "== profile 5: light appearance and the clock =="
# ==============================================================================
DATA5="$WORK/data5"
printf '%s' "$BASE_CONFIG" | write_config "$DATA5"
patch_config "$DATA5/config.json" '{"themeSource": "light", "mainColor": "#633738", "miniBreakColor": "#633738", "currentTimeInBreaks": true, "currentTimeInBreaksFormat": "cccc, D, tt"}'
start_app "$DATA5" CAESURA_SHOTS_DIR="$SHOTS"
sleep 4
"$CLI" --data-dir "$DATA5" mini
sleep 2
check "own window capture of the light mini break" \
  test -n "$(ls "$SHOTS" 2>/dev/null | grep '^mini-break-' | head -1)"
cp "$LOG" "$EVIDENCE/logs/profile5-light-clock.log"
stop_app

# ==============================================================================
echo
echo "== profile 6: Snow White theme (foreground contrast) =="
# ==============================================================================
DATA6="$WORK/data6"
printf '%s' "$BASE_CONFIG" | write_config "$DATA6"
patch_config "$DATA6/config.json" '{"mainColor": "#ffffff", "miniBreakColor": "#ffffff"}'
start_app "$DATA6" CAESURA_SHOTS_DIR="$SHOTS"
sleep 1
"$CLI" --data-dir "$DATA6" mini
sleep 2
check "snow white break captured" \
  test -n "$(ls "$SHOTS" 2>/dev/null | grep '^mini-break-' | head -1)"
check "own window capture of the snow white break" \
  test -n "$(ls "$SHOTS" 2>/dev/null | grep 'mini-break' | head -1)"
cp "$LOG" "$EVIDENCE/logs/profile6-snow-white.log"
stop_app

# ==============================================================================
echo
echo "== profile 7: a second GUI instance must not start a duplicate =="
# ==============================================================================
DATA7="$WORK/data7"
printf '%s' "$BASE_CONFIG" | write_config "$DATA7"
start_app "$DATA7"
sleep 1
"$APP/Contents/MacOS/Caesura" --data-dir "$DATA7" &
SECOND_PID=$!
sleep 3
if kill -0 "$SECOND_PID" 2>/dev/null; then
  echo "  FAIL  the second instance is still running"
  FAILURES=$((FAILURES + 1))
  kill "$SECOND_PID" 2>/dev/null || true
else
  echo "  PASS  the second instance exited"
  CHECKS=$((CHECKS + 1))
fi
cp "$LOG" "$EVIDENCE/logs/profile7-single-instance.log"
stop_app

# ==============================================================================
echo
echo "== profile 8: the first-run toast (explicitly on the main display) =="
# ==============================================================================
# The toast hangs under the menu bar icon, which is on the display of the
# user. Showing it therefore needs the explicit opt-in of the main display.
if [[ "${CAESURA_NATIVE_TEST_MAIN_DISPLAY:-0}" == "1" ]]; then
  DATA8="$WORK/data8"
  printf '%s' "$BASE_CONFIG" | write_config "$DATA8"
  patch_config "$DATA8/config.json" '{"isFirstRun": true}'
  start_app "$DATA8" CAESURA_NATIVE_TEST_MAIN_DISPLAY=1 CAESURA_SHOTS_DIR="$SHOTS"
  sleep 3
  check "the first-run toast points at the menu bar icon" \
    log_contains "the first-run toast points at the menu bar icon" "$LOG"
  check "the toast is captured" \
    test -n "$(ls "$SHOTS" 2>/dev/null | grep '^toast-' | head -1)"
  cp "$LOG" "$EVIDENCE/logs/profile8-first-run-toast.log"
  stop_app

else
  echo "  SKIP  first-run toast: main-display opt-in was not provided"
fi

# --- keep the evidence --------------------------------------------------------
cp "$SHOTS"/*.png "$EVIDENCE/screenshots/" 2>/dev/null || true

echo
echo "== summary =="
echo "checks: $CHECKS, failures: $FAILURES"
echo "evidence: $EVIDENCE"
ls -1 "$EVIDENCE/screenshots" 2>/dev/null | sed 's/^/  /'
if [[ $FAILURES -gt 0 ]]; then
  echo "SMOKE TEST FAILED"
  exit 1
fi
echo "SMOKE TEST PASSED"
