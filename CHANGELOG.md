# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Screenshots for `docs/screenshots/`.
- Android release artifact gate: the exact APK that will be published is now
  installed, cold-launched, and proven to render a first frame on real Android
  system images (API 30 and API 35) before a release can be cut. A non-empty
  Android crash buffer (including a native `galleryd` tombstone) or an adverse
  `ApplicationExitInfo` reason (crash / native crash / ANR / initialization
  failure) blocks the release. Screenshot, crash buffer, exit-info and logcat
  are retained as evidence.
- `scripts/android_release_signing.sh`: a single, tested source of truth for
  Android release signing. All four `ANDROID_KEYSTORE_*` secrets are required;
  a partial configuration always fails rather than being silently ignored; no
  signing material at all fails the release with setup instructions instead of
  publishing an unsigned APK. A throwaway per-run key is possible only via the
  explicit `PRIVATE_GALLERY_RELEASE_ALLOW_EPHEMERAL_SIGNING` repository
  variable, and the release notes say so when it is used.
- `scripts/tests/` — device-free tests for the release gate itself (91
  assertions), run in CI via the "Release gate" job and locally with
  `make release-gate`. `release_workflow_test.sh` asserts the release
  workflow's safety properties structurally, so the guarantee cannot be removed
  by an unrelated edit. A suite that cannot run its assertions (for example, no
  Android SDK for the signature test) is reported as degraded and fails the run
  rather than passing quietly.
- The published APK now ships a `app-release.apk.sha256` checksum alongside it.

### Fixed

- The Android release APK was published completely unsigned, so stock Android
  refused to install it ("App not installed"). `build.gradle.kts` now resolves
  signing material from the CI environment, and CI refuses to publish without
  it.
- `apksigner verify` now runs as a hard gate before publication and asserts
  that APK Signature Scheme v2 and v3 are both present. This assertion is real
  protection, not ceremony: `apksigner` by itself returns 0 for a v2-only APK,
  so an exit-status-only check would publish an artifact the release notes
  describe as v3-signed. v1/JAR signing is no longer claimed in the release
  notes; it is off because minSdk is 24, and it switches on automatically if
  minSdk ever drops below 24.
- The signature gate is a committed, tested script
  (`scripts/android_release_verify_signature.sh`) rather than inline workflow
  logic. `scripts/tests/apksigner_gate_test.sh` links real APKs with `aapt2`,
  signs them with a throwaway key, and runs the real gate against an unsigned, a
  v1-only, a v2-only and a correct v2+v3 artifact.
- The published checksum now records the bare APK filename rather than the CI
  build path, so a user who downloads the APK and its `.sha256` can verify the
  pair with `sha256sum -c`.
- A half-configured keystore, or a configured keystore path that does not
  exist, now fails the Gradle build with an actionable message instead of
  silently producing an unsigned APK.
- Every platform job appended to the GitHub release body instead of replacing
  it, so the last platform to finish no longer erased the other platforms'
  signing warnings. Exactly one job generates the changelog, so it is no longer
  duplicated once per platform.
- Build-only release jobs no longer hold `contents: write`.

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