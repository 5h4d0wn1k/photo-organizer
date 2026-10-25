# Desktop Development

## Purpose

This repository ships generated Flutter runners for Linux, macOS, and Windows. The app code can be analyzed and tested anywhere Flutter runs, but native desktop builds still depend on host-specific toolchains.

## Linux

Required host tools:

- `cmake`
- `ninja`
- `g++`
- `pkg-config`
- `gtk+-3.0` development headers

Typical validation commands:

```bash
cd app
flutter analyze
flutter test
flutter build linux
```

Build a local release bundle that includes both the Flutter app and the Rust
daemon:

```bash
scripts/build_linux_release.sh
```

Install a local app-menu launcher for this checkout:

```bash
scripts/install_linux_desktop_entry.sh
```

The generated launcher starts the bundled `galleryd` first when present, falls
back to local Cargo build outputs, waits for
`http://127.0.0.1:4821/health`, writes logs under `runtime/`, then opens
`app/build/linux/x64/release/bundle/private_gallery_app`.

## macOS

Required host tools:

- Xcode
- Xcode command line tools
- Flutter macOS desktop support enabled

Typical validation commands:

```bash
cd app
flutter build macos
```

## Windows

Required host tools:

- Visual Studio with Desktop development for C++
- CMake
- Ninja or MSBuild-compatible tooling
- Flutter Windows desktop support enabled

Typical validation commands:

```powershell
cd app
flutter build windows
```

## Local API Dependency

The desktop app expects the Rust daemon on `http://127.0.0.1:4821`. It can try to start the daemon automatically on desktop, but manual startup is also supported:

```bash
cargo run --manifest-path native_core/Cargo.toml --bin galleryd
```

## Stable-release desktop acceptance

Tracked by issues #216 (release workflows), #217 (encrypted media display),
and #218 (device-neutral local family groups).

Desktop is a local gallery and file workspace. Gallery, Files, Albums, People,
Places, Events, Search, Archive, My Devices, Activity and Settings must remain
reachable at typical laptop and compact window sizes. Presence of a screen is
not acceptance: verify importing real media, seeing previews, opening a photo,
organizing files, exporting a selected original and recovering from an offline
peer or unavailable file.

Managed originals remain encrypted-only by default. Desktop previews use the
loopback-private media API; the grid requests a thumbnail and photo detail
requests full-size decrypted bytes in memory. Neither flow should create a
plaintext temporary original. Remote peers must use their own scoped sessions;
opening desktop management routes to the LAN is not a pairing implementation.

Family groups must not require a dedicated desktop or a cloud account. A device
may own a library, join another group, and store selected encrypted replicas;
Admin/Contributor/Viewer/StorageOnly permissions remain independent of hardware.
The current implementation has gaps: desktop rejects local group invites and
mobile cannot yet run a supported local backend to create a fully offline group.
Optional hosted bootstrap currently stores unencrypted group/device membership
metadata and does not satisfy this release requirement.

Required family acceptance: phone creates a group offline, desktop joins,
selected photos/files transfer end-to-end encrypted, both restart and reconnect,
a member is revoked and access is denied, and key recovery is exercised. Repeat
with a desktop-created group. Android and iOS runtime/key-storage integration must
be proven separately; iOS background availability must be stated accurately.
These are release blockers, not completed features.
