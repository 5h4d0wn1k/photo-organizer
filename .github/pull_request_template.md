## Summary

-

## Risk

- [ ] Touches authentication, session, pairing, vault sync, secrets, backup/restore, or encryption.
- [ ] Touches media import/upload/download paths.
- [ ] Touches database schema or persisted API contracts.

## Verification

- [ ] `cargo fmt --check`
- [ ] `cargo clippy --all-targets --all-features -- -D warnings`
- [ ] `cargo test`
- [ ] `flutter analyze` from `app/`
- [ ] `flutter test` from `app/`
- [ ] Secret scan
- [ ] Dependency audit / SBOM

## Security Checklist

- [ ] No media, vault keys, bearer tokens, pairing tokens, `.env` files, or service credentials are committed.
- [ ] Remote clients remain limited to `/health` and authenticated `/mobile/*`.
- [ ] New managed originals are encrypted-only or the plaintext exception is documented.
- [ ] Session expiry/revocation behavior is covered when mobile access changes.

## Rollback

-
