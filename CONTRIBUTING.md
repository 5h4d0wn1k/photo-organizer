# Contributing to Photo Organizer

Thanks for contributing. This project is local-first and privacy-first; keep
those values intact in every change.

## Repository Layout

- `native_core/` — Rust daemon (`galleryd`) and library: storage, import
  orchestration, metadata, search, sync, and the local HTTP API.
- `app/` — Flutter client for Linux desktop and Android.
- `ml_sidecar/` — local Python OCR/scene sidecar (command-line only).
- `tools/quick-face-sort/` — legacy standalone Python face sorter; this is a
  separate tool, not part of the daemon or the Flutter app.
- `supabase/` — optional metadata-only bootstrap migration for device groups.
- `docs/` — architecture, security, and delivery notes.

## Prerequisites

- Rust **stable** toolchain (edition 2024), including `rustfmt` and `clippy`.
- Flutter **stable** channel SDK with the target platform toolchain.
- Linux desktop builds additionally need `cmake`, `ninja`, `g++`, and GTK3
  development headers.
- A local Tesseract CLI is required for OCR features.

## Local Setup

```bash
git clone https://github.com/5h4d0wn1k/photo-organizer.git
cd photo-organizer

# Rust daemon
cargo build --manifest-path native_core/Cargo.toml --bin galleryd

# Flutter app
cd app
flutter pub get
flutter run -d linux
```

## Checks

Run the requested checks before submitting a PR:

```bash
# Rust
cargo fmt --check
cargo clippy --all-targets --all-features -- -D warnings
cargo test --manifest-path native_core/Cargo.toml

# Flutter (from app/)
flutter analyze
flutter test

# Narrow project gate (fast smoke)
scripts/dev-check.sh
```

Privacy-sensitive / high-risk changes should also mention secret scanning
(gitleaks) and the dependency audit that run in CI.

## Contribution Workflow

Every change to `main` lands through a tracked, reviewed pull request —
never by pushing to `main` directly.

1. **Issue first.** Open an issue (or claim an existing one) describing the
   change and its rationale; reference it from the PR description so merging
   closes it.
2. **Focused branch.** Create a branch off `main` named after the change:
   `feat/...`, `fix/...`, `ci/...`, `docs/...`, `chore/...`. One logical
   change per PR; keep the diff as small as practical.
3. **Conventional title.** Title the PR `type(scope): subject`
   (`feat`, `fix`, `build`, `ci`, `docs`, `chore`, `refactor`, `perf`,
   `test`, `style`). The semantic-PR check enforces this, and the title
   becomes the squash-merge commit message.
4. **Review before merge.** Merge only after all three required checks
   (Rust service, Flutter app, Security gates) pass and the diff has been
   formally reviewed — self-review with written comments on your own PR,
   Copilot code review where available, and every review finding addressed.
5. **Squash-merge.** Merge with the PR title; branch auto-deletes. Keep the
   change history linear.

Repo automation keeps the baseline consistent without manual process:
PR labeler (`gha/**` → `rust`/`flutter`/`ci`/`docs`/`deps`/...), semantic-PR
title validation, dependency review on every PR, dependabot security updates
with grouped minor/patch bumps, CodeQL + Scorecard on `main`, gitleaks/GitGuardian
secret scanning, cargo-audit, SBOM generation, and stale issue/PR cleanup.

## Architecture Pointers

- Read `docs/architecture.md` before touching API routes or the data model.
- Store secrets and sensitive derived data encrypted at rest; never log media
  paths, tokens, or metadata.
- Remote clients are limited to `/health`, `/local-web/*`, and authenticated
  `/mobile/*`. Desktop control routes must stay loopback-only.
- Do not add hosted services for media, thumbnails, keys, OCR text, or
  embeddings without a documented privacy review.
- Keep the legacy face sorter in `tools/`; do not wire it into `galleryd`.

## PR Checklist

- [ ] Change addresses an open issue or documents a rationale.
- [ ] `cargo fmt --check`, `cargo clippy`, `cargo test` pass.
- [ ] `flutter analyze` and `flutter test` pass from `app/`.
- [ ] No secrets, `.env` files, tokens, or private media committed.
- [ ] Updated `CHANGELOG.md` under `[Unreleased]` when user-visible.
- [ ] Updated relevant docs when behavior, API, or the data model changes.

## Code of Conduct

Be kind and constructive. All interactions fall under our
[CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).