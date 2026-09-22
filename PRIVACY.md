# Privacy Policy

**Photo Organizer** is a local-first photo and video library. By default, your
library lives entirely on your own devices: this product does not upload your
photos, videos, or the intelligence derived from them to hosted services.

## What Stays On Device

The following data is processed and stored locally, on the device running the
Photo Organizer daemon (`galleryd`), unless you explicitly choose otherwise:

- Original photos and videos.
- Thumbnails and previews.
- Capture metadata, including timestamps, GPS, and folder hints.
- Derived organization data: timeline buckets, place and event clusters, albums,
  archive/favorite/trash flags, and manual tags.
- OCR text extracted from photos.
- Scene tags computed locally.
- Face templates and labels (future feature; see "Biometric Data" below).
- Search queries and feedback events.
- Library keys, device pairing tokens, and session tokens — kept in OS secure
  storage or hash-only.

## Encryption

- The metadata database is encrypted at rest with **SQLCipher**.
- Imported originals are stored as **ChaCha20-Poly1305** encrypted vault chunks
  with per-chunk nonces, authenticated associated data, and content-hash
  verification.
- Library keys pass through the operating system keychain.
- New libraries default to encrypted-only originals.

For the detailed local-intelligence privacy policy, see
[docs/PRIVACY.md](docs/PRIVACY.md). For trust boundaries and required
controls, see [docs/security-model.md](docs/security-model.md).

## On-Device ML

In v1, machine-learning features run only on your device:

- OCR uses a local Tesseract CLI installation.
- Scene tagging uses a built-in local heuristic analyzer.
- Model files require explicit confirmation and SHA-256 verification before
  installation.

No cloud AI, analytics SDKs, telemetry, remote geocoding, or training on your
library is enabled by default.

## Biometric Data

Face recognition will store face templates and labels. Processing biometric data
requires your **explicit consent**, and templates are **encrypted at rest**. You
always have the right to delete face templates and reset the People feature.

## Networking

- The daemon API binds to `127.0.0.1:4821` by default.
- Non-loopback binding is refused unless `PRIVATE_GALLERY_ALLOW_REMOTE_MOBILE=1`
  is set explicitly; remote clients are limited to `/health` and authenticated
  `/mobile/*` routes.
- Optional LAN/Tailscale sync moves encrypted chunks between devices you own.

## No Telemetry

Photo Organizer does not collect crash reports, usage analytics, or behavioral
telemetry.

## Your Data, Your Control

- Everything is stored locally; you can copy, back up, or remove your library at
  any time.
- Deleting assets and resetting derived data is supported from the app.
- Deleting a face template or resetting People deletes the corresponding
  biometric data from your device.

## Contact

Privacy questions and requests: **5h4d0wn1k@users.noreply.github.com**.

## Changes

This policy may be updated as features ship. Material changes will be noted in
the [CHANGELOG.md](CHANGELOG.md).