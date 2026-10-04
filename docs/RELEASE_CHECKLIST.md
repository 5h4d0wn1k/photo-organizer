# Private Beta Release Checklist

## Before Tagging

- Confirm there are no committed local env files, service credentials, bearer tokens, pairing tokens, signing keys, runtime databases, or media exports.
- Confirm every exposed credential from local workspace files has been rotated at its provider.
- Confirm the release scope and completion evidence against [platform-release-and-entitlements.md](platform-release-and-entitlements.md).
- Run Rust checks: `cargo fmt --check`, `cargo clippy --all-targets --all-features -- -D warnings`, and `cargo test`.
- Run Flutter checks from `app/`: `flutter analyze` and `flutter test`.
- Run secret scanning and dependency audit in CI.
- Generate or refresh an SBOM artifact from CI. It is produced by the `linux` job and
  published as a release asset.
- **Confirm the published asset list matches the intended platform set, and that the tag
  resolves to the commit you intend to release.** CI cannot do this: nothing in the
  workflow compares the tag to a commit, and v0.1.5, v0.1.6 and v0.1.7 were three
  tags on one commit with a byte-identical APK.
- **Sideload the new APK over the previous release on a real device.** This is the only
  check that proves an upgrade path exists. It cannot be automated here: it needs a
  device that already has the previous signed build, and losing the release key forces
  an uninstall, which discards `flutter_secure_storage` (the mobile bearer token and
  paired identity). If the key is an ephemeral per-run key, the upgrade WILL require
  an uninstall -- see the signing paragraph in the release notes.

## Platform And Store Completion

- Linux desktop release has a signed or checksummed bundle/package, daemon startup smoke, import/search/vault/backup smoke, and rollback instructions.
- Windows desktop release has a signed installer/package, daemon launch smoke, Windows secure-storage validation, import/vault smoke, and update/uninstall behavior.
- macOS desktop release is signed/notarized where required, validates keychain storage, reviews sandbox/privacy prompts, and passes import/vault smoke.
- Android Play Store release has a release-signed APK/AAB, Play policy/privacy declarations, staged rollout plan, and mobile pairing/upload/download/storage-node/revocation evidence.
- iOS App Store release has signing, privacy disclosures, permission review, secure-storage validation, and pairing/upload/download behavior designed within iOS platform limits.
- Web/browser release has a privacy-compatible boundary, no default company-hosted content, auth/session review, browser storage review, and upload/download smoke.
- Local web UI release is served from a trusted device, keeps desktop/admin routes isolated, passes CORS/CSRF review, and has LAN/Tailscale exposure rules.
- Direct desktop installers/packages include checksums, signing where available, update strategy, rollback path, and support diagnostics.

## Subscription And Entitlements

- Lowest paid tier remains genuinely usable: local cloud, device group, LAN sync, organization, search, and backup.
- Entitlement checks cover device count, family/workspace limits, relay priority, OCR/intelligence scale, storage-policy features, and admin controls.
- Existing local libraries keep safe offline grace when billing checks are unavailable.
- Billing identifiers and support flows exclude private content, file names, OCR text, face data, exact metadata, vault keys, bearer tokens, and pairing tokens.
- Business/workspace features include roles, permissions, audit logs, support boundaries, and admin reporting before business launch.

## Functional Smoke

- Linux daemon starts on loopback.
- Remote mobile mode only exposes `/health`, static `/local-web/*` assets, and authenticated `/mobile/*`.
- Two authorized Android phones can pair through Tailscale/HTTPS or an explicitly enabled LAN development URL.
- `scripts/android_mobile_smoke.sh` passes with `PRIVATE_GALLERY_SMOKE_REQUIRE_DEVICE_COUNT=2`.
- Android can upload synthetic media larger than Axum's historical default body limit through offset chunks.
- Interrupted/resumed, duplicate, and canceled mobile uploads behave correctly.
- Each phone can see, search, and download each phone's uploaded original before revocation.
- Each phone that explicitly opts into storage contribution receives encrypted chunk assignments, stores the chunks locally, reports proof-of-possession replicas, and can restore a missing encrypted chunk back to the laptop.
- Ranged original and preview downloads verify SHA-256.
- Mobile session refresh rotates the bearer token and rejects the previous token.
- Current mobile session revocation rejects the old bearer token while other phones remain valid.
- Device session revocation rejects all sessions for that device.
- `scripts/android_mobile_app_smoke.sh` installs the debug app on both phones and confirms the visible pairing workspace.
- Profile/release APKs do not accept the `private_gallery_mobile_bearer_token` debug launch extra.
- Release APK/AAB signing does not fall back to the debug key; release signing material is supplied through ignored local properties or external CI secrets, and `PRIVATE_GALLERY_READINESS_REQUIRE_RELEASE_SIGNING=1` passes on the release machine/CI job.
- Android release signing is all-or-nothing: CI refuses to publish unless all four `ANDROID_KEYSTORE_*` secrets are present. A throwaway per-run key is only used when the repository variable `PRIVATE_GALLERY_RELEASE_ALLOW_EPHEMERAL_SIGNING` is explicitly enabled, and the release notes say so. There is no silent fallback, because a release that silently loses its signing key forces users to uninstall — which discards their paired-device identity.
- The published APK is signature-verified with `apksigner` (APK Signature Scheme v2 and v3 asserted explicitly) before it can be published. v1/JAR signing is off because minSdk is 24.
- The exact published APK is installed, cold-launched, and proven to render a stable, visually-complex frame on real Android system images (API 30 and API 35) with a clean crash buffer and no adverse `ApplicationExitInfo`, before the APK can be attached to the release. Screenshot, crash buffer, exit-info and logcat are retained as release evidence; a missing evidence directory fails the job rather than passing quietly.
- Two limits are known and are not regressions. The images are x86_64, so the arm64-v8a and armeabi-v7a slices are checked structurally from the archive and never installed on arm hardware; and on API 31+ the system splash is drawn inside the app's own window, so a stable focused frame cannot be distinguished from the splash. Both are recorded in `AGENTS.md` and in the runbook's *What this does not prove*.
- Every platform artifact is install/launch-gated in CI before publication: Android on real system images, Linux under Xvfb, Windows natively, macOS by mounting the published DMG, and iOS by installing/launching the simulator slice and proving it reaches a host backend. The Android arm-hardware and API 31+ splash limits above still apply. The iOS device `.app` is built and packaged but not install-tested (`simctl` cannot install an `iphoneos` bundle), and the desktop gates prove install/launch/process health, not feature behaviour (issue #98 tracks the remaining manual surfaces).
- One real camera-roll item per phone is intentionally uploaded and visible from the other phone and laptop.

## Data Protection

- New copy/mobile imports seal originals into vault chunks and remove managed plaintext originals when `encrypted_only` is active.
- Reference imports are still marked as external and not protected until copied into the vault.
- Backup verification checks encrypted vault chunks.
- Restore runs only into a separate staging root.

## Recovery Drill

- Restore into a clean root.
- Confirm corrupt vault chunks are detected.
- Confirm missing vault keys block decryption without falling back to plaintext.
- Confirm an interrupted or duplicate mobile upload does not create duplicate assets.
