#!/bin/zsh
# Non-GUI tests of the production AX search and controller using a fake tree.
# --inspect-safari explicitly performs a read-only search of an existing Safari
# process. Neither mode presses real controls or requests permission.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
WORK="$(mktemp -d "${TMPDIR:-/tmp}/caesura-core-test-video-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
printf '%s\n' "$(cd "$ROOT" && pwd -P)" > "$WORK/.caesura-project"
# Compile the actual production files with their Foundation-only dependencies;
# only their module imports change because they share one compiler invocation.
for source in VideoPlayback VideoPlaybackProbe; do
  sed '/^import CaesuraCore$/d' "$ROOT/native/Sources/CaesuraApp/$source.swift" > "$WORK/$source.swift"
done
xcrun swiftc -o "$WORK/video-tests" \
  "$ROOT/native/Sources/CaesuraCore/PlaybackNames.swift" \
  "$ROOT/native/Sources/CaesuraCore/VideoPlaybackRules.swift" \
  "$WORK/VideoPlayback.swift" "$WORK/VideoPlaybackProbe.swift" \
  "$ROOT/native/Tests/VideoPlaybackTests/main.swift"
"$WORK/video-tests" "$@"
