# System media backend and application allowlist — 2026-11-04

The owner selected system media control, requested an editable application
allowlist with Spotify and AlgerMusic, and explicitly requested complete
removal of the previous YouTube/site/player adapters. The earlier personal
maintenance waiver of the Issue/PR workflow still applies. AI assistance:
OpenCode MiniMax M3.1 Flash and Codex, with implementation and independent
review/testing under owner direction.

## Behavior and ownership

- Breaks operate on the system Now Playing session, including participating
  audio and video. Window focus, fullscreen state, website names, AX roles,
  localized button labels and Accessibility permission are no longer inputs.
- The system session's bundle identity and parent application are checked
  against `mediaPlaybackAllowedApps`. Settings → Breaks → Media during breaks
  supports adding app bundles and removing entries. Defaults were verified
  against local app Info.plists: Spotify `com.spotify.client`; local AlgerMusic
  trial `com.alger.music.trial`. An explicit empty list stays empty; malformed
  settings preserve default music exemptions.
- Keep `pauseFullscreenVideo` as the stored Boolean preference for compatibility;
  its visible label now describes media. No profile reset or migration occurs.
- Reads/commands run on one worker queue. A generation invalidates stale work;
  end always queues a finish so an in-flight confirmed pause is either released
  or inherited by the next active break. Only owned pauses can resume.
- Resuming requires the same bundle, parent, positive PID and stable media item
  identifier, still paused. Unconfirmed/unknown states and missing identities
  are skipped. Metadata titles are not identity fallbacks. A changed target
  relinquishes ownership so it cannot be revived in a later break.
- An app added to the allowlist during a break can regain the pause Caesura
  already owned. Changing media policy does not reinitialize scheduler machines
  or change the planner's captured durations.
- Complete, skipped, postponed, reset and cancelled breaks share `endBreak`;
  disabling media pause ends its ownership. Shutdown cancels only the owned
  helper process and does not start media. Isolated profiles never read or
  control system media through the default transport.

## Implementation

The pinned BSD-3-Clause upstream MediaRemote Adapter is vendored at revision
`0e82bf1c44ec39554fbfc402ec88a48c6ae2a0fd`. Only its Perl dispatch/header are
patched; the guarded command and provenance are local additions. License and
provenance ship with the bundle. The framework is built locally for arm64 and
macOS 13+, with no package-manager/global-tool/security-setting changes.

The private API uses a global command. The helper rechecks identity/state and
the allowlist immediately before sending an explicit Pause or Play in the
same process; post-command confirmation also validates identity. This reduces
but cannot atomically eliminate a takeover between the check and the global
command. No directed/atomic command guarantee is claimed. Private API changes
can require future maintenance; nonparticipating apps remain uncontrolled.

Removed the old VideoPlayback controller/search, poem video probe, PlaybackNames,
AX tree budget/rules, YouTube/native-player exceptions, permission notifications,
and their specific Swift/shell test fixtures. Old verification documents remain
historical records rather than active adapter code.

## Checks

- `native/scripts/test.sh`: exit 0, 226/226 core checks; application/CLI compile.
- `native/scripts/system-media-playback-test.sh`: exit 0, 29 checks of the actual
  controller/parser using a synchronized fake transport; includes late pause,
  rapid consecutive breaks, stale resume, shutdown, changed item/target,
  allowlist edits and malformed Boolean state.
- `native/scripts/mediaremote-guard-test.sh`: exit 0, 17 checks compiling the real
  guarded helper against a fake system API. No private framework is loaded or
  real command sent by this check.
- Real system read: the bridge identified a playing Safari session reported by
  WebKit GPU, with Safari as parent and stable item identifiers. A native
  dry-run pause was accepted; adding that parent to a temporary test allowlist
  refused the same action. Both modes explicitly sent no media command.
- Real production Swift transport read and subsequent cancellation: exit 0;
  no titles, full URLs or raw item identifiers were printed.
- Source provenance comparison: all other vendored files match the pinned
  upstream copy. Native source/test/script searches show no website-specific
  adapter symbols. Syntax and whitespace checks pass.
- GUI/app-picker and real playback control/fullscreen tests were not run:
  AGENTS.md requires opt-in for intrusive tests. The prior single media test
  authorization belonged to the previous AX investigation and was not reused.
- `CAESURA_NATIVE_UNIVERSAL=0 native/scripts/install-dist.sh`: exit 0. Staged
  package verified before replacing the prior trial, exact-path shutdown, then
  one restarted scheduler with responsive IPC (PID 22699).
- Final GUI UUID: `DCE6E4EA-A0A7-3646-8372-36097489FACC`. GUI, CLI and the bundled
  framework are all arm64 only. Version remains 1.22.1. Main/CLI/framework/bundle
  signatures verify with `Apple Development: JI DING (NA9R277JH4)`.
- Runtime `caesura-cli status`: `mediaBackend: systemNowPlaying`, media pause on,
  and the exact Spotify/AlgerMusic default IDs. Installed signed bridge read
  succeeds and recognizes the current Safari session without sending a command.
- Exactly one verified rollback retained:
  `dist/Caesura.app.rollback-20261104-193113`; both isolated version commands pass.
  Older owned rollback pruned only after verification. No `native/dist` duplicate.
- Final `native/scripts/clean.sh --apply`: exit 0. Profiles, migration backup,
  unrelated user documents and migration tools were preserved. No push.
