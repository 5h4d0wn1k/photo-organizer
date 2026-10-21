# Photo Organizer restart handoff — 2026-10-21

This is a preservation map for a fresh human-led session. It records the current working tree and release state after interrupted multi-agent work. It does not authorize deleting, pruning, moving, stashing, or force-resetting any listed checkout.

## Immediate restart point

- Repository: `/workspace/projects/personal projects/opensource projects/photo-organizer`.
- Laptop fan sensors were read without elevation: both CPU/GPU fans were running at roughly 3,200–3,300 RPM. CPU `Tctl` readings were 93–100°C. Check vents/load/firmware if that persists; no fan control was changed.
- The temporary sudo password shared in chat was not used. Rotate it because it was exposed in chat history; do not copy it into a file or command.
- No stable release was published. The existing `v0.0.1` tag must remain untouched; release issue [#180](https://github.com/5h4d0wn1k/photo-organizer/issues/180) requires a new immutable version after gates and platform evidence.
- PR [#200](https://github.com/5h4d0wn1k/photo-organizer/pull/200) (Rust TLS trust dependency fixes) was CI green, reviewed, and squash-merged as `66df8c06` on 2026-10-21.

## Project orientation for a human restart

Photo Organizer is an Apache-2.0, local-first photo/video organizer. The current product is a desktop-usable MVP, not a production-ready multi-platform release and not a hosted SaaS. Linux desktop is the reference target; Android is currently a paired client for a desktop daemon. The promise is that media, metadata, OCR, model outputs, vault keys, bearer/pairing tokens, and private library activity remain on the user's devices/network by default. There is no product telemetry or hosted library storage.

Main components:

- `native_core/`: Rust `galleryd` daemon, local API on `127.0.0.1:4821`, SQLCipher metadata DB, encrypted vault chunk storage, import/search/metadata/backup, mobile pairing, and Iroh device-to-device sync.
- `app/`: Flutter UI. Linux is the primary desktop implementation. Android is a paired mobile UI; it does not bundle the daemon. iOS simulator checks use an injected host backend. Windows/macOS shells build, but distribution and native platform evidence remain incomplete.
- `ml_sidecar/`: local Python OCR and local scene analysis; no hosted AI. Scene detection is currently heuristic. Face recognition and vector/semantic search are unfinished.
- `tools/quick-face-sort/`: legacy standalone Python/Tk tool, separate from the main app.
- `supabase/`: optional metadata-only bootstrap for phone-created device groups; it is not for user content, thumbnails, keys, or indexes.

Useful entry points: `README.md`, `CONTRIBUTING.md`, `docs/architecture.md`, `docs/security-model.md`, `docs/PRIVACY.md`, `docs/RELEASE_CHECKLIST.md`, `docs/product-vision.md`, `Makefile`, and `scripts/dev-check.sh`. Typical local checks are `cargo fmt --check`, `cargo test --locked -p native_core`, `cargo clippy --all-targets --all-features --locked -- -D warnings`, then `cd app && flutter analyze && flutter test`.

## State of the release

- `main`/`origin/main` is at `66df8c06` after #200. The old remote tag `v0.0.1` points to a failed release and must not be moved or reused. There is no current successful public GitHub Release.
- The code has meaningful privacy/security foundations and CI artifact install/launch gates across Android, Linux, Windows, macOS, and iOS simulator. Passing these gates proves the tested artifact surfaces only; it does not prove full end-user features on every platform.
- The repository currently advertises a desktop-usable MVP. Do not call it a finished SaaS, stable cross-platform app, fully mature AI product, or ready to charge for until the issue #180 gates and the product gaps below are closed.
- Release issue [#180](https://github.com/5h4d0wn1k/photo-organizer/issues/180) expects a new immutable version (currently expected `0.0.2`, reconfirm before tagging), all blocker PRs green and merged, synchronized version/changelog files, complete release workflow evidence, verified checksums/signatures, and a published release URL. Physical iOS device and real ARM-device evidence remain manual if CI cannot prove them.

## Pull request ledger — refreshed 2026-10-21

Open PRs are work in progress, not merged changes. Do not interpret “mergeable” as “verified”. This table records the current triage and the specific action needed before consolidation.

| PR | Work | Current disposition |
| --- | --- | --- |
| [#201](https://github.com/5h4d0wn1k/photo-organizer/pull/201) | This restart map, issue #180 | Expanded handoff is committed, independently reviewed, and pushed. Fresh required CI has started for the latest head; refresh checks before merging. |
| [#198](https://github.com/5h4d0wn1k/photo-organizer/pull/198), [#195](https://github.com/5h4d0wn1k/photo-organizer/pull/195), [#179](https://github.com/5h4d0wn1k/photo-organizer/pull/179), [#177](https://github.com/5h4d0wn1k/photo-organizer/pull/177) | Dependabot pub/actions updates | Merge only after their own full required CI/security review; not release blockers proven by this audit. |
| [#191](https://github.com/5h4d0wn1k/photo-organizer/pull/191) | Hidden exact GPS projection fix | Security/privacy scoped PR, mergeable; verify latest checks/review before merge. |
| [#175](https://github.com/5h4d0wn1k/photo-organizer/pull/175) | Iroh 0.98→1.x compatibility | Open dependency/security upgrade with explicit wire-compatibility tests; verify current CI and review. |
| [#173](https://github.com/5h4d0wn1k/photo-organizer/pull/173) | macOS mutation harness lifecycle/logging, issue #172 | Latest rerun failed the macOS mutation suite after ~8 minutes; aggregate release gate failed. Inspect failed attempt logs, fix or prove runner cause, then rerun. |
| [#170](https://github.com/5h4d0wn1k/photo-organizer/pull/170), [#168](https://github.com/5h4d0wn1k/photo-organizer/pull/168), [#166](https://github.com/5h4d0wn1k/photo-organizer/pull/166), [#164](https://github.com/5h4d0wn1k/photo-organizer/pull/164) | Windows warning policy, iOS deployment target, Linux CMake compiler cache, macOS `lsappinfo` gate | Current heads are mergeable. These are issue-first release fixes. Refresh all checks, do independent review, merge one at a time, then revalidate release branch. The CMake portion of root WIP duplicates #166. |
| [#161](https://github.com/5h4d0wn1k/photo-organizer/pull/161) | Release workflow structural assertions, issue #159 | PR head is conflicting. Primary checkout has uncommitted workflow edits that change matrix shape and set a macOS shard value; local `release_workflow_test.sh` fails 10 assertions because it only parses the old list matrix. The runner ignores that new env value. Do not commit this version; adapt parser and prove effective shard parity, or remove the experiment. |
| [#160](https://github.com/5h4d0wn1k/photo-organizer/pull/160) | Android API 35 exit-info smoke fix | Mergeable; refresh checks/review. |
| [#157](https://github.com/5h4d0wn1k/photo-organizer/pull/157) | CodeQL SQLCipher false-positive suppression, issue #156 | Conflicting with main; rebase carefully and verify the exact query identifier and mutation test. |
| [#146](https://github.com/5h4d0wn1k/photo-organizer/pull/146), [#144](https://github.com/5h4d0wn1k/photo-organizer/pull/144) | Windows and Linux release artifact gates, issue #98 | Both conflicting with main. Their CI may pass against old bases; rebase and repeat all gates/reviews. These are core release work. |
| [#129](https://github.com/5h4d0wn1k/photo-organizer/pull/129) | Dev-check/CI parity, issue #84 | Conflicting with main, plus its worktree has an uncommitted `app/pubspec.yaml` probe comment. Review that exact local edit before including or dropping it. |
| [#126](https://github.com/5h4d0wn1k/photo-organizer/pull/126) | One-click duplicate review | Open feature PR; verify current checks and scope before merge. |
| [#125](https://github.com/5h4d0wn1k/photo-organizer/pull/125) | Pin legacy face-sorter dependencies, issue #85 | Open PR; current head is in `r125`, newer than its local named branch. Refresh checks/review. |
| [#123](https://github.com/5h4d0wn1k/photo-organizer/pull/123) | Per-vault asset ownership fix, issue #112 | Functional CI, security tests, artifact smoke and mutation suites passed on `2f966ece`. CodeQL is currently **failing** with a critical “hard-coded cryptographic value” alert at `native_core/src/original_quarantine.rs:572`; review says the zero-initialized nonce is filled from `OsRng` before use, so it appears false-positive, but the required check is red and must be resolved explicitly before merge. Portable cross-device key recovery remains out of scope. |
| [#118](https://github.com/5h4d0wn1k/photo-organizer/pull/118) | Explicit vault key storage, issue #110 | All observed checks pass and GitHub reports mergeable. Still has a stable-upgrade concern: legacy file-key installations lack a supported safe migration path, and CI does not prove native Keychain/Credential Manager/Secret Service round-trips. Resolve or explicitly document a safe migration/release contract before merge. |
| [#115](https://github.com/5h4d0wn1k/photo-organizer/pull/115) | Interrupted encryption activation recovery | Conflicting with main. Keep distinct from the orphan #109 durability series until their overlapping security semantics/tests are reconciled. |

Recent completed PRs on `main`: #200 TLS trust dependencies (`66df8c06`), #197 keychain error preservation, #193 receiver-owned sync paths, #186 file export, #182 encrypted DB activation recovery, #174 Rust test temp cleanup, #145 action-pin mutation needles, #143 mutation-needle follow-up, #141 Android ABI assertion, #139 atomic release publish, #138 hash-pinned test dependency, #134 checkout-pin parity, #131 Dependabot major-version guard, #124 workflow concurrency, and earlier product/security work. Verify GitHub before treating any branch copy as canonical.

## Branch/worktree triage ledger

`git fetch origin --prune` was run on 2026-10-21. The repository has **31 registered worktrees**, including one missing `/tmp` checkout, and many local branches. During the audit, eight extant checkouts had local file changes: seven pre-existing project WIP checkouts plus this handoff checkout while its changes were being prepared. After commit/push, this handoff checkout is clean; seven pre-existing project WIP checkouts remain dirty. No checkout was reset, pruned, or removed. Clean checkouts can still contain commits not in `main`, so “clean” does not mean disposable. Do not prune remote/local refs again until the orphan and already-merged branch inventory has been reconciled.

### Active or dirty worktrees

| Checkout | State | Owner / next action |
| --- | --- | --- |
| `/workspace/projects/personal projects/opensource projects/photo-organizer` | PR #161 branch `test/release-gate-continue-on-error-and-evidence`; dirty `.github/workflows/ci.yml`, `app/linux/CMakeLists.txt` | CI change fails local structural test and is ineffective as written. CMake change belongs to #166. A binary patch is saved at [`docs/recovery/2026-10-21-primary-checkout-wip.patch`](recovery/2026-10-21-primary-checkout-wip.patch) in this handoff branch. After confirming this commit is published, use the patch if needed, clean the two files, and switch this checkout to updated `main` for normal VS Code work. PR branch remains available remotely. |
| `_local/worktrees/po-wt/r123` | Clean; branch `fix/112-vault-leak`, `2f966ece` | Canonical #123 checkout. Resolve CodeQL check before merge. |
| `_local/worktrees/po-wt/r118-hardening` | Clean; branch `codex/110-vault-key-storage-hardening`, `4c7378f8` | Canonical #118 checkout. Resolve upgrade contract before merge. |
| `/home/shadowarch/.codex/worktrees/keyring-error-safety/photo-organizer` | Dirty `docs/security-model.md`, `native_core/src/service.rs`, `native_core/src/vault_store.rs`, untracked `native_core/tests/vault_key_production.rs`; branch `fix/110-keyring-error-no-overwrite`, `79d82096` | `service.rs` equals #118; other files add legacy-key refusal/migration tests. Preserve, compare hunk-by-hunk against #118 and issue #110; do not copy wholesale. Remote branch was removed after #197 merged. |
| `_local/worktrees/po-wt/fix115` | Clean active #115, `086b0519` | Canonical activation recovery PR; resolve conflict and review interaction with #109 durability branch. |
| `_local/worktrees/po-tmp/issue109-durable` | Clean orphan branch `fix/109-encryption-swap-durability`, `f706a091`; remote tracking ref gone | 14 commits ahead/5 behind cached main; overlaps #115 in `security.rs` and encryption activation. Keep the branch; reconcile tests/semantics before selecting a canonical issue/PR. |
| `_local/worktrees/po-tmp/chk164` | #173 at `52243a83`; untracked `HANDOFF-codex-2026-10-05.md` | Active PR checkout. The note is explicitly protected; leave untouched. Latest macOS mutation CI failed. |
| `_local/worktrees/po-wt/devcheck` | #129 at `21c05af9`, modified `app/pubspec.yaml` adding `# parity probe` | Keep the edit pending comparison; branch is 2 ahead/20 behind cached main and PR conflicts. |
| `_local/worktrees/po-wt/gate-ios` | `feat/98-ios-release-gate`, 3 untracked iOS gate scripts | Stale conflicting draft: those paths already exist on main with different contents. Do not overwrite current versions. |
| `_local/worktrees/po-wt/gate-macos` | `feat/98-macos-release-gate`, 2 modified macOS gate test scripts | Unpublished test edits; compare with current #173 and main before consolidating. |
| `_local/worktrees/po-wt/gate-win2` | Mismatched `feat/98-windows-artifact-gate`, 5 commits ahead/12 behind its incorrectly configured Linux upstream; 3 untracked Windows smoke scripts | Mixed Linux history plus Windows helper draft; preserve and compare with canonical Windows #146. |
| `/home/shadowarch/.codex/worktrees/photo-organizer-handoff/photo-organizer` | Clean handoff branch `codex/180-worktree-handoff` | Issue #180 / PR #201. Independent review passed; fresh required CI has started. |

### Clean snapshots and branches to retain or archive only after verification

| Checkout or local branch | State and disposition |
| --- | --- |
| `/home/shadowarch/.codex/worktrees/fix-112-vault-ownership/photo-organizer` | Detached `76262a6a`, 3 ahead/14 behind origin/main; historical first #123 commits, already represented in #123. Preserve until #123 is resolved; then archive candidate. |
| `_local/worktrees/po-tmp/issue171` | Clean `1772e2b2`, exact merged #174 head; redundant snapshot. |
| `_local/worktrees/po-tmp/issue175-iroh-update` | Clean `3a752ac3`, exact open #175 head; canonical. |
| `_local/worktrees/po-tmp/issue183-file-export` | Clean `c23f57b1`, merged #186; redundant snapshot. |
| `_local/worktrees/po-tmp/issue188-hidden-gps` | Clean `a5a96976`, exact open #191 head; canonical. |
| `_local/worktrees/po-tmp/release-macos-asn` | Clean `66c997b9`, behind open PR #164 by two commits; not authoritative. |
| `_local/worktrees/po-tmp/wt136` | Clean detached `cf3d5b89`, original #138 head; redundant snapshot. |
| `_local/worktrees/po-wt/abi` | Clean `31d6fd34`; merged #141 work. |
| `_local/worktrees/po-wt/gate-linux` | Clean `0315fa8e`; canonical open #144 but conflicts with main. |
| `_local/worktrees/po-wt/gate-windows` | Clean `03977d05`; canonical open #146 but conflicts with main. |
| `_local/worktrees/po-wt/gate-windows-win` | Clean stale branch `5cf26eb7`, 13 behind origin/main; no PR; head already on main. |
| `_local/worktrees/po-wt/needles` | Clean `fb76c9e8`; merged #145 plus two unmerged follow-up commits. Preserve follow-ups separately under issue #142 before archiving. |
| `_local/worktrees/po-wt/r121`, `r121b` | Two clean detached variants of merged #121 plus equivalent audit-suppression follow-up commits with different parents. Compare and retain one canonical follow-up. |
| `_local/worktrees/po-wt/r124` | Clean detached `41b6fce6`; merged #124 plus 3 unmerged workflow follow-ups. Preserve/review those commits. |
| `_local/worktrees/po-wt/r125` | Clean detached `6680502b`; canonical current head of open #125 (local named branch is older). |
| `_local/worktrees/po-wt/r131` | Clean `4a36dd81`; merged #131 plus one unmerged guard/mutation follow-up. Preserve/review. |
| `_local/worktrees/po-wt/r136` | Clean `a59a1518`; merged #138 plus a 20-file fail-open-path follow-up. Preserve/review separately. |
| `_local/worktrees/po-tmp/issue109-durable` | Listed above as an orphan security series; do not treat its clean state as permission to delete. |
| `/tmp/photo-organizer-172` | Registered path is missing and marked prunable. Commit `ef8bae0a` remains reachable from local branch `fix/172-ci-harness-followup`; committed files can be recovered. Uncommitted files from the absent directory cannot be established. Do not prune until the branch is triaged. |

### Local branch-only work outside registered worktrees

Some local refs have no active checkout. Keep them until their ancestry is compared with remote/merged PRs: `backup/fix188-before-main-rebase`, `chore/120-cargo-lock-refresh`, `cofix2`, `dependabot/github_actions/actions/download-artifact-8.0.1`, `dependabot/github_actions/github-actions-e9b0a10433`, `docs/store-product-principles`, `fix/104-required-checks-contract`, `fix/109-encryption-activation-crash`, `fix/110-vault-key-storage`, `fix/112-vault-isolation`, `fix/142-mutation-needle`, `fix/163-native-asn-release`, `fix/172-ci-harness-followup`, `fix/84-dev-check-parity`, `fix/85-python-pins`, `fix/87-docs-branding`, `fix/89-import-duplicate-review`, `fix/android-smoke-exit-info-header`, `fix/codeql-sqlcipher-false-positive`, `fix/ios-deployment-target-skew`, `fix/linux-cmake-compiler-cache-entry`, `fix/macos-gate-lsappinfo-verb`, `fix/windows-lnk4099-build-warnings`, `gate-linux`, `main`, `merged`, `post143`, `pr115`, `pr118`, `pr121`, `pr124`, `pr126`, `pr131`, `release-v1.0.0`, and `release/v0.0.1-version`. A number of these are exact duplicates or old PR baselines; do not delete local refs until `git branch --contains`, remote PR state, and any unique follow-up commit have been checked.

## Manual developer start

Once the handoff PR is merged and the primary checkout's two-file WIP is either restored or archived, start in the familiar repo directory in VS Code. Update to `main` first; then create one short-lived branch per existing GitHub issue, or open the existing canonical PR branch for that issue. Avoid starting on old `v0.0.1` or on a detached snapshot.

```bash
cd "/workspace/projects/personal projects/opensource projects/photo-organizer"
git fetch origin
git switch main
git pull --ff-only origin main
git status --short --branch
```

For a tracked PR branch, use its GitHub head/worktree listed above, not a stale similarly named branch. Before editing any preserved WIP, inspect the exact commit and diff and confirm its issue owner. Use the repo's required issue → branch → PR → review → full local/CI gate → squash merge process. Never merge merely because GitHub says mergeable.

## Product roadmap and release gates

Sequence work by risk and dependency. The issue numbers below are the existing trackers; check their current bodies and GitHub board before changing scope.

### 1. Recover a trustworthy release candidate

1. Finish #123's CodeQL disposition with a code change or an exact-query, test-backed accepted false-positive disposition. Confirm vault ownership and quarantine tests on the latest main; independently review.
2. Resolve key-storage upgrade behavior in #118/#110. Existing users with file keys must not silently lose access or downgrade guarantees. Test the actual OS keychain lifecycle on Linux Secret Service, macOS Keychain and Windows Credential Manager; define safe unsupported-headless behavior.
3. Reconcile #115 with the clean orphan #109 durability series and run activation/crash-recovery tests on Linux, Windows and macOS. Do not cherry-pick either series blind.
4. Finish platform gate blockers: #144 Linux and #146 Windows need rebase/conflict resolution; #173 macOS mutation lifecycle needs reliable successful rerun; #160 Android; #164 macOS; #166 Linux; #168 iOS; #170 Windows. #161's workflow assertion work must pass after the parser matches the actual matrix shape.
5. Merge and refresh in dependency order, rerunning complete required CI after each main change. Keep release publish atomic and required checks fail-closed.
6. Validate release candidates against real install/upgrade paths and collect evidence. Then update version in `app/pubspec.yaml`, `native_core/Cargo.toml`, `Cargo.lock` and `CHANGELOG.md` together. Only then tag a new immutable version and run the whole release workflow; preserve `v0.0.1`.

### 2. Establish platform support contracts

- **Linux desktop (primary):** clean-machine bundle/package, daemon/app startup, import, search, encrypted originals, backup/restore and update/rollback end-to-end proof. Make compiler-cache issue #166 green.
- **Android (paired client):** explicit supported workflow with a desktop/storage host; confirm signing continuity, upgrade path, pairing over Tailscale/HTTPS, upload/download/resume/revoke, and real ARM hardware. APK does not contain `galleryd`; do not market it as standalone storage.
- **Windows desktop:** installer, native key storage, import/vault flows, update/uninstall/rollback and signed-artifact proof. Gate and linker PRs #146/#170 are incomplete.
- **macOS desktop:** notarized/signed `.app`, Keychain, permissions, import/update/rollback evidence. The runner gate is not a substitute for notarization and a real install.
- **iOS:** define if it is a paired client or local-library app; simulator host-backend test is not a real device or store-ready flow. Device packaging/signing and privacy-permission review remain manual/managed evidence.
- **Web:** repository `web/index.html` is a Flutter bootstrap, not a marketing site. Do not ship SEO/marketing claims from it. Establish a separate marketing surface/repository if requested and keep it free of private library data.

### 3. Mature core workflows and privacy/security

- Storage-pool epic #185: portable key wrapping and recovery/revocation, replica manifest/health, quotas, pause/resume/repair, relay privacy and cross-device recovery. This is the largest architecture-level product blocker.
- Library safety: migration tooling (#34), encrypted-only managed copies, secure backup/restore and clear distinction between copied/protected and referenced/unprotected originals.
- Local intelligence: honest face capability and opt-in biometric storage (#189/#27), semantic/vector search (#30), model registry/versioning and full offline behavior. Current scene detection is heuristic; model support is not an end-to-end finished AI feature.
- Privacy UI: never label unknown/unhealthy sync state “Remote enabled”; report actual transport, encryption, protection and key-storage state. Retain no telemetry or silent uploads.
- Operational privacy: diagnostics must redact paths/content; keep user content, OCR, embeddings, face data, exact GPS and tokens out of hosted services.

### 4. Complete product experience and business readiness

- Fix first-run setup and remove the hard-coded `/mnt/windows/transfer/Ok/Photos` path/default move behavior; make copy/reference/move choices explicit and reversible.
- Normalize desktop and mobile navigation; add keyboard/focus/selection semantics to asset tiles; centralize motion tokens and honor reduced-motion settings. Add interaction and accessibility tests before broad animation polish.
- Improve import progress/cancel/summary (#89), onboarding/daemon auto-start (#88), thumbnails (#28/#63), video viewing (#29/#90), mobile file manager (#187), Spanish localization (#32), and accessibility (#75) in dependency order.
- Define monetization only after the privacy boundary and platform support are real. `docs/product-vision.md` describes subscriptions/entitlements, but this repo audit did not verify an end-to-end billing implementation or production pricing. Billing must never gate local access or transmit library data. No revenue-ready SaaS is established today.
- Establish a source-of-truth public support matrix, platform-specific installers/update plans, incident/recovery runbooks, and a release owner before calling it production-ready.

## What was and was not consolidated in this pass

Completed in this pass: fetched current remote refs; audited all 31 registered worktrees and local branches; identified seven pre-existing dirty checkouts (eight were dirty during the audit while this handoff was also being edited); linked active work to existing PRs/issues; checked latest CI on #118/#123/#173/#201 and inspected the #123 CodeQL annotation; obtained independent reviews of the security worktree group, release-gate worktrees, other detached/orphan branches, and primary PR #161 diff; saved the primary checkout's two-file diff as a restorable patch; and wrote this inventory and roadmap.

Not merged or deleted: code PRs with red checks, conflicts, migration questions, or incomplete review; clean snapshots with unique follow-up commits; any dirty/protected worktree; the missing `/tmp` registration; or the local #161 experiment. This is intentional: the repo's mandatory CI/review and preserve-first rules prohibit claiming those changes are safe to squash together. Follow the ledger above to complete them one issue at a time.


## Latest verification snapshot — 2026-10-21

- #118 at `4c7378f8`: all observed checks pass; mergeable. The legacy-key migration and real platform keychain evidence remain release decisions.
- #123 at `2f966ece`: Rust/Flutter/security/dependency/platform smoke and all three platform mutation suites pass. CodeQL fails with one critical alert at `original_quarantine.rs:572`; an independent review believes the nonce is overwritten by `OsRng`, but the required check remains red pending explicit disposition. GitHub reports mergeable; do not merge with CodeQL red.
- #173 at `52243a83`: latest rerun attempt 2 failed macOS mutation after about 8 minutes and the required release aggregate failed. Inspect logs and rerun after a fix or evidence-backed runner diagnosis. GitHub reports mergeable; CI remains red, so do not merge.
- #201: the preceding head had all observed CI pass; the expanded doc/patch is independently reviewed and pushed. Fresh required CI has started on the latest head; refresh `gh pr checks 201` and do not merge until all required checks are green.
- #161 head `201c500a`: conflicting with `main`. Local dirty workflow changes fail 10 `release_workflow_test.sh` assertions; its matrix shard environment value is ignored by the driver. The Linux CMake edit corresponds to #166. Keep the diff parked in the saved patch and do not commit it as-is.
- Root `main` is not checked out in the primary working directory yet. After this patch is committed/pushed and its PR checks pass, restore the two primary checkout files from its saved patch if needed, run `git restore -- .github/workflows/ci.yml app/linux/CMakeLists.txt` in the primary checkout, switch to `main`, fast-forward from `origin/main`, and verify `git status --short --branch` is clean before starting manual work. The original PR #161 branch remains on its local/remote ref.
