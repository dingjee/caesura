# Break ripple and shared tween plan

Requested locally on 2026-11-02. Implementation delegated to OpenCode; Codex
reviews lifecycle risks and performs minimal acceptance. No commit, push, Issue,
or PR submission is requested. AI-assisted work.

## Intended behavior

- A break opens with a soft radial reveal of its existing blurred backdrop and
  content, originating at the cursor captured once at presentation. On exit the
  reveal contracts toward that same origin. No repeated rings or bounce.
- All participating windows share one global desktop origin, radius and monotonic
  timeline: a wave crosses display boundaries rather than restarting per screen.
  Honor the existing screen selection and window bounds; never add coverage.
- Preserve break deadlines, poem timing, outcomes, strict mode, manual finish,
  shortcuts, and foreground app focus. Closing stops countdowns and callbacks
  immediately; only the visual tail can remain briefly.
- Reduce Motion uses immediate presentation/dismissal or a short opacity change.
  Reduce Transparency keeps an opaque readable background. Regular titled windows
  may use the shared opacity transition when a radial frame would be inappropriate.

## Implementation boundaries

1. Foundation-only shared tween tokens and easing plus radial geometry in
   CaesuraCore; native adapters in CaesuraApp for SwiftUI, AppKit/Core Animation.
   Start with approximately 600 ms entry, 400 ms exit, 300 ms emphasis/reader
   handover, and 200–300 ms small UI feedback; choose one gentle cubic family.
   Reuse semantic tokens, not scattered animation literals. Keep poem reveal and
   scheduler timing intact; use shared easing where applicable without retiming
   poetic content. Migrate existing explicit toast, focus and reader animations.
2. Use public macOS 13+ APIs. Preserve NSVisualEffectView behind-window sampling
   below readable content. Apple's documented maskImage masks the material:
   https://developer.apple.com/documentation/appkit/nsvisualeffectview/maskimage
   A layer mask alone must not be assumed to mask the WindowServer backdrop.
   Prefer native compositing; if using maskImage updates, use a bounded, small
   alpha raster and one short-lived shared driver, never screenshot the desktop
   or animate blur radius through private APIs. Avoid per-frame full-screen
   bitmap allocation. Dispose all masks/drivers when settled.
3. Capture the global pointer once, convert to each actual content coordinate
   system (including flipped views), and compute the furthest target corner with
   feather margin. Cover negative origins, gaps, different scales/aspect ratios,
   and a cursor outside target windows. Fully hidden/visible endpoints must be
   exact, without an initial unmasked frame or dimmed final corners.
4. Keep dismissal ownership until the last frame, even if BreakSession is released.
   Early exit reverses from current progress without a flash. Repeated close,
   cancellation, hot-plug and immediate next-break creation must cancel/discard old
   visuals safely. Relayout and application termination can discard immediately;
   no stale completion may touch replacement windows. Preserve lifecycle probes.
5. Update README and CHANGELOG [Unreleased]. Preserve all current uncommitted
   poem work. Add focused behavior tests (geometry, endpoints, interruption,
   reduced motion) where they provide regression value, using the custom runner.

## Verification and handoff

- OpenCode runs native/scripts/test.sh once (compile + custom core runner), fixes
  relevant failures, and reports exact results and files. A pure, non-visible
  probe for mask endpoints/lifecycle is preferred over GUI runs if useful.
- No automated windows on the main display, no activation/sounds, no screen
  recording permission requests, no playback or login-item changes. Do not run
  broad GUI suites. Codex decides whether one targeted isolated secondary-display
  check is necessary after reviewing the diff.
- Codex reviews the critical diff, runs native/scripts/install-dist.sh (including
  staged package verification and exact-path singleton restart), and finally
  native/scripts/clean.sh --apply. Persistent trial identity/profile are retained.
- OpenCode must not shut down the machine. After successful acceptance, Codex
  reports the result and initiates the user-requested normal macOS shutdown.

## Delivery record — 2026-11-02

- OpenCode implemented the change in interactive sessions. Kimi for Coding
  produced the initial implementation; MiniMax M3.1 Flash completed integration
  and review corrections. GLM channels were unavailable due to usage limits.
- Codex ran `native/scripts/test.sh`: **215/215 passed**, including six motion
  regression cases. The existing poem work was preserved; its view changes in
  this task only adopt the shared animation calls and duration tokens.
- Codex ran `native/scripts/radial-mask-test.sh`: **10/10 passed**, compiling the
  actual application raster and rendering its layer mask offscreen. The initial
  temporary probe's pixel sampler needed top-down bitmap rows converted to
  Quartz coordinates; the retained test calibrates this against a reference fill.
- `native/scripts/install-dist.sh` built, signed, verified and replaced
  `dist/Caesura.app`; its visible name is Caesura and its identifier remains
  `net.hovancik.stretchly.trial`. The isolated version check passed. No trial
  instance was running before replacement, so no scheduler needed restarting.
- One display was attached: GUI lifecycle and real multi-display compositor
  checks were skipped. No windows were shown by acceptance. Intel/universal
  packaging was not run; this delivery verifies the host build.
