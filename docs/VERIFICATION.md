# Verification

Independent-project migration, 2026-11-01. These results describe checks actually
run for this revision; they do not imply full GUI or integration acceptance.

- `native/scripts/test.sh`: debug application compiled, **183/183** core checks
  passed. `native/scripts/test.sh --release`: release application compiled,
  **183/183** core checks passed after the isolated-import guard was added.
- Universal release packaging through `CAESURA_NATIVE_UNIVERSAL=1
  native/scripts/install-dist.sh`: passed. GUI and CLI executables both contain
  `arm64` and `x86_64`; signatures, bundle metadata, resource bundle, license and
  notices passed `verify-app.sh`. No embedded browser/runtime residue was found.
- The staged `version` self-check exited successfully without a scheduler or UI.
  macOS emitted a sandbox-extension diagnostic for the temporary bundle; it did
  not prevent version reporting, signature validation, installation or launch.
- The installed `dist/Caesura.app` loaded all 465 poems and responded to CLI help
  and log-path requests. Exactly one application process owned the persistent
  profile's `cli.sock`; the previous executable no longer ran. A cold restart
  after `.build` removal again loaded all 465 poems from the packaged resources,
  reported the login item enabled and preserved the config bytes.
- The existing trial profile's config remained byte-for-byte identical before
  and after both replacements (92 settings keys, including poem progress,
  migration state and `openAtLogin: true`). Existing custom-asset/profile files
  were checked by SHA-256; no non-log profile file changed.
- Public ServiceManagement status at the obsolete trial URL changed from
  `enabled` to `notRegistered`. The replacement reports `enabled`. The temporary
  maintenance bundle and vacated old checkout directory were removed. An
  isolated invocation of login-item maintenance was refused with exit code 2,
  before creating a profile or starting UI.
- All shell scripts passed `zsh -n`; GitHub workflow/issue YAML parsed; local
  documentation links resolved. All 54 locale catalogs parsed and no longer
  contained built-in exercise collections or hosted-account sections.

The compiler still reports existing warnings, including missing explicit Combine
visibility imports and unused values in tests; builds completed successfully.

GUI suites, media playback tests, permission dialogs and System Settings were not
used. This kept verification quiet and avoided disturbing the working display
or other applications. Developer ID signing, notarization, manual permission
flows, sleep/lock and physical display hot-plug remain outside this acceptance.

Cleanup ownership probe passed: new and legacy temporary directories bearing
this checkout's markers were removed; foreign and unmarked fixtures were left
alone. The probe fixtures were then explicitly removed. Final
`native/scripts/clean.sh --apply` completed, preserving source, applications and
persistent data.
