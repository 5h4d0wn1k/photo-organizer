<!--
  One PR, one tracked issue. Reference it in the title (e.g. "fix(security): ... (#58)") and link the issue below.
  Delete the issue line below if no issue exists (dependabot-style bumps).
-->

## Issue

Closes #

## What changed

<!-- Brief, factual summary. No travelogues. -->

## Risk

- [ ] Touches authentication, session, pairing, vault sync, secrets, backup/restore, or encryption.
- [ ] Touches media import/upload/download paths.
- [ ] Touches database schema or persisted API contracts.

## Verification

- [ ] `cargo test --locked` (narrowest relevant target first)
- [ ] `cargo fmt --check` and `cargo clippy --all-targets --all-features -- -D warnings`
- [ ] `flutter analyze` and relevant `flutter test`
- [ ] Secret scan
- [ ] Dependency audit / SBOM
- [ ] CI: Rust service / Flutter app / Security gates green

## Security Checklist

- [ ] No media, vault keys, bearer tokens, pairing tokens, `.env` files, or service credentials are committed.
- [ ] Remote clients remain limited to `/health` and authenticated `/mobile/*`.
- [ ] New managed originals are encrypted-only or the plaintext exception is documented.
- [ ] Session expiry/revocation behavior is covered when mobile access changes.

## Rollback

<!-- Schema/API migrations and where the canary lives; how to revert safely if this ships broken. -->