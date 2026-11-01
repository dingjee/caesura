#!/bin/zsh
# Inspects a packaged app without launching it or reading a user profile.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP="${1:-$ROOT/native/dist/Caesura.app}"

plutil -lint "$APP/Contents/Info.plist"
codesign --verify --deep --strict --verbose=1 "$APP"
for key in CFBundleName CFBundleDisplayName CFBundleExecutable; do
  [[ "$(/usr/libexec/PlistBuddy -c "Print :$key" "$APP/Contents/Info.plist")" == "Caesura" ]] || {
    echo "Unexpected $key in $APP" >&2
    exit 1
  }
done
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
case "$bundle_id" in
  io.github.dingjee.caesura|net.hovancik.stretchly.trial) ;;
  *) echo "Unexpected bundle identity: $bundle_id" >&2; exit 1 ;;
esac
for notice in LICENSE.txt ThirdPartyNotices.txt; do
  [[ -s "$APP/Contents/Resources/$notice" ]] || { echo "Missing $notice" >&2; exit 1; }
done
[[ -d "$APP/Contents/Resources/Caesura_CaesuraCore.bundle" ]] || {
  echo "Missing Swift resource bundle: $APP" >&2
  exit 1
}

for name in Caesura caesura-cli; do
  binary="$APP/Contents/MacOS/$name"
  [[ -x "$binary" ]] || { echo "Missing executable: $binary" >&2; exit 1; }
  dependencies="$(otool -L "$binary")"
  if printf '%s\n' "$dependencies" | tail -n +2 | grep -Ei 'Electron|Chromium|libnode'; then
    echo "Unexpected runtime dependency: $binary" >&2
    exit 1
  fi
  if [[ "${CAESURA_NATIVE_UNIVERSAL:-0}" == "1" ]]; then
    for architecture in arm64 x86_64; do
      lipo "$binary" -verify_arch "$architecture"
    done
  fi
done

residue="$(find "$APP/Contents" \( -iname '*electron*' -o -iname '*chromium*' \
  -o -iname '*libnode*' -o -name node_modules -o -name '*.asar' \) -print)"
if [[ -n "$residue" ]]; then
  echo "Unexpected runtime files in native app:" >&2
  printf '%s\n' "$residue" >&2
  exit 1
fi
echo "Verified native app: $APP"
