# JTL and poem scrollbar visual refinement

Requested 2026-11-03. Plan and minimal acceptance: Codex. Implementation and
self-check: OpenCode interactive CLI, GLM 5.3 Flash. No commit, push, Issue or PR.
Preserve all pre-existing dirty files and the installed persistent profile.

## Bounded implementation

1. In `BreakContentView.swift`, move the icon-only JTL toward the verses by
   about one existing button diameter beyond its current trailing inset. Keep
   it bottom trailing within the body, left of the scroller, with readable
   spacing and its existing accessible name and hit area. Use a white glyph
   (`.white`), so it visually belongs to the white verse text. Preserve the
   existing button treatment unless a tiny adjustment is needed; this is not
   a redesign. Keep the overlay inside poem opacity and the review/visibility
   conditions unchanged: verses disappear => JTL disappears with them.
2. In `PoemViewport.swift`, simplify the vertical scrollbar: transparent slot,
   no track/background, only a slim rounded capsule foreground thumb. Prefer
   a small native `NSScroller` drawing subclass installed on the existing
   `PoemScrollView`; reuse AppKit's knob geometry and native event handling.
   Keep wheel, drag, track click, keyboard, auto-follow, review and resume
   working as before. Do not replace scrolling with a custom gesture system.
   Ensure overlay and legacy/always-visible scrollbar preferences do not
   reintroduce a background. No new perpetual refresh timers or animation.
3. Touch only these presentation files and a minimal existing probe adjustment
   if necessary, plus README and Unreleased CHANGELOG. No scheduling, poem
   timing, profile migration, bundle identity or settings changes. Read
   AGENTS.md and CONTRIBUTING.md fully. This is delegated local work, not
   public contribution submission preparation.

## Minimal self-check and delivery

- Use the existing offscreen poem probe once after compilation. If its JTL
  pixel ROI (currently rightmost tenth) misses the moved icon, adjust that
  ROI only; the existing differential comparison uses identical text state,
  so a modestly wider right-edge region is sufficient. Avoid new speculative
  test frameworks or long pixel calibration loops.
- Check actual custom-scroller output offscreen if useful: slot pixels should
  stay clear, thumb should be a capsule. Reuse the existing probe with a small
  bounded check, or inspect a probe image. No tests that merely repeat code.
- No GUI activation, windows on the primary display, audible sounds, other
  apps/media, permissions, login-item experiments or actual data writes. A
  temporary isolated profile is mandatory; prefer offscreen rendering.
- Because the change is appearance only, a successful native compile/package
  and targeted probe are sufficient; do not rerun the unrelated core or
  migration suites. Fix a concrete failure and repeat only its targeted check
  if needed. Do not claim live multi-display verification.
- Run `native/scripts/install-dist.sh`: build and verify replacement before
  swapping; exact-path stop/restart; retain the current Caesura identity and
  `~/Library/Application Support/Caesura` data, and confirm one instance.
- Document exact changes, checks, results and limits in
  `docs/POEM-CONTROLS-STYLE-RESULT.md` (concise). Clean only owned temp assets,
  then run `native/scripts/clean.sh --apply` as the final maintenance step.
- Leave the Codex baseline untouched:
  `/var/folders/dt/hqqgsgbj2kx2y6zk22dvzrc80000gn/T/caesura-oc-controls-review-0i_3pn2m`.

## Codex acceptance

Review only the incremental diff, OC evidence, and one representative
offscreen image if produced. Read installed bundle identity/process/profile
path without driving the UI. Do not repeat a passing check or take over the
implementation. Return a bounded finding to OC only if needed.
