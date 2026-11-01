#!/bin/zsh
# Removes the build and test residue this project's scripts create.
#
# Default mode is a dry run: every removal is printed as
# "[dry-run] would remove: <path>" and nothing is touched. --apply performs
# the removal.
#
# Targets:
# - <repo>/.build, <repo>/native/evidence, native/verification/{logs,screenshots}
# - temp directories named caesura-smoke-* (smoke-test.sh),
#   caesura-lifecycle-* (lifecycle-test.sh), caesura-core-test-* (test.sh),
#   caesura-blur-* (blur-test.sh) and caesura-trial-stage-* (install-dist.sh)
#   under $TMPDIR or /tmp. A
#   directory counts as residue only when it carries a .caesura-project
#   marker containing this checkout's canonical repo root — the name prefix
#   alone proves nothing across clones, and unmarked leftovers are left alone.
#
# --pidfile <path> stops only PIDs whose executable path is a test path of
# this checkout (.build or a marked caesura-* temp directory). The
# persistent bundles under dist/ and native/dist/ are protected even when
# listed. Processes are never searched by name.
#
# Usage: native/scripts/clean.sh [--apply] [--pidfile <path>] [--help]

set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ROOT_REAL="$(cd "$ROOT" && pwd -P)"
TMP_BASE="${TMPDIR:-/tmp}"
TMP_BASE="${TMP_BASE%/}"
TMP_REAL="$(cd "$TMP_BASE" 2>/dev/null && pwd -P)"
MARKER=".caesura-project"
PREVIOUS_ROOT="${CAESURA_PREVIOUS_PROJECT_ROOT:-}"
if [[ -n "$PREVIOUS_ROOT" && ( "$PREVIOUS_ROOT" != /* || -e "$PREVIOUS_ROOT" ) ]]; then
  echo "Previous project root must be an absolute, retired checkout path" >&2
  exit 2
fi
APPLY=0
PIDFILE=""
FAILURES=0

usage() {
  cat <<'EOF'
Usage: native/scripts/clean.sh [--apply] [--pidfile <path>] [--help]

Removes the build and test residue this project's scripts create. Default
mode is a dry run: every removal is printed as "[dry-run] would remove:
<path>" and nothing is touched. --apply performs the removal.

Targets:
  <repo>/.build                    swift build, test.sh, package-app.sh,
                                   install-dist.sh
  <repo>/native/evidence           lifecycle-test.sh evidence (logs)
  <repo>/native/verification/logs  smoke-test.sh logs
  <repo>/native/verification/screenshots  smoke-test.sh screenshots
  $TMPDIR/caesura-smoke-*        smoke-test.sh work directory (profiles,
                                   logs, screenshots, stale cli.sock)
  $TMPDIR/caesura-lifecycle-*    lifecycle-test.sh work directory (same;
                                   kept behind --keep)
  $TMPDIR/caesura-core-test-*    test.sh core-suite data directory
  $TMPDIR/caesura-blur-*        blur-test.sh work directory (profiles,
                                   logs, screenshots, stale cli.sock)
  $TMPDIR/caesura-trial-stage-*  install-dist.sh staging bundle

  A temp directory is removed only when its .caesura-project marker file
  records this checkout's canonical repo root. Unmarked directories and
  markers of other clones are left alone, whatever their name.

Options:
  --apply          actually remove (default: dry run)
  --pidfile <p>    stop only the PIDs listed in <p>, one per line, and only
                   when ps(1) shows a test executable path of this checkout
                   (.build or a marked caesura-* temp directory). The
                   persistent bundles under dist/ and native/dist/ are
                   protected even when listed. Processes are never searched
                   by name.
  --help           this text

Protected (asserted, never touched):
  repository sources, tests, tools, dependencies and every repo path outside
  the generated directories above; <repo>/dist/ (including moved-aside
  trial copies); <repo>/native/dist/; all of ~/Library (including
  Caesura and the legacy profiles),
  login items included; no sweeping of /tmp beyond the caesura- prefixes.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --pidfile)
      if [[ $# -lt 2 ]]; then
        echo "--pidfile needs a path" >&2
        exit 2
      fi
      PIDFILE="$2"
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1 (supported: --apply, --pidfile <path>, --help)" >&2
      exit 2
      ;;
  esac
  shift
done

# The generated directories of this checkout (exact paths).
repo_targets() {
  printf '%s\n' "$ROOT/.build" "$ROOT/.ruff_cache" "$ROOT/native/evidence" \
    "$ROOT/native/verification/logs" "$ROOT/native/verification/screenshots"
}

# The known caesura-* temp shapes, wherever TMPDIR pointed when they were
# created, plus /tmp.
temp_candidates() {
  local base
  for base in "$TMP_BASE" "/tmp"; do
    find "$base" -maxdepth 1 \
      \( -name 'caesura-smoke-*' -o -name 'caesura-lifecycle-*' \
         -o -name 'caesura-core-test-*' -o -name 'caesura-trial-stage-*' \
         -o -name 'caesura-blur-*' -o -name 'caesura-tooltip-*' -o -name 'caesura-video-*' \
         -o -name 'stretchly-smoke-*' -o -name 'stretchly-lifecycle-*' \
         -o -name 'stretchly-core-test-*' -o -name 'stretchly-trial-stage-*' \
         -o -name 'stretchly-blur-*' -o -name 'stretchly-tooltip-*' -o -name 'stretchly-video-*' \) \
      2>/dev/null || true
  done | sort -u
}

# Ownership proof: the marker must record this checkout's canonical repo root.
temp_owned() {
  local p="$1" recorded
  local marker
  for marker in "$MARKER" .stretchly-project; do
    recorded="$(head -n 1 "$p/$marker" 2>/dev/null | tr -d '\r\n' || true)"
    if [[ -n "$recorded" && ( "$recorded" == "$ROOT_REAL" || "$recorded" == "$ROOT" || ( -n "$PREVIOUS_ROOT" && "$recorded" == "$PREVIOUS_ROOT" ) ) ]]; then
      return 0
    fi
  done
  return 1
}

is_expected_target() {
  local p="$1"
  case "$p" in
    "$ROOT/.build"|"$ROOT/.build/"*|"$ROOT/.ruff_cache"|"$ROOT/native/evidence"|"$ROOT/native/evidence/"*|"$ROOT/native/verification/logs"|"$ROOT/native/verification/screenshots") return 0 ;;
  esac
  local parent="${p%/*}" name="${p##*/}"
  case "$name" in
    caesura-smoke-*|caesura-lifecycle-*|caesura-core-test-*|caesura-trial-stage-*|caesura-blur-*|caesura-tooltip-*|caesura-video-*|stretchly-smoke-*|stretchly-lifecycle-*|stretchly-core-test-*|stretchly-trial-stage-*|stretchly-blur-*|stretchly-tooltip-*|stretchly-video-*) ;;
    *) return 1 ;;
  esac
  case "$parent" in
    "$TMP_BASE"|"$TMP_REAL"|"/tmp"|"/private/tmp") return 0 ;;
  esac
  return 1
}

is_protected() {
  local p="$1"
  case "$p" in
    /|"$HOME"|"$ROOT"|"$ROOT_REAL") return 0 ;;
  esac
  case "$p/" in
    "$HOME/Library/"*) return 0 ;;
  esac
  case "$p/" in
    "$ROOT/"*|"$ROOT_REAL/"*)
      case "$p" in
        "$ROOT/.build"|"$ROOT/.build/"*|"$ROOT/.ruff_cache"|"$ROOT/native/evidence"|"$ROOT/native/evidence/"*|"$ROOT/native/verification/logs"|"$ROOT/native/verification/screenshots") return 1 ;;
        *) return 0 ;;
      esac
      ;;
  esac
  return 1
}

remove_path() {
  local p="$1"
  if [[ ! -e "$p" && ! -L "$p" ]]; then
    return 0
  fi
  if ! is_expected_target "$p"; then
    echo "  REFUSED (not a known project artifact): $p"
    FAILURES=$((FAILURES + 1))
    return 1
  fi
  if is_protected "$p"; then
    echo "  skipped (protected): $p"
    return 0
  fi
  if [[ "$p" != "$ROOT/"* && "$p" != "$ROOT_REAL/"* ]] && ! temp_owned "$p"; then
    echo "  skipped (no $MARKER for this checkout): $p"
    return 0
  fi
  if [[ $APPLY -eq 1 ]]; then
    if rm -rf -- "$p"; then
      echo "  removed: $p"
    else
      echo "  FAILED to remove: $p"
      FAILURES=$((FAILURES + 1))
      return 1
    fi
  else
    echo "[dry-run] would remove: $p"
  fi
  return 0
}

# Only test executable paths of this checkout may be stopped: the test
# binaries in .build and the executables inside caesura-* temp directories.
# The persistent bundles under dist/ and native/dist/ are never stopped.
pid_classify() {
  local comm="$1"
  case "$comm" in
    "$ROOT/dist/"*|"$ROOT_REAL/dist/"*|"$ROOT/native/dist/"*|"$ROOT_REAL/native/dist/"*) return 2 ;;
  esac
  case "$comm" in
    "$ROOT/.build/"*|"$ROOT_REAL/.build/"*) return 0 ;;
  esac
  local base relative directory
  for base in "$TMP_BASE" "$TMP_REAL" /tmp /private/tmp; do
    case "$comm" in
      "$base/"*)
        relative="${comm#"$base/"}"
        directory="$base/${relative%%/*}"
        if is_expected_target "$directory" && temp_owned "$directory"; then
          return 0
        fi
        ;;
    esac
  done
  return 1
}

process_pidfile() {
  local pid raw comm rc
  if [[ -z "$PIDFILE" ]]; then
    return 0
  fi
  if [[ ! -r "$PIDFILE" ]]; then
    echo "pidfile not readable: $PIDFILE"
    FAILURES=$((FAILURES + 1))
    return 1
  fi
  while IFS= read -r pid || [[ -n "$pid" ]]; do
    case "$pid" in
      *[![:space:]]*) ;;
      *) continue ;;
    esac
    case "$pid" in
      *[!0-9]*)
        echo "  skipped (not a pid): $pid"
        FAILURES=$((FAILURES + 1))
        continue
        ;;
    esac
    raw="$(ps -p "$pid" -o comm= 2>/dev/null)"
    comm="$(printf '%s\n' "$raw" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    if [[ -z "$comm" ]]; then
      echo "  pid $pid: not running (stale entry)"
      continue
    fi
    pid_classify "$comm"
    rc=$?
    if [[ $rc -eq 2 ]]; then
      echo "  pid $pid: PROTECTED — $comm is a persistent app bundle, not a test process"
      FAILURES=$((FAILURES + 1))
    elif [[ $rc -eq 0 ]]; then
      if [[ $APPLY -eq 1 ]]; then
        echo "  pid $pid: stopping $comm"
        if ! kill "$pid"; then
          echo "  FAILED to stop pid $pid"
          FAILURES=$((FAILURES + 1))
        fi
      else
        echo "[dry-run] would stop pid $pid ($comm)"
      fi
    else
      echo "  pid $pid: REFUSED — $comm is not a test executable path of this checkout"
      FAILURES=$((FAILURES + 1))
    fi
  done < "$PIDFILE"
}

MODE="dry run"
[[ $APPLY -eq 1 ]] && MODE="apply"
echo "== caesura clean (mode: $MODE) =="
echo "protected: $ROOT/dist, $ROOT/native/dist, all of $HOME/Library, and source files outside generated build/test directories"

echo
echo "== test processes (pidfile) =="
process_pidfile

echo
echo "== generated build and test directories =="
while IFS= read -r t; do
  remove_path "$t"
done < <(repo_targets)

echo
echo "== temp profiles, logs, screenshots, sockets, staging =="
while IFS= read -r candidate; do
  [[ -n "$candidate" ]] || continue
  remove_path "$candidate"
done < <(temp_candidates)

if [[ $APPLY -eq 1 ]]; then
  rmdir "$ROOT/native/verification" 2>/dev/null || true
fi

echo
echo "== summary =="
if [[ $FAILURES -gt 0 ]]; then
  echo "clean finished with $FAILURES refusal(s) or failure(s)"
  exit 1
fi
if [[ $APPLY -eq 1 ]]; then
  echo "clean applied"
else
  echo "dry run finished — run with --apply to remove"
fi
