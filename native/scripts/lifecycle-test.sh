#!/bin/zsh
# Lifecycle regression test for the native Caesura app.
#
# The app runs with an isolated data directory (--data-dir) and the opt-in
# lifecycle runner (CAESURA_LIFECYCLE_TEST). The runner drives the real windows
# of the app: it opens and closes them with the real close path, runs breaks
# (start, postpone, skip, automatic completion) and checks the menu bar item.
# Every step runs in its own run loop turn, so the main autorelease pool is
# drained between the steps — that is where a window that is released twice
# crashes the app.
#
# Everything stays inside a temporary directory: the settings, the log and the
# screenshots of the real installation are never touched, no notification
# permission is requested and the login item is never changed (an isolated run
# skips the login item entirely).
#
# Usage: native/scripts/lifecycle-test.sh [app-bundle] [--keep] [--only <scenario>]
#   app-bundle  path to Caesura.app (default: native/dist/Caesura.app)
#   --keep      keeps the temporary directory for inspection
#   --only      runs a single scenario (windows, windows-zombies,
#               breaks, mixed, tray-restore, break-relayout, break-release,
#               soak-fresh, soak-after-close, quit, duplicate)

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP="$ROOT/native/dist/Caesura.app"
KEEP=0
ONLY=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep) KEEP=1 ;;
    --only) ONLY="$2"; shift ;;
    *) APP="$1" ;;
  esac
  shift
done

if [[ ! -x "$APP/Contents/MacOS/Caesura" ]]; then
  echo "Caesura.app is not built — run native/scripts/package-app.sh first" >&2
  exit 1
fi

SCENARIOS="windows windows-zombies breaks mixed tray-restore break-relayout break-release soak-fresh soak-after-close quit duplicate"
if [[ -n "$ONLY" ]]; then
  case " $SCENARIOS " in
    *" $ONLY "*) ;;
    *)
      echo "unknown scenario '$ONLY' (known: $SCENARIOS)" >&2
      exit 2
      ;;
  esac
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/caesura-lifecycle-XXXXXX")"
# Ownership marker for clean.sh: the canonical repo root proves this temporary
# directory belongs to this project's test runs (a name prefix alone is not proof).
printf '%s\n' "$ROOT" > "$WORK/.caesura-project"
EVIDENCE="$ROOT/native/evidence"
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

# The profile mirrors the settings of the crashing runs: the tray icon is on, the
# break windows are blurred and the audio runs at volume 0 (the path is
# exercised, nothing is audible). The login item setting is off on purpose: an
# isolated run must not touch the login item of the real installation.
#
# The break windows and the windows of the app are placed on the secondary display
# (`allScreens: false`, `screen: "1"`, `breakContentScreen: "1"`), so that the
# display of the user is never covered. The app places its own windows there
# without activating the app; the runner fails when no secondary display is
# attached.
make_profile() {
  local dir="$1"
  mkdir -p "$dir"
  cat > "$dir/config.json" <<'JSON'
{
  "microbreak": true,
  "break": true,
  "microbreakDuration": 8000,
  "microbreakInterval": 900000,
  "breakDuration": 300000,
  "breakInterval": 3,
  "microbreakNotification": false,
  "breakNotification": false,
  "allScreens": false,
  "screen": "1",
  "breakContentScreen": "1",
  "naturalBreaks": true,
  "monitorDnd": true,
  "appExclusions": [],
  "naturalBreaksCheckInterval": 2000,
  "monitorDndCheckInterval": 2000,
  "appExclusionsCheckInterval": 2000,
  "blurredBackground": true,
  "miniBreakAudio": "crystal-glass",
  "longBreakAudio": "crystal-glass",
  "miniBreakStartSound": "silence",
  "volume": 0,
  "silentNotifications": false,
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

# run_scenario <name> <steps> <timeout-seconds> <expected-log-marker> [env…]
run_scenario() {
  local name="$1" steps="$2" timeout="$3" marker="$4"; shift 4
  if [[ -n "$ONLY" && "$ONLY" != "$name" ]]; then return; fi
  local dir="$WORK/$name"
  make_profile "$dir"
  local log="$dir/caesura-native.log"
  local out="$dir/stdout.log"
  : > "$log"

  env "$@" CAESURA_LIFECYCLE_TEST="$steps" \
    "$APP/Contents/MacOS/Caesura" --data-dir "$dir" > "$out" 2>&1 &
  APP_PID=$!

  local waited=0
  while kill -0 "$APP_PID" 2>/dev/null; do
    sleep 0.2
    waited=$((waited + 1))
    if [[ $waited -gt $((timeout * 5)) ]]; then
      echo "  FAIL  $name: the app did not finish within ${timeout}s"
      kill "$APP_PID" 2>/dev/null || true
      wait "$APP_PID" 2>/dev/null || true
      APP_PID=""
      FAILURES=$((FAILURES + 1))
      CHECKS=$((CHECKS + 1))
      return
    fi
  done
  wait "$APP_PID"
  local code=$?
  APP_PID=""

  if [[ $code -ge 128 ]]; then
    echo "  FAIL  $name: the app crashed with signal $((code - 128)) (exit $code)"
    tail -5 "$out" | sed 's/^/        /'
    FAILURES=$((FAILURES + 1))
    CHECKS=$((CHECKS + 1))
    return
  fi
  check "$name: the app exited cleanly" test "$code" -eq 0
  check "$name: the run reached its end" grep -q "$marker" "$log"
  check "$name: no over-released object" \
    bash -c "! grep -q 'message sent to deallocated instance' '$out'"
  check "$name: the app terminated on request" grep -q "Caesura: terminated" "$log"

  # The evidence of every run is kept in the ignored evidence directory.
  mkdir -p "$EVIDENCE/$name"
  cp "$log" "$out" "$EVIDENCE/$name/" 2>/dev/null || true
}

echo "== work directory: $WORK"
echo "== app: $APP"

echo
echo "== scenario: window open/close cycles =="
run_scenario windows \
  "repeat:5:preferences,preferences-close,released:preferences,tray" \
  120 "lifecycle test finished successfully"

echo
echo "== scenario: window open/close cycles (NSZombies) =="
run_scenario windows-zombies \
  "repeat:5:preferences,preferences-close,released:preferences,tray" \
  120 "lifecycle test finished successfully" NSZombieEnabled=YES

echo
echo "== scenario: breaks (start, postpone, skip, automatic completion) =="
run_scenario breaks \
  "repeat:2:mini,wait:3,postpone,wait:2,mini,wait:3,skip,wait:2,mini,wait:12,tray" \
  180 "lifecycle test finished successfully"

echo
echo "== scenario: breaks and windows together =="
run_scenario mixed \
  "repeat:3:mini,wait:12,preferences,preferences-close,released:preferences,mini,wait:3,postpone,wait:2,tray" \
  240 "lifecycle test finished successfully"

echo
echo "== scenario: menu bar item restoration (hide, refresh, idle relayout, visible again) =="
run_scenario tray-restore \
  "tray,tray-hide,refresh,tray,tray-hide,relayout,tray" \
  120 "lifecycle test finished successfully"

echo
echo "== scenario: break windows relayout and release =="
run_scenario break-relayout \
  "mini,wait:1,break-visible,relayout,released:break-0,break-visible,skip,released:break-0,tray" \
  180 "lifecycle test finished successfully"

echo
echo "== scenario: break window release after skip =="
run_scenario break-release \
  "mini,wait:1,skip,released:break-0,tray" \
  120 "lifecycle test finished successfully"

echo
echo "== scenario: fresh idle soak, no window is ever opened =="
run_scenario soak-fresh "wait:180,tray" 300 "lifecycle test finished successfully"

echo
echo "== scenario: idle soak after window and break cycles =="
run_scenario soak-after-close \
  "repeat:3:preferences,preferences-close,released:preferences,mini,wait:12,tray;wait:180,tray" \
  400 "lifecycle test finished successfully"

echo
echo "== scenario: quitting =="
run_scenario quit "tray,quit" 120 "lifecycle test: quitting"

echo
echo "== scenario: a second GUI instance must not start a duplicate =="
if [[ -z "$ONLY" || "$ONLY" == "duplicate" ]]; then
  DATA7="$WORK/duplicate"
  make_profile "$DATA7"
  env "$APP/Contents/MacOS/Caesura" --data-dir "$DATA7" > "$WORK/duplicate-first.log" 2>&1 &
  APP_PID=$!
  sleep 2
  env "$APP/Contents/MacOS/Caesura" --data-dir "$DATA7" > "$WORK/duplicate-second.log" 2>&1 &
  SECOND_PID=$!
  sleep 3
  CHECKS=$((CHECKS + 1))
  if kill -0 "$SECOND_PID" 2>/dev/null; then
    echo "  FAIL  the second instance is still running"
    FAILURES=$((FAILURES + 1))
    kill "$SECOND_PID" 2>/dev/null || true
    wait "$SECOND_PID" 2>/dev/null || true
  else
    wait "$SECOND_PID" 2>/dev/null
    SECOND_CODE=$?
    check "the second instance exited with 0" test "$SECOND_CODE" -eq 0
  fi
  check "the first instance is still running" kill -0 "$APP_PID"
  stop_app
fi

echo
echo "== summary =="
echo "checks: $CHECKS, failures: $FAILURES"
if [[ $CHECKS -eq 0 ]]; then
  echo "LIFECYCLE TEST FAILED (no scenario ran)"
  exit 1
fi
if [[ $FAILURES -gt 0 ]]; then
  echo "LIFECYCLE TEST FAILED"
  exit 1
fi
echo "LIFECYCLE TEST PASSED"
