# Photo Organizer

[![License: Apache-2.0](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)
[![CI](https://github.com/5h4d0wn1k/photo-organizer/actions/workflows/ci.yml/badge.svg)](https://github.com/5h4d0wn1k/photo-organizer/actions/workflows/ci.yml)

Photo Organizer is a **local-first, private-by-default photo and video library**.
It gives you a Google-Photos-style organization experience — timeline, places,
events, albums, archive, tags, and search — while keeping your media, metadata,
OCR text, and intelligence on devices you control. No hosted storage, no cloud
AI, no analyzing your library on someone else's servers.

Screenshots land in [`docs/screenshots/`](docs/screenshots/) at v1.0.

## Features

- **Import** — scan folders and removable drives, commit with `copy` or
  `reference` modes, plus persistent watch folders.
- **Checksum dedupe** — content-addressed storage and SHA-256 based deduplication
  across scans and imports.
- **Timeline, places, events** — capture dates, place clusters from
  EXIF/manual hints, and event clusters from time + place.
- **Albums** — create, rename, add/remove assets, and delete albums.
- **Archive & tags** — archive/favorite/trash flags and manual asset tags.
- **Search** — full-text and metadata search, extended by **local OCR**
  (Tesseract CLI) and **scene tags** (on-device heuristic analyzer).
- **Encryption at rest** — the whole metadata database is sealed with
  **SQLCipher**, and originals are stored as **ChaCha20-Poly1305** authenticated
  encrypted vault chunks with per-chunk nonces and content-hash verification.
- **P2P LAN sync** — encrypted vault chunks move between desktop peers over the
  Iroh transport, with replica health, transfer plans, retry, and cancel.
- **Android pairing** — pair a phone by QR invite, upload camera items over
  authenticated resumable uploads, and download originals with bounded ranges.

## Privacy

- The daemon API binds to `127.0.0.1:4821` by default; non-loopback binding is
  refused unless `PRIVATE_GALLERY_ALLOW_REMOTE_MOBILE=1` is set explicitly, and
  remote clients are limited to `/health` and authenticated `/mobile/*` routes.
- **On-device ML only in v1** — OCR runs through the local Tesseract CLI, scene
  tags are computed locally, and model downloads are hash-verified and
  opt-in. No cloud AI, analytics SDKs, telemetry, or remote geocoding.
- Pairing tokens, bearer-token hashes, and library keys stay on device; keys go
  through the OS keychain.
- Keys, face templates, and tokens are stored encrypted at rest.

## Status

Photo Organizer is an evolving **desktop-usable MVP**. The Linux desktop client
is the primary target, with Android mobile pairing over the local network. macOS
and Windows desktop shells are scaffolded but require native platform tooling.
Everything else we plan is tracked in [Roadmap](#roadmap) and the
[CHANGELOG.md](CHANGELOG.md).

## Supported Platforms

- **Linux desktop** — fully supported reference target.
- **Android** — mobile pairing, camera-roll upload, and vault-original download.
- **macOS / Windows / web** — runner scaffolds exist; installers are future work.

## Architecture

```
+----------------+  HTTP over loopback   +------------------------------------+
|  Flutter app   | <--------------------> |  galleryd  (Rust daemon)          |
| desktop+mobile |   127.0.0.1:4821       |  import · metadata · search · sync|
+----------------+                        +-----------+-------+------+-------+
                                                    |       |      |
                        +--------------------------+       |      |
                        |                                  |      |
                 SQLite + SQLCipher  database              |      |
                 (metadata, indexes)                       |      |
                 Encrypted vault chunk store  <------------+      |
                 (ChaCha20-Poly1305 sealed originals)              |
                 Tesseract OCR + Python ML sidecar  <--------------+
                 (local, offline-guarded)
```

- `native_core/` — Rust daemon and library (storage, import orchestration, local API).
- `app/` — Flutter client for Linux desktop and Android.
- `ml_sidecar/` — local Python OCR/scene sidecar (command-line only, never a listener).
- `tools/quick-face-sort/` — legacy standalone Python face sorter.
- `supabase/` — optional metadata-only bootstrap for phone-created device groups.

## Quickstart

### Production (Linux)

Requires the Rust and Flutter toolchains plus native host tools (`cmake`,
`ninja`, `g++`, GTK3 development headers).

```bash
bash scripts/build_linux_release.sh        # builds galleryd + Flutter app, bundles both
bash scripts/install_linux_desktop_entry.sh # adds an application-menu launcher entry
scripts/private_gallery_linux_launcher.sh  # starts the daemon and launches the app
```

The bundled output lands in `app/build/linux/x64/release/bundle/` with `galleryd`
and the `ml_sidecar/` beside the Flutter binary; the application-menu entry still
displays the legacy *Private Gallery* name until the branding migration lands
(see [CHANGELOG](CHANGELOG.md)).

For Android pairing during development, run the daemon in LAN mode on a trusted
network:

```bash
PRIVATE_GALLERY_ALLOW_REMOTE_MOBILE=1 scripts/private_gallery_mobile_lan_daemon.sh
```

Then open the app's Vaults screen, create a device group, add the phone, and scan
the invite QR from the Android app.

### Development

```bash
# Rust daemon
cargo build --manifest-path native_core/Cargo.toml --bin galleryd
cargo test --manifest-path native_core/Cargo.toml

# Flutter desktop client
cd app
flutter run -d linux
flutter analyze
flutter test
```

A one-shot convenience check runs the narrowest supported gate:

```bash
scripts/dev-check.sh
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for the full development workflow.

## Quick Face Sort

`tools/quick-face-sort/` is a standalone legacy tool (Python + tkinter) that
sorts a photo folder against a reference face using dlib face encodings. It is
kept for import/export workflows and is independent of the Photo Organizer
daemon.

```bash
pip install -r tools/quick-face-sort/requirements.txt
python tools/quick-face-sort/main.py
```

The pip `dlib` wheel is CPU-only; builds of `dlib` compiled with CUDA enable GPU
acceleration at higher throughput.

## Roadmap

- Face recognition (clustering + templates) with explicit-consent, encrypted
  biometric storage.
- Thumbnails and previews for mobile and desktop orbits.
- Desktop video playback.
- Semantic search and vector indexing.
- Windows and macOS installers.
- Internationalization (Spanish translation in
  [README.es-ES.md](README.es-ES.md)).

## Documentation

- [docs/architecture.md](docs/architecture.md) — system design and API surface.
- [docs/PRIVACY.md](docs/PRIVACY.md) — detailed local-intelligence privacy model.
- [docs/security-model.md](docs/security-model.md) — trust boundaries and controls.
- [docs/product-vision.md](docs/product-vision.md) — product goals and direction.
- [PRIVACY.md](PRIVACY.md) — short privacy policy.
- [SECURITY.md](SECURITY.md) — how to report vulnerabilities.
- [CONTRIBUTING.md](CONTRIBUTING.md) — how to build and test.
- [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) — community expectations.
- [CHANGELOG.md](CHANGELOG.md) — release history.

## Heritage and Affiliation

Photo Organizer was formerly developed as **Private Gallery**, which grew out of
the *photos-and-videos-organizer* project and still carries its `PG_*`
configuration prefixes in some scripts. The legacy Python face sorter now lives
in [`tools/quick-face-sort/`](tools/quick-face-sort/).

Photo Organizer is **not affiliated with or endorsed by Google Photos**, or by
any other photo-hosting provider.

## License

Apache-2.0. See [LICENSE](LICENSE).