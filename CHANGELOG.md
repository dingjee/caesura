# Change Log

## [Unreleased]

### Added

- Caesura: an independent native macOS menu bar app for pauses and progressive
  poetry reading, with 465 bundled public-domain poems and persistent progress.
- Swift/AppKit/SwiftUI application, Foundation core, command-line client, isolated
  core tests, universal packaging and macOS-only GitHub Actions.
- Original two-slash application/menu bar artwork, Caesura modules, executable
  names, documentation and project links.
- Safe replacement of the existing local trial, preserving its stable identity,
  settings, custom assets and migration state.

### Changed

- The macOS implementation becomes the standalone project's `main` snapshot.
- Update checks and feedback links target `dingjee/caesura`.
- Default content is poetry; optional user-provided content remains supported.

### Removed

- The previous cross-platform application, JavaScript/Node dependencies,
  Windows/Linux packaging, inherited release automation and old brand assets.
- Hosted contributor login/settings sync, account windows, sponsorship controls,
  WebKit bridge and bundled exercise tips and sound themes.
