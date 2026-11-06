#!/usr/bin/env python3
"""Explicit, narrowly scoped maintenance migration of the two old native
profiles into the Caesura layout (authorized 2026-11-03).

    ~/Library/Application Support/StretchlyNativeTrial  ->  Caesura        (trial, active)
    ~/Library/Application Support/StretchlyNative       ->  CaesuraNative  (ordinary)

The trial keeps bundle ID net.hovancik.stretchly.trial and visible name
Caesura; only the data directories move. The Electron `Stretchly` directory is
never touched, and nothing outside the four exact directories above is read
or written (beyond the bundled-app check of the replacement executable).

Safety properties:

- Non-destructive copy: existing destination files always win; a differing
  source file is preserved under
  `Caesura/Migration Backup/<timestamp>/conflicts/<source-dir>/...`.
- Full recoverable snapshots of both old directories are kept under
  `Caesura/Migration Backup/<timestamp>/<source-dir>/...` before anything is
  retired. Runtime sockets (`cli.sock`) are never copied into active data.
- The ordinary destination (CaesuraNative) must not be overwritten: it may
  only exist when its content is exactly what a previous run of this
  migration copied there (the matching manifest is the credential); any
  other pre-existing profile aborts the run.
- Checksum manifests (SHA-256) are written and re-verified; a rerun resumes
  from the matching manifest instead of copying blindly.
- Retirement (`--retire`) removes ONLY the two exact old directories, and
  only after: the verified replacement executable runs as exactly one
  process, the new trial socket accepts a connection (responsive IPC), both
  FULL backup trees hash exactly to the recorded source manifests (any
  missing or corrupted snapshot file aborts; the copy phase repairs
  snapshots from the still-unchanged sources before this check), the old
  profiles still hash to their recorded manifests (abort if anything
  changed), and no process holds the old socket or files of the old
  directories open.

Usage:
  migrate-local-profiles.py [--library-root <dir>] [--dist-app <Caesura.app>]
                            [--retire] [--execute]

Default (no --execute) is a dry run. --library-root redirects all four
directories under a test root so the logic can be exercised against temporary
data; with a custom root, --retire is refused unless --allow-test-retire is
also given (the real run uses the real Library root).
"""

import argparse
import hashlib
import json
import os
import shutil
import socket
import subprocess
import sys
import time
from pathlib import Path

TRIAL_OLD = "StretchlyNativeTrial"
ORDINARY_OLD = "StretchlyNative"
TRIAL_NEW = "Caesura"
ORDINARY_NEW = "CaesuraNative"
RUNTIME_SOCKET = "cli.sock"
MANIFEST_NAME = "migration-manifest.json"


def log(message):
    print(f"migrate: {message}", flush=True)


def fail(message):
    print(f"migrate: ERROR: {message}", file=sys.stderr, flush=True)
    sys.exit(1)


def sha256_of(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def durable_tree(root):
    """The durable files of a profile: everything but the runtime socket.
    Returns {relative POSIX path: [size, sha256]} using JSON-native lists, so
    a recorded manifest survives a JSON round-trip and rerun comparisons;
    missing root -> None."""
    if not root.is_dir():
        return None
    entries = {}
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        for name in sorted(filenames):
            full = Path(dirpath) / name
            rel = full.relative_to(root).as_posix()
            if rel == RUNTIME_SOCKET:
                continue
            entries[rel] = [full.stat().st_size, sha256_of(full)]
    return entries


def exact_running_pids(executable):
    out = subprocess.run(["ps", "-axo", "pid=,comm="],
                         capture_output=True, text=True, check=True)
    pids = []
    for line in out.stdout.splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) == 2 and parts[1] == executable:
            pids.append(int(parts[0]))
    return pids


def socket_accepts(path):
    if not path.exists():
        return False
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.settimeout(2)
    try:
        client.connect(str(path))
        return True
    except OSError:
        return False
    finally:
        client.close()


def open_writers_under(path):
    """Processes with files open under `path` (lsof +D on one exact dir)."""
    out = subprocess.run(["lsof", "+D", str(path), "-t"],
                         capture_output=True, text=True)
    return sorted({int(line) for line in out.stdout.split() if line.isdigit()})


def copy_missing(source, destination, conflicts_dir, counters, execute):
    """Copy every durable file of source into destination that is not already
    there. Existing destinations win; differing sources go to conflicts_dir.
    Identical files are skipped. Returns True when every copied file verified.
    """
    ok = True
    for dirpath, dirnames, filenames in os.walk(source):
        dirnames.sort()
        for name in sorted(filenames):
            src = Path(dirpath) / name
            rel = src.relative_to(source)
            if rel.as_posix() == RUNTIME_SOCKET:
                counters["socket-skipped"] += 1
                continue
            dst = destination / rel
            if dst.exists():
                if sha256_of(src) == sha256_of(dst):
                    counters["identical-kept"] += 1
                    continue
                counters["conflicts"] += 1
                log(f"destination exists, kept it; source preserved: {rel} "
                    f"(-> {conflicts_dir / rel})")
                if execute:
                    target = conflicts_dir / rel
                    target.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(src, target)
                    if sha256_of(target) != sha256_of(src):
                        log(f"VERIFICATION FAILED for conflict copy {rel}")
                        ok = False
                continue
            counters["copied"] += 1
            log(f"copy {rel} ({src.stat().st_size} bytes)")
            if execute:
                dst.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(src, dst)
                if sha256_of(dst) != sha256_of(src):
                    log(f"VERIFICATION FAILED for {rel}")
                    ok = False
    return ok


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--library-root", default=None,
                        help="test root replacing ~/Library/Application Support")
    parser.add_argument("--dist-app", default=None,
                        help="path to the replacement dist/Caesura.app")
    parser.add_argument("--retire", action="store_true",
                        help="also retire the two exact old directories (after all checks)")
    parser.add_argument("--execute", action="store_true",
                        help="perform the actions (default: dry run)")
    parser.add_argument("--allow-test-retire", action="store_true",
                        help="allow --retire with a custom --library-root (tests only)")
    args = parser.parse_args()

    repo_root = Path(__file__).resolve().parents[2]
    if args.library_root is None:
        support = Path.home() / "Library" / "Application Support"
    else:
        support = Path(args.library_root)
    dist_app = Path(args.dist_app) if args.dist_app else repo_root / "dist" / "Caesura.app"
    executable = dist_app / "Contents" / "MacOS" / "Caesura"

    old_trial = support / TRIAL_OLD
    old_ordinary = support / ORDINARY_OLD
    new_trial = support / TRIAL_NEW
    new_ordinary = support / ORDINARY_NEW

    if args.retire and args.library_root is not None and not args.allow_test_retire:
        fail("--retire with a custom --library-root needs --allow-test-retire (tests only)")

    execute = args.execute
    mode = "EXECUTE" if execute else "DRY RUN"
    log(f"mode: {mode}; support root: {support}")

    # --- Inventory -----------------------------------------------------------
    trial_tree = durable_tree(old_trial)
    ordinary_tree = durable_tree(old_ordinary)
    if trial_tree is None:
        fail(f"old trial profile is missing: {old_trial}")
    if ordinary_tree is None:
        fail(f"old ordinary profile is missing: {old_ordinary}")
    log(f"inventory: {TRIAL_OLD}: {len(trial_tree)} durable file(s), "
        f"{ORDINARY_OLD}: {len(ordinary_tree)} durable file(s)")
    if "config.json" not in trial_tree:
        fail(f"old trial profile has no config.json: {old_trial}")

    # --- Manifest discovery --------------------------------------------------
    # Every manifest this migration ever wrote, oldest first. A manifest whose
    # recorded source trees still match the live old profiles identifies the
    # backup root to resume (an interrupted copy, a later --retire, a rerun):
    # copies and snapshots are idempotent under it.
    manifests = []
    backup_base = new_trial / "Migration Backup"
    if backup_base.is_dir():
        for candidate in sorted(backup_base.glob("*/*.json")):
            try:
                data = json.loads(candidate.read_text())
            except (OSError, json.JSONDecodeError):
                continue
            data["backup-dir"] = candidate.parent
            manifests.append(data)

    stamp = time.strftime("%Y%m%d-%H%M%S")
    backup_root = backup_base / stamp
    suffix = 1
    while backup_root.exists():
        suffix += 1
        backup_root = backup_base / f"{stamp}-{suffix}"
    prior = next((m["backup-dir"] for m in reversed(manifests)
                  if m.get("sources", {}).get(TRIAL_OLD) == trial_tree
                  and m.get("sources", {}).get(ORDINARY_OLD) == ordinary_tree), None)
    if prior is not None:
        backup_root = prior
        log(f"resuming the migration of {prior}")
    elif manifests and args.retire:
        # Previous migration waves were recorded, but the old profiles no
        # longer match any of them: something wrote to the sources after the
        # recorded migration. Retiring on a fresh inventory would silently
        # bless that change — refuse, and let a copy-only run record a new
        # reviewed backup wave first.
        fail("old profiles changed since the recorded migration (no manifest "
             "matches them) — run without --retire to record a new backup "
             "wave, review it, then retire")
    manifest_path = backup_root / MANIFEST_NAME

    # An existing ordinary profile is only acceptable when it is exactly what
    # a previous run of this migration copied (the matching manifest is the
    # credential); anything else is never overwritten.
    ordinary_existing = durable_tree(new_ordinary) or {}
    if ordinary_existing and not any(
            m.get("sources", {}).get(ORDINARY_OLD) == ordinary_existing
            for m in manifests):
        fail(f"refusing to overwrite an existing ordinary profile: {new_ordinary}")

    # --- Copy + snapshot -----------------------------------------------------
    counters = {"copied": 0, "identical-kept": 0, "conflicts": 0,
                "socket-skipped": 0, "snapshot-copied": 0, "snapshot-repaired": 0}
    verified = True

    if execute:
        backup_root.mkdir(parents=True, exist_ok=True)
    # Full snapshots of both old directories (the recoverable copies the
    # retirement relies on). Missing files are copied; a file that exists but
    # differs from the still-unchanged source is repaired, so the snapshot is
    # complete and correct before it is ever trusted.
    for source in (old_trial, old_ordinary):
        snapshot = backup_root / source.name
        for rel in (durable_tree(source) or {}):
            src = source / rel
            dst = snapshot / rel
            if dst.exists() and sha256_of(dst) == sha256_of(src):
                continue
            counters["snapshot-repaired" if dst.exists() else "snapshot-copied"] += 1
            log(f"snapshot {source.name}/{rel}"
                + (" (repairing)" if dst.exists() else ""))
            if execute:
                dst.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(src, dst)
                if sha256_of(dst) != sha256_of(src):
                    log(f"VERIFICATION FAILED for snapshot {source.name}/{rel}")
                    verified = False

    # Trial data wins for the active profile: merge only missing files.
    verified &= copy_missing(old_trial, new_trial,
                             backup_root / "conflicts" / TRIAL_OLD,
                             counters, execute)
    # The ordinary profile moves to its own new directory, preserved whole.
    verified &= copy_missing(old_ordinary, new_ordinary,
                             backup_root / "conflicts" / ORDINARY_OLD,
                             counters, execute)

    manifest = {
        "timestamp": stamp,
        "sources": {TRIAL_OLD: trial_tree, ORDINARY_OLD: ordinary_tree},
        "backup-root": str(backup_root),
        "counters": counters,
        "complete": verified,
    }
    if execute:
        manifest_path.write_text(json.dumps(manifest, indent=1, sort_keys=True))
        loaded = json.loads(manifest_path.read_text())
        if loaded["sources"] != manifest["sources"]:
            fail("manifest did not round-trip; refusing to continue")

    log(f"copy summary: {json.dumps(counters)}")
    if not verified:
        fail("copy verification failed — nothing was retired; rerun after checking")

    # --- Retirement ----------------------------------------------------------
    if not args.retire:
        log("copy phase complete; retirement skipped (pass --retire)")
        return

    # The verified replacement must be the single running scheduler.
    pids = exact_running_pids(str(executable))
    if len(pids) != 1:
        fail(f"expected exactly one running replacement at {executable}, "
             f"found {len(pids)} — aborting retirement")
    log(f"replacement running as pid {pids[0]}")

    # Responsive IPC of the new profile: its socket must accept a connection.
    if not socket_accepts(new_trial / RUNTIME_SOCKET):
        fail(f"new trial socket is not accepting connections: "
             f"{new_trial / RUNTIME_SOCKET} — aborting retirement")
    log("new trial socket accepts connections (responsive IPC)")

    # The old socket must be dead and nothing may hold the old profiles open.
    if socket_accepts(old_trial / RUNTIME_SOCKET):
        fail(f"old trial socket still answers: {old_trial / RUNTIME_SOCKET} "
             f"— a writer remains, aborting retirement")
    for directory in (old_trial, old_ordinary):
        writers = open_writers_under(directory)
        if writers:
            fail(f"processes still hold {directory} open: {writers} "
                 f"— aborting retirement")

    # The full backup trees must equal the recorded source manifests — every
    # file of both snapshots, not only what this run copied: retirement is
    # only allowed when the recoverable copies are complete and intact.
    for name, recorded in ((TRIAL_OLD, trial_tree), (ORDINARY_OLD, ordinary_tree)):
        snapshot = backup_root / name
        actual = durable_tree(snapshot) if snapshot.is_dir() else None
        if actual != recorded:
            if actual is None:
                fail(f"backup of {name} is missing: {snapshot} — aborting retirement")
            changed = sorted(set(recorded) ^ set(actual))
            differing = sorted(r for r in set(recorded) & set(actual)
                               if recorded[r] != actual[r])
            fail(f"backup of {name} is incomplete or corrupted "
                 f"(missing/extra: {changed[:5]}, differing: {differing[:5]}) "
                 f"— aborting retirement")
    log(f"backup trees verified against the manifest: {backup_root}")

    # The old profiles must be exactly what was inventoried.
    for name, root, recorded in ((TRIAL_OLD, old_trial, trial_tree),
                                 (ORDINARY_OLD, old_ordinary, ordinary_tree)):
        current = durable_tree(root)
        if current != recorded:
            changed = sorted(set(recorded) ^ set(current))
            differing = sorted(r for r in set(recorded) & set(current)
                               if recorded[r] != current[r])
            fail(f"old profile {name} changed since inventory "
                 f"(added/removed: {changed[:5]}, modified: {differing[:5]}) "
                 f"— aborting retirement")
    log("old profiles unchanged since inventory")

    for root in (old_trial, old_ordinary):
        if execute:
            shutil.rmtree(root)
            log(f"retired: {root}")
        else:
            log(f"would retire: {root}")

    log("migration complete")


if __name__ == "__main__":
    main()
