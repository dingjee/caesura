# Contributing to Caesura

Caesura is an independent macOS project. Discuss proposed behavior changes in a
Caesura Issue and obtain maintainer agreement before implementation or a PR.
Use the bug report or feature request template and complete the PR template,
including its linked Issue and Verification Process. Follow the
[Code of Conduct](CODE_OF_CONDUCT.md).

Use Swift with Foundation-only logic in `CaesuraCore`, AppKit and SwiftUI in
`CaesuraApp`. Follow local style and keep changes focused. Support macOS 13+,
Apple Silicon (arm64) only, accessibility and low background resource usage.
Keep the poetry experience quiet and preserve user settings, assets and progress.

Run checks appropriate to the implementation:

- `native/scripts/test.sh` compiles and runs the custom core test executable;
  use this instead of `swift test`.
- `native/scripts/package-app.sh` builds and verifies a signed package.
  The sources are shared and carry no architecture-specific code, but
  releases are packaged arm64-only: `CAESURA_NATIVE_UNIVERSAL=1` is refused,
  and the verification accepts nothing but arm64.
- `native/scripts/verify-app.sh <bundle>` inspects a package without launching it.
- GUI checks require temporary profiles, a secondary display, no activation and
  no audible sounds. Skip them if the secondary display is unavailable.
- Refresh the persistent application with `native/scripts/install-dist.sh` after
  a major application change or on explicit request; routine changes need no new
  build. Keep one verified, usable trial and never reset an existing profile.
  The trial stays in `dist/` — no `/Applications` copy, alias or symlink is
  created.
- Run `native/scripts/clean.sh --apply` as the final maintenance step.

For scheduling/settings changes, trace captured settings, cancellation and
reinitialization. Test intended behavior and specific regressions with minimal
stubbing. User-facing changes require README and Unreleased CHANGELOG updates.
Do not change the version without agreement. Retain required license notices.

Disclose AI assistance. Submit only changes you understand and can maintain.
Report exactly which checks ran, their outcomes and any unverified behavior.
