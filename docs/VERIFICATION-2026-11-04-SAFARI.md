# Safari YouTube follow-up — 2026-11-04

The user reported that fullscreen Safari playback still did not pause after
Accessibility was granted. Issue/PR workflow remains waived by the owner for
this personal maintenance task. AI assistance: OpenCode MiniMax M3.1 Flash,
directed and reviewed by Codex.

## Evidence

- Running installed trial: Accessibility trusted, video pause setting enabled.
- Existing break logs at 14:50:01 and 16:57:20 Asia/Shanghai targeted Safari
  correctly but found no recognizable playback control. Searches did not report
  budget exhaustion.
- A temporary Swift process confirmed its own existing AX trust without asking
  for permission, then read Safari's AX tree. It visited 108 elements across two
  windows: zero `AXVideo` elements, 32 buttons, one pressable Pause control.
- The Pause control belongs directly to an `AXGroup` with DOM ID `movie_player`
  and class `html5-video-player`; its own classes contain `ytp-play-button`.
  The nearest `AXWebArea` has a URL-typed `AXURL` on the exact HTTPS YouTube
  origin. The player also exposed `ytp-fullscreen` and `playing-mode`.
- The previous implementation required the button to descend from `AXVideo`,
  so it rejected this real player structure despite valid permission.
- Only roles, selected known class names, counts and identity booleans were
  output. No page titles or full URLs were logged. No AX actions, focus changes,
  playback commands, permission prompts or System Settings were used.

## Verification

- Final `native/scripts/video-playback-test.sh`: exit 0, 43 Boolean checks passed.
  Uses the production search/controller and fake AX elements; covers regular
  and fullscreen YouTube structures, pause/resume, invalid origins and DOM
  identities, unpressable/unknown buttons, already paused playback, navigation,
  changed ownership, vanished windows and a shared traversal budget.
- `native/scripts/video-playback-test.sh --inspect-safari`: exit 0. This uses
  the production observer against the existing Safari instance, without any
  press. Result: `state=paused`, `recognizedYouTube=true`, and both the control
  and container PID match Safari. Permission was already granted.
- Initial full application build and core suite: exit 0, 224/224 passed.
- Initial installed trial: signed with the selected JI DING certificate,
  arm64-only app and CLI, one restarted scheduler, GUI AX trust remains true.

## Authorized real-media check

The user explicitly authorized one pause/resume test on the playing Safari
YouTube video. A temporary executable compiled the production observer and
controller, selected Safari without activation, and called `pauseIfNeeded`.
AXPress succeeded and the player subsequently exposed `paused-mode`.
The controller did not confirm the pause within its 200 ms wait, so it sent
no resume and exited 5. A read-only follow-up identified a second real defect:
the button label was `Play keyboard shortcut k`, which was not recognized by
the old exact-label classifier. This is a fixed player UI label; no video
metadata was output. The classifier now accepts this exact spoken shortcut
suffix with one ASCII key and retains exact matching and conflict rejection.

A follow-up attempt to complete the authorized resume refused before any
AXPress because the target was no longer confirmed paused. A later read-only
production observation reported `playing`, with verified YouTube identity and
matching Safari process IDs. No second pause or actual resume was sent.
The real pause was demonstrated; a successful real resume and an entire real
break lifecycle were not demonstrated. Mock pause/resume uses the captured
spoken labels and passes for both ordinary and fullscreen windows.

## Final package and maintenance

- Final `native/scripts/test.sh`: application and CLI compiled, 225/225 core
  tests passed. The spoken label regression runs here; the YouTube structural
  rules are exercised by the separate 43-check focused harness.
- `CAESURA_NATIVE_UNIVERSAL=0 native/scripts/install-dist.sh`: exit 0.
  Stage verified before replacement; exact old PID stopped; final trial
  restarted as PID 12043 with one scheduler and responsive IPC.
- Final GUI and CLI contain arm64 only. GUI UUID:
  `DC43DE66-E1BA-3572-8FBC-68317B2BCB75`. Version remains 1.22.1.
- Same configured `Apple Development: JI DING (NA9R277JH4)` signing identity;
  installed GUI reports `accessibilityTrusted: 1`, `pauseVideoPlayback: 1`,
  and the exact root `dist/Caesura.app` path.
- Exactly one rollback retained: `dist/Caesura.app.rollback-20261104-171649`.
  Verified signature/structure/arm64 and both isolated `version` commands before
  pruning the older owned rollback. No redundant `native/dist/Caesura.app`.
- Persistent profiles, migration backup, existing unrelated documents and
  migration scripts were preserved. No push or version bump.
- Final `native/scripts/clean.sh --apply`: exit 0. Owned build/test residue
  removed; root dist and all profiles/backups preserved.
