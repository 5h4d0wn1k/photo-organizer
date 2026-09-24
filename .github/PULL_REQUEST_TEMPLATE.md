<!--
  One PR, one tracked issue. Reference it in the title (e.g. "fix(security): ... (#58)") and link the issue below.
-->

## Issue

Closes #

## What changed

<!-- Brief, factual summary. No travelogues. -->

## Verification

<!-- State exactly what you ran and the result. -->

- [ ] `cargo test --locked` (narrowest relevant target first)
- [ ] `cargo fmt --check` and `cargo clippy --all-targets --all-features -- -D warnings`
- [ ] `flutter analyze` and relevant `flutter test`
- [ ] CI: Rust service / Flutter app / Security gates green

## Security & rollout

<!-- Call out anything a reviewer must check: secrets, migration/back-compat, data-loss windows, permissions, cleanup. -->