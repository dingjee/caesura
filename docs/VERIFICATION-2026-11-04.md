# Verification of the changes of 2026-11-04 — result

Scope of this round: the reading viewport of the poem, the radial reveal of the
break window, the video feature and the signing of the packages. The user
authorized local implementation, packaging, installation and a commit, and
waived the Issue/PR workflow for this personal development task. No push.

AI assistance is disclosed: MiniMax M3.1 Flash (OpenCode) wrote the changes
under the review and the instructions of Codex.

## 1. The reading viewport (the "Back to the newest words" entry is gone)

- The entry, its style, its strings (`break.backToNewest`,
  `break.continueReading`), the resume token, the animated follow and the
  travel of the complete poem are removed (`BreakContentView.swift`,
  `PoemViewport.swift`, `PoemPresence.swift`, `en.json`).
- The reading area opens at the end of the document in **both** modes: the
  slider of the viewport stands at the bottom. The growing poem keeps the
  frontier line as the brightest focus; the complete poem reads at the
  position of the reader (at its end: its last line).
- The cursor keeps the poem visible and nothing else: it never moves the
  poem, never changes the reading position and never changes the brightness
  of a line.
- A rebuilt window restores the reading position of its reader.

Checks (offscreen probe of the **release** bundle, `CAESURA_POEM_PROBE`, exit 0,
38 boolean checks — viewport 3, focus 5, reveal 15, video 15 — all true):

- `viewport.revealingStartsAtTheEnd` true — a growing poem whose last line
  wraps over many rows still starts at the end of the document.
- `viewport.completeStartsAtTheEnd` true and
  `viewport.completeReadsItsLastLine` true — the complete poem starts at its
  end and reads at its last line.
- `focus.hoverMovesNoFocus` and `focus.hoverMovesNoReadingPosition` true —
  the cursor moves neither the focus nor the reading position.
- `focus.scrollTakesTheReview` true — a real scroll takes the reading
  position over.

Core suite: `native/scripts/test.sh` → **224/224 passed** (the travel plan of
the core and its two cases were removed with the travel).

## 2. The radial reveal follows the pointer

- The driver reads `NSEvent.mouseLocation` **once per frame**, shares that
  one global centre with every display, measures the covering radius from it
  again and converts it into the local coordinates of every window
  (`BreakRevealTransition.swift`). The pointer and the clock are injectable,
  which is what the probe uses.
- When the wave has covered every window, the masks are removed and the timer
  stops: an idle break reads nothing. The exit reads the pointer again and
  contracts towards it.
- The early exit, the cancellation and Reduced Motion (a plain fade, no
  pointer read at all) are unchanged.

Checks (offscreen probe, on windows that are never ordered in, with an
injected pointer — the mouse of the user is never moved; 15 of them):

- `reveal.entryFollowedThePointer`, `reveal.exitFollowedThePointer`,
  `reveal.exitReadThePointerAgain` true.
- `reveal.noSamplingWhenSettled` and `reveal.noSamplingAfterTheExit` true —
  no pointer read while the break is idle.
- `reveal.maskRemovedWhenSettled`, `reveal.exitCompleted`,
  `reveal.cancelledWaveNeverCallsBack` and
  `reveal.cancelledWaveStopsSampling` true.

`native/scripts/radial-mask-test.sh` → the mask raster keeps its own pixel
checks (the raster itself is unchanged).

## 3. The video feature

- The window of the target is no longer required to be in fullscreen: the
  candidates are the focused window, the main window and then every other
  window of the application.
- In a window of the normal size the play/pause control only counts when it
  sits inside a **video element** (the subrole `AXVideo` of the HTML-AAM
  mapping of `<video>`); an `<audio>` element carries `AXAudio` and is never
  matched. The localised role description is never used.
- In a window in fullscreen the control of a **known native video player**
  (`org.videolan.vlc`, `com.colliderli.iina`,
  `com.apple.QuickTimePlayerX`) may be acted on outside a video element; a
  browser in fullscreen has to show a video element like every other page.
- The search is one traversal with one shared budget (one second, 2 500
  elements, 40 levels, 1 200 elements per level) for all the windows
  together; a report that was cut short says so.
- Among several videos the one that says the playback runs wins; a paused
  video never hides a running one.
- The resume uses the very same control of the very same video element, with
  the very same media (the address of the media is collected **before** the
  press), in the very same window of the very same process. A target that is
  gone, a page that navigated away, a video that was replaced and a video the
  user started again are left alone.

Checks (offscreen probe, an in-memory accessibility tree — no other
application is touched, no media is played, no permission is asked for;
15 of them):

- `video.videoIsFound`, `video.audioIsNotAVideo`,
  `video.plainControlNeedsTheNativePlayer`, `video.playingVideoWins`,
  `video.budgetIsShared` true.
- The real controller was driven (`pauseIfNeeded`, `resumeIfNeeded` with an
  injected target and observation): `video.pausedOnce`,
  `video.pausedOnlyOnce`, `video.resumedOnce`, `video.resumedOnlyOnce`,
  `video.pausedVideoIsLeftAlone`, `video.replacedVideoIsNotResumed`,
  `video.vanishedTargetIsNotResumed`, `video.userPlaybackIsLeftAlone` true.
- `video.sameElementIsTheSame` true — two wrappers around one accessibility
  element are the same element (the identity of another process is not the
  identity of the object that carries it).

**Permission evidence:** Caesura's permission to read and control other
applications was missing in the installation logs. They show
`the playback of 'Safari' in fullscreen stays untouched — the accessibility
permission is missing` (2026-11-03T01:46:49Z) and the same for VLC
(2026-11-04T02:32Z and 02:38Z). Without that permission nothing can be read
or pressed at all — no search can help. An ad-hoc signature has a designated
requirement of nothing but the hash of the binary, so macOS asks for the
permission again after a changed build; a stable signing identity (see § 4)
avoids the changing binary-hash identity. The bundled `caesura-cli status`
now answers with the accessibility
permission of the **running application** (not of the client that asks), with
its bundle and its executable.

The public `MPNowPlayingInfoCenter` publishes the media information of *this*
application, and `MPRemoteCommandCenter` receives the media commands of *this*
application — neither can read the playback of another application. The
private MediaRemote interface is not used. There is no blind media key
anywhere in the code.

## 4. The signature of the packages

- `native/scripts/signing-identity.sh` resolves the identity:
  `CAESURA_NATIVE_SIGN_IDENTITY` first, then the git-ignored one-line file
  `native/scripts/signing-identity.local`, otherwise ad-hoc.
- `package-app.sh` and `install-dist.sh` share it: the command line client
  and the application are signed first, the bundle is sealed over them, and
  the installer never signs a signed bundle ad-hoc.
- The packaging step verifies the signature itself: the authority of the
  bundle and of both executables, their common team and the designated
  requirement of the identity (which has to be the stable one, not a hash of
  the binary).
- `verify-app.sh` proves the validity of a bundle by default and never reads
  the identity of this machine — an earlier ad-hoc rollback stays valid. The
  identity is only checked when the caller asks for it
  (`--expect-identity "<name>"`).

Checks:

- `native/scripts/package-app.sh` (arm64 only; a universal build is refused)
  → exit 0, signed
  with `Apple Development: JI DING (NA9R277JH4)`, leaf certificate
  `1d661fe22d630eeba86cd7d7532b2878134ce052`, team `MFMGY838LG` (read from
  the signature, never written down in the project), stable designated
  requirement (`identifier … and certificate leaf[subject.CN] = …`).
- `native/scripts/verify-app.sh native/dist/Caesura.app` → valid; with
  `--expect-identity` → the identity is confirmed.
- `native/scripts/verify-app.sh dist/Caesura.app.rollback-20261104-1111` →
  still valid (the ad-hoc rollback is not refused).
- Both packaged executables are arm64 only (`lipo -archs`); the verification
  refuses any other architecture.
- The workflow builds the arm64 artifact (`CAESURA_NATIVE_UNIVERSAL=0`).

## 5. The probe of the release bundle

The final package (`native/dist/Caesura.app`, release build, binary UUID
`9A1D3AD5-9D95-380E-9AB7-306DDCCE4FDD`) was probed offscreen: the run
finished with exit 0 and **38 boolean checks, none false** (viewport 3, focus
5, reveal 15, video 15). The log of the run shows the real controller at
work: the video of the fixture is paused once and resumed once, a video that
is paused already is left alone, and a replaced or a vanished target is never
resumed.

The probe renders the poem, the reading viewport, the reveal and the rules of
the video playback. It reads the pixels of every rendered image one by one
(`NSColor.colorAt` and a conversion into the device RGB space), which costs a
colour profile lookup per pixel: the run of the release bundle takes about a
minute. That is the price of the image report of the probe, not of the
application — the probe is a development tool and never runs in a normal
session. A batched conversion of the whole bitmap was tried and **reverted**:
its numbers did not match the reading of the pixels (and an independent test
showed an empty copy), so the correct reading was kept.

## 6. What was not checked

- No GUI run: no break window was shown, no pointer was moved, no media was
  played, no permission was requested and no system setting was opened.
- The live pause of a real video was not exercised: the new GUI process
  reports `accessibilityTrusted: 0` (see below), so the behaviour of the real
  accessibility interface of Safari could not be observed. The offscreen
  probe checks the rules of the search and the controller, not the interface
  of a real browser.
- CI was updated for arm64 artifacts; the remote workflow was not run.

## 7. Final installation and acceptance by Codex

- Ran `CAESURA_NATIVE_UNIVERSAL=0 native/scripts/install-dist.sh`, exit 0.
  The staged bundle was verified before replacement; the existing trial
  stopped by exact executable path, then restarted as PID 63450 with one
  scheduler and responsive IPC.
- Verified installed `dist/Caesura.app` with the selected signing identity.
  Both executables are arm64; the leaf certificate is
  `1D661FE22D630EEBA86CD7D7532B2878134CE052`, actual team `MFMGY838LG`.
  Trial identity stays `net.hovancik.stretchly.trial` and its profile stays
  `~/Library/Application Support/Caesura`.
- Installed release UUID: `9A1D3AD5-9D95-380E-9AB7-306DDCCE4FDD`.
  The same release passed all 38 direct boolean checks in the isolated
  offscreen report: viewport 3, focus 5, reveal 15, video 15.
- Read `caesura-cli status` from the installed GUI process: its executable
  and bundle paths resolve to this repository's `dist/Caesura.app`, the video
  option is enabled, and `accessibilityTrusted` is false. The existing
  Privacy screenshot does not establish a valid grant for this new signed
  executable. The user was asked to re-add this exact bundle and enable it.
- Reverified `dist/Caesura.app.rollback-20261104-1111`, including isolated
  `version` checks of both executables, and pruned the older owned rollback
  ZIP. Exactly one verified rollback remains. Removed the redundant verified
  `native/dist/Caesura.app` and its empty directory.
- Packaging now explicitly targets arm64 and rejects universal releases;
  the CI artifact and environment were updated to arm64. Shell syntax and
  installed package verification passed.
- Updated the gated fullscreen fixture to expose an AXVideo group and an
  actual Pause/Play button; its standalone Swift compilation passed. The
  gated GUI test was not launched.
- Ran `native/scripts/clean.sh --apply`, exit 0, after verification and
  installation. Owned build/test residue was removed; root dist, profiles,
  migration backups and other persistent data remain protected.
- The commit includes the existing native poetry/transition and stable profile
  path prerequisites needed to reproduce the installed application. Existing
  repository-policy edits, migration tooling and historical design artifacts
  remain outside this commit; the local signing identity remains ignored.
