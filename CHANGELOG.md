# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Screenshots for `docs/screenshots/`.

## [0.1.0] - 2026-09-22

Ported from the *photos-and-videos-organizer* / Private Gallery MVP.

### Added

- Import: folder and removable-drive scan/commit with `copy` and `reference`
  modes, watch folders, and checksum-based dedupe.
- Timeline, places, and events views backed by persisted API state.
- Albums, archive/favorite/trash flags, manual asset tags, and smart folders.
- Search with local Tesseract OCR indexing and heuristic scene tags.
- Whole-library SQLCipher encryption and ChaCha20-Poly1305 sealed vault chunks
  with per-chunk nonces and hash verification.
- Desktop P2P vault sync over Iroh: vaults, device enrollment, storage policies,
  replica health, transfer plans, retry, and cancel.
- Android pairing with QR invites, resumable authenticated uploads, bounded-range
  downloads, session expiry/revocation, and optional encrypted storage
  contribution.
- Loopback-only API (`127.0.0.1:4821`) with `/mobile/*` restricted remote
  surface and `PRIVATE_GALLERY_ALLOW_REMOTE_MOBILE=1` LAN development mode.
- Local backup verify/export and non-destructive restorable restore staging.

### Changed

- Legacy Python face sorter relocated to `tools/quick-face-sort/`.