#!/bin/zsh
# Regression test for the blurred background of the native break windows.
#
# The break window is a transparent, non-activating overlay. With "blurredBackground"
# enabled it shows the blurred desktop *behind* the break content (legacy
# `vibrancy: 'hud'`). The bug this test guards against: the blurred background was
# drawn over the content, so the idea, the countdown and the buttons disappeared.
#
# Two kinds of evidence, kept strictly apart in the labels:
#   - "screen capture": the real desktop pixels. This is the ONLY proof that the
#     blurred background is applied *behind* the content. `screencapture -R`
#     cannot be used on every host ("could not create image from rect"), so the
#     full screen is captured and the display under test is cut out of the PNG
#     with png-crop.py.
#   - "app window capture": the render of the app's own window hierarchy into
#     CAESURA_SHOTS_DIR. It proves that the break content is drawn — it can
#     never show the blurred desktop, because that is composited by the window
#     server from the pixels *behind* the window.
#
# The test drives real breaks with the real windows:
#   - a Mini break with the blurred background on, ended by skip,
#   - a Mini break with the blurred background off (the reference for the blur),
#   - a Long break with the blurred background on that ends by itself,
#   - two Mini breaks in a row in ONE app run (a new window per run).
# Every break runs in an isolated profile (temporary settings, no login item, no
# notification permission, no sound).
#
# If the host does not allow a screen capture, the script says so explicitly,
# claims no desktop-pixel proof, and still runs the app-window-capture checks
# with the correct labels. It never requests or changes permissions.
#
# The test needs a display: the secondary display when one is attached, otherwise
# the main display — but only with the explicit opt-in
# CAESURA_NATIVE_TEST_MAIN_DISPLAY=1. There is no silent fallback: without a
# secondary display and without the opt-in the test stops.
#
# Usage: native/scripts/blur-test.sh [app-bundle] [--keep]

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

CLI="$APP/Contents/MacOS/caesura-cli"
CROP="$ROOT/native/scripts/png-crop.py"
STATS="$ROOT/native/scripts/png-metrics.py"

if [[ ! -x "$APP/Contents/MacOS/Caesura" ]]; then
  echo "Caesura.app is not built — run native/scripts/package-app.sh first" >&2
  exit 1
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/caesura-blur-XXXXXX")"
# Ownership marker for clean.sh: the canonical repo root proves this temporary
# directory belongs to this project's test runs (a name prefix alone is not proof).
printf '%s\n' "$ROOT" > "$WORK/.caesura-project"
SHOTS="$WORK/shots"
mkdir -p "$SHOTS"
EVIDENCE="$ROOT/native/verification"
mkdir -p "$EVIDENCE/screenshots" "$EVIDENCE/logs"
FAILURES=0
CHECKS=0
SKIPPED=0
APP_PID=""
CAFFEINATE_PID=""
MARK=0
CONTENT_FLOOR_RATIO=0.005  # the content has to cover 0.5 % of the window area
CONTENT_FLOOR_MIN=4000     # absolute floor of the "content is visible" threshold
INK_FLOOR=200         # absolute floor of the "the ink of the buttons is opaque" threshold
BLUR_DIFF_MIN=2       # the blurred background has to differ more than desktop noise

cleanup() {
  stop_app
  if [[ -n "${CAFFEINATE_PID:-}" ]] && kill -0 "$CAFFEINATE_PID" 2>/dev/null; then
    kill "$CAFFEINATE_PID" 2>/dev/null
  fi
  CAFFEINATE_PID=""
  if [[ $KEEP -eq 1 ]]; then
    echo "kept: $WORK"
  else
    rm -rf "$WORK"
  fi
}
trap cleanup EXIT

stop_app() {
  if [[ -n "${APP_PID:-}" ]] && kill -0 "$APP_PID" 2>/dev/null; then
    kill "$APP_PID" 2>/dev/null
    wait "$APP_PID" 2>/dev/null
  fi
  APP_PID=""
}

check() {
  local label="$1"; shift
  local result=0
  CHECKS=$((CHECKS + 1))
  "$@" || result=$?
  if [[ $result -eq 0 ]]; then
    echo "  PASS  $label"
  else
    echo "  FAIL  $label"
    FAILURES=$((FAILURES + 1))
  fi
  return $result
}

skip_check() {
  local label="$1" reason="$2"
  SKIPPED=$((SKIPPED + 1))
  echo "  SKIP  $label  (skipped: $reason)"
}

run_cli() {
  local command_name="$1" dir="$2"
  local output="$dir/cli-$command_name.log"
  if ! "$CLI" --data-dir "$dir" "$command_name" > "$output" 2>&1; then
    echo "  the cli command '$command_name' failed: $(tr '\n' ' ' < "$output")"
    return 1
  fi
}

bigger_than() {
  python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) > float(sys.argv[2]) else 1)' "${1:-0}" "$2" 2>/dev/null
}

# Only log lines written AFTER the last mark can satisfy a check; a check of
# cycle 2 cannot pass on a matching line of cycle 1.
mark_log() {
  if [[ -n "${LOG:-}" && -f "$LOG" ]]; then
    MARK=$(( $(wc -l < "$LOG") ))
  else
    MARK=0
  fi
}

have_log_since_mark() {
  local pattern="$1"
  [[ -n "${LOG:-}" && -f "$LOG" ]] || return 1
  (( $(wc -l < "$LOG") <= MARK )) && return 1
  tail -n +$((MARK + 1)) "$LOG" | grep -q -- "$pattern"
}

wait_for_log() {
  local pattern="$1" timeout_s="${2:-10}"
  local waited=0
  while (( waited < timeout_s * 10 )); do
    have_log_since_mark "$pattern" && return 0
    sleep 0.1
    waited=$((waited + 1))
  done
  return 1
}

# --- the display under test ----------------------------------------------------

# The frames of every attached display, printed as "(minX, minY, width, height)"
# with a bottom-left origin.
DISPLAY_FRAMES="$(swift -e 'import AppKit; for screen in NSScreen.screens { print(screen.frame) }' 2>/dev/null)"
DISPLAY_COUNT=$(printf '%s\n' "$DISPLAY_FRAMES" | grep -c '(')
echo "== displays attached: $DISPLAY_COUNT"
if (( DISPLAY_COUNT < 1 )); then
  echo "the displays of this host could not be read (swift/NSScreen)." >&2
  exit 1
fi

# The display space: its left edge, its width (the field of view of one
# full-screen capture) and the top of the highest display.
read -r MIN_X SPACE_WIDTH SPACE_HEIGHT <<< "$(printf '%s\n' "$DISPLAY_FRAMES" | awk -F'[(), ]+' '
  BEGIN { minx = 1e18; maxx = -1e18; top = -1e18 }
  {
    mx = $2; my = $3; w = $4; h = $5
    if (mx < minx) minx = mx
    if (mx + w > maxx) maxx = mx + w
    if (my + h > top) top = my + h
  }
  END { printf "%.0f %.0f %.0f", minx, maxx - minx, top }')"
echo "== the display space: left $MIN_X, width $SPACE_WIDTH, top $SPACE_HEIGHT"
echo "== display frames: $(printf '%s\n' "$DISPLAY_FRAMES" | tr '\n' ';')"
if (( SPACE_WIDTH < 1 || SPACE_HEIGHT < 1 )); then
  echo "the display space could not be computed from the frames above." >&2
  exit 1
fi

# --- the app -------------------------------------------------------------------

# A profile of the reported case: a transparent theme (opacity 0), the dark theme
# and a fullscreen break. The sound is muted and the notifications are silent.
# Postponement is off so the cli skip is honored at any point of the break: with
# the default settings the first 30% of a break refuses to skip ("cannot skip
# break (source: cli): skipping is not allowed right now") — that is why the
# skips of the previous run were refused a few seconds into each break.
BASE_CONFIG='{
  "microbreak": true,
  "break": true,
  "microbreakDuration": 60000,
  "microbreakInterval": 600000,
  "breakDuration": 20000,
  "breakInterval": 2,
  "microbreakPostpone": false,
  "breakPostpone": false,
  "microbreakNotification": false,
  "breakNotification": false,
  "allScreens": true,
  "screen": "all",
  "breakContentScreen": "all",
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
  "_migratedOpenAtLogin": true,
  "transparentMode": true,
  "opacity": 0,
  "miniBreakColor": "#1D1F21",
  "mainColor": "#1D1F21",
  "fullscreen": true,
  "volume": 0,
  "miniBreakAudio": "silence",
  "longBreakAudio": "silence",
  "miniBreakStartSound": "silence",
  "longBreakStartSound": "silence",
  "blurredBackground": true
}'

start_app() {
  local data_dir="$1"
  LOG="$data_dir/caesura-native.log"
  : > "$LOG"
  rm -f "$SHOTS"/*.png(N)
  env CAESURA_NATIVE_TEST_MAIN_DISPLAY="$ALLOW_MAIN" \
      CAESURA_SHOTS_DIR="$SHOTS" \
      "$APP/Contents/MacOS/Caesura" --data-dir "$data_dir" &
  APP_PID=$!
  local waited=0
  while (( waited < 100 )); do
    grep -q "initializing" "$LOG" 2>/dev/null && break
    if ! kill -0 "$APP_PID" 2>/dev/null; then
      echo "the app exited during startup:" >&2
      cat "$LOG" >&2
      exit 1
    fi
    sleep 0.1
    waited=$((waited + 1))
  done
  # The frame (bottom-left origin, in points) of the display the app reported.
  local frame x y w h
  frame=$(grep -o "isolated run \(uses the main display\|on the secondary display\) ([^)]*)" "$LOG" | head -1 | sed -E 's/.*\(([^)]*)\).*/\1/')
  if [[ -z "$frame" ]]; then
    echo "the app did not report its display:" >&2
    cat "$LOG" >&2
    exit 1
  fi
  read -r x y w h <<< "$(printf '%s' "$frame" | awk -F'[(), ]+' '{printf "%.0f %.0f %.0f %.0f", $1, $2, $3, $4}')"
  # The frame has to be four numbers: an NSRect that is printed with braces or
  # with a different order would silently produce a broken region. The origin
  # may be negative — a secondary display can sit left of the main one.
  if ! [[ "$x" == (|[-+])<-> && "$y" == (|[-+])<-> && "$w" == <-> && "$h" == <-> ]] \
     || [[ "$w" -le 0 || "$h" -le 0 ]]; then
    echo "the app reported an unusable display frame: '$frame'" >&2
    exit 1
  fi
  CAPTURE_X="$x"                              # top-left origin of the space, in points
  CAPTURE_Y=$(( SPACE_HEIGHT - y - h ))
  CAPTURE_W="$w"
  CAPTURE_H="$h"
  echo "== the app uses the display x=$x y=$y w=$w h=$h (bottom-left origin)"
  echo "== the region under test (top-left origin, points): $CAPTURE_X,$CAPTURE_Y,$CAPTURE_W,$CAPTURE_H"
  mark_log
}

# Captures the full screen and cuts the region of the display under test out of
# the PNG (`screencapture -R` does not work on every host).
capture() {
  local out="$1"
  if (( SCREEN_CAPTURES == 0 )); then
    echo "  (no screen capture: not possible on this host)"
    return 1
  fi
  local full="$WORK/screen-full.png"
  if ! screencapture -x "$full" 2>"$WORK/screencapture.err"; then
    echo "  the screencapture of the full screen failed: $(tr '\n' ' ' < "$WORK/screencapture.err")"
    return 1
  fi
  # A capture that is written but all black is not a desktop picture (the display
  # is asleep or the screen recording is denied): the desktop pixels cannot be
  # checked from then on — the checks are skipped, not failed.
  local full_mean
  full_mean=$("$STATS" "$full" 2>"$WORK/stats.err" \
    | python3 -c 'import json,sys; print(max(json.load(sys.stdin)["mean"]))' 2>/dev/null)
  if [[ -z "${full_mean:-}" ]] || ! bigger_than "$full_mean" 0; then
    SCREEN_CAPTURES=0
    echo "  WARNING: the screen capture is all black — the desktop pixels are not usable on this host"
    echo "  WARNING: the remaining desktop checks are SKIPPED, no desktop proof is claimed"
    return 1
  fi
  local cropped
  if ! cropped=$("$CROP" "$full" "$out" "$CAPTURE_X" "$CAPTURE_Y" "$CAPTURE_W" "$CAPTURE_H" \
        --space "$SPACE_WIDTH" --minx "$MIN_X" 2>&1); then
    echo "  cutting the region out of the full capture failed: $cropped"
    return 1
  fi
  echo "  screen capture: $(printf '%s' "$cropped" | python3 -c 'import json,sys; d=json.load(sys.stdin); print("points", d["points"], "scale", d["scale"], "pixels", d["pixels"])')"
  return 0
}

contrast_of_file() {
  "$STATS" "$1" 2>"$WORK/stats.err" | python3 -c 'import json,sys; print(json.load(sys.stdin)["contrast"])' 2>/dev/null
}

# The opaque dark pixels of a window render: the ink of the break buttons. The
# theme colour carries the transparency alpha, so an ink that is not opaque is
# invisible — the labels of the buttons would be a blank white pill.
ink_of_file() {
  "$STATS" "$1" 2>"$WORK/stats.err" | python3 -c 'import json,sys; print(json.load(sys.stdin)["dark"])' 2>/dev/null
}

# The number of pixels of a window render: the reference for the relative
# content threshold below.
pixels_of_file() {
  "$STATS" "$1" 2>"$WORK/stats.err" | python3 -c 'import json,sys; print(json.load(sys.stdin)["pixels"])' 2>/dev/null
}

# The threshold of "the content is visible": the break content (a centred poem,
# the progress ring and a small pill) has to cover a fraction of the window
# area. An absolute pixel count would only encode the pixel footprint of one
# design — the earlier layout painted a full-width progress bar, the centred
# layout does not — so the floor is relative to the window, with a small
# absolute minimum that still separates "content" from an empty render.
content_threshold() {
  CONTENT_FLOOR_RATIO="$CONTENT_FLOOR_RATIO" CONTENT_FLOOR_MIN="$CONTENT_FLOOR_MIN" \
  python3 -c 'import os, sys
contrast = int(float(sys.argv[1])) if sys.argv[1] else 0
pixels = int(float(sys.argv[2])) if sys.argv[2] else 0
floor = max(int(pixels * float(os.environ["CONTENT_FLOOR_RATIO"])), int(os.environ["CONTENT_FLOOR_MIN"]))
print(max(floor, contrast // 4))' "${1:-}" "${2:-}" 2>/dev/null
}

# Measured statistics of the break screen capture against its baseline. Sets
# BASELINE_CONTRAST, DURING_CONTRAST and DURING_DIFF.
measure_break_against_baseline() {
  local during="$1" baseline="$2"
  local json
  json=$("$STATS" "$during" --compare "$baseline" 2>"$WORK/stats.err") || return 1
  DURING_CONTRAST=$(printf '%s' "$json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["contrast"])' 2>/dev/null)
  DURING_DIFF=$(printf '%s' "$json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["compare"]["mean_abs_diff"])' 2>/dev/null)
  [[ -n "${DURING_CONTRAST:-}" && -n "${DURING_DIFF:-}" ]] || return 1
}

# Copies the newest window shot of the app (written into CAESURA_SHOTS_DIR,
# one file per app start and break kind) for the app-window-capture check.
copy_newest_shot() {
  local kind="$1" dest="$2"
  local newest
  newest=$(ls -t "$SHOTS" 2>/dev/null | grep -E "^${kind}-break-window-[0-9]+\.png$" | head -1)
  [[ -n "$newest" ]] || return 1
  cp "$SHOTS/$newest" "$dest"
}

# --- one break in its own app run ----------------------------------------------

# run_break <name> <blurred: 0|1> <mini|long> <end: skip|natural>
run_break() {
  local name="$1" blurred="$2" kind="$3" ending="$4"
  local dir="$WORK/$name"
  mkdir -p "$dir"
  printf '%s\n' "$BASE_CONFIG" > "$dir/config.json"
  if [[ "$blurred" == "0" ]]; then
    python3 - "$dir/config.json" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path))
data["blurredBackground"] = False
json.dump(data, open(path, "w"), indent=2)
PY
  fi

  echo
  echo "== scenario: $name (blurredBackground=$blurred, $kind break, ends by $ending) =="
  # The profile of the scenario has to really carry the setting under test: a
  # scenario that claims a blurred background but runs without one would prove
  # nothing.
  local profile_blur
  profile_blur=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["blurredBackground"])' "$dir/config.json" 2>/dev/null)
  echo "  the profile of the scenario: blurredBackground=$profile_blur"
  check "the profile of the scenario carries the setting under test" \
    test "$profile_blur" = "$([[ "$blurred" == "0" ]] && echo False || echo True)"
  start_app "$dir"
  sleep 1.5

  # The baseline of the desktop pixels, before any break window.
  local baseline="$dir/baseline.png"
  local have_baseline=0
  if (( SCREEN_CAPTURES == 0 )); then
    skip_check "screen capture before the break (desktop pixels)" "screen capture is not possible on this host"
  else
    if check "screen capture before the break (desktop pixels)" capture "$baseline"; then
      have_baseline=1
      BASELINE_CONTRAST=$(contrast_of_file "$baseline")
      if [[ -z "${BASELINE_CONTRAST:-}" ]]; then
        echo "  (the statistics of the baseline failed: $(tr '\n' ' ' < "$WORK/stats.err"))"
        BASELINE_CONTRAST=0
      fi
      echo "  screen capture: the contrast pixels before the break: ${BASELINE_CONTRAST:-0}"
    fi
  fi

  if [[ "$kind" == "mini" ]]; then
    check "the cli could start the mini break" run_cli mini "$dir"
  else
    check "the cli could start the long break" run_cli long "$dir"
  fi
  check "the break window is shown" wait_for_log "showing window" 20
  wait_for_log "captured window shot" 10

  # The render of the app's own window hierarchy: proof of the content, not of
  # the blurred desktop.
  local app_shot="$dir/app-window.png"
  local app_contrast=0
  local app_pixels=0
  if ! copy_newest_shot "$kind" "$app_shot"; then
    echo "  (the app did not write a window shot into $SHOTS)"
  else
    app_contrast=$(contrast_of_file "$app_shot")
    app_pixels=$(pixels_of_file "$app_shot")
    if [[ -z "${app_contrast:-}" ]]; then
      echo "  (the statistics of the app window capture failed: $(tr '\n' ' ' < "$WORK/stats.err"))"
      app_contrast=0
    fi
  fi
  echo "  app window capture: the contrast pixels of the content: ${app_contrast:-0}"
  local threshold
  threshold=$(content_threshold "${app_contrast:-0}" "${app_pixels:-0}")
  echo "  the content threshold: $threshold contrast pixels ($CONTENT_FLOOR_RATIO of the window, minimum $CONTENT_FLOOR_MIN)"
  check "app window capture: the break content is visible" bigger_than "${app_contrast:-0}" "$threshold"

  # The ink of the buttons. The window render of the scenario without the blurred
  # background has a transparent background, so the only opaque dark pixels are the
  # labels of the buttons.
  if [[ "$blurred" == "0" && -s "$app_shot" ]]; then
    local ink
    ink=$(ink_of_file "$app_shot")
    echo "  app window capture: the opaque dark pixels (the ink of the buttons): ${ink:-0}"
    check "app window capture: the label of the button is opaque (the ink is visible)" \
      bigger_than "${ink:-0}" "$INK_FLOOR"
  fi

  # The real desktop pixels during the break.
  local during="$dir/break.png"
  if (( SCREEN_CAPTURES == 0 )); then
    skip_check "screen capture during the break (desktop pixels)" "screen capture is not possible on this host"
    skip_check "screen capture: the break content is visible on the display (desktop pixels)" "screen capture is not possible on this host"
    skip_check "screen capture: the break window is on the display (desktop pixels)" "screen capture is not possible on this host"
  elif (( have_baseline == 1 )); then
    if capture "$during"; then
      check "screen capture during the break (desktop pixels)" true
    else
      skip_check "screen capture during the break (desktop pixels)" "the screen capture is not usable on this host"
      skip_check "screen capture: the break content is visible on the display (desktop pixels)" "the screen capture is not usable on this host"
      skip_check "screen capture: the break window is on the display (desktop pixels)" "the screen capture is not usable on this host"
    fi
    if (( SCREEN_CAPTURES == 1 )) && measure_break_against_baseline "$during" "$baseline"; then
      local extra=0
      if bigger_than "${DURING_CONTRAST:-0}" "${BASELINE_CONTRAST:-0}"; then
        extra=$(( ${DURING_CONTRAST:-0} - ${BASELINE_CONTRAST:-0} ))
      fi
      echo "  screen capture: the contrast pixels during the break: ${DURING_CONTRAST:-0}, extra above the baseline (the content): $extra"
      check "screen capture: the break content is visible on the display (desktop pixels)" bigger_than "$extra" "$threshold"
      echo "  screen capture: the mean difference to the screen before the break: ${DURING_DIFF:-0}"
      check "screen capture: the break window is on the display (desktop pixels)" bigger_than "${DURING_DIFF:-0}" 1
    elif (( SCREEN_CAPTURES == 1 )); then
      echo "  (the screen capture of the break could not be measured: $(tr '\n' ' ' < "$WORK/stats.err"))"
      check "screen capture: the break capture could be measured (desktop pixels)" false
    fi
  fi

  # The end of the break: a skip is awaited in the log, the natural end too (no
  # fixed sleep).
  local break_label="Mini"
  [[ "$kind" == "long" ]] && break_label="Long"
  mark_log
  if [[ "$ending" == "skip" ]]; then
    check "the cli could send skip" run_cli skip "$dir"
    check "the break is skipped" wait_for_log "finishing $break_label break" 10
  else
    check "the break ends by itself" wait_for_log "finishing $break_label break" 35
  fi

  [[ -s "$during" ]] && cp "$during" "$EVIDENCE/screenshots/$name.png"
  cp "$LOG" "$EVIDENCE/logs/$name.log"
  stop_app
  LAST_SHOT="$during"
}

echo "== work directory: $WORK"

# The display has to be awake for the whole run: a sleeping display captures as
# a valid, all-black PNG, which would be mistaken for a content-free screen.
# These are temporary assertions; the script changes no setting and no permission.
caffeinate -u -t 5
sleep 2
caffeinate -d -w $$ &
CAFFEINATE_PID=$!

# The session has to be unlocked as well: a locked session shows the lock screen
# on the display, not the break window, so the desktop pixels would prove nothing
# (the clock of the lock screen changes and looks like "content").
SESSION_STATE=$(swift -e '
import CoreGraphics
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
var locked = false
for window in list {
    let owner = (window[kCGWindowOwnerName as String] as? String) ?? ""
    guard owner == "loginwindow" else { continue }
    let layer = (window[kCGWindowLayer as String] as? Int) ?? -1
    let bounds = (window[kCGWindowBounds as String] as? [String: Any]) ?? [:]
    let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) ?? .zero
    if layer >= 0 && rect.width > 100 && rect.height > 100 { locked = true }
}
print(locked ? "locked" : "unlocked")
' 2>/dev/null)
echo "== the session state: ${SESSION_STATE:-unknown}"
if [[ "${SESSION_STATE:-unknown}" != "unlocked" ]]; then
  SESSION_LOCKED=1
  echo
  echo "WARNING: the session is ${SESSION_STATE:-unknown} — the display shows the lock screen,"
  echo "WARNING: so the desktop pixels are NOT the break window and are not checked."
  echo "WARNING: No proof that the blurred background is applied can be claimed."
fi

# Can this host capture the screen at all? (The terminal already holds the
# Screen Recording permission; the script never requests or grants one.)
SCREEN_CAPTURES=1
PROBE="$WORK/screen-probe.png"
PROBE_ERR=""
PROBE_MEAN=""
if ! screencapture -x "$PROBE" 2>"$WORK/probe.err" || [[ ! -s "$PROBE" ]]; then
  PROBE_ERR="the screencapture failed: $(tr '\n' ' ' < "$WORK/probe.err")"
else
  probe_json=$("$STATS" "$PROBE" 2>"$WORK/stats.err")
  PROBE_MEAN=$(printf '%s' "$probe_json" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(max(d["mean"]))' 2>/dev/null)
  probe_contrast=$(printf '%s' "$probe_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["contrast"])' 2>/dev/null)
  echo "== screen capture probe: mean ${PROBE_MEAN:-not analyzed}, contrast pixels ${probe_contrast:-?}"
  if [[ -z "${PROBE_MEAN:-}" ]]; then
    PROBE_ERR="the capture could not be analyzed: $(tr '\n' ' ' < "$WORK/stats.err")"
  elif bigger_than "$PROBE_MEAN" 0; then
    echo "== the screen capture works and shows the desktop"
  else
    PROBE_ERR="a capture was written but all of its pixels are black (either the display"
    PROBE_ERR="$PROBE_ERR was asleep or screen recording is denied)"
  fi
fi
if [[ -n "$PROBE_ERR" ]]; then
  SCREEN_CAPTURES=0
  echo
  echo "WARNING: the screen cannot be captured usefully on this host."
  echo "WARNING: reason: $PROBE_ERR"
  echo "WARNING: the desktop pixels are NOT checked — no proof that the blurred background"
  echo "WARNING: is applied can be claimed. The script never grants a permission."
  echo "WARNING: Only the app window captures (the content) are checked."
fi
if [[ "${SESSION_LOCKED:-0}" == "1" ]]; then
  SCREEN_CAPTURES=0
  echo
  echo "WARNING: the session is locked — the desktop pixels are the lock screen, not the"
  echo "WARNING: break window. They are NOT checked; only the app window captures are."
fi

ALLOW_MAIN=0
if (( DISPLAY_COUNT < 2 )); then
  if [[ "${CAESURA_NATIVE_TEST_MAIN_DISPLAY:-}" == "1" ]]; then
    ALLOW_MAIN=1
    echo "== no secondary display: the main display is used (explicitly allowed)"
  else
    echo "no secondary display is attached." >&2
    echo "Attach one, or run with CAESURA_NATIVE_TEST_MAIN_DISPLAY=1 to use the main display." >&2
    exit 1
  fi
fi

# (a) Mini break, blur ON, ended by skip.
run_break blur-on-mini 1 mini skip
ON_SHOT="$LAST_SHOT"
# (b) Mini break, blur OFF — the reference for the blur.
run_break blur-off-mini 0 mini skip
OFF_SHOT="$LAST_SHOT"

echo
echo "== the blurred background differs from the plain one (screen capture, desktop pixels) =="
echo "== threshold: the mean absolute difference has to exceed $BLUR_DIFF_MIN (an identical desktop differs by ~0) =="
if (( SCREEN_CAPTURES == 0 )); then
  skip_check "the blurred background is applied behind the content" \
    "needs the blur-on and blur-off screen captures, which are not possible on this host"
elif [[ -s "$ON_SHOT" && -s "$OFF_SHOT" ]]; then
  blur_json=$("$STATS" "$ON_SHOT" --compare "$OFF_SHOT" 2>"$WORK/stats.err")
  BLUR_DIFF=$(printf '%s' "$blur_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["compare"]["mean_abs_diff"])' 2>/dev/null)
  BLUR_DIFFER=$(printf '%s' "$blur_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["compare"]["differing_pixels"])' 2>/dev/null)
  BLUR_PIXELS=$(printf '%s' "$blur_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["pixels"])' 2>/dev/null)
  if [[ -z "${BLUR_DIFF:-}" ]]; then
    echo "  (the blur-on and blur-off captures could not be compared: $(tr '\n' ' ' < "$WORK/stats.err"))"
  fi
  echo "  screen capture: blur-on vs blur-off: mean_abs_diff=${BLUR_DIFF:-not comparable}, differing pixels=${BLUR_DIFFER:-?} of ${BLUR_PIXELS:-?}"
  check "the blurred background is applied behind the content" bigger_than "${BLUR_DIFF:-}" "$BLUR_DIFF_MIN"
else
  check "the blurred background is applied behind the content" false
fi

# (c) Long break, blur ON, natural end. (Reports the same numbers per break.)
echo
echo "== scenario: long break with the blurred background (natural end) =="
run_break blur-on-long 1 long natural

# (d) Two Mini breaks in a row in ONE app run, each with its own captures.
echo
echo "== scenario: two mini breaks in a row in one app run (blurredBackground=1) =="
SEQ_DIR="$WORK/blur-on-sequential"
mkdir -p "$SEQ_DIR"
printf '%s\n' "$BASE_CONFIG" > "$SEQ_DIR/config.json"
start_app "$SEQ_DIR"
sleep 1.5

seq_baseline="$SEQ_DIR/baseline.png"
seq_have_baseline=0
seq_base_contrast=0
if (( SCREEN_CAPTURES == 0 )); then
  skip_check "screen capture before cycle 1 (desktop pixels)" "screen capture is not possible on this host"
else
  if check "screen capture before cycle 1 (desktop pixels)" capture "$seq_baseline"; then
    seq_have_baseline=1
    seq_base_contrast=$(contrast_of_file "$seq_baseline")
    if [[ -z "${seq_base_contrast:-}" ]]; then
      echo "  (the statistics of the baseline failed: $(tr '\n' ' ' < "$WORK/stats.err"))"
      seq_base_contrast=0
    fi
    echo "  screen capture: the contrast pixels before cycle 1: ${seq_base_contrast:-0}"
  fi
fi

for cycle in 1 2; do
  mark_log
  check "the cli could start the mini break of cycle $cycle" run_cli mini "$SEQ_DIR"
  check "the break window of cycle $cycle is shown" wait_for_log "showing window" 20
  wait_for_log "captured window shot" 10

  seq_app_shot="$SEQ_DIR/app-window-cycle-$cycle.png"
  seq_app_contrast=0
  seq_app_pixels=0
  if ! copy_newest_shot mini "$seq_app_shot"; then
    echo "  (the app did not write a window shot into $SHOTS)"
  else
    seq_app_contrast=$(contrast_of_file "$seq_app_shot")
    seq_app_pixels=$(pixels_of_file "$seq_app_shot")
    if [[ -z "${seq_app_contrast:-}" ]]; then
      echo "  (the statistics of the app window capture failed: $(tr '\n' ' ' < "$WORK/stats.err"))"
      seq_app_contrast=0
    fi
  fi
  echo "  app window capture: the contrast pixels of cycle $cycle: ${seq_app_contrast:-0}"
  seq_threshold=$(content_threshold "${seq_app_contrast:-0}" "${seq_app_pixels:-0}")
  echo "  the content threshold: $seq_threshold contrast pixels ($CONTENT_FLOOR_RATIO of the window, minimum $CONTENT_FLOOR_MIN)"
  check "app window capture: the content of cycle $cycle is visible" bigger_than "${seq_app_contrast:-0}" "$seq_threshold"

  seq_shot="$SEQ_DIR/screen-cycle-$cycle.png"
  if (( SCREEN_CAPTURES == 0 )); then
    skip_check "screen capture in cycle $cycle (desktop pixels)" "screen capture is not possible on this host"
    skip_check "screen capture: the content of cycle $cycle is visible on the display (desktop pixels)" "screen capture is not possible on this host"
  elif (( seq_have_baseline == 1 )); then
    if capture "$seq_shot"; then
      check "screen capture in cycle $cycle (desktop pixels)" true
    else
      skip_check "screen capture in cycle $cycle (desktop pixels)" "the screen capture is not usable on this host"
      skip_check "screen capture: the content of cycle $cycle is visible on the display (desktop pixels)" "the screen capture is not usable on this host"
    fi
    if (( SCREEN_CAPTURES == 1 )); then
      seq_json=$("$STATS" "$seq_shot" 2>"$WORK/stats.err")
      seq_contrast=$(printf '%s' "$seq_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["contrast"])' 2>/dev/null)
      if [[ -n "${seq_contrast:-}" ]]; then
        seq_extra=0
        if bigger_than "${seq_contrast:-0}" "${seq_base_contrast:-0}"; then
          seq_extra=$(( ${seq_contrast:-0} - ${seq_base_contrast:-0} ))
        fi
        echo "  screen capture: the contrast pixels of cycle $cycle: ${seq_contrast:-0}, extra above the baseline (the content): $seq_extra"
        check "screen capture: the content of cycle $cycle is visible on the display (desktop pixels)" bigger_than "$seq_extra" "$seq_threshold"
      else
        echo "  (the screen capture of cycle $cycle could not be measured: $(tr '\n' ' ' < "$WORK/stats.err"))"
        check "screen capture: the capture of cycle $cycle could be measured (desktop pixels)" false
      fi
    fi
  fi

  mark_log
  check "the cli could skip the mini break of cycle $cycle" run_cli skip "$SEQ_DIR"
  check "the break of cycle $cycle is skipped" wait_for_log "finishing Mini break" 10
  [[ -s "$seq_shot" ]] && cp "$seq_shot" "$EVIDENCE/screenshots/blur-on-sequential-$cycle.png"
done
cp "$LOG" "$EVIDENCE/logs/blur-on-sequential.log"
stop_app

echo
echo "== summary =="
echo "checks: $CHECKS, failures: $FAILURES, skipped: $SKIPPED"
if (( SCREEN_CAPTURES == 0 )); then
  echo "NOTE: no screen capture was possible on this host, so the desktop-pixel evidence"
  echo "      (the blurred background behind the content) was NOT verified."
fi
if (( FAILURES > 0 )); then
  echo "BLUR TEST FAILED"
  exit 1
fi
echo "BLUR TEST PASSED"
