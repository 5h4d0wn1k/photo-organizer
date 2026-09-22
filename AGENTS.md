# Repository Instructions

## Scope

- Keep changes small and aligned with the current Rust daemon plus Flutter client architecture.
- Treat Linux desktop and Android as the primary supported targets.
- Preserve local-first behavior: media, vault keys, bearer tokens, pairing tokens, OCR text, embeddings, and precise metadata must stay out of hosted services by default.

## Security Defaults

- New managed libraries should use encrypted-only originals unless a task explicitly requires plaintext managed copies.
- Tailscale/HTTPS is the beta mobile-sync default. LAN HTTP is a development mode and must remain explicitly enabled.
- Do not print, commit, or transform secret files. Remove local secret material when it appears in the workspace and tell the user to rotate the exposed credentials.

## Verification

- For Rust service changes, run the narrowest relevant `cargo test` first, then `cargo fmt --check` and `cargo clippy --all-targets --all-features -- -D warnings` when practical.
- For Flutter changes, run `flutter analyze` and the relevant `flutter test` target from `app/`.
- If a check is blocked by missing SDKs, network, keychain access, or platform tooling, report the blocker and the remaining risk.

## Repository Notes

- Repo brand = Photo Organizer.
- Key docs = README.md, CONTRIBUTING.md, PRIVACY.md, SECURITY.md.
- Structure = native_core (Rust daemon), app (Flutter), ml_sidecar (Python), tools/quick-face-sort (legacy face sorter).
