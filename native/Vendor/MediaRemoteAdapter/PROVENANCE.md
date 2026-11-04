# Provenance of the vendored MediaRemote adapter

The sources in this directory are a **vendored copy** of an upstream project.
They are kept in the repository so that the build never depends on the network
and so that the exact revision stays auditable.

## Upstream

- Project: [ungive/mediaremote-adapter](https://github.com/ungive/mediaremote-adapter)
- Revision: `0e82bf1c44ec39554fbfc402ec88a48c6ae2a0fd` ("Sort projects alphabetically")
- License: BSD 3-Clause — the full text is in `LICENSE`
- Copyright (c) 2025 Jonas van den Berg and contributors
- Purpose: read system media through the private `MediaRemote.framework`.
  The upstream bridge loads its helper into the entitled system `/usr/bin/perl`
  interpreter to handle entitlement restrictions introduced in macOS 15.4.
  Caesura invokes the bundled script without global installation or changes
  to system security settings.

## Vendored files

| Path | Origin |
| --- | --- |
| `LICENSE` | upstream, unchanged |
| `bin/mediaremote-adapter.pl` | upstream, patched (see below) |
| `include/MediaRemoteAdapter.h` | upstream, patched (see below) |
| `src/adapter/*.m`, `src/adapter/*.h` | upstream, unchanged, except `guarded.m` / `guarded.h` |
| `src/private/MediaRemote.h`, `src/private/MediaRemote.m` | upstream, unchanged |
| `src/utility/Debounce.*`, `src/utility/helpers.*` | upstream, unchanged |

The upstream `src/test` directory (the test client) is **not** vendored: it
registers a fake media session with the system, which Caesura never does.
`src/adapter/test.m` is therefore not part of the build either, so the
upstream `test` command is not available in the vendored adapter.

## Local patches (narrow, by Caesura)

1. **`src/adapter/guarded.m` / `src/adapter/guarded.h` (new).** The
   `guarded` command reads the current media session, verifies a guard and
   sends the command **in the same process**. The upstream commands `get` and
   `send` run in two processes, so the session can change between the read
   and the command. The guard compares the application (bundle identifier,
   bundle identifier of the parent application, process identifier) and the
   identifier of the media item (`uniqueIdentifier`, otherwise
   `contentItemIdentifier`). A session that reports no identifier of the media
   item is never acted on — the metadata of the media (title, artist, album)
   is not a proof of the identity of an item and is not used for it. The
   output carries the identity and the state of the session only; no title,
   no address and no artwork leave the helper.
2. **`bin/mediaremote-adapter.pl` (patched).** It accepts the new `guarded`
   command and passes its parameters to the helper through the environment.
3. **`include/MediaRemoteAdapter.h` (patched).** It declares the two new
   functions.

## What the guard does not make atomic

`MRMediaRemoteSendCommand` always goes to the application that reports now
playing information **at the moment of the call**. This adapter does not expose a
command addressed to a specific client or a command carrying a
condition ("pause this session"), so the following remains a race and is not
claimed to be solved:

- Between the verification read and the call of `sendCommand` (a non-atomic
  interval) another application can take over the media session. The
  command would then reach that application.
- The confirmation after the command reads the state again, but the state of
  a player follows the command with a delay of a few milliseconds; a session
  that reports the old state is read as "not confirmed".
- The private framework can change with a future macOS release. The adapter
  then fails and Caesura leaves every media session untouched.

The guard makes the window as small as the interface allows: the read, the
comparison and the command happen in one process, back to back, and every
later read has to show the very same session again.

## Build

From the Caesura repository root:

```sh
native/scripts/build-mediaremote.sh /path/to/MediaRemoteAdapter.framework
```

The script builds arm64 for macOS 13+, excludes the upstream test client,
and needs neither CMake nor a network connection. Packaging signs the
framework with Caesura's configured identity (ad-hoc only when none is
configured). The patched Perl script, license and provenance ship under
`Contents/Resources/MediaRemoteAdapter`; the framework ships under
`Contents/Frameworks`.
