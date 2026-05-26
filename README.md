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
- Android mobile onboarding with create/join group choices, QR/manual invite capture, secure session storage, camera-roll access checks, upload of the newest local item to the paired vault, and download of an available vault original.

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

For private beta mobile sync, prefer a Tailscale/HTTPS path that exposes only
`/health` and `/mobile/*` while the daemon stays loopback-bound. Desktop control
routes remain loopback-only, and the daemon treats Tailscale Serve identity
headers as remote clients even when the proxy forwards to `127.0.0.1`.

Plain hotspot/LAN HTTP is development mode. To use it, intentionally enable
remote mobile mode and use the dedicated launcher. It binds `0.0.0.0:4821` only
when `PRIVATE_GALLERY_ALLOW_REMOTE_MOBILE=1` is set:

```bash
PRIVATE_GALLERY_ALLOW_REMOTE_MOBILE=1 scripts/private_gallery_mobile_lan_daemon.sh
```

For LAN development, connect each Android phone to the laptop hotspot or the
same trusted LAN, then open the desktop app's Vaults screen. Create a device
group if one does not exist, choose "Add Device", confirm the
`http://<laptop-hotspot-ip>:4821` URL, and scan the generated QR from the
Android app's "Join group" flow. Pair the phone, upload the newest camera item,
then use "Download first original" to verify a vault original can round trip.
The hotspot IP can change; when it does, create a fresh invite QR with the
current URL.

Flutter builds may optionally enable metadata-only group bootstrap with
Supabase by passing `PRIVATE_GALLERY_SUPABASE_URL` and
`PRIVATE_GALLERY_SUPABASE_ANON_KEY` as Flutter `--dart-define` values and
installing `supabase/device_group_bootstrap.sql`. This uses anonymous Auth plus
RLS-protected Postgres tables/RPC only, so it fits the free-tier feature set
without Edge Functions. It stores group membership metadata only; originals,
thumbnails, vault keys, desktop pairing tokens, and mobile bearer tokens remain
local. Desktop "Join Group" accepts pasted cloud or hybrid invite JSON.

Before pairing phones over LAN development mode, the expected remote boundary is:

```bash
curl -fsS http://<laptop-hotspot-ip>:4821/health
curl -i http://<laptop-hotspot-ip>:4821/library/status # 403
```

When using Tailscale Serve, keep the daemon on loopback and expose only
`/mobile` and `/health`; desktop control routes should return `403` to
tailnet-proxied clients.

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
the deterministic real-device mobile API smoke. For hotspot/LAN mode, pass the
URL that phones should use and require two authorized phones for final
acceptance:

```bash
PRIVATE_GALLERY_SMOKE_DEVICE_BASE_URL=http://<laptop-hotspot-ip>:4821 \
PRIVATE_GALLERY_SMOKE_REQUIRE_DEVICE_COUNT=2 \
scripts/android_mobile_smoke.sh
```

For USB-only development against loopback, the default command still works with
`adb reverse`:

```bash
scripts/android_mobile_smoke.sh
```

The API smoke installs a temporary Dex HTTP helper on each authorized phone,
pairs all phones first, checks remote `/health` and desktop-route blocking for
LAN URLs, uploads synthetic originals larger than Axum's historical default
body limit through resumable chunks, proves duplicate/cancel handling, verifies
cross-device visibility before revocation, downloads ranged originals/previews,
checks SHA-256 hashes, verifies bearer refresh rejects the previous token, and
verifies session/device revocation. Use
`PRIVATE_GALLERY_SMOKE_DEVICE_SERIALS="serial1 serial2"` to pin the exact phones.

For a Flutter app-level pairing smoke, build/install the debug APK and load a
debug-only local group session into each installed app:

```bash
PRIVATE_GALLERY_SMOKE_DEVICE_BASE_URL=http://<laptop-hotspot-ip>:4821 \
PRIVATE_GALLERY_SMOKE_DEVICE_SERIALS="serial1 serial2" \
scripts/android_mobile_app_smoke.sh
```

The app smoke defaults to `PRIVATE_GALLERY_APP_SMOKE_PAIR_MODE=direct`, which is
debug-only and not compiled into release behavior. Use
`PRIVATE_GALLERY_APP_SMOKE_PAIR_MODE=ui` to exercise the visible pairing flow,
`PRIVATE_GALLERY_APP_SMOKE_PAIR_MODE=manual` for a manual checklist, or
`PRIVATE_GALLERY_APP_SMOKE_UPLOAD_NEWEST=1` to attempt the real camera-roll
upload button after pairing. See
[docs/android-mobile-smoke.md](docs/android-mobile-smoke.md) for the full
laptop-plus-two-phones runbook.

Linux desktop builds require native host tools such as `cmake`, `ninja`, `g++`, and `gtk+-3.0` development headers. See [docs/desktop-development.md](/mnt/windows/transfer/Work/Projects/Personal%20Use%20Projects/photos%20and%20videos%20organizer/docs/desktop-development.md).

Use the helper below to run the narrowest supported checks:

```bash
scripts/dev-check.sh
```
