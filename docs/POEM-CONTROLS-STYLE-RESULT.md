# JTL and poem scrollbar visual refinement — result

Implemented 2026-11-03 per `docs/POEM-CONTROLS-STYLE-PLAN.md`. Implementation:
OpenCode interactive CLI (GLM 5.3 Flash), AI-assisted delegated local work —
no commit, push, Issue or PR. Plan and acceptance: Codex.

## Changes

- `native/Sources/CaesuraApp/BreakContentView.swift` — the "back to the newest
  words" entry (`ResumeReadingEntry`) lost its glass plate, stroke and shadow:
  it is now a white glyph over a transparent, unchanged hit frame. The
  `circleDiameter(forHeight:)` helper (unchanged `max(30, height * 0.032)`)
  is shared by the frame and the trailing inset. Inset: scroller width + half
  a button diameter + the previous small gap — the icon sits visibly closer
  to the verses than before, clear of the scroller and of the longest line's
  tail (the initially implemented full-diameter move covered the last line's
  comma in the sample render and was pulled back per review). Overlay stays
  inside `state.poemOpacity`; visibility conditions, help and accessible
  name are unchanged.
- `native/Sources/CaesuraApp/PoemViewport.swift` — new `PoemScroller`
  (`NSScroller` subclass) installed on the existing `PoemScrollView` in
  `makeNSView`. It overrides only `drawKnobSlot(in:highlight:)` (draws
  nothing — no track in overlay or legacy style) and `drawKnob()` (slim white
  capsule, 55% alpha, 85% under Increased Contrast; geometry inset 20% of the
  scroller width per side). It declares
  `isCompatibleWithOverlayScrollers` per the NSScroller subclass contract, so
  the reader's overlay preference is not demoted to legacy. No gesture
  system, no timers, no layout changes; knob geometry and all event handling
  stay AppKit's.
- `native/Sources/CaesuraApp/PoemProbe.swift` — the JTL differential ROI
  widened from the rightmost tenth to the rightmost fifth (moved icon stays
  inside it); the review-state render is written as `review.png`; the bridge
  probe gained one bounded drawing check (see below). No new test frameworks.
- `README.md`, `CHANGELOG.md` ([Unreleased] → Changed) updated; sample images
  under `docs/`.

## Checks actually run

- Release compile of `Caesura` (SwiftPM, Xcode toolchain): clean.
- Offscreen poem probe (`CAESURA_POEM_PROBE`, isolated `CAESURA_NATIVE_DATA_DIR`,
  no window ordered in, nothing activated, no sound), once per iteration:
  - JTL residue rules all pass: `entryShownWithReview` (diff 0.72 > 0.05),
    `entryGoneWithPoem` (diff exactly 0), `entryBackWithReview`,
    `finishCleansReviewState`.
  - Scroll bridge data-flow checks unchanged and passing (mount/follow/resume
    report no reader scroll, review reports continuously).
  - Scroller drawing check (actual `cacheDisplay` of the scroller view, not a
    direct draw call): legacy style renders a compact ink blob — no track
    ink over the scroller height, thumb ink present, end rows much narrower
    than the widest row (rounded capsule). Overlay style is accepted with the
    subclass installed (`overlayAccepted`, `overlayCompatible`) and draws
    nothing at rest (native fade) — recorded as native at-rest behaviour, not
    force-shown. The offscreen legacy fixture needed an explicit
    `tile()` + `reflectScrolledClipView` and, after a coordinate-mapping
    attempt proved unreliable, the assertion was downgraded to
    ink-classification; the sample images below are the visual confirmation.
- `swift build -c release --product Caesura` rebuilt clean after every probe
  iteration.

## Evidence for Codex acceptance

- `docs/POEM-CONTROLS-STYLE-SAMPLE.png` — offscreen break-window render
  (review state, poem visible): white entry glyph beside the last verse with
  clear spacing, slim capsule thumb at the right edge, no track background.
  The thumb happens to be visible in this render; with the overlay style at
  rest it can stay hidden (native fade) — no live scrolling was driven and
  none is claimed.
- `docs/POEM-CONTROLS-STYLE-SCROLLER.png` — the legacy-style scroller strip
  render (16×200): capsule thumb, transparent track.

## Limits

- Appearance-only verification: no live multi-display/GUI run, no activation,
  no sounds, no primary-display screenshots; overlay-during-scroll appearance
  is inferred from the shared drawing path plus the legacy render, not
  observed live.
- Unrelated core/migration suites not rerun (per plan). No scheduling, poem
  timing, migration, bundle identity or settings changes.
- Codex review baseline
  `/var/folders/dt/hqqgsgbj2kx2y6zk22dvzrc80000gn/T/caesura-oc-controls-review-0i_3pn2m`
  untouched.

## Delivery record

- `native/scripts/package-app.sh` — release build of `Caesura` +
  `caesura-cli`, bundle assembled at `native/dist/Caesura.app`
  (binary uuid `D4B2310D-183E-3D39-B9BC-F54CED44A3F4`), ad-hoc signed,
  `verify-app.sh` pass (Info.plist OK, valid on disk, satisfies its
  Designated Requirement).
- `native/scripts/install-dist.sh` (explicitly requested) — staged bundle
  built and verified before anything was replaced; trial identity
  `net.hovancik.stretchly.trial` kept; non-GUI version self-check printed
  `Caesura version 1.22.1`; the running trial was stopped by its exact
  executable path (pid 851), the bundle installed at
  `/Users/jee/Documents/Projects/caesura/dist/Caesura.app`, re-verified in
  place, restarted (pid 12332) with one scheduler and responsive IPC; the
  replaced copy `dist/Caesura.app.removed-20261103-091618-12152` was removed
  after verification. Persistent profile
  `~/Library/Application Support/Caesura` untouched; no `/Applications`
  copy created.
- `native/scripts/clean.sh --apply` — removed the generated `.build`
  directory; dist/ bundles, `~/Library` and sources protected; owned probe
  temp assets (offscreen probe directory, its isolated profile, one stray
  `/tmp` backup file) removed before the clean; result: "clean applied".
- Codex minimal read-only acceptance (observed by Codex, recorded here):
  product increment limited to `BreakContentView.swift`, `PoemViewport.swift`
  + the existing `PoemProbe.swift`, README/CHANGELOG; no pre-existing file
  missing. Installed bundle ID still `net.hovancik.stretchly.trial`; exactly
  one app process (pid 12332) at the `dist/` path; the log/CLI path is still
  `~/Library/Application Support/Caesura/caesura-native.log` and the socket in
  the new directory is connectable. `AGENTS.md` received an external
  modification during the session (install-rule change) — not made by this
  run; preserved as found, not reverted.
