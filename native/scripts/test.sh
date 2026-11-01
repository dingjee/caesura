#!/bin/zsh
# Builds the native Caesura sources and runs the core test suite.
#
# The Command Line Tools of this host ship a SwiftUI macro plugin that is missing
# ("external macro implementation type 'SwiftUIMacros.StateMacro' could not be
# found"), so the build uses the installed Xcode toolchain. The selection is
# process scoped: the global `xcode-select` is not changed and nothing is installed.
#
# Usage: native/scripts/test.sh [--release]

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CONFIG="debug"
[[ "${1:-}" == "--release" ]] && CONFIG="release"

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  echo "== using DEVELOPER_DIR=$DEVELOPER_DIR =="
fi

cd "$ROOT"
echo "== swift build -c $CONFIG =="
swift build -c "$CONFIG"
echo "== core test suite =="
# Keep nested UNIX socket fixtures below sockaddr_un's path limit.
WORK="$(mktemp -d "/tmp/caesura-core-test-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
printf '%s\n' "$(cd "$ROOT" && pwd -P)" > "$WORK/.caesura-project"
TMPDIR="$WORK/" CAESURA_NATIVE_DATA_DIR="$WORK" swift run -c "$CONFIG" caesura-core-tests
