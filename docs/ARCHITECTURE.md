# Architecture

Caesura supports macOS 13+ with no third-party runtime dependencies.

- `native/Sources/CaesuraCore`: Foundation-only scheduling/state machines,
  JSON settings and safe import, poem catalog/rotation/reveal, localization,
  command parsing and UNIX-domain socket IPC.
- `native/Sources/CaesuraApp`: AppKit/SwiftUI windows, menu bar, permissions,
  notifications, display/idle/sleep/Focus monitoring, audio and accessibility-based
  fullscreen playback integration.
- `native/Sources/caesura-cli`: forwards commands to the instance for its profile.
- `native/Tests/CaesuraCoreTests`: custom executable regression suite.
- `native/scripts`: build, package, verify, install and owned-artifact cleanup.
- `assets`: original Caesura vector identity; the AppKit icon renderer uses the
  same geometry for application icons.

A scheduler is owned by one coordinator. Its profile's live CLI socket rejects a
second application instance. Changing configuration rebuilds the relevant planner
machines; poem progress writes suppress configuration notifications so they do
not restart the schedule. A completed break advances a frozen poem session;
skipping/postponing does not. Current-poem browsing never advances progress.

Known JSON keys remain compatible with imported profiles. Invalid known values
fall back to defaults; unknown keys remain intact. First-run imports preserve
source files, create backups and never overwrite existing destination assets.
The trial's bundle ID/profile directory are permanent compatibility contracts;
new source, modules, executables and the ordinary bundle use Caesura names.
Archived account stamps are copied only as migration data and grant no feature.

All local UI is native. There is no hosted account service or privileged web
bridge. Update checks request the independent project's GitHub releases endpoint.
Global shortcuts use Carbon, login items use ServiceManagement and notification
permission belongs to the installed application. Isolated runs skip profile
imports, login registration and notification authorization.

The catalog and localization resources are bundled with SwiftPM. Application
bundles include the original BSD license and third-party/poetry attribution.
