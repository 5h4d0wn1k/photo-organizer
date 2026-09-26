# Private Beta Release Checklist

## Before Tagging

- Confirm there are no committed local env files, service credentials, bearer tokens, pairing tokens, signing keys, runtime databases, or media exports.
- Confirm every exposed credential from local workspace files has been rotated at its provider.
- Confirm the release scope and completion evidence against [platform-release-and-entitlements.md](platform-release-and-entitlements.md).
- Run Rust checks: `cargo fmt --check`, `cargo clippy --all-targets --all-features -- -D warnings`, and `cargo test`.
- Run Flutter checks from `app/`: `flutter analyze` and `flutter test`.
- Run secret scanning and dependency audit in CI.
- Generate or refresh an SBOM artifact from CI.

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
- Remote mobile mode only exposes `/health` and authenticated `/mobile/*`.
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
- The exact published APK is installed, cold-launched, and proven to render a first frame on real Android system images (API 30 and API 35) with a clean crash buffer and no adverse `ApplicationExitInfo`, before the release is cut. Screenshot, crash buffer, exit-info and logcat are retained as release evidence.
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
