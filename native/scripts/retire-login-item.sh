#!/bin/zsh
# Retires one obsolete trial URL through ServiceManagement, without starting UI.
# A verified replacement temporarily occupies the vacated URL so mainApp refers
# to that exact registration. Only directories created here are removed.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
[[ $# -eq 2 ]] || { echo "Usage: retire-login-item.sh <verified-trial> <vacated-trial-url>" >&2; exit 2; }
REPLACEMENT="$1"
RETIRED="$2"
case "$RETIRED" in
  /*/dist/Stretchly.app|/*/dist/Caesura.app) ;;
  *) echo "Not a known trial application path: $RETIRED" >&2; exit 2 ;;
esac
[[ ! -e "$RETIRED" && ! -L "$RETIRED" ]] || { echo "Refusing to overwrite: $RETIRED" >&2; exit 1; }
"$ROOT/native/scripts/verify-app.sh" "$REPLACEMENT"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$REPLACEMENT/Contents/Info.plist")" == "net.hovancik.stretchly.trial" ]] || exit 2

created_directories=()
parent="${RETIRED:h}"
while [[ ! -e "$parent" ]]; do
  created_directories+=("$parent")
  parent="${parent:h}"
done
CREATED=0
cleanup() {
  local directory
  if [[ $CREATED -eq 1 ]]; then rm -rf -- "$RETIRED"; fi
  for directory in "${created_directories[@]}"; do rmdir "$directory" 2>/dev/null || true; done
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "${RETIRED:h}"
CREATED=1
ditto "$REPLACEMENT" "$RETIRED"
echo "== obsolete login URL: $RETIRED =="
"$RETIRED/Contents/MacOS/Caesura" --unregister-login-item
result="$("$RETIRED/Contents/MacOS/Caesura" --login-item-status)"
printf '%s\n' "$result"
[[ "$result" == "Login item: notRegistered" || "$result" == "Login item: notFound" ]] || {
  echo "Obsolete login registration is still active" >&2
  exit 1
}
