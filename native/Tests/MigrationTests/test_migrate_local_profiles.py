#!/usr/bin/env python3
"""Fixture regression test of migrate-local-profiles.py (temporary roots).

Runs the explicit profile migration tool against an isolated temporary
Library root and a self-built sleeper standing in as the verified replacement
executable, so the retirement checks (exact single process, live new socket,
dead old socket) run hermetically — the real installation and the real
~/Library are never touched.

Covered behavior:

- dry run changes nothing
- copy: JSON-native manifest round-trip, full snapshots, conflict backups,
  runtime sockets excluded, existing destination files win
- rerun: idempotent resume under the same backup root; an existing ordinary
  destination is accepted only with the matching manifest credential
- sources changed after the recorded migration: --retire refuses; a copy-only
  run records a new reviewed wave; --retire then proceeds
- an unrelated or tampered ordinary destination refuses
- corrupted or incomplete snapshots are repaired/restored from the unchanged
  sources before retirement; retirement deletes only the two exact old dirs
  and keeps the backups

Usage: migration-test.sh (or: python3 test_migrate_local_profiles.py)
"""

import shutil
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path

TOOL = (Path(__file__).resolve().parents[2] / "scripts"
        / "migrate-local-profiles.py")

failures = []


def check(name, cond, extra=""):
    print(("PASS " if cond else "FAIL ") + name
          + (f" -- {extra}" if extra and not cond else ""), flush=True)
    if not cond:
        failures.append(name)


class Fixture:
    """The temporary Library root and the fake replacement app."""

    def __init__(self):
        # Short prefix: the fixture binds AF_UNIX sockets whose paths are
        # limited to about 100 characters.
        self.root = Path(tempfile.mkdtemp(prefix="cmig-"))
        self.trial_old = self.root / "StretchlyNativeTrial"
        self.ord_old = self.root / "StretchlyNative"
        self.trial_new = self.root / "Caesura"
        self.ord_new = self.root / "CaesuraNative"
        self.dist_app = self.root / "Dist.app"
        executable = self.dist_app / "Contents" / "MacOS" / "Caesura"
        executable.parent.mkdir(parents=True)
        source = self.root / "sleeper.c"
        source.write_text("#include <unistd.h>\n#include <signal.h>\n"
                          "int main(void){for(;;)pause();return 0;}\n")
        subprocess.run(["cc", "-o", str(executable), str(source)],
                       check=True, capture_output=True)
        self.process = subprocess.Popen([str(executable)])

    def build_profiles(self):
        for d in (self.trial_old / "audio", self.trial_old / "images",
                  self.ord_old / "audio"):
            d.mkdir(parents=True, exist_ok=True)
        (self.trial_old / "config.json").write_text(
            '{"trial": true, "poemProgress": 42}')
        (self.trial_old / "caesura-native.log").write_text("old trial log\n")
        (self.trial_old / "stretchly-native.log").write_text("legacy log\n")
        self.trial_old.joinpath("cli.sock").unlink(missing_ok=True)
        s = socket.socket(socket.AF_UNIX)
        s.bind(str(self.trial_old / "cli.sock"))
        s.close()
        (self.ord_old / "config.json").write_text('{"ordinary": true}')
        (self.ord_old / "stretchly-native.log").write_text("ordinary log\n")
        # The replacement app already started: the trial destination exists
        # with the auto-imported config and a fresh log; its socket is live.
        self.trial_new.mkdir(parents=True, exist_ok=True)
        (self.trial_new / "config.json").write_text(
            '{"trial": true, "poemProgress": 42}')
        (self.trial_new / "caesura-native.log").write_text("fresh log\n")
        return self.live_socket()

    def live_socket(self):
        self.trial_new.joinpath("cli.sock").unlink(missing_ok=True)
        s = socket.socket(socket.AF_UNIX)
        s.bind(str(self.trial_new / "cli.sock"))
        s.listen(1)
        return s

    def run(self, *extra):
        return subprocess.run(
            [sys.executable, str(TOOL), "--library-root", str(self.root),
             "--dist-app", str(self.dist_app), "--allow-test-retire", *extra],
            capture_output=True, text=True)

    def backup_dirs(self):
        return sorted((self.trial_new / "Migration Backup").glob("*"))

    def close(self):
        self.process.terminate()
        try:
            self.process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.process.kill()
        shutil.rmtree(self.root, ignore_errors=True)


def scenario_copy_and_rerun():
    fx = Fixture()
    try:
        fx.build_profiles().close()
        before = sorted(str(p.relative_to(fx.root)) for p in fx.root.rglob("*"))
        r = fx.run()
        after = sorted(str(p.relative_to(fx.root)) for p in fx.root.rglob("*"))
        check("dry-run rc=0", r.returncode == 0, r.stderr)
        check("dry-run touches nothing", before == after)

        live = fx.build_profiles()
        r = fx.run("--execute")
        check("copy rc=0", r.returncode == 0, r.stderr)
        check("ordinary migrated",
              (fx.ord_new / "config.json").read_text() == '{"ordinary": true}')
        check("old ordinary log migrated",
              (fx.ord_new / "stretchly-native.log").exists())
        check("trial config kept (identical)",
              (fx.trial_new / "config.json").read_text()
              == '{"trial": true, "poemProgress": 42}')
        check("fresh log not overwritten",
              (fx.trial_new / "caesura-native.log").read_text() == "fresh log\n")
        check("old socket not copied into ordinary",
              not (fx.ord_new / "cli.sock").exists())
        check("one backup root", len(fx.backup_dirs()) == 1, str(fx.backup_dirs()))
        b = fx.backup_dirs()[0]
        check("snapshot trial complete",
              (b / "StretchlyNativeTrial" / "stretchly-native.log").exists())
        check("snapshot ordinary complete",
              (b / "StretchlyNative" / "config.json").exists())
        check("conflicting source preserved",
              (b / "conflicts" / "StretchlyNativeTrial" / "caesura-native.log")
              .read_text() == "old trial log\n")
        check("manifest exists", (b / "migration-manifest.json").exists())
        live.close()

        live = fx.live_socket()
        r = fx.run("--execute")
        check("rerun rc=0 (idempotent resume)", r.returncode == 0, r.stderr)
        check("rerun no extra backup", len(fx.backup_dirs()) == 1)
        live.close()
    finally:
        fx.close()


def scenario_changed_source():
    fx = Fixture()
    try:
        fx.build_profiles().close()
        r = fx.run("--execute")
        check("initial copy rc=0", r.returncode == 0, r.stderr)
        (fx.trial_old / "config.json").write_text(
            '{"trial": true, "poemProgress": 43}')
        live = fx.live_socket()
        r = fx.run("--execute", "--retire")
        check("changed source refuses retire",
              r.returncode != 0
              and "changed since the recorded migration" in r.stderr, r.stderr)
        check("old dirs kept on refusal",
              fx.trial_old.exists() and fx.ord_old.exists())
        r = fx.run("--execute")
        check("copy-only records new wave",
              r.returncode == 0 and len(fx.backup_dirs()) == 2, r.stderr)
        r = fx.run("--execute", "--retire")
        check("retire ok after reviewed wave", r.returncode == 0, r.stderr)
        check("old dirs retired",
              not fx.trial_old.exists() and not fx.ord_old.exists())
        b2 = fx.backup_dirs()[-1]
        check("changed source preserved in new wave",
              (b2 / "StretchlyNativeTrial" / "config.json").read_text()
              == '{"trial": true, "poemProgress": 43}')
        live.close()
    finally:
        fx.close()


def scenario_ordinary_guard():
    fx = Fixture()
    try:
        # Unrelated pre-existing ordinary profile refuses.
        fx.ord_new.mkdir(parents=True)
        (fx.ord_new / "config.json").write_text("foreign profile")
        fx.build_profiles().close()
        r = fx.run("--execute")
        check("foreign ordinary refuses",
              r.returncode != 0 and "existing ordinary" in r.stderr, r.stderr)

        # A migrated-then-tampered ordinary destination refuses; restored it
        # is accepted again.
        shutil.rmtree(fx.ord_new)
        r = fx.run("--execute")
        check("initial copy rc=0", r.returncode == 0, r.stderr)
        (fx.ord_new / "config.json").write_text("tampered")
        r = fx.run("--execute")
        check("tampered ordinary refuses",
              r.returncode != 0 and "existing ordinary" in r.stderr, r.stderr)
        (fx.ord_new / "config.json").write_text('{"ordinary": true}')
        r = fx.run("--execute")
        check("restored ordinary accepted", r.returncode == 0, r.stderr)
    finally:
        fx.close()


def scenario_backup_integrity():
    fx = Fixture()
    try:
        fx.build_profiles().close()
        r = fx.run("--execute")
        check("initial copy rc=0", r.returncode == 0, r.stderr)
        # Corrupted snapshot is repaired from the unchanged source.
        b = fx.backup_dirs()[-1]
        (b / "StretchlyNative" / "config.json").write_text("corrupted")
        live = fx.live_socket()
        r = fx.run("--execute", "--retire")
        check("corrupt snapshot repaired, retire ok",
              r.returncode == 0 and "repairing" in r.stdout,
              r.stderr + r.stdout)
        check("repaired backup matches source",
              (b / "StretchlyNative" / "config.json").read_text()
              == '{"ordinary": true}')
        live.close()
    finally:
        fx.close()


def scenario_incomplete_snapshot_and_retire():
    fx = Fixture()
    try:
        fx.build_profiles().close()
        r = fx.run("--execute")
        check("initial copy rc=0", r.returncode == 0, r.stderr)
        b = fx.backup_dirs()[-1]
        (b / "StretchlyNativeTrial" / "stretchly-native.log").unlink()
        live = fx.live_socket()
        r = fx.run("--execute", "--retire")
        check("incomplete snapshot restored, retire ok",
              r.returncode == 0, r.stderr + r.stdout)
        check("old dirs retired",
              not fx.trial_old.exists() and not fx.ord_old.exists())
        check("backups survive retirement",
              (b / "StretchlyNativeTrial" / "config.json").exists())
        live.close()
    finally:
        fx.close()


def main():
    start = time.time()
    scenario_copy_and_rerun()
    scenario_changed_source()
    scenario_ordinary_guard()
    scenario_backup_integrity()
    scenario_incomplete_snapshot_and_retire()
    print(f"{'ALL PASS' if not failures else 'FAILURES'}: "
          f"{failures if failures else 'none'} "
          f"({time.time() - start:.1f}s)", flush=True)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
