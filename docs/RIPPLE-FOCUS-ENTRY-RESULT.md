# Ripple / focus / entry — minimal verification result

Date: 2026-11-03 · Xcode toolchain (`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`)
Scope: ripple tween tokens+curve, reveal focus anchor, JTL ring. Local work only; no Issue/PR, no commit.

## Changes
- `native/Sources/CaesuraCore/Motion.swift`: `breakEntryMillis` 600→900, `breakExitMillis` 400→700; new `TransitionCurve.ripple` (0.37, 0, 0.63, 1) — zero velocity at both ends, monotonic, exact endpoints.
- `native/Sources/CaesuraApp/BreakRevealTransition.swift`: radial entry/exit sampling uses `.ripple`; dismissal keeps sampling the current progress and starts the exit from that value (reversal continuity comes from that sampled start, not from sharing the curve). Comments updated.
- `native/Sources/CaesuraApp/Tween.swift`: `breakEntry`/`breakExit` adapters use `.ripple`.
- `native/Sources/CaesuraApp/BreakContentView.swift`:
  - `PoemFocusGeometry.revealAnchorY(following:frontierLine:reportedAnchorY:)` — growing poem reads at the frontier center while `emphasis.following` (including the first frame with controller default anchorY=0); only a real review (`following == false`) reads the reported anchor; invalid frontier index falls back. `PoemRevealView` wired through this helper; full poem rules unchanged.
  - `ResumeReadingEntry`: added `.overlay(Circle().strokeBorder(.white, lineWidth: 1))` on the existing frame — transparent background, position, size, `.contentShape(Rectangle())` hit area, help/a11y name, show/hide rules unchanged.

## Checks actually run
1. `native/scripts/test.sh` — **ran twice**; the second run was only to extract the motion-specific lines (both runs: build OK, **216/216 passed**). Its internal `swift build` is the native app compile (no separate compile). New passing test: `motion: the ripple wave rises and lands gently` (first/last tenth gentle; old entering/exiting shapes fail it). `.ripple` added to endpoint/monotonic loops. test.sh's own mktemp work dir self-cleans via trap.
2. Offscreen PoemProbe — **once**: `.build/debug/Caesura` with `CAESURA_POEM_PROBE=<probe dir>` and temp profile via `CAESURA_NATIVE_DATA_DIR`; no window ordered in, no activation, no sound. Results:
   - focus (new): `frontierLeadsOnFirstFrame=true` (first-frame anchor = frontier center 196.6, frontier line 3 opacity 1, first line 0.26); `hoverKeepsRetention=true`; `hoverMovesNoFocus=true`; `scrollTakesTheReview=true`; `entryRestoresTheFollow=true`.
   - bridge (existing): `followAnchor 700/700` (locked frontier), `reviewAnchor 200/200`, `resumeAnchor 700/700`, mount/follow/resume reader-free, review continuous, scroller overlay accepted.
   - residue (existing): entry only with review (diff 0.72), gone with poem (diff 0), finish cleans review state — ring renders inside the existing differential comparison; no new pixel test added.
3. JTL ring on-screen look: source review only (per instruction).

## Temp paths used this round (for your cleanup)
- Probe output dir: `/private/var/folders/dt/hqqgsgbj2kx2y6zk22dvzrc80000gn/T/opencode/caesura-probe-run` (PNGs, `probe.json`, `probe-run.log`)
- Temp profile dir: `/private/var/folders/dt/hqqgsgbj2kx2y6zk22dvzrc80000gn/T/opencode/caesura-probe-profile`
- Both were **already removed** (`rm -rf`) right after the probe run; nothing should remain. Repo `.build/` artifacts are the normal build cache, left in place.

## Docs
- `README.md`: focus follows only the actual reading position (first appearance/hover never brighten old lines), entry "thin white ring", reveal 900/700 + at-rest curve.
- `CHANGELOG.md` [Unreleased]: 900/700 + dedicated zero-velocity wave curve, first-appearance/hover rule, entry ring.

## Not verified (visual)
- Live-window wave pacing (900/700, reversal feel) and the ring's on-screen weight: no GUI run this round; mask raster path untouched (`radial-mask-test.sh` not run).
- No dist install/package; no profile, login-item or settings changes; `clean.sh` intentionally left for Codex.
