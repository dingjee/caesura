# Radial backdrop strip — result

Date: 2026-11-07 · Xcode toolchain (`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`)
Scope: the grey strip / misplaced head of the radial break reveal. Local bug fix
only: no Issue/PR, no commit, no push, no install, no package, no clean, no
profile migration (Codex owns the dist refresh, the rollback and the final
clean).

## Root cause

`BreakRevealDriver.apply` masks the blurred material of the break window with
the documented `NSVisualEffectView.maskImage` and the poem with an identical
`CALayer.mask`. The image was built as `NSImage(cgImage:size:)` — an image
**without cap insets**.

AppKit does not draw that image itself: it builds a Core Animation mask layer
out of it and maps the raster onto the bounds of the effect view through the
`contentsCenter` of that layer, and it derives that centre from the *cap
insets* of the image (the SDK's `NSVisualEffectView.h` recommends setting them
correctly). Without cap insets the centre stays **degenerate**:

```
default NSImage(cgImage:size:)   capInsets .zero    → material mask contentsCenter (0, 0, 0, 0)
same image, resizingMode .stretch                    → contentsCenter (0, 0, 0, 0)   (no change)
same image, capInsets (1,1,1,1)                      → contentsCenter (0.00104, 0.00185, 0.99792, 0.99630)
```

`CALayer.contentsCenter` is the *centre part* of the 3x3 grid that scales the
image: the centre is stretched in both directions, the top and bottom parts
only horizontally, the left and right parts only vertically and the corners
not at all. A centre with a zero width and height is implicitly adjusted to
"a single source pixel", so the grid degenerates: the raster is drawn at the
wrong scale and the wrong place, and the material appears as **rectangles
instead of the disc** — the grey strip of the report.

Measured offscreen on the mask layer AppKit itself builds (wide 960×540
window, disc in the lower left, radius 220, feather 48; the row through the
middle of the frame, alpha of the rendered material mask):

```
broken  (capInsets .zero)   0:0  21:0  42:0  63:0  84:0 105:0 126:246 147:246 168:246 189:246 210:246 231:245 252:0
fixed   (capInsets 1pt)     0:45 21:247 42:255 63:155 84:0 105:0 126:0  147:0  168:0  189:0  210:0  231:0  252:0
direct content mask        0:45 21:246 42:255 63:155 84:0 105:0 126:0  147:0  168:0  189:0  210:0  231:0  252:0
```

The broken material shows a vertical band of ~394 points on the right half of
the window (a strip) while the poem is revealed by the disc; the fixed
material follows the disc pixel for pixel. The same holds for the other
geometries: with the disc near the right top the broken mask paints the top
right corner (alpha 251) instead of the disc, and on a tall 540×960 window it
paints a vertical band in the middle of the window.

Mean alpha difference between the material mask and the direct content mask:

| frame                                | broken | fixed |
|--------------------------------------|--------|-------|
| wide window, disc in the lower left  | 103.58 | 0.048 |
| wide window, disc near the right top |  43.93 | 0.056 |
| tall window, disc in the lower left  |  82.82 | 0.052 |

## Files

- `native/Sources/CaesuraApp/RadialMaskImage.swift` (new): the mask image of
  the wave. It builds the `NSImage` of the frame and gives it the explicit
  one-point cap insets AppKit needs for a nondegenerate stretch region. The
  inset is clamped to a quarter of the shorter edge, so even a very small
  effect view keeps a valid inset. The raster still covers the whole bounds,
  the disc stays at the same global point as the poem and the allocation
  stays bounded (≤ 256 px on the longest edge).
- `native/Sources/CaesuraApp/BreakRevealTransition.swift`: the one call site
  now uses `RadialMaskImage.make(cgImage:size:)` instead of
  `NSImage(cgImage:size:)`. Nothing else changed — the durations (900 ms in,
  700 ms out), the pointer-following centre, the multi-display geometry, the
  plain fade of Reduced Motion, the opaque background of Reduced Transparency,
  the cancellation, the early exit and the teardown of the tail are untouched.
- `native/Tests/RadialMaskRasterTests/MaterialMaskProbe.swift` (new): the
  AppKit side of the check. It owns a window that is **never ordered in**
  (AppKit builds the material mask of an effect view only inside a window),
  reads the mask layer out of the public layer tree, copies it with its public
  properties (`contents`, `contentsCenter`, `contentsGravity`,
  `contentsScale`, `bounds`, `frame`) and renders it offscreen over a white
  host layer. The direct content mask of the poem is rendered the same way.
- `native/Tests/RadialMaskRasterTests/main.swift`: the new checks (the
  existing pixel checks are unchanged).
- `native/scripts/radial-mask-test.sh`: compiles the two new production/test
  files as well.
- `README.md`, `CHANGELOG.md`: focused notes (Unreleased, no version bump).
- `docs/RADIAL-BACKDROP-STRIP-RESULT.md`: this report.

## The check (behaviour, not a property)

`native/scripts/radial-mask-test.sh` renders, for five frames of the wave
(wide window with the disc in the lower left, wide window with the disc near
the right top, tall window, twice the raster resolution, the resolution of the
raster itself) and for both endpoints:

1. the material mask AppKit builds from the **production** mask image of the
   frame, and
2. the direct content mask of the poem (the same raster on the layer of the
   content host),

and asserts that both reveal the same disc at the same place: the mean alpha
difference stays below 24/255, the material shows **no strip** where the wave
has not arrived yet and hides **nothing** where it already arrived. The
hidden endpoint stays fully clear and the full endpoint fully opaque in both.

### Old vs new (the same script, the fix removed temporarily)

With the fix in place:

```
== radial mask pixel checks ==
PASS: 37 radial raster, offscreen layer and AppKit material mask checks; no window was ever shown
failures=0
```

With the cap insets removed from `RadialMaskImage.make` (the production code
before the fix, the temporary change was reverted afterwards):

```
FAIL: wide window, disc in the lower left: the material mask and the content mask agree
FAIL: wide window, disc in the lower left: the material shows no strip outside the wave
FAIL: wide window, disc in the lower left: the material hides nothing inside the wave
FAIL: wide window, disc near the right top: the material mask and the content mask agree
FAIL: wide window, disc near the right top: the material hides nothing inside the wave
FAIL: tall window, disc in the lower left: the material mask and the content mask agree
FAIL: tall window, disc in the lower left: the material shows no strip outside the wave
FAIL: tall window, disc in the lower left: the material hides nothing inside the wave
FAIL: twice the raster resolution: the material mask and the content mask agree
FAIL: twice the raster resolution: the material shows no strip outside the wave
FAIL: twice the raster resolution: the material hides nothing inside the wave
FAIL: the resolution of the raster itself: the material mask and the content mask agree
FAIL: the resolution of the raster itself: the material shows no strip outside the wave
FAIL: the resolution of the raster itself: the material hides nothing inside the wave
FAIL: full endpoint: the material and the content are fully shown
failures=15
```

## Checks actually run

1. `native/scripts/radial-mask-test.sh` — **ran five times**: once with the
   fix (37 checks, 0 failures), once with the fix temporarily removed to
   prove the regression (15 failures, listed above; the temporary removal was
   reverted afterwards) and three more times with the fix, to show that the
   check is stable and does not depend on a lucky run loop turn. No window is
   ever ordered in.
2. `native/scripts/test.sh` — **ran once**: `swift build -c debug` compiled the
   application (including the new file) and the core suite reported
   **236/236 passed**.
3. `swift build -c debug` — one extra targeted build to look for warnings:
   **build complete, no warnings, no errors**.

The whole check is offscreen: no window is ever ordered in, nothing is
activated, no sound, no permission prompt, no System Settings, no mouse
movement, no external window or media, no login item, no profile, no
fullscreen. The application of the probe stays `.prohibited`. The scratch
probes of the diagnosis lived in the temporary directory of the session and
were removed again; the repository keeps only the files listed above.

## Not verified

- **No GUI run.** The strip was never seen on a screen by this session: the
  evidence is the offscreen rendering of the very mask layer AppKit builds for
  `NSVisualEffectView.maskImage`. The compositing of the window server itself
  was not exercised (offscreen acceptance was chosen; two displays were detected,
  and no visible window was shown).
- The other geometries of the reveal were not re-tested behaviourally: the
  change touches one line of the mask construction, so the pointer-following
  centre, the multi-display wave, Reduced Motion, Reduced Transparency, the
  cancellation, the early exit and the teardown of the tail are unchanged by
  construction, not by a new check. The core suite covers their compilation
  only.
- No packaging, no installation, no `dist/` refresh, no rollback, no
  `clean.sh` — those belong to Codex.
- No settings, profile, migration or login-item state was touched.

## AI assistance

The diagnosis, the implementation, the check and this report were written with
AI assistance (OpenCode, MiniMax M3.1 Flash) and are reported as they were
run: every number above comes from the runs described above. The changes are
limited to the mask image of the radial reveal; no public API, no version bump
and no unrelated behaviour was touched.

## Codex minimal acceptance and deployment

- Reviewed the production helper/call site and the actual AppKit mask pixel
  regression; preserved the pre-existing dirty work. `git diff --check` passed.
  No additional core/GUI test run was needed. OpenCode session:
  `ses_e4d11752fffeLxydXh2tjiRKm0` (interactive MiniMax M3.1 Flash).
- `CAESURA_NATIVE_UNIVERSAL=0 native/scripts/install-dist.sh` completed:
  release build, signing, staged package verification, isolated version check,
  installed verification, exact-path graceful restart. Both Caesura and
  caesura-cli were verified arm64-only. Trial identity remains
  `net.hovancik.stretchly.trial`, version 1.22.1. Restart reported one scheduler
  and responsive IPC (PID 8793).
- The release build emitted existing warnings in AppCoordinator, AudioPlayer,
  BreakContentView, BreakTypography, Notifier and RevealProbe; the new mask
  helper/call site emitted no warnings. No unrelated warning cleanup was done.
- Saved the previously installed app as `Caesura.app.rollback-20261107-062322`, verified
  its signature/resources/arm64 executables and isolated `version` self-check,
  verified it again after replacement, then pruned the older owned rollback.
  Exactly one usable rollback remains. `native/dist/Caesura.app` was absent.
- Real visible WindowServer compositing remains unverified: acceptance used
  offscreen rendering and the old-versus-new regression. No persistent profile,
  migration backup, login settings or external window/media was modified.
- Final maintenance: `native/scripts/clean.sh --apply` (outcome below).

Final cleanup outcome: passed (exit 0); generated build/test artifacts removed.
