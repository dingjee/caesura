#!/bin/zsh
# Inspects a packaged app without launching it or reading a user profile.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP="$ROOT/native/dist/Caesura.app"
EXPECTED_IDENTITY=""
# The signature identity is optional: the default check only proves that the
# bundle is valid (and arm64-only). A bundle that was signed ad-hoc earlier
# stays valid — the check never reads the identity of this machine, so it
# never refuses a usable rollback.
while [[ $# -gt 0 ]]; do
  case "$1" in
    --expect-identity) EXPECTED_IDENTITY="${2:-}"; shift ;;
    *) APP="$1" ;;
  esac
  shift
done
source "$ROOT/native/scripts/signing-identity.sh"

plutil -lint "$APP/Contents/Info.plist"
codesign --verify --deep --strict --verbose=1 "$APP"
# When the caller names the identity it expects, the signature has to carry
# it (the authority of the bundle and of both executables, their team and the
# stable designated requirement of the identity).
if [[ -n "$EXPECTED_IDENTITY" ]]; then
  verify_signed_identity "$APP" "$EXPECTED_IDENTITY" || exit 1
fi
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
  architectures="$(lipo -archs "$binary")"
  [[ "$architectures" == "arm64" ]] || {
    echo "Unexpected architectures in $binary: $architectures" >&2
    exit 1
  }
done

residue="$(find "$APP/Contents" \( -iname '*electron*' -o -iname '*chromium*' \
  -o -iname '*libnode*' -o -name node_modules -o -name '*.asar' \) -print)"
if [[ -n "$residue" ]]; then
  echo "Unexpected runtime files in native app:" >&2
  printf '%s\n' "$residue" >&2
  exit 1
fi
echo "Verified native app: $APP"
