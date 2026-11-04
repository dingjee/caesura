#!/bin/zsh
# Refreshes the persistent trial application at <repo>/dist/Caesura.app.
#
# The official bundle is built and staged by package-app.sh into a temporary
# staging directory (no duplication of its layout, icon and signing logic), then
# adjusted to the trial identity: net.hovancik.stretchly.trial / "Caesura",
# so the app keeps its own persistent user-data directory, separate from
# the official bundle (native/dist/Caesura.app) and the legacy Electron app.
#
# The staged bundle is verified before anything is replaced: plutil, executable
# binaries, resource bundle, signature, and a non-GUI `version` self-check with
# CAESURA_NATIVE_DATA_DIR inside the staging directory. A trial that is
# currently running is terminated gracefully by its exact executable path —
# never by name — and restarted after the verified replacement. The previous
# bundle is moved aside inside dist/ and removed only after the new bundle
# verifies; a failed move or verification restores it, so exactly one usable
# trial remains. The staging directory carries a .caesura-project marker with
# this repo root (the same proof test.sh writes) so clean.sh can verify
# ownership of leftover staging directories.
#
# Usage: native/scripts/install-dist.sh [--dry-run]

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ROOT_REAL="$(cd "$ROOT" && pwd -P)"
# The identity of the signature: the very same one that package-app.sh used.
# The trial is never re-signed ad-hoc behind the back of the build.
source "$ROOT/native/scripts/signing-identity.sh"
APP_NAME="Caesura"
TRIAL_ID="net.hovancik.stretchly.trial"
DIST="$ROOT/dist"
TRIAL="$DIST/$APP_NAME.app"
TRIAL_BIN="$TRIAL/Contents/MacOS/Caesura"
LEGACY_TRIAL="$DIST/Stretchly.app"
PREVIOUS_TRIAL="$TRIAL"
PREVIOUS_BIN="$TRIAL_BIN"
if [[ ! -e "$TRIAL" && -e "$LEGACY_TRIAL" ]]; then
  PREVIOUS_TRIAL="$LEGACY_TRIAL"
  PREVIOUS_BIN="$LEGACY_TRIAL/Contents/MacOS/Stretchly"
fi
# A checkout rename leaves a running process reporting its original executable path.
PREVIOUS_PROCESS_BIN="${CAESURA_PREVIOUS_TRIAL_EXECUTABLE:-$PREVIOUS_BIN}"
if [[ -e "$PREVIOUS_TRIAL" ]]; then
  previous_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PREVIOUS_TRIAL/Contents/Info.plist")"
  [[ "$previous_id" == "$TRIAL_ID" ]] || { echo "Refusing to retire another bundle identity: $previous_id" >&2; exit 1; }
fi
STAGE_PREFIX="caesura-trial-stage"
MARKER=".caesura-project"
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    *)
      echo "unknown argument: $1 (supported: --dry-run)" >&2
      exit 2
      ;;
  esac
  shift
done

fail() {
  echo "install-dist: $*" >&2
  exit 1
}

# Bundle checks shared by the staged and the installed bundle.
verify_bundle() {
  local app="$1" bin
  plutil -lint "$app/Contents/Info.plist" >/dev/null || {
    echo "FAIL: Info.plist does not lint: $app" >&2
    return 1
  }
  for bin in Caesura caesura-cli; do
    [[ -x "$app/Contents/MacOS/$bin" ]] || {
      echo "FAIL: $bin is missing or not executable: $app" >&2
      return 1
    }
  done
  [[ -d "$app/Contents/Resources/Caesura_CaesuraCore.bundle" ]] || {
    echo "FAIL: resource bundle missing: $app" >&2
    return 1
  }
  codesign --verify "$app" 2>/dev/null || {
    echo "FAIL: signature does not verify: $app" >&2
    return 1
  }
  "$ROOT/native/scripts/verify-app.sh" "$app" || return 1
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")" == "$TRIAL_ID" ]] || return 1
  echo "  verified: $app"
  return 0
}

# PIDs whose executable path is exactly the given one (ps(1), never name search).
exact_pids() {
  local want="$1" pid rest
  while read -r pid rest; do
    [[ "$rest" == "$want" ]] && printf '%s\n' "$pid"
  done < <(ps -axo pid=,comm= 2>/dev/null)
  return 0
}

# Polls until no process with the exact executable path remains.
# wait_for_pids <executable-path> <half-second-limit> — fails when it survives.
wait_for_pids() {
  local want="$1" limit="$2" waited=0
  while [[ -n "$(exact_pids "$want")" ]]; do
    sleep 0.5
    waited=$((waited + 1))
    if [[ $waited -ge $limit ]]; then
      return 1
    fi
  done
  return 0
}

if [[ $DRY_RUN -eq 1 ]]; then
  echo "== install-dist.sh (dry run) — nothing is built or touched =="
  echo "[dry-run] stage: mktemp -d \"${TMPDIR:-/tmp}/$STAGE_PREFIX-XXXXXX\" + $MARKER=$ROOT_REAL"
  echo "[dry-run] build+stage: native/scripts/package-app.sh <stage> (release build, bundle layout, icon, Info.plist, PkgInfo, ad-hoc sign; DEVELOPER_DIR handled inside)"
  echo "[dry-run] identity: plutil -replace CFBundleIdentifier=$TRIAL_ID, CFBundleName/CFBundleDisplayName=$APP_NAME; codesign with the identity of the build (ad-hoc when none is configured)"
  echo "[dry-run] verify staged bundle: plutil -lint, Caesura + caesura-cli executable, resource bundle, codesign --verify"
  echo "[dry-run] verify staged binary: CAESURA_NATIVE_DATA_DIR=<stage>/selfcheck <stage>/$APP_NAME.app/Contents/MacOS/Caesura version → 'Caesura version …', exit 0"
  echo "[dry-run] stop: SIGTERM to pids of exactly $PREVIOUS_PROCESS_BIN (wait up to 10s; abort and leave the old trial if it survives)"
  echo "[dry-run] swap: mv '$PREVIOUS_TRIAL' '$DIST/$APP_NAME.app.removed-<timestamp>' (when present) → mv staged → '$TRIAL'; rollback restores the backup if the move or the verification fails"
  echo "[dry-run] swap: remove only this invocation's backup after the installed bundle verifies"
  echo "[dry-run] restart: open '$TRIAL' (only when it was running before) and confirm the exact path is running again"
  exit 0
fi

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/$STAGE_PREFIX-XXXXXX")"
ASIDE=""
WAS_RUNNING=0
SWAP_STARTED=0
COMMITTED=0
cleanup() {
  local result=$?
  if [[ $COMMITTED -eq 0 && ( $SWAP_STARTED -eq 1 || -n "$ASIDE" && -e "$ASIDE" ) ]]; then
    local pid
    while IFS= read -r pid; do
      [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
    done < <(exact_pids "$TRIAL_BIN")
    if ! wait_for_pids "$TRIAL_BIN" 20; then
      echo "install-dist: replacement is still running; previous bundle retained at $ASIDE" >&2
      rm -rf -- "$STAGE"
      return 1
    fi
    rm -rf -- "$TRIAL"
    if [[ -n "$ASIDE" && -e "$ASIDE" ]]; then
      echo "== restoring the previous trial =="
      if ! mv "$ASIDE" "$PREVIOUS_TRIAL"; then
        echo "install-dist: restore failed; previous bundle retained at $ASIDE" >&2
        rm -rf -- "$STAGE"
        return 1
      fi
    fi
  fi
  if [[ $COMMITTED -eq 0 && $WAS_RUNNING -eq 1 && -d "$PREVIOUS_TRIAL" ]]; then
    open -g "$PREVIOUS_TRIAL" || true
  fi
  rm -rf -- "$STAGE"
  return "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
printf '%s\n' "$ROOT_REAL" > "$STAGE/$MARKER"

echo "== building and staging the official bundle into $STAGE =="
"$ROOT/native/scripts/package-app.sh" "$STAGE"

STAGED="$STAGE/$APP_NAME.app"
echo "== trial identity: $TRIAL_ID =="
PLIST="$STAGED/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string "$TRIAL_ID" "$PLIST"
plutil -replace CFBundleName -string "$APP_NAME" "$PLIST"
plutil -replace CFBundleDisplayName -string "$APP_NAME" "$PLIST"
echo "== signing $STAGED with the identity of the build =="
sign_bundle "$STAGED"

echo "== verifying the staged bundle (the existing trial is not touched yet) =="
if ! verify_bundle "$STAGED"; then
  fail "the staged bundle failed verification — the existing trial is untouched"
fi

# Non-GUI self-check of the staged binary: `version` prints and exits before any
# scheduler or window starts. The isolated data dir keeps even the log line of
# the check inside the staging directory.
echo "== self-check: version (isolated data dir inside the staging directory) =="
SELF_OUT="$(env CAESURA_NATIVE_DATA_DIR="$STAGE/selfcheck" "$STAGED/Contents/MacOS/Caesura" version 2>&1)" \
  || fail "the staged binary failed the version self-check"
printf '%s\n' "$SELF_OUT" | grep -q "Caesura version" \
  || fail "unexpected version output of the staged binary: $SELF_OUT"
echo "  $SELF_OUT"

# Gracefully stop the running trial by exact executable path (never by name).
PIDS="$(exact_pids "$PREVIOUS_PROCESS_BIN")"
if [[ -n "$PIDS" ]]; then
  WAS_RUNNING=1
  echo "== stopping the running trial (exact executable path) =="
  while IFS= read -r pid; do
    echo "  terminating pid $pid"
    kill "$pid" 2>/dev/null || true
  done <<< "$PIDS"
  if ! wait_for_pids "$PREVIOUS_PROCESS_BIN" 20; then
    fail "the running trial did not terminate — the existing trial is left untouched"
  fi
fi

mkdir -p "$DIST"
if [[ -e "$PREVIOUS_TRIAL" ]]; then
  ASIDE="$DIST/$APP_NAME.app.removed-$(date +%Y%m%d-%H%M%S)-$$"
  [[ ! -e "$ASIDE" ]] || fail "the backup path already exists: $ASIDE"
  echo "== moving the existing trial aside: $ASIDE =="
  mv "$PREVIOUS_TRIAL" "$ASIDE" || fail "could not move the existing trial aside — nothing was replaced"
fi
SWAP_STARTED=1
if [[ "$PREVIOUS_TRIAL" != "$TRIAL" && -n "$ASIDE" ]]; then
  "$ROOT/native/scripts/retire-login-item.sh" "$STAGED" "$PREVIOUS_TRIAL"
fi
if [[ -n "${CAESURA_RETIRED_TRIAL_APP:-}" && "$CAESURA_RETIRED_TRIAL_APP" != "$PREVIOUS_TRIAL" ]]; then
  "$ROOT/native/scripts/retire-login-item.sh" "$STAGED" "$CAESURA_RETIRED_TRIAL_APP"
fi
echo "== installing $TRIAL =="
if ! mv "$STAGED" "$TRIAL"; then
  fail "could not install the staged bundle"
fi

echo "== re-verifying the installed bundle =="
if ! verify_bundle "$TRIAL"; then
  fail "the installed trial failed verification"
fi

if [[ $WAS_RUNNING -eq 1 ]]; then
  echo "== restarting the trial =="
  open -g "$TRIAL" || fail "could not relaunch the installed trial"
  waited=0
  until [[ -n "$(exact_pids "$TRIAL_BIN")" ]]; do
    sleep 0.5
    waited=$((waited + 1))
    if [[ $waited -ge 30 ]]; then
      fail "the replacement trial is installed but did not come back up"
    fi
  done
  NEW_PID="$(exact_pids "$TRIAL_BIN" | head -1 || true)"
  sleep 2
  PID_COUNT="$(exact_pids "$TRIAL_BIN" | awk 'NF { count++ } END { print count+0 }')"
  [[ "$PID_COUNT" == "1" ]] || fail "expected one replacement instance, found $PID_COUNT"
  [[ -z "$(exact_pids "$PREVIOUS_PROCESS_BIN")" || "$PREVIOUS_PROCESS_BIN" == "$TRIAL_BIN" ]] || fail "the old scheduler is still running"
  "$TRIAL/Contents/MacOS/caesura-cli" logs >/dev/null || fail "replacement IPC is not ready"
  echo "  running again (pid $NEW_PID), one scheduler and responsive IPC"
fi

COMMITTED=1
if [[ -n "$ASIDE" ]]; then
  echo "== removing the replaced trial copy: $ASIDE =="
  LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
  if [[ "$PREVIOUS_TRIAL" != "$TRIAL" && -x "$LSREGISTER" ]]; then
    "$LSREGISTER" -u "$ASIDE" || true
  fi
  rm -rf -- "$ASIDE"
fi

echo "Installed: $TRIAL"
