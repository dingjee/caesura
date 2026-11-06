# Change Log

## [Unreleased]

### Added

- Caesura: an independent native macOS menu bar app for pauses and progressive
  poetry reading, with 465 bundled public-domain poems and persistent progress.
- Swift/AppKit/SwiftUI application, Foundation core, command-line client, isolated
  core tests, Apple Silicon packaging and macOS-only GitHub Actions.
- Original two-slash application/menu bar artwork, Caesura modules, executable
  names, documentation and project links.
- Safe replacement of the existing local trial, preserving its stable identity,
  settings, custom assets and migration state.
- A radial reveal for the break window: the blurred background and the poem
  arrive together in one soft wave that crosses the display boundaries as one
  wave. The centre of the wave is the pointer: it is read once per frame,
  every display shares that one centre, and the wave covers the last corner of
  the last display from wherever the pointer is. The reveal never repeats
  itself and never bounces.
- A signing identity for the packaged bundles: `CAESURA_NATIVE_SIGN_IDENTITY`
  or the git-ignored `native/scripts/signing-identity.local` name the
  certificate. `package-app.sh` and `install-dist.sh` share it, the installer
  never signs a signed bundle ad-hoc, and the packaging step checks the
  authority, the team and the stable designated requirement of the signature.
- A `status` command for the command line client: it asks the running
  instance and answers with the identity of the process that is really
  running — its bundle, its executable, the system media policy and the
  allowed applications.

### Changed

- The reading focus of the poem follows the reading position itself: the top
  of the poem reads at its first line, its end at its last one, and the
  wheel, the trackpad, the slider, the track and the keyboard all place the
  focus the same way. The newest words of a growing poem stay the brightest
  focus — including on its very first appearance.
- Every transition of the app shares one set of durations and one small
  family of gentle curves: the reveal of a break (about 900 ms in, 700 ms
  out, on its dedicated wave curve that starts and ends at rest — the ripple
  neither bursts out of its origin nor pops its last pixels), the brightness
  handover between the
  lines of a poem (300 ms) and the small feedback of the menu bar (250–300 ms).
  Reduced
  Motion replaces the wave of the break with a short fade, Reduced Transparency
  keeps an opaque, readable background behind the poem, and the poem, the
  deadlines and the shortcuts keep their own timing.
- The break window gives the poem a reading focus: while the poem grows, the
  line with the newest words is the brightest and the lines before it step
  back smoothly with reading distance (about 0.55 one line away, levelling
  near 0.22, higher with Increased Contrast), with the lines that hold the new
  words of the break keeping a secondary emphasis. The newest word stays
  readable at the soft edge. Type size, weight and spacing never move.
- The reading area listens to every way of scrolling — the wheel, the
  trackpad, the slider, the track and the keyboard all read at your position
  as you move and keep it there. Scrolling never reveals words, never
  switches the poem and never counts extra readings. The brightness follows
  only the actual reading position: the poem's first appearance keeps the
  newest words brightest even under a resting cursor, and hovering never
  brightens the old lines back — it only keeps the poem visible.
- The complete poem that fits the reading area shows clearly as one; a longer
  one opens at its last lines and keeps the reading position as its focus.
  The hover retention keeps the whole poem visible without brightening the old
  lines back, and Reduced Motion keeps the focus hierarchy without the
  transitions.
- The break window keeps the already revealed text of the poem readable
  from its beginning: earlier lines and stanza breaks survive in a scrollable
  reading area of stable, comfortable type, with the newest word at the soft
  edge.
- The complete poem is visible for about its reading time (a calm 220 words
  a minute), capped by the captured duration of the break. Reading semantics are
  unchanged: the break that completes a poem shows it once ("1"), and the
  poem is repeated the configured number of extra full readings ("+ n",
  0–9, default 2) before the next poem of the rotation begins. Skipped,
  postponed or cancelled breaks still do not count.
- Replace all website-specific and AX video-control adapters with a system
  Now Playing media backend. Mini and Long breaks pause participating audio or
  video sessions and resume only the same session paused for that break.
- Add an editable application allowlist in Breaks settings. Spotify and the
  local AlgerMusic trial keep playing by default; adding or removing apps does
  not pause or otherwise change the break schedule. Remove obsolete media
  Accessibility prompts and website-specific test fixtures.
- The cursor on the poem or on its author line keeps both visible as one
  group; moving it away fades them out softly (never earlier than the
  planned schedule), and pointing at the hidden text calls the poem back
  until the break ends. A hover that calls a hidden or partly faded poem
  back eases it in over about 250 ms from its current brightness instead of
  snapping it to full strength, and a leave during that fade continues from
  the brightness reached. Hovering never moves the poem and never extends the
  break.
- The reading area opens at the end of the poem: the slider of the viewport
  stands at the bottom and the newest words are the ones that are read — in
  both modes, also when the last line wraps over a large part of the area.
  Nothing travels on its own any more: only the reader moves the poem, and
  the line they read is the brightest. A rebuilt window restores the reading
  position of its reader.
- The reading viewport's vertical scroller draws no track in either scroll
  bar style: only a slim white capsule thumb moves over the poem. The native
  scroller keeps its knob geometry and every interaction, and the reader's
  overlay preference is kept (the drawing subclass declares overlay
  compatibility).
- The poem's lines breathe a little wider: the body of a poem is laid out at
  1.2 times the base spacing of the window by default, and Preferences offers
  a labelled multiplier (1.0–2.0, step 0.1) persisted as a Double. A missing,
  mistyped or out-of-range value falls back to the default or is clamped, in
  the store and again at every read. The multiplier is captured with the
  settings of a break and the reading window reads it when it opens: a new
  value reaches the next break, and the reading window applies it when it is
  reopened — without restarting the scheduler or moving the poem's timing.
  The measurement, the line centres, the drawn stack and the layout/content
  cache keys share one exact spacing (nearby multipliers that share a rounded
  value measure two different heights, never one cached layout).
- The menu bar menu merges the countdown of the next break and the former
  Skip submenu into two direct items: "Skip n min — start a Mini break now"
  and "Skip n min — start a Long break now" (natural Chinese wording in the
  Chinese locale). The minutes are shown only for the type that is planned
  right now — the scheduler's own countdown — and a type without an exact
  plan starts without a number; the long break never wears the countdown of
  the short one. Pause, Do Not Disturb, exclusions, Strict Mode, disabled
  types and the immediate-skip behaviour are unchanged.
- Documentation and this changelog entry were drafted with AI assistance
  (OpenCode) and verified locally by the maintainer.
- Releases can be notarized: a `Developer ID Application` signature carries
  the hardened runtime, `native/scripts/notarize-app.sh` uploads the bundle
  to Apple's notary service, staples the ticket and writes the distributable
  zip with its SHA-256 — a downloaded Caesura then opens without a Gatekeeper
  detour. The local trial keeps its development signature.
- The persistent trial profile lives at
  `~/Library/Application Support/Caesura` and the ordinary native profile at
  `~/Library/Application Support/CaesuraNative`. A first run imports the
  previous native profiles (`StretchlyNativeTrial`, then `StretchlyNative`
  for the trial; `StretchlyNative` for the ordinary app) non-destructively,
  preserving config, custom assets and migration state; existing profiles
  are never overwritten and sources are never modified.
- The macOS implementation becomes the standalone project's `main` snapshot.
- Update checks and feedback links target `dingjee/caesura`.
- Default content is poetry; optional user-provided content remains supported.

### Fixed

- The blurred background of a break follows the wave of the reveal again
  instead of showing a grey strip: the mask image of the wave now carries the
  cap insets AppKit needs, so the material mask of the effect view maps the
  raster onto the window instead of degenerating into a rectangle. The blurred
  background and the poem are revealed by one and the same disc — at the same
  global point, with the same feather and the same hidden and full endpoints —
  and no part of the background survives outside the wave. The timing of the
  wave (about 900 ms in, 700 ms out), the pointer-following centre, the plain
  fade of Reduced Motion and the cancellation of a running wave are unchanged.
- This fix and its documentation were written with AI assistance (OpenCode)
  and verified locally; the check renders the mask of the real AppKit
  consumer offscreen and compares it with the mask of the poem.

### Removed

- The quiet "Back to the newest words" entry of the reading viewport, with
  its style, its strings, the resume it triggered and the probe that guarded
  it. The reading position belongs to the reader alone.
- The automatic travel of the complete poem and the pause that the cursor
  caused in it.
- The previous cross-platform application, JavaScript/Node dependencies,
  Windows/Linux packaging, inherited release automation and old brand assets.
- Hosted contributor login/settings sync, account windows, sponsorship controls,
  WebKit bridge and bundled exercise tips and sound themes.
