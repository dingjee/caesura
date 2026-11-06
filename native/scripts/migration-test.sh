#!/bin/zsh
# Regression test of the explicit local profile migration
# (native/scripts/migrate-local-profiles.py) against temporary roots.
#
# The test builds a tiny sleeper as a stand-in for the verified replacement
# executable, so the retirement checks (single exact process, live new socket,
# dead old socket) run hermetically. The real ~/Library and the real trial
# are never touched; every temporary root lives inside the marked work
# directory and is removed on exit.
#
# Usage: native/scripts/migration-test.sh

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/caesura-migration-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
# Ownership marker for clean.sh: the canonical repo root proves this temporary
# directory belongs to this project's test runs.
printf '%s\n' "$(cd "$ROOT" && pwd -P)" > "$WORK/.caesura-project"

echo "== migration fixture tests (temporary roots, self-cleaned) =="
python3 "$ROOT/native/Tests/MigrationTests/test_migrate_local_profiles.py"
