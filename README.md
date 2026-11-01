# Caesura

<img src="assets/caesura.svg" width="128" align="right" alt="Caesura's two-slash mark">

**A pause for poetry.**

Caesura is a native macOS menu bar app that makes room for a poem between periods
of work. Each completed short pause reveals one word; a long pause reveals four.
A poem stays with you until it has been read in full and repeated, then the next
poem follows. The name refers to a pause within a line of poetry.

This independent project supports **macOS 13 or later**, on Apple Silicon and
Intel. Its interface uses Swift, AppKit and SwiftUI, with no embedded browser,
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
completed readings. Progress survives restarts. Long poems scroll within the
reading area while the author, title and clock remain visible.

Idle time, sleep, lock, app exclusions and the Focus heuristic can pause the
schedule. Strict Mode restricts dismissal; Manual Finish waits for your action.
An optional fullscreen-video feature pauses and resumes the same readable
playback control; it needs accessibility permission and leaves unrecognized
players alone. Permission is requested only from its Preferences button.

## Build and verification

Install an Xcode or Command Line Tools Swift toolchain, then use:

```sh
native/scripts/test.sh
native/scripts/package-app.sh
native/scripts/verify-app.sh native/dist/Caesura.app
open native/dist/Caesura.app
```

`test.sh` compiles the application and runs the custom `caesura-core-tests`
executable; this package does not use `swift test`. Build scripts select an
installed Xcode for their own process when available, without changing global
developer-tool selection. Universal packaging checks both architectures:

```sh
CAESURA_NATIVE_UNIVERSAL=1 native/scripts/package-app.sh
CAESURA_NATIVE_UNIVERSAL=1 native/scripts/verify-app.sh native/dist/Caesura.app
```

Applications are signed ad-hoc, without notarization or Developer ID. CI runs core
checks on macOS and packages universal builds from `main` or a manual dispatch.
Artifacts are workflow downloads, not automatically published releases.

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

The local trial retains bundle ID `net.hovancik.stretchly.trial` and profile
`~/Library/Application Support/StretchlyNativeTrial`. These are deliberately
stable migration identifiers; the application is visibly named **Caesura**.
When a checkout itself has moved, `CAESURA_RETIRED_TRIAL_APP` can identify the
former trial URL for exact login-registration retirement. The maintenance helper
uses ServiceManagement without starting a scheduler or opening windows.
The ordinary package uses `io.github.dingjee.caesura` and
`~/Library/Application Support/Caesura`.

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
`mini`, `long`, `last`, `postpone`, `skip`, `finish` and `preferences`.

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
`CaesuraCore` contains Foundation-only scheduling, settings, poetry and IPC;
`CaesuraApp` owns macOS integration; `caesura-cli` forwards commands.
Run `native/scripts/clean.sh --apply` as the last maintenance step after changes.
It removes owned build/test residue and preserves source, packaged applications
and all persistent profiles.

The macOS implementation and its independent-project migration were developed
with AI assistance, including OpenCode models and Codex review and implementation.
Contributors must understand and be able to maintain submitted changes, disclose
assistance and distinguish observed checks from suggested ones.

## License and attribution

BSD-2-Clause; see [LICENSE](LICENSE). Original copyright notices are retained.
PoetryDB data is CC BY 4.0. See [third-party notices](THIRD_PARTY_NOTICES.md) for
provenance and credits; both documents ship inside the application bundle.

## Known issues

Focus detection is a heuristic. Accessibility-based playback support depends on
the target application's exposed controls. Real permission prompts, physical
display hot-plug and sleep/lock need manual integration verification. Distribution
uses ad-hoc signing and is not notarized. Report issues with the macOS version,
CPU architecture, build revision and relevant logs with private data removed.
