#!/bin/zsh
# Tests the production guarded command against a fake MediaRemote transport.
# No private framework is loaded and no real media is read or controlled.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
VENDOR="$ROOT/native/Vendor/MediaRemoteAdapter"
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
WORK="$(mktemp -d "${TMPDIR:-/tmp}/caesura-core-test-media-guard-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
printf '%s\n' "$(cd "$ROOT" && pwd -P)" > "$WORK/.caesura-project"
xcrun clang -arch arm64 -mmacosx-version-min=13.0 -fobjc-arc \
  -I"$VENDOR/include" -I"$VENDOR/src" -framework Foundation -framework AppKit \
  "$VENDOR/src/adapter/guarded.m" "$VENDOR/src/adapter/keys.m" \
  "$ROOT/native/Tests/MediaRemoteGuardTests/main.m" -o "$WORK/guard-tests"
"$WORK/guard-tests"
