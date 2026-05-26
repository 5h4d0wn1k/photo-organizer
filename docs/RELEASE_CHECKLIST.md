# Private Beta Release Checklist

## Before Tagging

- Confirm there are no committed local env files, service credentials, bearer tokens, pairing tokens, signing keys, runtime databases, or media exports.
- Confirm every exposed credential from local workspace files has been rotated at its provider.
- Run Rust checks: `cargo fmt --check`, `cargo clippy --all-targets --all-features -- -D warnings`, and `cargo test`.
- Run Flutter checks from `app/`: `flutter analyze` and `flutter test`.
- Run secret scanning and dependency audit in CI.
- Generate or refresh an SBOM artifact from CI.

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
