#!/bin/zsh
# Notarizes a packaged Caesura.app and staples the ticket to it.
#
# Notarization is what turns a Developer ID signature into a bundle that
# Gatekeeper opens without a warning: the notary service of Apple scans the
# uploaded app and issues a ticket, and stapling attaches that ticket to the
# bundle so it is verified even offline. The notary requires the hardened
# runtime on every signature; package-app.sh adds it for a
# "Developer ID Application" identity, and this script refuses anything else.
#
# Requirements, once per machine:
#   - a "Developer ID Application" identity in the keychain, named in
#     native/scripts/signing-identity.local (or CAESURA_NATIVE_SIGN_IDENTITY);
#   - a notarytool credentials profile stored with
#       xcrun notarytool store-credentials caesura-notary
#     (the app-specific password of the Apple Account of the team).
#
# Usage: native/scripts/notarize-app.sh [<app-bundle>]
# The profile name comes from CAESURA_NOTARY_PROFILE (default caesura-notary).
# After a successful run the bundle carries the staple and a distributable
# zip with its SHA-256 sits next to it.

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

source "$ROOT/native/scripts/signing-identity.sh"

APP="${1:-$ROOT/native/dist/Caesura.app}"
PROFILE="${CAESURA_NOTARY_PROFILE:-caesura-notary}"

[[ -d "$APP/Contents/MacOS" ]] || { echo "not an app bundle: $APP" >&2; exit 1; }

# The identity has to be a Developer ID one: the notary rejects development
# certificates, and a stapled ticket belongs to exactly such a signature.
IDENTITY="$(resolve_sign_identity)"
[[ "$IDENTITY" == "Developer ID Application: "* ]] || {
  echo "FAIL: '$IDENTITY' is not a Developer ID Application identity; notarization needs one" >&2
  exit 1
}

# The hardened runtime is a precondition of the notary, not a preference.
for bin in caesura-cli Caesura; do
  if [[ -x "$APP/Contents/MacOS/$bin" ]]; then
    codesign -dv "$APP/Contents/MacOS/$bin" 2>&1 | grep -q 'runtime' || {
      echo "FAIL: $bin is signed without the hardened runtime; package it again with the Developer ID identity" >&2
      exit 1
    }
  fi
done

# The bundle has to carry exactly the resolved identity before anything is
# uploaded — a stale or ad-hoc signature would waste a notary submission.
verify_signed_identity "$APP" "$IDENTITY"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/caesura-notary-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
UPLOAD="$WORK/Caesura-macOS-arm64.zip"
echo "== uploading $APP to the notary service (profile: $PROFILE) =="
ditto -c -k --sequesterRsrc --keepParent "$APP" "$UPLOAD"
xcrun notarytool submit "$UPLOAD" --keychain-profile "$PROFILE" --wait

echo "== stapling the ticket to the bundle =="
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl -a -vv "$APP"

OUT_DIR="$(dirname "$APP")"
DIST_ZIP="$OUT_DIR/Caesura-macOS-arm64.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$DIST_ZIP"
SHA="$(shasum -a 256 "$DIST_ZIP" | awk '{print $1}')"

echo "== notarized: $APP =="
echo "   distributable zip: $DIST_ZIP"
echo "   sha256: $SHA"
