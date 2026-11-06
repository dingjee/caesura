# Poem controls, dismissal and native profile migration

Requested 2026-11-03. Investigation and acceptance: Codex; implementation and
self-check: OpenCode interactive session, Kimi for Coding. No commit or push.
The working tree already contains contributor changes: preserve all of them.

## Authorized scope and findings

- The return control is `ResumeReadingEntry` in `BreakContentView.swift`,
  currently a text capsule in a bottom-centred overlay of `poemText`.
  Make it an icon only, bottom trailing **inside the body viewport**, to the
  left of the native vertical scroller, with a usable hit area, hover help and
  accessible name. Keep the existing follow/review semantics and poem timing.
  Account for overlay and legacy scroller widths rather than guessing text width.
- User clarification: the multi-monitor disappearance residue is the **JTL
  button**, not the break-window reveal. Trace each window's review/follow,
  opacity and hover state. The current overlay is attached AFTER the body's
  `.opacity(state.poemOpacity)`, so the button may remain when the body fades.
  Establish the specific button lifecycle failure across displays and fix it;
  do not expand into an unrelated window-exit or animation redesign.
- Current persistent trial is pid 1047 at this checkout's
  `dist/Caesura.app/Contents/MacOS/Caesura` (recheck before stopping it).
  Its profile is `~/Library/Application Support/StretchlyNativeTrial`;
  `StretchlyNative` also exists. `Caesura` does not currently exist.
  Both old profiles have config and logs; asset folders are currently empty;
  the running trial has `cli.sock`. Re-inventory after stopping, before copying.

## Execution sequence

1. Read AGENTS.md and CONTRIBUTING.md fully. This is explicitly delegated local
   work; prepare no public Issue, PR, commit or push. Preserve existing edits.
2. Implement the icon placement and bounded JTL visibility/lifecycle fix. Add meaningful
   regression checks only where needed (a display-independent AppKit probe can
   use multiple hidden windows on the secondary display). Never activate or
   cover the primary display; never operate another app's media or windows.
3. The user's explicit rename/migrate/retire request supersedes the old fixed
   trial-directory rule. Keep `net.hovancik.stretchly.trial` and visible name
   `Caesura`; use `~/Library/Application Support/Caesura` for the persistent
   trial. Keep ordinary native data separate (e.g. `CaesuraNative`), and preserve
   `--data-dir` / environment isolation. Ensure bundled CLI uses the same path.
   Do not touch Electron's `Stretchly` directory or unrelated Library contents.
4. Implement tested, non-destructive automatic compatibility import; importing
   must preserve config, unknown keys, poem progress, migration markers, custom
   assets and other durable files. Existing destinations win. Do not silently
   start with defaults after a failed or incomplete import. Check old absolute
   asset references if present. Skip runtime sockets/locks. Automatic import
   never deletes its source; isolated runs never import persistent profiles.
5. Provide a narrowly scoped **explicit maintenance migration** for this machine
   (may integrate with install-dist if safe): build+verify replacement first;
   stop only the verified old trial executable cleanly; snapshot/copy and
   validate all durable files of both exact old directories; trial data wins
   for the active profile, preserve the ordinary profile and any conflicts under
   named migration backups within Caesura. Never overwrite an existing profile.
   Use checksums/tree verification, handle partial copies and reruns safely.
   Exclude stale sockets from active data. Retire only the two exact old
   directories **after verified replacement launch and responsive IPC**, with
   recoverable copies kept under the new Caesura directory. Abort deletion if
   the old profiles change or a writer remains. Do not broadly sweep Library,
   change permissions, or touch unrelated login registrations.
6. Update README and Unreleased CHANGELOG. Update the conflicting AGENTS.md
   directory guidance to match the explicit migration, preserving other rules.
7. Self-check with `native/scripts/test.sh` (custom runner, never swift test),
   targeted migration tests (temporary roots only), compile/package via
   `native/scripts/install-dist.sh`, and `verify-app.sh` as packaging requires.
   Run at most one relevant quiet lifecycle/probe check with temporary profile
   and secondary display. If unavailable, report GUI skipped; no fallback.
   Avoid unrelated suites and repeated acceptance loops.
8. Execute the explicit migration for this machine as authorized above, refresh
   `dist/Caesura.app` with install-dist.sh, verify one live exact executable,
   new data path, responsive CLI, preserved config/progress/assets and no old
   scheduler. Keep one usable app throughout and rollback on failure.
9. Write a concise implementation/self-check report to
   `docs/POEM-CONTROLS-AND-PROFILE-RESULT.md`: findings with evidence, files,
   exact checks and outcomes, migration manifests/backup locations, limits.
   Run `native/scripts/clean.sh --apply` as the last maintenance action.

## Codex minimal acceptance

Review only the incremental changes against the pre-OpenCode snapshot. Verify
icon geometry and JTL visibility across screens, migration safety and profile selection;
read OC's evidence. Perform read-only checks of installed bundle identity,
single process/IPC and new/old data locations. Do not rerun passing self-checks
without a concrete failure. If changes need revision, send the bounded finding
back to the same OC interactive session for implementation and recheck.
