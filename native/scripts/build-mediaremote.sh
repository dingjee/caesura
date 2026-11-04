#!/bin/zsh
# Build the pinned, bundled MediaRemote bridge without installing any tools.
# This only compiles; it never reads or controls another application's media.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${1:?Usage: build-mediaremote.sh output-framework-path}"
VENDOR="$ROOT/native/Vendor/MediaRemoteAdapter"
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
[[ -f "$VENDOR/include/MediaRemoteAdapter.h" ]] || { echo "Missing vendored MediaRemote sources" >&2; exit 1; }
[[ "$OUT" == */MediaRemoteAdapter.framework ]] || { echo "Unexpected framework output path" >&2; exit 2; }
mkdir -p "$OUT/Versions/A/Resources"
# The source list follows the vendored upstream layout; local guarded command
# implementation files in src/adapter are included by the same bounded glob.
SOURCES=()
for source in "$VENDOR"/src/adapter/*.m "$VENDOR"/src/private/*.m "$VENDOR"/src/utility/*.m; do
  # The optional upstream test client publishes a synthetic media session;
  # Caesura neither bundles nor invokes it.
  [[ "${source:t}" == test.m ]] && continue
  SOURCES+=("$source")
done
xcrun clang -arch arm64 -mmacosx-version-min=13.0 -dynamiclib -fobjc-arc \
  -fvisibility=default -I"$VENDOR/include" -I"$VENDOR/src" \
  -install_name '@rpath/MediaRemoteAdapter.framework/Versions/A/MediaRemoteAdapter' \
  -framework Foundation -framework AppKit -framework UniformTypeIdentifiers \
  -framework ImageIO "${SOURCES[@]}" -o "$OUT/Versions/A/MediaRemoteAdapter"
cat > "$OUT/Versions/A/Resources/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.vandenbe.MediaRemoteAdapter</string>
<key>CFBundleName</key><string>MediaRemoteAdapter</string>
<key>CFBundleExecutable</key><string>MediaRemoteAdapter</string>
<key>CFBundlePackageType</key><string>FMWK</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>0.1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
</dict></plist>
PLIST
ln -sfn A "$OUT/Versions/Current"
ln -sfn Versions/Current/MediaRemoteAdapter "$OUT/MediaRemoteAdapter"
ln -sfn Versions/Current/Resources "$OUT/Resources"
[[ "$(lipo -archs "$OUT/MediaRemoteAdapter")" == arm64 ]]
echo "Built arm64 bridge: $OUT"
