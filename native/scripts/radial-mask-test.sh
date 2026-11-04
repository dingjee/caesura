#!/bin/zsh
# Pixel check of the actual radial mask raster of the app.
#
# The raster of the break reveal (native/Sources/CaesuraApp/RadialMaskRaster.swift)
# is compiled together with a small test main and read at its real pixels: the
# opaque centre, the clear exterior, the feathered edge, the exact hidden and
# full endpoints, the soft emergence of an early radius, the orientation of the
# raster in the non-flipped host and the bounded size of the allocation. The
# layer mask is rendered offscreen; no window is ever shown and nothing is
# activated.
#
# Usage: native/scripts/radial-mask-test.sh

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# The selection of the toolchain is process scoped: the global `xcode-select`
# is not changed and nothing is installed.
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  echo "== using DEVELOPER_DIR=$DEVELOPER_DIR =="
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/caesura-core-test-ripple-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
# Ownership marker for clean.sh: the canonical repo root proves this temporary
# directory belongs to this project's test runs.
printf '%s\n' "$(cd "$ROOT" && pwd -P)" > "$WORK/.caesura-project"

echo "== compiling the radial mask raster and its pixel checks =="
xcrun swiftc \
  -o "$WORK/radial-mask-test" \
  "$ROOT/native/Sources/CaesuraApp/RadialMaskRaster.swift" \
  "$ROOT/native/Tests/RadialMaskRasterTests/main.swift"

echo "== radial mask pixel checks =="
"$WORK/radial-mask-test"
