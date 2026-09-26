# Repository Instructions

## Product Principles (non-negotiable)

1. **Local-first.** All media, metadata, indexes, models, vault keys, bearer/pairing tokens, OCR text, and embeddings live on the user's own devices and network. Nothing about the user's library is hosted by us.
2. **Security-first.** Encryption (SQLCipher), key storage (OS keychain/secure storage), constant-time comparisons, and secrecy at rest are default-on for anything sensitive. Security defects get the highest backlog priority and are fixed without workarounds or downgraded guarantees.
3. **Privacy-first — we collect nothing.** This is purely software. There is no telemetry, no analytics, no crash reporting to us, and no account that must reach our servers. The product must continue to work fully offline. Any feature that would ship user data off-device is not acceptable unless the user opts in explicitly and the transfer is end-to-end encrypted.
4. **Quality over shortcuts.** No workarounds, no degraded guarantees, no "good enough" merges. Every change must be robust, tested, and **matured and improved over time**. Features must reach a mature, production-grade state — not a sketch.

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

## Workflow (mandatory for every change)

- Every task is tracked as a GitHub issue on the project board first. No orphan branches or untracked PRs.
- Changes land via: branch → PR → deep multi-agent review → green CI/security tests → squash-merge → board item moved to Shipped.
- Every change is verified end-to-end (unit + integration + CI in `.github/workflows/` and the blocklist of checks on the PR) before merge. Do not merge code you haven't verified both locally and in CI.
- Never auto-close issues; issues are closed only when the work is genuinely solved or deliberately triaged with rationale.

## Repository Notes

- Repo brand = Photo Organizer.
- Key docs = README.md, CONTRIBUTING.md, PRIVACY.md, SECURITY.md.
- Structure = native_core (Rust daemon), app (Flutter), ml_sidecar (Python), tools/quick-face-sort (legacy face sorter).
- Dev entry points = Makefile (fmt/lint/test/check/audit/flutter-*/release-gate/release-linux-local) and scripts/dev-check.sh.

## Artifact QA (thanks to research sess-2026-09-25, applied as drop-gate)

- Every release artifact must be **installed, cold-launched, non-crash-verified, and evidenced (screenshot/log artifact on the runner harness)** on at least the targets that free runners can prove (Android emulator, iOS simulator, Linux Xvfb, Windows native, macOS `.app`). Fail on install/launch/crash; any failure blocks the release tag.
- Gates are hard (non-zero) OR explicitly degraded with reported cause — never silently skipped. If a runner cannot prove a surface (physical device, paid signing, Metal/GPU), document that it is manual/managed, do not fake it.
- Reference OSS that already do this and are approval-compatible: LocalSend, FlClash, SQLDelight (PR.yml emulator matrix), flutter's own engine test harness (Xvfb 1280x800x24), and the iOS/Android `integration_test` screenshot carriers.
- Current coverage: **Android is implemented and blocking.** `scripts/android_release_artifact_smoke.sh` installs the exact artifact, cold-launches it, proves a real first frame rendered, and fails on a non-empty crash buffer (Java or native `galleryd` tombstone) or an adverse `ApplicationExitInfo` reason — on API 30 and API 35. `scripts/android_release_verify_signature.sh` asserts the APK is signed with v2 **and** v3 (apksigner alone accepts a v2-only APK, so the exit status is not enough), and `scripts/android_release_signing.sh` owns the all-or-nothing signing policy. The iOS/Linux/Windows/macOS artifact gates are **not** implemented and are tracked in issue #98; never describe them as gated.
- The gate's own logic runs on every CI run (`make release-gate`), and `scripts/tests/release_workflow_test.sh` asserts the release workflow's safety properties structurally, so the guarantee cannot be quietly removed by an unrelated edit.
