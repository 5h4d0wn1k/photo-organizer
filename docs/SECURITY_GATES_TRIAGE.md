# Security Gates Triage

Status snapshot for the repository security gates, recorded 2026-09-23 during
the post-audit cleanup (see `docs/FOUNDATION_HARDENING.md` for the broader
hardening migration).

Scope: branch protection, vulnerability (dependabot/cargo-audit) posture,
static-analysis (CodeQL) alert triage, and the residual risk accepted with
rationale.

## Branch protection (main)

- Repository ruleset `main-protection`: `non_fast_forward`, `deletion`,
  `required_linear_history`.
- Classic branch protection: strict required status checks `Rust service`,
  `Flutter app`, `Security gates`; `required_approving_review_count: 0`
  (solo maintainer cannot self-approve); `enforce_admins: true`;
  `allow_force_pushes: false`; `allow_deletions: false`.
- Push-to-main is closed; all changes land via PR. `allow_auto_merge` and
  `delete_branch_on_merge` enabled so green dependabot/PR flows merge
  themselves.
- CodeQL `Analyze (*)` checks are intentionally NOT required contexts:
  dependabot PRs report a neutral `CodeQL` state for them, which would
  deadlock auto-merge. Analysis still runs and alerts still file.

## Dependency vulnerabilities

### Closed this session

- `cmov` CVE GHSA-3rjw-m598-pq24 — fixed by dependabot bump to 0.5.4 (PR #17,
  merged). Query: "Which asset is optional" — used only by `textmarker` in the
  optional OCR feature path.
- `hickory-proto` GHSA-q2qq-hmj6-3wpp and `hickory-net` GHSA-3v94-mw7p-v465 —
  dismissed as `tolerable_risk`. `iroh = "0.98.2"` (latest release) pins
  `hickory-resolver =0.26.0-beta.4`; there is no patched release to bump to.
  The affected `DnssecDnsHandle` path is never compiled because iroh builds
  hickory-resolver without `dnssec-ring`/`dnssec-aws-lc-rs`. Mirror of the
  ignore entry in `.cargo/audit.toml` (RUSTSEC-2026-0120/-0119);
  re-audit on every iroh bump.

### Open queued PRs

Auto-merge queued (rebase + CI then merge):
- `cmov 0.5.4` (PR #17), `image 4.10.1` (PR #12, Flutter package), `actions/checkout@7`
  (PR #2), `actions-rust-lang/setup-rust-toolchain@2` (PR #3).

Require a code migration, closed with rationale on next triage pass:
- `chacha20poly1305` 0.10 -> 0.11, `sha2` 0.10 -> 0.11, `keyring` 3 -> 4,
  `reqwest` 0.12 -> 0.13 (native_core `Cargo.toml` requirements). Each is an
  API-breaking major bump with no forced driver (no advisory); defer until a
  feature requires them.
- `supabase_flutter` 2.12.4 -> 2.17.2, `mobile_scanner` 7.2.0 -> 7.4.2,
  `intl` 0.20.2 -> 0.20.3 (`/app` pubspec) — evaluated on fresh rebase; merge
  when checks go green.

## Static analysis (CodeQL) triage

Default-setup code scanning was silently removed from the repository (all
`code-scanning` endpoints return 404) — the 71-alert set produced during the
audit is not currently regenerable. A first-party
`.github/workflows/codeql-analysis.yml` (PR #19) replaces it
(security-and-quality, weekly + push/PR on main). When it runs, file the
following classification against any regenerated alerts.

### Criticals (4) — all false positives, dismiss with `false_positive`

- `rust/command-line-injection` (native_core/src/ocr.rs:53, :80): the
  Tesseract subprocess is `Command::new(cmd).args(...)` — argv-based, never a
  shell. The `tesseract_path` is operator-provided local config, not remote
  input. No `sh -c`/string interpolation anywhere in the file.
- `rust/hard-coded-cryptographic-value` (native_core/src/vault_store.rs:73,
  :105): the flagged "constant" is the standard Rust idiom
  `let mut nonce = [0_u8; 12]; OsRng.fill_bytes(&mut nonce)` — a zeroed
  buffer immediately filled by a CSPRNG. Keys come from the OS keyring
  (`keyring` crate) or an 0600 file fallback; nonces are per-chunk random.

### High path-injection (67) — dismiss with `false_positive` + comment

Sample-audited across all five files; every flagged sink derives from paths
built out of:
- `AppConfig.runtime_root` / `library_root` (operator-owned local config), and
- internally generated UUIDs (`vault_id`, `blob_id`, `upload.id`, `key_id`).

No remote-controlled filename (sync payload bytes, import path, HTTP request)
flows into a `Path::join`/`fs::*` sink:
- `vault_store.rs` file-key paths: `file_key_path(config, key_id)` where
  `key_id` is `<Uuid>:v<n>`.
- `sync_transport.rs:1141`: `secret_key_path(config)` under operator config.
- `service.rs` mobile-upload staging: `mobile_upload_dir(config, upload.id)`
  — deterministic UUID-based staging directory, op-initiated.
- `model_registry.rs` / `security.rs`: model files + entity paths keyed by ids.

Threat model (see `docs/security-model.md`, `VISION.md`): single-user
local-first app; file-outcome is always under the operator's owned roots.
residual: a malicious peer with key material already breaches the mesh
channel, not the filesystem layering.

## Residuals

1. `required_approving_review_count: 0` — known solo-maintainer tradeoff;
   revisit when a second human reviewer is added.
2. CodeQL checks not required on PRs (neutral on dependabot PRs) — revisit if
   GitHub closes that gap.
3. Rust `cargo-audit` runs under CI `Security gates`; the four iroh-pinned
   ignores re-audit on every iroh bump.

## Re-audit triggers

- iroh bump (hickory/quick-xml ignores re-evaluate).
- New remote-peer write path touching library root (re-filed path-injection).
- Adoption of a second approving reviewer (raise required review count).