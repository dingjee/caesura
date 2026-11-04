#!/bin/zsh
# Non-GUI tests of the production media backend of the system.
#
# The tests drive the real controller with a fake transport: no media session
# is read, no command is sent and no permission is asked for. The run is
# isolated (CAESURA_NATIVE_DATA_DIR), so the production transport of the
# controller stays a dry run as well.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
WORK="$(mktemp -d "${TMPDIR:-/tmp}/caesura-core-test-media-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
printf '%s\n' "$(cd "$ROOT" && pwd -P)" > "$WORK/.caesura-project"

# The app sources import the core module; the harness compiles the core files
# it needs directly, so only the module imports change.
for source in SystemMediaPlayback MediaRemoteSessionSource; do
  sed '/^import CaesuraCore$/d' "$ROOT/native/Sources/CaesuraApp/$source.swift" > "$WORK/$source.swift"
done

# The paths of the core cannot be compiled outside the package (it reads its
# resource bundle), so the harness gets the one fact it needs: an isolated run.
cat > "$WORK/AppPaths.swift" <<'SHIM'
import Foundation

/// The isolation of the harness: the test script sets the data directory, so
/// the run is always isolated.
enum AppPaths {
    static var isIsolatedRun: Bool {
        if let env = ProcessInfo.processInfo.environment["CAESURA_NATIVE_DATA_DIR"],
           !env.isEmpty { return true }
        return false
    }
}
SHIM

xcrun swiftc -o "$WORK/system-media-tests" \
  "$ROOT/native/Sources/CaesuraCore/SystemMediaPlaybackPolicy.swift" \
  "$ROOT/native/Sources/CaesuraCore/SettingsValue.swift" \
  "$WORK/SystemMediaPlayback.swift" "$WORK/MediaRemoteSessionSource.swift" \
  "$WORK/AppPaths.swift" \
  "$ROOT/native/Tests/SystemMediaPlaybackTests/main.swift"

# A test that waits for an event that never comes must not hold the run
# forever: the run is ended and reported as a failure.
run_with_timeout() {
  local limit="$1"; shift
  local task_exit_code=0
  "$@" &
  local pid=$!
  local waited=0
  while kill -0 "$pid" 2>/dev/null; do
    if (( waited >= limit )); then
      kill -TERM "$pid" 2>/dev/null || true
      sleep 1
      kill -KILL "$pid" 2>/dev/null || true
      echo "the test run did not finish within ${limit}s" >&2
      return 124
    fi
    sleep 1
    waited=$(( waited + 1 ))
  done
  wait "$pid" || task_exit_code=$?
  return $task_exit_code
}

task_exit_code=0
CAESURA_NATIVE_DATA_DIR="$WORK" run_with_timeout 120 "$WORK/system-media-tests" "$@" || task_exit_code=$?
exit $task_exit_code
