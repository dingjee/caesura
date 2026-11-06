# Break ripple / poem spacing / menu skip — result (2026-11-06)

Local maintenance task (OpenCode implementation and verification; Codex did
minimal acceptance). No Issue agreement is claimed, nothing committed, pushed
or submitted. All work-tree changes are preserved uncommitted.

## Scope and evidence

Two items were implemented (poem line spacing; the two direct menu skip
items); the third — the ripple/scroller investigation — was checked but the
reported on-screen symptoms were **not reproduced** (see item 3). This
session completed the two acceptance fixes Codex found, re-ran the checks
with the correct toolchain and performed deployment.

### 1. Poem line spacing (default 1.2×, preference 1.0–2.0)

- `CaesuraCore/PoemSpacing.swift`: multiplier policy — default 1.2, range
  1.0–2.0, step 0.1, persisted as a Double under `poemLineSpacing`
  (`DefaultSettings` default, `SettingsPolicy.boundedDoubleKeys`,
  sanitising on write/load).
- `factor(settings:)` now reads through `SettingsStore.getBoundedDouble(_:)`
  (this session's acceptance fix 2): the accessor is on the production read
  path (Preferences binding, break-settings capture in `AppCoordinator`,
  Today's-poem reading window), not only in tests. A missing key returns the
  registered default 1.2; a wrong type or non-finite value falls back to it;
  an out-of-range value is clamped.
- `BreakContentView` measures the body, derives `lineCenters`, draws the
  stack and builds the content key with one shared spacing value; the
  multiplier is captured with the break settings (`AppCoordinator` line ~762),
  so a new value reaches the **next break**; the Today's-poem reading window
  reads it when it opens (`AppCoordinator` line ~1593). No scheduler restart,
  poem timing or rotation change.
- Acceptance fix 1 (this session): the layout cache key
  `PoemBodyLayoutResolver.Key.spacing` and the hashing in
  `BreakContentView.poemContentKey` were rounded (`Int(spacing.rounded())`);
  two nearby multipliers (e.g. 8.76 and 9.49 from base 7.3) could hit the
  same cache entry and share a measured height / hosted poem. Both keys now
  carry the exact `CGFloat` spacing. No other cache keys were extended.
- New offscreen probe section `spacing` in `PoemProbe` (real cache path):
  base 7.3, spacings 8.76 and 9.49 — `nearbySpacingsMeasureDifferentHeights`,
  `smallSpacingMeasuredExactly`, `largeSpacingMeasuredExactly` all true
  (contentHeight equals independently measured wrapped heights + exact
  spacing × (blocks − 1) + slack).

### 2. Menu bar: two direct skip items

- `CaesuraCore/MenuSkipPlan.swift`: one item per enabled break type; minutes
  only for the type the planner currently schedules (its countdown is exact;
  rounded, ≥ 1 minute) — the long break never wears the mini countdown, and
  no minutes are invented for unplanned types.
- `StatusBarController`: the former countdown item and Skip submenu are
  replaced by two top-level items ("Skip n min — start a Mini/Long break
  now"; natural zh-CN wording), rebuilt on every menu open, wired to the
  existing immediate-skip callbacks. Pause/DND/exclusion/strict/disabled-type
  semantics unchanged (no items while paused etc.).
- Behaviour regressions in `Tests/CaesuraCoreTests/MenuSkipPlanTests.swift`
  (plus `PoemSpacingTests`) run inside the core suite.

### 3. Ripple/scroller investigation (no production ripple change)

User-reported on-screen symptoms (an extra circle centre, a scrollbar-like
bar during the animation) were **not reproduced**. Existing evidence only:

- `RevealProbe` (offscreen, real driver, injected pointer/clock) asserts:
  `contentMaskPresentDuringTheWave`, `scrollerInsideTheMask`,
  `overlayScrollerAccepted`, `maskRemovedAfterTheExit`,
  `contentMaskRemovedAfterCancel` — all **true** in this session's run with a
  freshly built binary. An earlier `false` reading was traced to executing a
  stale binary after a wrong-toolchain compile; with the correct
  `DEVELOPER_DIR` build they pass.
- The scroller is a descendant of the mask host; the overlay style is
  accepted (not demoted); masks are removed after settle/exit/cancel.
- No root cause is claimed; no production reveal/mask code was changed. The
  pointer-following circle centre is preserved.

## Changed files

- `native/Sources/CaesuraCore/PoemSpacing.swift` — production read through
  `getBoundedDouble` (this session).
- `native/Sources/CaesuraApp/PoemViewport.swift` — exact-`CGFloat` spacing in
  `PoemBodyLayoutResolver.Key` (this session).
- `native/Sources/CaesuraApp/BreakContentView.swift` — exact spacing hash in
  `poemContentKey` (this session).
- `native/Sources/CaesuraApp/PoemProbe.swift` — new `spacing` probe section
  (this session).
- Earlier sessions: `PoemSpacing.swift`, `MenuSkipPlan.swift` (new),
  `StatusBarController.swift`, `BreakContentView.swift`, `PoemWindow.swift`,
  `PreferencesWindow.swift`, `AppCoordinator.swift`, `RevealProbe.swift`,
  `SettingsStore.swift`, `DefaultSettings.swift`, locales (`en`, `zh-CN`),
  `Tests/CaesuraCoreTests/MenuSkipPlanTests.swift` (incl. `PoemSpacingTests`),
  test registration.
- `README.md`, `CHANGELOG.md` — Unreleased entries for spacing, menu skip,
  applicability note (next break / reopened reading window) and AI-assistance
  disclosure. No version change.

## Checks actually run

| Check | Command | Result |
|---|---|---|
| Core suite | `./native/scripts/test.sh` (toolchain built in) | **236/236 passed**, exit 0 |
| App build | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -c release --product Caesura` | exit 0, no errors (full log reviewed) |
| Offscreen probe | fresh binary, `CAESURA_POEM_PROBE=$TMPDIR/…`, `CAESURA_NATIVE_DATA_DIR=$TMPDIR/…` temp profile | exit 0; 45 boolean checks: 44 true, 1 informational |
| Radial mask raster | not re-run this session | passed 15/15 in the previous session, before this task's acceptance fixes; this session's changes touch no production raster/mask drawing code, so the run was not repeated (the `RevealProbe` checks above verify mask attachment/removal and scroller placement in the view tree, not the pixel-level raster verification of that script) |

Probe detail: the one non-true value is `bridge.scroller.overlay.inkPresent =
false` with `measured = true` — the documented rest state of the overlay
scroller (the native fade hides it entirely; no track residue), asserted
alongside `overlayAccepted: true` and the legacy-style drawing checks (all
true). All five new reveal checks and all three spacing checks are true.
Probe output was produced by the binary built in the same session (old probe
output was discarded as instructed).

## Deployment

- Pre-verification: `verify-app.sh dist/Caesura.app` → valid, satisfies DR.
  Running instance pid 804 from the exact dist path.
- Rollback saved **before** install: `dist/Caesura.app.rollback-20261106-165246`
  (the install script's own aside is removed by it; this copy is separate).
- `CAESURA_NATIVE_UNIVERSAL=0 ./native/scripts/install-dist.sh` → exit 0;
  installed, verified, restarted (new pid 63041), "one scheduler and
  responsive IPC".
- Post-install verification: both executables (`Caesura`, `caesura-cli`)
  `lipo -archs` → **arm64 only**; bundle id `net.hovancik.stretchly.trial`,
  visible name `Caesura`; single running pid 63041 at the exact dist path;
  `caesura-cli status` answers with that pid, path and trial identity.
  Profiles `~/Library/Application Support/Caesura` and `CaesuraNative`
  untouched; no real profile, migration backup, system or login-item change.
- Owned build residue: `native/dist` is absent (nothing to remove).
- Rollback policy: newest copy verified (valid on disk, satisfies DR,
  arm64-only) and the older `dist/Caesura.app.rollback-20261104-193113` was
  pruned afterwards — exactly one verified usable rollback remains.
- Final maintenance: `native/scripts/clean.sh --apply` ran and its summary
  reported `clean applied` (only the generated `.build` directory was
  removed; dist, profiles and sources stayed protected). The process exit
  code was not captured separately, so the script's own summary line is the
  recorded evidence.

## Settings capture / cancellation / reinitialisation

The spacing multiplier is a pure capture-at-break-start read
(`AppCoordinator` → `BreakContentView.Model.poemLineSpacing`): it adds no
timer, no cancellation path and no scheduler reinitialisation. The menu items
are rebuilt on every menu open from the planner's current state and reuse the
existing skip actions, so pause/resume and skip semantics are unchanged
(covered by the menu tests). The layout-cache key change affects cache
identity only; measurement stays deterministic and the cache keeps its
8-entry bound.

## Not verified / limits

- No visible GUI check was run (offscreen chosen this round; the dynamic,
  hard-to-screenshot symptoms were never reproduced offscreen).
- `radial-mask-test.sh` was not re-run this session (see table above).
- The on-screen ripple symptoms remain unexplained; no fix is claimed.
- Line-spacing changes are applied at the next break (captured settings);
  the reading window applies a new value on reopen. This is stated in
  README/CHANGELOG.

AI assistance: implemented and documented with AI assistance (OpenCode) and
verified locally; to be reviewed and maintained by the contributor.
