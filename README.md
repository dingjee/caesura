# Caesura

<img src="assets/caesura.svg" width="128" align="right" alt="Caesura's two-slash mark">

**A pause for poetry.**

Caesura is a native macOS menu bar app that makes room for a poem between periods
of work. Each completed short pause reveals one word; a long pause reveals four.
A poem stays with you until it has been read in full and repeated, then the next
poem follows. The name refers to a pause within a line of poetry.

This independent project supports **macOS 13 or later**, on Apple Silicon (arm64).
Its interface uses Swift, AppKit and SwiftUI, with no embedded browser,
account, subscription or hosted settings service. Poetry is bundled for offline
reading. Source and feedback: [dingjee/caesura](https://github.com/dingjee/caesura).

## Using Caesura

Launch `Caesura.app` and look for the two-slash menu bar icon. The menu opens
Preferences, the current poem, and pause/resume controls. By default, a short
pause lasts 20 seconds and starts every 10 minutes; every third pause is a
5-minute long pause. Preferences changes the schedule, displays, background,
sounds and the number of full-poem repetitions (0–9, default 2).

The catalog contains 465 public-domain poems. Seasonal lines and author
anniversaries influence selection. Opening **Current poem** reads the full text
without advancing it. Skipped, postponed or cancelled breaks do not count as
completed readings. Progress survives restarts. A break shows the revealed text
in a scrollable reading area of stable, comfortable type — the line with the
newest words is the brightest focus, earlier lines step back smoothly with
reading distance and keep their brightness floor, and the newest word stays
readable at the soft edge. The reading area opens at the end of the poem, so
the slider of the viewport stands at the bottom and the newest words are the
ones that are read. Nothing travels on its own: only the reader moves the poem.
The focus follows only the actual reading position — the top of the poem reads
at its first line, its end at its last one, and every way of moving the
reading area (wheel, trackpad, the slider, the track or the keyboard) places it
the same way. Resting the pointer on the poem or on its author line keeps both
visible; it never moves the poem, never changes the reading position and never
brightens the old lines back. Moving the pointer away lets them fade out
softly, and pointing at the hidden text calls the poem back with a brief
gentle fade-in (about a quarter of a second, seeded from its current
brightness) until the break ends. The reading area's scroll bar is a slim white
capsule without a track. Reduced Motion keeps the focus hierarchy without the
transitions; Increased Contrast raises the brightness floor behind the focus.
Once a poem is complete it is shown in full on that break and repeated the
configured number of times (the "1 + n" readings: one unlocking break plus 0–9,
default 2, extra full readings before the next poem begins). A short complete
poem shows clearly as one; a longer one is visible for about its reading time,
capped by the break, and opens at its last lines — the same reading position a
reader sees when they move the reading area themselves.

Idle time, sleep, lock, app exclusions and the Focus heuristic can pause the
schedule. Strict Mode restricts dismissal; Manual Finish waits for your action.
An optional video feature pauses and resumes readable video playback in the
frontmost application. Browser windows, including fullscreen ones, must expose
a video element (`AXVideo`) containing a play/pause control, or the verified
YouTube player and its own play/pause button. Safari can omit `AXVideo` for
YouTube: that player is matched by its DOM identity and HTTPS YouTube page,
and playback is resumed only while the same page and controls remain.
Both bracketed and spoken shortcut labels (such as `Play keyboard shortcut k`)
are recognized.
Audio elements do not qualify. Known native video players also retain their
fullscreen control fallback. Other custom web players without recognizable
video controls remain unsupported. The feature needs Caesura's accessibility permission, requested
only from its Preferences button.

A break opens with a soft radial reveal: the blurred background and the poem
appear together in one wave that crosses the display boundaries, and they leave
the same way — about 900 ms to open and 700 ms to close, on a dedicated curve
that starts and ends at rest, so the wave neither bursts out of the origin nor
pops its last pixels. The centre of the wave is your pointer: it is read once
per frame, every display shares that one centre, and the wave covers the last
corner of the last display from wherever the pointer is. The wave never
repeats itself and never bounces. When the break ends, the pointer is read
again and the wave contracts towards it. Between the waves nothing is read at
all. Reduced Motion presents and dismisses the break with a short fade instead
of the wave, and Reduced Transparency keeps an opaque, readable background
behind the poem. Every transition of the app — the reveal of the break, the
brightness handover between the lines of a poem and the small feedback of the
menu bar — answers to one shared set of durations and one small family of
gentle curves, with a dedicated at-rest curve for the wave.

## Build and verification

Install an Xcode or Command Line Tools Swift toolchain, then use:

```sh
native/scripts/test.sh
native/scripts/radial-mask-test.sh
native/scripts/package-app.sh
native/scripts/verify-app.sh native/dist/Caesura.app
open native/dist/Caesura.app
```

`test.sh` compiles the application and runs the custom `caesura-core-tests`
executable; this package does not use `swift test`. `radial-mask-test.sh`
compiles the actual mask raster of the break reveal together with a small
pixel check and asserts its real pixels — the opaque centre, the clear
exterior, the feathered edge, the exact hidden and full endpoints and the
bounded allocation. It renders offscreen and never shows a window. The
offscreen probe (`CAESURA_POEM_PROBE=<directory>`) renders the poem, the
reading viewport, the reveal and the rules of the video playback into images
and a JSON report, again without showing a window. Build scripts select an
installed Xcode for their own process when available, without changing global
developer-tool selection. The releases are Apple Silicon only: the packaging
builds arm64 and refuses a universal build, and the verification accepts
nothing but arm64 in the packaged executables:

```sh
native/scripts/package-app.sh
native/scripts/verify-app.sh native/dist/Caesura.app
```

### The signature of the bundles

Without any configuration the bundles are signed ad-hoc, which needs no
identity and no keychain access. A checkout can sign with a real certificate:
the identity is resolved from `CAESURA_NATIVE_SIGN_IDENTITY` (the environment
wins) or from `native/scripts/signing-identity.local` — a one-line file with
the name of the certificate, ignored by git so that the choice of one machine
never reaches the project:

```sh
printf 'Apple Development: Your Name (TEAMID)\n' > native/scripts/signing-identity.local
native/scripts/package-app.sh
```

`package-app.sh` and `install-dist.sh` share that identity: the executable is
signed with the same certificate as the bundle, and the installer never signs
a signed bundle ad-hoc behind the back of the build. The packaging step checks
the signature itself — the authority of the bundle and of both executables,
their common team, the leaf certificate of the signature and the stable
designated requirement of the certificate (the team and the fingerprint are
read from the signature, never written down in the project).
`verify-app.sh` only proves that a bundle is valid; it checks the identity
only when the caller asks for it:

```sh
native/scripts/verify-app.sh native/dist/Caesura.app --expect-identity "Apple Development: Your Name (TEAMID)"
```

A signed bundle matters for the permissions of macOS: an ad-hoc signature has
a designated requirement of nothing but the hash of the binary, so macOS asks
for the accessibility permission again after every rebuild.

CI runs core checks on macOS and packages builds from `main` or a manual
dispatch. Artifacts are workflow downloads, not automatically published
releases.

GUI checks are optional development tools. Use a temporary `--data-dir` profile,
a secondary display, no activation and no sounds. With no secondary display,
skip GUI checks; never silently use the working display. The fullscreen-video
check requires a separate explicit opt-in and remains off by default. See
[verification](docs/VERIFICATION.md) for the checks actually performed.

## Persistent local installation

```sh
native/scripts/install-dist.sh
```

The installer stages and verifies `dist/Caesura.app` before replacing a usable
trial. It can retire the previous `dist/Stretchly.app` copy, stops only its exact
executable, unregisters the obsolete login registration through the replacement's
stable identity, and restores the old app if replacement or restart fails.
A previously running trial is restarted, with one CLI socket and one scheduler.

`dist/Caesura.app` is the only long-term trial entry point: the installer
creates no `/Applications` copy, alias or symlink, and nothing is written to
`~/Applications`. Launch the bundle in the repository directly. The trial is
rebuilt and replaced after a new application version has been compiled and
the checks of that version passed; routine maintenance needs no new build.

The local trial retains bundle ID `net.hovancik.stretchly.trial` and profile
`~/Library/Application Support/Caesura`. These are deliberately stable
migration identifiers; the application is visibly named **Caesura**. The
ordinary package uses `io.github.dingjee.caesura` and
`~/Library/Application Support/CaesuraNative`. Existing migration backups
under `~/Library/Application Support/Caesura/Migration Backup/` are preserved.
When a checkout itself has moved, `CAESURA_RETIRED_TRIAL_APP` can identify the
former trial URL for exact login-registration retirement. The maintenance
helper uses ServiceManagement without starting a scheduler or opening windows.

Existing trial settings, custom audio/images, poem progress and migration state
are preserved. First-run import copies an existing ordinary native profile, or
imports legacy settings non-destructively; it never overwrites an existing
profile or changes the source. Legacy names survive only where needed for data
compatibility or attribution. No account or contributor entitlement is used.

`--data-dir <directory>` and `CAESURA_NATIVE_DATA_DIR` are for isolated testing,
not the persistent trial's launch mode. Isolated runs never import real profiles,
register login items or request notification authorization.

## Command line

The CLI bundled with each application resolves its own profile and forwards to
the running instance:

```sh
dist/Caesura.app/Contents/MacOS/caesura-cli help
dist/Caesura.app/Contents/MacOS/caesura-cli pause -d 1h
dist/Caesura.app/Contents/MacOS/caesura-cli resume
dist/Caesura.app/Contents/MacOS/caesura-cli logs
```

Commands include `help`, `version`, `logs`, `reset`, `pause`, `resume`, `toggle`,
`mini`, `long`, `last`, `postpone`, `skip`, `finish`, `preferences` and
`status`. `status` asks the running instance and answers with the identity of
the process that is really running — its bundle, its executable, whether macOS
trusts it for accessibility, and whether the video feature is on. It never
measures the permission of the client that asks:

```sh
dist/Caesura.app/Contents/MacOS/caesura-cli status
```

## Settings and custom content

Settings are stored in `config.json` within the profile. Quit the app and keep a
backup before editing it manually. Durations use milliseconds; unknown keys and
valid advanced values survive updates. The supported defaults and validation
rules are in [DefaultSettings.swift](native/Sources/CaesuraCore/DefaultSettings.swift).

Custom audio goes in `audio/`, images in `images/`. Default sounds use macOS
`Glass`; `silence` disables a sound. Imported custom content remains usable through
`useIdeasFromSettings`, `microbreakIdeas` and `breakIdeas`; new profiles contain no
exercise-tip collection. UI translations remain bundled, while the poetry
catalog and current Preferences release are English-first.

## Development

See [CONTRIBUTING.md](CONTRIBUTING.md) and [architecture](docs/ARCHITECTURE.md).
`CaesuraCore` contains Foundation-only scheduling, settings, poetry, IPC and the
shared tween tokens (the transition durations and their small curve family);
`CaesuraApp` owns macOS integration and the adapters that turn them into
SwiftUI animations and Core Animation timing functions; `caesura-cli` forwards
commands.
Run `native/scripts/clean.sh --apply` as the last maintenance step after changes.
It removes owned build/test residue and preserves source, packaged applications
and all persistent profiles.

The macOS implementation and its independent-project migration were developed
with AI assistance, including OpenCode models (MiniMax M3.1 Flash) and Codex
review and implementation. Contributors must understand and be able to maintain
submitted changes, disclose assistance and distinguish observed checks from
suggested ones.

## License and attribution

BSD-2-Clause; see [LICENSE](LICENSE). Original copyright notices are retained.
PoetryDB data is CC BY 4.0. See [third-party notices](THIRD_PARTY_NOTICES.md) for
provenance and credits; both documents ship inside the application bundle.

## Known issues

Focus detection is a heuristic. The video feature depends on the accessibility
interface of the target application: a playback whose play/pause control
cannot be read is left alone, and the search through a very large page is cut
short after a fixed budget (the report then says so). Real permission prompts,
physical display hot-plug and sleep/lock need manual integration verification.
Distribution is not notarized. Report issues with the macOS version,
CPU architecture, build revision and relevant logs with private data removed.
