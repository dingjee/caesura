# Poem controls, JTL residue and native profile migration — result

Executed 2026-11-03 by OpenCode (Kimi for Coding), per
`docs/POEM-CONTROLS-AND-PROFILE-PLAN.md`. Investigation/acceptance: Codex.
No commit, no push, no Issue/PR. Pre-existing working-tree changes were
preserved. Codex minimal read-only acceptance passed afterwards (bundle
identity, single process, IPC, data locations, config equality, button
diff review).

## 1. JTL button: icon placement and the multi-monitor residue

**Residue object:** the "jump to the last / back to the newest words" button
(`ResumeReadingEntry`, abbreviated JTL) — not the break window, and no exit
animation was touched (`BreakRevealDriver` is unchanged).

**Findings (root causes, both fixed):**

1. `poemBreakView` applied `.opacity(state.poemOpacity)` to `poemText`
   *before* `.overlay(alignment: .bottom)`, so the JTL button rendered
   **outside** the poem's opacity scope: when the verses faded out (cursor
   left, or the break reached its captured duration) the button stayed at
   full brightness on screen.
2. `BreakWindowState.updatePoem()` zeroed `poemOpacity` at the captured
   duration but never reset `poemUserScrolled`, so the button's only
   display condition stayed true on a poem that was gone for good — visible
   during manual-await and across display-change window rebuilds.

Each display carries its own `BreakWindowState`; the screen the reader had
scrolled kept its button while the poem was gone — the reported
"multi-screen disappearance residue". Per-screen state independence is
existing design and was left as is.

**Changes (`native/Sources/CaesuraApp/BreakContentView.swift`):**

- The overlay was moved **inside** the `.opacity(state.poemOpacity)` scope:
  the button fades out and disappears together with the poem, and returns
  with it. When the poem reappears, the button shows exactly when a manual
  review is active (`poemUserScrolled`) — the accepted semantics.
- Display condition is now `poemUserScrolled && poemOpacity > 0`.
- The button is **icon-only** (`arrow.down.to.line` in a glass circle,
  hit area ≥ 30 pt, hover help, accessible name from the locale strings),
  anchored `.bottomTrailing` inside the body viewport, offset left by the
  real `NSScroller.scrollerWidth(for:preferredScrollerStyle)` plus a small
  gap — geometry accounts for overlay/legacy scroller widths, no text-width
  guessing.
- `updatePoem()` resets `poemUserScrolled` when the poem is gone for good.

**Regression check:** `PoemProbe.residueProbe()`
(`native/Sources/CaesuraApp/PoemProbe.swift`), a display-independent,
offscreen-rendered AppKit probe (never-ordered hosting view, no pointer, no
activation). It compares the rightmost tenth of the window **within one
visibility state** (review renders seeded to the same reading position, so
only the button can differ): shown-with-review diff 0.646, hidden diff 0.0,
returns-with-review diff 0.646, `finishCleansReviewState` true. Verified on
both the debug build and the installed trial bundle.

## 2. Profile migration (explicitly authorized)

Directories now (trial/ordinary separated):

- Trial (active): `~/Library/Application Support/Caesura`
  (`TrialSupport.trialDirectoryName`), bundle ID unchanged
  `net.hovancik.stretchly.trial`, visible name `Caesura`.
- Ordinary native: `~/Library/Application Support/CaesuraNative`
  (`TrialSupport.ordinaryDirectoryName`).
- `TrialSupport.importCompatibleProfileIfNeeded`: trial imports
  `StretchlyNativeTrial` then `StretchlyNative`; the ordinary app imports
  only `StretchlyNative`. Isolated runs (`--data-dir` /
  `CAESURA_NATIVE_DATA_DIR`) never import. The bundled CLI resolves the
  same paths through `AppPaths`.

**Tool:** `native/scripts/migrate-local-profiles.py` — non-destructive
(existing destinations win; differing sources preserved under
`Caesura/Migration Backup/<stamp>/conflicts/…`), full snapshots of both old
directories, SHA-256 manifests (JSON-native lists), idempotent reruns keyed
by the matching manifest, retirement only after: exactly one replacement
process at the exact executable path, the new socket accepts a connection,
the old socket is dead, no process holds the old directories
(`lsof +D` on the two exact dirs), both **full backup trees** hash-equal
the recorded manifests, and both old directories are unchanged since the
recorded migration (any divergence refuses `--retire`; a copy-only run
records a new reviewed wave). Retired with `shutil.rmtree` exactly the two
old directories.

**Fixture regression test:** `native/Tests/MigrationTests/test_migrate_local_profiles.py`
via `native/scripts/migration-test.sh` — temporary roots only
(`mkdtemp` + `finally` cleanup), a self-built sleeper stands in as the
replacement executable, `--allow-test-retire` gates test retirement. 29
checks (dry-run purity, copy/snapshot/conflict semantics, idempotent rerun,
changed-source refusal, ordinary guards, snapshot repair/restore,
retirement) — all pass.

## 3. Checks actually run

| Check | Result |
| --- | --- |
| `native/scripts/test.sh` (build + core suite) | 215/215 passed |
| Poem probe incl. `residueProbe` (debug build, isolated data dir) | all residue booleans true |
| `native/scripts/migration-test.sh` (temporary roots) | 29/29 PASS |
| `native/scripts/install-dist.sh` (release build, staged + installed verification, self-check, exact-path stop of pid 1047, restart) | installed; replacement verified; pid 8100, one scheduler |
| Poem probe against the installed trial bundle (isolated data dir, offscreen) | residue + bridge booleans all true |
| Migration dry run / `--execute` / `--execute --retire` (real run) | completed; see below |
| Codex read-only acceptance | passed (config keys 92/88 identical, backups 5/5 SHA-256 match, single pid, socket connectable) |

## 4. Migration evidence (this machine)

- Auto-import on first launch copied the trial `config.json` byte-identical
  into `~/Library/Application Support/Caesura` (source untouched).
- Copy phase: 3 durable trial files (config, two logs; `cli.sock` excluded),
  2 ordinary files; 1 conflict (the new instance's fresh
  `caesura-native.log` won; the old log preserved under
  `Migration Backup/20261103-061137/conflicts/StretchlyNativeTrial/`).
- Retirement checks logged: replacement pid 8100 (exact path), new socket
  accepts connections, backup trees verified against the manifest, old
  profiles unchanged, `lsof` found no writers.
- **Retired:** `~/Library/Application Support/StretchlyNativeTrial` and
  `~/Library/Application Support/StretchlyNative` (both verified gone).
- **Backups (kept):** `~/Library/Application Support/Caesura/Migration Backup/20261103-061137/`
  with full snapshots of both old directories, the conflict copy and
  `migration-manifest.json`.
- **Active profile:** `~/Library/Application Support/Caesura` — config 92
  keys with migration markers and poem progress intact; ordinary profile
  preserved at `~/Library/Application Support/CaesuraNative`.
- The legacy Electron `Stretchly` directory does not exist on this machine;
  nothing else under `~/Library` was touched.

## 5. Not verified (limits)

- **No live dual-display run of the break window was performed.** The JTL
  fix is verified by offscreen rendering only; button geometry next to a
  live scroller was not exercised on a real secondary display.
- Socket "responsive IPC" is a **connect-accept check**, not a
  command/response round-trip.
- Poem timing/follow semantics were not re-tested beyond the suites above.

## 6. Cleanup

Known session-owned temp artifacts removed: `/tmp/caesura-poem-probe-*` (4),
`/tmp/caesura-migtest*` (2), `residue-*.png` (already absent). Handoff
snapshot `/var/folders/.../caesura-oc-review-1d5pha8g` left intact for the
reviewer. `native/scripts/clean.sh --apply` run as the last maintenance
step.
