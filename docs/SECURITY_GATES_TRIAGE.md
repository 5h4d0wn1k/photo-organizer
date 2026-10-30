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
- Push-to-main is closed; all changes land via PR. `delete_branch_on_merge` enabled.
- Repo-level `allow_auto_merge` was DISABLED on 2026-09-24 after the auto-merge
  flow produced empty single-parent dependabot commits (e.g. `dde6176`, `fcefda6`
  for #38/#39): strict status checks + `allow_update_branch` + auto-merge races
  rebased dependabot branches onto main and merged empty results, so dependabot
  believed PRs landed while no changes did (pub #47 and actions #50 bumps had to be
  re-landed manually). Dependabot PRs now require a deliberate merge by a human.
- CodeQL `Analyze (*)` checks are intentionally NOT required contexts:
  dependabot PRs report a neutral `CodeQL` state for them, which would
  deadlock auto-merge. Analysis still runs and alerts still file.

## Dependency vulnerabilities

### Iroh dependency and compatibility upgrade

- `cmov` CVE GHSA-3rjw-m598-pq24 — fixed by dependabot bump to 0.5.4 (PR #17,
  merged). Query: "Which asset is optional" — used only by `textmarker` in the
  optional OCR feature path.
- `hickory-proto` GHSA-q2qq-hmj6-3wpp and `hickory-net` GHSA-3v94-mw7p-v465 —
  the prior `tolerable_risk` dismissals and matching `.cargo/audit.toml`
  suppressions were removed with issue #175's Iroh 1.x update. The current
  locked dependency graph contains no Hickory packages, so these advisories no
  longer apply to this repository. The Iroh 1.4.1 locked graph also removes the old
  `atomic-polyfill` warning and upgrades `lru` to 0.18.5, above the patched
  minimum. The yanked `yoke-derive` 0.8.3 lock entry was advanced to 0.8.4.
  PR #175 merged as `1fd18ae7` after all 27 current checks passed, including
  the actual historical Photo Organizer 0.98.2 daemon/current 1.x daemon
  acceptance in both role placements. The gate verifies encrypted Push,
  persisted replica proof before eviction, restart, Pull, exact original bytes,
  and enrolled identity preservation after upgrade. The independent wire peer
  remains separate regression coverage; it is not the historical-app proof.

### Audit refresh: 30 October 2026 (#228)

The PR #175 hosted audit reported no vulnerability errors but five visible
informational warnings. A green audit exit did not mean that `paste` was the
only warning:

- `tokio` 1.53.1: RUSTSEC-2026-0386, unsound `AsyncFd` constructors. The
  production minimum and lock now require 1.53.3, the patched maintenance
  release. The transport and historical application gates must pass again.
- `paste` 1.0.15: RUSTSEC-2024-0436, unmaintained compile-time macro dependency
  through Iroh's netlink stack. It remains visible and unsuppressed.
- `zbus_names` 3.0.0, `zvariant` 4.2.0 and `zvariant_derive` 4.2.0:
  RUSTSEC-2026-0371, -0370 and -0372, respectively. These are present in the
  lockfile through optional keyring dependencies. `cargo tree --locked
  --target all --all-features -i zbus` (and the equivalent `zvariant` and
  `secret-service` queries) finds no active reverse dependency for the configured
  workspace. The selected Linux keyring uses synchronous `dbus-secret-service`.
  This is an applicability finding, not removal from the lockfile or a claim
  that those crates are maintained. Reassess before enabling an asynchronous
  keyring backend or changing keyring features.

No advisory ignores were added. The immutable historical source used only by
the isolated compatibility harness intentionally retains its original lockfile;
its dependencies are not part of the shipped product dependency graph.

### Merged this session

- `cmov 0.5.4` (#17) — closes GHSA-3rjw-m598-pq24.
- `image 4.10.1` (#12, Flutter package), `actions/checkout@7` (#2),
  `actions-rust-lang/setup-rust-toolchain@2` (#3), `mobile_scanner 7.4.2` (#15),
  `intl 0.20.3` (#13), `supabase_flutter 2.17.2` (#14).
  #14 required a one-line migration shipped on the PR branch
  (`Supabase.initialize` `anonKey:` -> `publishableKey:`, cloud_bootstrap_service.dart:73).

### Closed with rationale (no forcing advisory; dependabot will re-file)

- `chacha20poly1305` 0.10 -> 0.11 — API breakage in the vault crypto path
  (`aead::OsRng`/`RngCore` renamed, `Array::from_slice` deprecated); deliberately
  deferred, it is security-sensitive code.
- `sha2` 0.10 -> 0.11 — the prior upstream resolution blocker is gone: Iroh
  1.4.1 resolves stable `sha2 0.11.0`. The application still directly uses
  `sha2 0.10`; evaluate its API and behavior in a separately tested update.
- `keyring` 3 -> 4 — API break; `apple-native` feature dropped upstream.
- `reqwest` 0.12 -> 0.13 — API break; `rustls-tls` feature renamed upstream.

## Static analysis (CodeQL) triage

GitHub default-setup was producing flaky, unbuildable scans (CodeQL cpp
autobuild cannot build the Flutter-generated C/C++ boilerplate, failing the
non-required `Analyze (c-cpp)` check on every PR-triggered run), so it was
set to `not-configured`. It is replaced by the first-party
`.github/workflows/codeql-analysis.yml` (this PR): security-and-quality,
weekly scheduled + push-on-main triggers, languages `actions`/`python`/`rust`
(c-cpp deliberately excluded — nothing buildable to scan). No PR trigger, so
PRs cannot carry flaky red checks, and analysis results file in the Security
tab as before.

The 71-alert set from the audit was dismissed via API in this session:
4 criticals as `false positive`, 67 high path-injection as `won't fix`,
each with a comment referencing this document. Classification below applies to
any regenerated alerts.

### Criticals (4) — false positives

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
3. Rust `cargo-audit` runs under CI `Security gates`; `.cargo/audit.toml` has
   no active advisory suppressions. Re-audit dependency findings whenever the
   Iroh dependency changes.

## Re-audit triggers

- Iroh bump (re-audit the resolved dependency graph and any new advisories).
- New remote-peer write path touching library root (re-filed path-injection).
- Adoption of a second approving reviewer (raise required review count).
