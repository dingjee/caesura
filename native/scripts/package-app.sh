#!/bin/zsh
# Packages the native Caesura.app from a release build.
# Usage: native/scripts/package-app.sh [output-dir] [--dev]
# - Release build of the Caesura executable
# - .app bundle with Info.plist (LSUIElement, LSMinimumSystemVersion 13.0, icon, 1.22.1)
# - SPM resource bundle (locales + audio) into Contents/Resources
# - .icns rendered natively from the Caesura mark with AppKit + iconutil
# - codesign with the identity of native/scripts/signing-identity.sh
#   (CAESURA_NATIVE_SIGN_IDENTITY, or the git-ignored local identity file);
#   ad-hoc when neither is set
# Releases support Apple Silicon only (CAESURA_NATIVE_UNIVERSAL=0).

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT_DIR="${1:-$ROOT/native/dist}"
CONFIG="release"
if [[ "${2:-}" == "--dev" ]]; then CONFIG="debug"; fi
if [[ "${CAESURA_NATIVE_UNIVERSAL:-0}" == "1" ]]; then
  echo "Universal releases are no longer supported; use CAESURA_NATIVE_UNIVERSAL=0." >&2
  exit 2
fi
BUILD_ARGS=(-c "$CONFIG" --arch arm64)

# The Command Line Tools of this host ship a SwiftUI macro plugin that is missing, so
# the build uses the installed Xcode toolchain. The selection is process scoped: the
# global `xcode-select` is not changed and nothing is installed.
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  echo "== using DEVELOPER_DIR=$DEVELOPER_DIR =="
fi

# The identity of the signature: the same one that install-dist.sh uses, so
# the installed bundle is never signed ad-hoc behind the back of the build.
source "$ROOT/native/scripts/signing-identity.sh"

APP_NAME="Caesura"
BUNDLE_ID="io.github.dingjee.caesura"
VERSION="1.22.1"
APP="$OUT_DIR/$APP_NAME.app"

cd "$ROOT"
echo "== swift build -c $CONFIG (Caesura, caesura-cli) =="
swift build "${BUILD_ARGS[@]}" --product Caesura
swift build "${BUILD_ARGS[@]}" --product caesura-cli

# The build directory depends on the toolchain (`.build/arm64-apple-macosx/<config>`
# with the older SwiftPM, `.build/out/Products/<config>` with the current one), so it
# is asked from SwiftPM itself. A stale binary of another toolchain must never be
# packaged.
BIN_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"
if [[ ! -x "$BIN_DIR/Caesura" ]]; then
  echo "the freshly built binary is missing in $BIN_DIR" >&2
  exit 1
fi
echo "== binaries from $BIN_DIR =="

echo "== assembling $APP =="
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_DIR/Caesura" "$APP/Contents/MacOS/Caesura"
cp "$BIN_DIR/caesura-cli" "$APP/Contents/MacOS/caesura-cli"

# SPM resource bundle (Caesura_CaesuraCore.bundle) with locales + audio.
RSRC_BUNDLE=$(find "$BIN_DIR" -maxdepth 2 -name "Caesura_CaesuraCore.bundle" | head -1)
if [[ -z "$RSRC_BUNDLE" ]]; then
  echo "resource bundle not found in $BIN_DIR" >&2
  exit 1
fi
cp -R "$RSRC_BUNDLE" "$APP/Contents/Resources/"
cp "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE.txt"
cp "$ROOT/THIRD_PARTY_NOTICES.md" "$APP/Contents/Resources/ThirdPartyNotices.txt"

# The packaged binary must be the one that was just built.
BUILT_UUID=$(dwarfdump --uuid "$BIN_DIR/Caesura" 2>/dev/null | awk '{print $2}')
PACKED_UUID=$(dwarfdump --uuid "$APP/Contents/MacOS/Caesura" 2>/dev/null | awk '{print $2}')
if [[ -n "$BUILT_UUID" && -n "$PACKED_UUID" && "$BUILT_UUID" != "$PACKED_UUID" ]]; then
  echo "the packaged binary is not the freshly built one ($PACKED_UUID != $BUILT_UUID)" >&2
  exit 1
fi
echo "== packaged binary uuid: $PACKED_UUID =="

# Render the owned vector artwork at each icon resolution.
ICONSET="$OUT_DIR/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
swift "$ROOT/native/scripts/make-icon.swift" "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Caesura</string>
    <key>CFBundleDisplayName</key><string>Caesura</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleExecutable</key><string>Caesura</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>BSD-2-Clause — Copyright (c) Jan Hovancik and contributors</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSAppleEventsUsageDescription</key><string>Caesura does not send Apple Events.</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.healthcare-fitness</string>
</dict>
</plist>
PLIST

# PkgInfo
printf 'APPL????' > "$APP/Contents/PkgInfo"

sign_bundle "$APP"

echo "== verification =="
SIGN_IDENTITY="$(resolve_sign_identity)"
if [[ -n "$SIGN_IDENTITY" ]]; then
  # The bundle that is built has to carry the identity of this checkout —
  # an ad-hoc signature would ask for the accessibility permission again.
  verify_signed_identity "$APP" "$SIGN_IDENTITY" || {
    echo "the bundle does not carry the expected identity: $SIGN_IDENTITY" >&2
    exit 1
  }
  "$ROOT/native/scripts/verify-app.sh" "$APP" --expect-identity "$SIGN_IDENTITY"
else
  "$ROOT/native/scripts/verify-app.sh" "$APP"
fi

echo "Packaged: $APP"
