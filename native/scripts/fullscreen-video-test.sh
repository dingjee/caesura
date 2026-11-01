#!/bin/zsh
# Regression test for the pause of a video that plays in fullscreen.
#
# A break has to pause the video of the application that plays it in
# fullscreen and play it again when the break ends. The app reads the playback
# of the target over the Accessibility interface and presses its play/pause
# control.
#
# macOS only lets an application that is trusted for accessibility read the
# controls of another application. The test needs that permission (the
# terminal that runs it has to be trusted); without it the check fails and
# says so.
#
# The test takes the focus for a moment (the stand-in has to be the
# application in front) and the break covers the display of the user.
#
# DISTURBANCE GATE — this test is loud by nature: it puts a fullscreen
# stand-in on the MAIN display, steals the focus and drives a real break. It
# is therefore disabled by default and only runs when BOTH are true:
#   - CAESURA_FULLSCREEN_VIDEO_TEST=1 is set, and
#   - --i-will-take-the-focus is passed on the command line.
# Everything else prints the notice below and stops without touching anything.
#
# Usage: CAESURA_FULLSCREEN_VIDEO_TEST=1 native/scripts/fullscreen-video-test.sh \
#          [app-bundle] [--keep] --i-will-take-the-focus

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP="$ROOT/native/dist/Caesura.app"
KEEP=0
GATE_ENV="${CAESURA_FULLSCREEN_VIDEO_TEST:-}"
GATE_FLAG=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep) KEEP=1 ;;
    --i-will-take-the-focus) GATE_FLAG=1 ;;
    *) APP="$1" ;;
  esac
  shift
done

if [[ "$GATE_ENV" != "1" || "$GATE_FLAG" -ne 1 ]]; then
  cat >&2 <<'NOTICE'
fullscreen-video-test.sh is gated: it puts a fullscreen stand-in on the MAIN
display, steals the focus of the user and drives a real break. It only runs
with BOTH:
  CAESURA_FULLSCREEN_VIDEO_TEST=1  and  --i-will-take-the-focus
Nothing was started or touched. Use an isolated profile and a free machine
when you decide to run it.
NOTICE
  exit 0
fi

if [[ ! -x "$APP/Contents/MacOS/Caesura" ]]; then
  echo "Caesura.app is not built — run native/scripts/package-app.sh first" >&2
  exit 1
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/caesura-video-XXXXXX")"
# Ownership marker for clean.sh: the canonical repo root proves this temporary
# directory belongs to this project's test runs.
printf '%s\n' "$ROOT" > "$WORK/.caesura-project"
FAILURES=0
CHECKS=0

cleanup() {
  stop_app
  stop_video
  if [[ $KEEP -eq 1 ]]; then
    echo "kept: $WORK"
  else
    rm -rf "$WORK"
  fi
}
trap cleanup EXIT

APP_PID=""
VIDEO_PID=""
stop_app() {
  if [[ -n "$APP_PID" ]] && kill -0 "$APP_PID" 2>/dev/null; then
    kill "$APP_PID" 2>/dev/null || true
    wait "$APP_PID" 2>/dev/null || true
  fi
  APP_PID=""
}
stop_video() {
  if [[ -n "$VIDEO_PID" ]] && kill -0 "$VIDEO_PID" 2>/dev/null; then
    kill "$VIDEO_PID" 2>/dev/null || true
    wait "$VIDEO_PID" 2>/dev/null || true
  fi
  VIDEO_PID=""
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

VIDEO_APP="$WORK/video-app"
if ! swiftc -O -o "$VIDEO_APP" "$ROOT/native/scripts/video-app.swift" >/dev/null 2>&1; then
  echo "the stand-in for the video could not be built" >&2
  exit 1
fi

make_profile() {
  local dir="$1"
  mkdir -p "$dir"
  cat > "$dir/config.json" <<'JSON'
{
  "microbreak": true,
  "break": true,
  "microbreakDuration": 12000,
  "microbreakInterval": 600000,
  "breakDuration": 12000,
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
  "_migratedOpenAtLogin": true,
  "pauseFullscreenVideo": true
}
JSON
}

count_lines() {
  local count
  count=$(grep -c "$1" "$2" 2>/dev/null) || count=0
  echo "${count:-0}"
}

DATA="$WORK/profile"
make_profile "$DATA"
LOG="$DATA/caesura-native.log"
VIDEO_LOG="$WORK/video.log"
: > "$LOG"
: > "$VIDEO_LOG"

echo "== work directory: $WORK"
echo "== app: $APP"

# The stand-in for the video comes first: it has to be the application in
# front when the break starts.
"$VIDEO_APP" "$VIDEO_LOG" 90 >/dev/null 2>&1 &
VIDEO_PID=$!
sleep 2

env CAESURA_NATIVE_TEST_MAIN_DISPLAY=1 "$APP/Contents/MacOS/Caesura" --data-dir "$DATA" \
  > "$WORK/stdout.log" 2>&1 &
APP_PID=$!
sleep 4

echo
echo "== the break pauses the video =="
"$APP/Contents/MacOS/caesura-cli" --data-dir "$DATA" mini >/dev/null 2>&1
PAUSED=0
for _ in {1..40}; do
  PAUSED="$(count_lines "^paused$" "$VIDEO_LOG")"
  [[ "$PAUSED" -gt 0 ]] && break
  sleep 0.25
done
check "the video is paused while the break is on the screen" test "$PAUSED" -gt 0
check "the app pressed the pause control of the target" \
  grep -q "paused the video of" "$LOG"

echo
echo "== the break plays the video again =="
PLAYING=0
for _ in {1..80}; do
  PLAYING="$(count_lines "^playing$" "$VIDEO_LOG")"
  [[ "$PLAYING" -gt 1 ]] && break
  sleep 0.25
done
check "the video plays again when the break ends" test "$PLAYING" -gt 1
check "the app pressed the play control of the target to resume" \
  grep -q "resumed the video of" "$LOG"

mkdir -p "$ROOT/native/verification/logs"
cp "$LOG" "$ROOT/native/verification/logs/fullscreen-video-test.log" 2>/dev/null || true
cp "$VIDEO_LOG" "$ROOT/native/verification/logs/fullscreen-video-test-video.log" 2>/dev/null || true

echo
echo "== summary =="
echo "checks: $CHECKS, failures: $FAILURES"
if [[ $CHECKS -eq 0 ]]; then
  echo "FULLSCREEN VIDEO TEST FAILED (no check ran)"
  exit 1
fi
if [[ $FAILURES -gt 0 ]]; then
  echo "FULLSCREEN VIDEO TEST FAILED"
  exit 1
fi
echo "FULLSCREEN VIDEO TEST PASSED"
