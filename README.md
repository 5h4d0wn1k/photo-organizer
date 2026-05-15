# Private Gallery

Private Gallery is a local-first, private-by-default photo and video organizer inspired by Google Photos while keeping all media intelligence on your own devices.

## Current Status

This repository now contains a desktop-usable MVP for the first phase of the product:

- Rust local daemon with persisted SQLite metadata.
- Flutter desktop client with real startup, setup, import, settings, and live-data screens.
- Cross-desktop runners for Linux, macOS, and Windows.
- Android runner with mobile pairing, camera-roll access, local upload, and vault-original download actions.
- Real folder and removable-drive scan/commit imports with copy/reference modes and checksum dedupe.
- Live timeline, places, events, and jobs views backed by persisted API state.
- Encrypted database activation, encrypted vault chunk storage, local-only OCR indexing/search, model governance, chunk-aware backup export/restore staging, and large-library timeline pagination.

The codebase intentionally preserves API surfaces for people, scenes, semantic search, pairing, and distributed vault sync. The vault/device/sync control plane is typed and persisted, originals are sealed into authenticated encrypted chunks, desktop peers can move encrypted chunks over the Iroh transport, and Android can pair with a desktop daemon over LAN for authenticated upload/download without hosted photo storage.

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
- Backup readiness verification, restorable local export, and non-destructive restore staging.
- Distributed vault state: vaults, enrolled devices, storage policies, content-addressed encrypted chunk records, local key envelopes, replica health, availability status, sync transfer planning, and retry/cancel controls.
- Vaults desktop screen for device status, replica health, network status, and transfer queue actions.
- Iroh-backed encrypted desktop P2P vault sync with durable transfer records, local endpoint payloads, storage-only replica support, and remote pull after local eviction.
- Android mobile pairing with QR/manual token capture, secure session storage, camera-roll access checks, upload of the newest local item to the paired vault, and download of an available vault original.

## Intentionally Deferred

- Face clustering and real biometric indexing providers.
- Scene tagging, semantic search, and vector indexing providers.
- Native Android Iroh transport and background chunk-level mobile sync; current Android sync uses the desktop local API over an explicitly entered LAN URL.
- Hosted discovery/relay service deployment and internet NAT traversal validation.
- File-picker based import selection.
- In-place restore over the active library; restore is staged into a separate folder for review.
- Cloud relay, public sharing, or remote ML.

## Local Development

Start the Rust daemon for desktop-only local development:

```bash
cargo run --manifest-path native_core/Cargo.toml --bin galleryd
```

For the daily-driver hotspot/LAN workflow, intentionally enable remote mobile
mode and use the dedicated launcher. It binds `0.0.0.0:4821` only when
`PRIVATE_GALLERY_ALLOW_REMOTE_MOBILE=1` is set:

```bash
PRIVATE_GALLERY_ALLOW_REMOTE_MOBILE=1 scripts/private_gallery_mobile_lan_daemon.sh
```

Connect each Android phone to the laptop hotspot or the same trusted LAN, then
enter `http://<laptop-hotspot-ip>:4821` as the desktop daemon URL in the
Android app. Create the pairing token from the local desktop app or local API,
pair the phone, upload the newest camera item, then use "Download first
original" to verify a vault original can round trip. The hotspot IP can change;
when it does, update the URL in the Android app and in smoke-test environment
variables.

Before pairing phones, the expected remote boundary is:

```bash
curl -fsS http://<laptop-hotspot-ip>:4821/health
curl -i http://<laptop-hotspot-ip>:4821/library/status # 403
```

Tailscale Serve remains optional/future for v1. When it is available, keep the
daemon on loopback and expose only `/mobile` and `/health`; the daemon treats
Tailscale Serve identity headers as remote clients, so desktop control routes
remain blocked even though Serve forwards over loopback.

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

When Android phones are attached over USB and a daemon is already running, run
the real-device mobile smoke. For hotspot/LAN mode, pass the URL that phones
should use:

```bash
PRIVATE_GALLERY_SMOKE_DEVICE_BASE_URL=http://<laptop-hotspot-ip>:4821 scripts/android_mobile_smoke.sh
```

For USB-only development against loopback, the default command still works with
`adb reverse`:

```bash
scripts/android_mobile_smoke.sh
```

The smoke installs a temporary Dex HTTP helper on each authorized phone, pairs
the phone, uploads a tiny test original, lists mobile assets, downloads the
original back, and checks the SHA-256 hash.

Linux desktop builds require native host tools such as `cmake`, `ninja`, `g++`, and `gtk+-3.0` development headers. See [docs/desktop-development.md](/mnt/windows/transfer/Work/Projects/Personal%20Use%20Projects/photos%20and%20videos%20organizer/docs/desktop-development.md).

Use the helper below to run the narrowest supported checks:

```bash
scripts/dev-check.sh
```
