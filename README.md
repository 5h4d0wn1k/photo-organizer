# Private Gallery

Private Gallery is a local-first, private-by-default photo and video organizer inspired by Google Photos while keeping all media intelligence on your own devices.

## Current Status

This repository now contains a desktop-usable MVP for the first phase of the product:

- Rust local daemon with persisted SQLite metadata.
- Flutter desktop client with real startup, setup, import, settings, and live-data screens.
- Cross-desktop runners for Linux, macOS, and Windows.
- Android runner with mobile pairing and camera-roll permission readiness screens.
- Real folder and removable-drive scan/commit imports with copy/reference modes and checksum dedupe.
- Live timeline, places, events, and jobs views backed by persisted API state.
- Encrypted database activation, local-only OCR indexing/search, model governance, backup verification/export surfaces, and large-library timeline pagination.

The codebase intentionally preserves API surfaces for people, scenes, semantic search, pairing, and distributed vault sync. The vault/device/sync control plane is typed and persisted, while actual P2P media transfer transport still returns honest planned or pending state until a transport provider is implemented.

## What This Repository Contains

- `app/`: Flutter client and desktop runners.
- `native_core/`: Rust core daemon and library for storage, import orchestration, and local APIs.
- `docs/`: architecture, security, and delivery notes.
- `scripts/`: lightweight local validation helpers.

## Product Principles

- Local-first, with the primary laptop as the authoritative library.
- Native clients for desktop and mobile, not a web-only wrapper.
- On-device ML only in v1.
- Privacy-sensitive data such as face templates, sync keys, and feedback events are encrypted at rest.
- The product learns through user correction loops instead of silent, irreversible automation.

## Implemented In This Slice

- Library setup with persisted `library_root` and default import mode.
- Watch-folder management.
- Folder and removable-drive import scans.
- Commit-time `copy` or `reference` import mode.
- Checksum-based dedupe across scans and imports.
- Timeline buckets derived from imported capture metadata.
- Place clusters from EXIF/manual hints.
- Event clusters from timestamps and place hints.
- Live job history for scans and imports.
- Desktop daemon bootstrap flow from the Flutter client.
- Paginated timeline loading for large local libraries.
- Local Tesseract OCR batches after encryption is active.
- Backup readiness verification and DB/manifest export.
- Distributed vault control-plane state: vaults, enrolled devices, storage policies, content-addressed blob records, replica health, availability status, and sync transfer planning.
- Android mobile pairing shell with QR/manual enrollment payload capture, secure local pairing storage, and camera-roll access checks.

## Intentionally Deferred

- Face clustering and real biometric indexing providers.
- Scene tagging, semantic search, and vector indexing providers.
- P2P media transfer execution over LAN, internet, or relay.
- Mobile P2P handshake, camera-roll upload execution, and remote original fetches.
- File-picker based import selection.
- Full media-copy backup restore UX.
- Cloud relay, public sharing, or remote ML.

## Local Development

Start the Rust daemon:

```bash
cargo run --manifest-path native_core/Cargo.toml --bin galleryd
```

Run the Flutter desktop client once Flutter is installed and the host toolchain is available:

```bash
cd app
flutter run -d linux
```

Build a one-command Linux bundle with the Rust daemon copied beside the app:

```bash
scripts/build_linux_release.sh
scripts/private_gallery_linux_launcher.sh
```

Useful checks:

```bash
cargo test --manifest-path native_core/Cargo.toml
cd app && flutter analyze && flutter test
```

Linux desktop builds require native host tools such as `cmake`, `ninja`, `g++`, and `gtk+-3.0` development headers. See [docs/desktop-development.md](/mnt/windows/transfer/Work/Projects/Personal%20Use%20Projects/photos%20and%20videos%20organizer/docs/desktop-development.md).

Use the helper below to run the narrowest supported checks:

```bash
scripts/dev-check.sh
```
