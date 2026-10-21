# Photo Organizer restart handoff — 2026-10-21

This is a preservation map for a fresh human-led session. It records the current working tree and release state after interrupted multi-agent work. It does not authorize deleting, pruning, moving, stashing, or force-resetting any listed checkout.

## Immediate restart point

- Repository: `/workspace/projects/personal projects/opensource projects/photo-organizer`.
- Laptop fan sensors were read without elevation: both CPU/GPU fans were running at roughly 3,200–3,300 RPM. CPU `Tctl` readings were 93–100°C. Check vents/load/firmware if that persists; no fan control was changed.
- The temporary sudo password shared in chat was not used. Rotate it because it was exposed in chat history; do not copy it into a file or command.
- No stable release was published. The existing `v0.0.1` tag must remain untouched; release issue [#180](https://github.com/5h4d0wn1k/photo-organizer/issues/180) requires a new immutable version after gates and platform evidence.
- PR [#200](https://github.com/5h4d0wn1k/photo-organizer/pull/200) (Rust TLS trust dependency fixes) was CI green, reviewed, and squash-merged as `66df8c06` on 2026-10-21.

## Work completed in this session

- PR [#123](https://github.com/5h4d0wn1k/photo-organizer/pull/123): rebased vault isolation work on current `main`; corrected its sync test fixture to include the asset and live vault-file membership now required by the fail-closed receiver. The tests still exercise rejection of peer-supplied paths. Commit `90e703c` was pushed, then the branch was rebased on #200 and pushed as `f71d4040`.
  - Local verification on the rebased tree: `cargo test --locked -p native_core` passed (183 unit tests, 1 production key-store integration guard, doc tests); `cargo fmt --check` passed; `cargo clippy --all-targets --all-features --locked -- -D warnings` passed before the final test-fixture-only commit. Re-run CI and review on the latest head before merge.
  - Cross-device portable key recovery remains unresolved/documented; do not represent all storage-pool recovery as complete.
- PR [#118](https://github.com/5h4d0wn1k/photo-organizer/pull/118): corrected Windows unused-variable lint in the key-marker durability code; rebased on current `main`; pushed latest head `e7f4816e`.
  - Local production key-store integration test passed (3 tests), `cargo fmt --check` and `git diff --check` passed. Windows cross-check could not run locally because the MinGW C compiler is not installed; hosted Windows CI is the validation gate.
  - Release/upgrade blocker remains: legacy file-key installations have no supported safe migration flow. Current tests mock key storage; they do not prove native Keychain/Credential Manager/Secret Service round-trips.
- PR [#173](https://github.com/5h4d0wn1k/photo-organizer/pull/173): latest observed hosted run `39517544327` failed its macOS mutation step after 8m10s and failed security/release aggregate checks. Other platform mutation and smoke jobs passed in that run. The failure must be diagnosed from that run and followed by a fresh run; do not call it green.
- PR #118 and #123 hosted checks were running at handoff time; query with `gh pr checks 118` and `gh pr checks 123`.

## Product readiness blockers before a stable release

- Android is currently a paired client; issue #140 notes the APK does not bundle `galleryd`. Decide and prove the supported phone workflow before advertising standalone Android library support.
- iOS simulator QA injects a host backend; the app does not launch a local daemon. A real device distribution path and explicit support contract are outstanding.
- Windows and macOS need signed distribution and platform-native secure-storage evidence; Windows also needs installer/update/uninstall/rollback proof, macOS needs notarization and privacy-prompt/import/update evidence. Linux still needs clean-machine packaged user-journey proof.
- The multi-device storage pool remains incomplete (#185): portable key wrapping/recovery and revocation, trusted replica manifest/health, transfer quotas, pause/resume/repair, and relay privacy.
- Local AI remains partial: face identification/cluster flows (#189/#27), semantic/vector search (#30), and model-based scene classification still need approved local models and end-to-end proof. Current scene tags are heuristic.
- Requested marketing landing page/SEO source was not found in this Flutter app repository. Its web `index.html` bootstraps the Flutter client; marketing design needs its own surface/repository.
- The UI audit also found setup hard-coded to `/mnt/windows/transfer/Ok/Photos` and defaulting to move; desktop asset tiles lack keyboard/focus/selection semantics; mobile navigation uses inconsistent shell patterns; motion/reduced-motion tokens are not centralized; and an unknown/unhealthy privacy status can be mislabeled as “Remote enabled.” Address these as discrete tracked UI issues with accessibility and reduced-motion coverage before calling the experience polished.

## Worktree preservation inventory

Registered inventory contained 26 worktrees. Most are clean. Entries below show the observed dirty or specially managed checkouts; keep their contents in place until ownership is verified.

| Path | Branch / head | Observed state and handling |
| --- | --- | --- |
| `/workspace/projects/personal projects/opensource projects/photo-organizer` | `test/release-gate-continue-on-error-and-evidence`, `201c500a` | Preserve local edits to `.github/workflows/ci.yml` and `app/linux/CMakeLists.txt`. This is the primary checkout; edits appear related to PR #161 / release-gate work but were not attributed or committed here. |
| `/home/shadowarch/.codex/worktrees/fix-112-vault-ownership/photo-organizer` | detached, `76262a6a` | Clean old #123 snapshot; latest active #123 work is in `.../_local/worktrees/po-wt/r123`. |
| `/home/shadowarch/.codex/worktrees/keyring-error-safety/photo-organizer` | `fix/110-keyring-error-no-overwrite`, `79d82096` | Preserve 3 modified files and untracked `native_core/tests/vault_key_production.rs`; substantial WIP overlaps #118/#110 and needs comparison before consolidation. |
| `/tmp/photo-organizer-172` | missing checkout | Worktree registration is prunable and path no longer exists. Do not prune automatically; confirm any recoverable diff/snapshot first. |
| `/workspace/projects/personal projects/opensource projects/photo-organizer/_local/worktrees/po-tmp/chk164` | #173 branch, `dae1c7fe` | Preserve untracked `HANDOFF-codex-2026-10-05.md`; the note explicitly says not to commit it. |
| `.../_local/worktrees/po-wt/devcheck` | `fix/84-dev-check-parity`, `21c05af9` | Preserve local `app/pubspec.yaml` edit. Branch is 20 behind and 2 ahead of its tracking ref. |
| `.../_local/worktrees/po-wt/gate-ios` | `feat/98-ios-release-gate`, `09eae744` | Preserve 3 untracked iOS smoke/mutation scripts; branch has no upstream configured. |
| `.../_local/worktrees/po-wt/gate-macos` | `feat/98-macos-release-gate`, `4b86e7fd` | Preserve edits to macOS mutation and smoke tests; branch has no upstream configured. |
| `.../_local/worktrees/po-wt/gate-win2` | `feat/98-windows-artifact-gate`, `ae7e130d` | Preserve 3 untracked Windows smoke scripts; branch is 12 behind and 5 ahead of tracking ref. |

Other registered clean worktrees at inventory time:

`.../_local/worktrees/po-tmp/issue109-durable` (`fix/109-encryption-swap-durability`, `f706a091`); `.../issue171` (`fix/171-temp-dir-cleanup`, `1772e2b2`); `.../issue175-iroh-update` (`fix/175-iroh-update`, `3a752ac3`, PR #175); `.../issue183-file-export` (`feat/183-file-export`, `c23f57b1`); `.../issue188-hidden-gps` (`fix/188-hidden-gps-projections`, `a5a96976`, PR #191); `.../release-macos-asn` (`fix/163-native-asn-release`, `66c997b9`); `.../wt136` (detached, `cf3d5b89`); `.../po-wt/abi` (`fix/140-android-abi-check`, `31d6fd34`); `.../po-wt/fix115` (`fix/115-activation-recovery`, `086b0519`, PR #115); `.../po-wt/gate-linux` (`feat/98-linux-release-gate`, `0315fa8e`, PR #144); `.../po-wt/gate-windows` (`feat/98-windows-release-gate`, `03977d05`, PR #146); `.../po-wt/gate-windows-win` (`feat/98-windows-release-gate-win`, `5cf26eb7`); `.../po-wt/needles` (`fix/142-action-sha-needles`, `fb76c9e8`); `.../po-wt/r118-hardening` (active #118 work); `.../po-wt/r121` (detached, `c95e6563`); `.../po-wt/r121b` (detached, `83bd25dc`); `.../po-wt/r123` (active #123 work); `.../po-wt/r124` (detached, `41b6fce6`); `.../po-wt/r125` (detached, `6680502b`, PR #125); `.../po-wt/r131` (`pr131`, `4a36dd81`); `.../po-wt/r136` (`fix/136-hash-pin-test-deps`, `a59a1518`).

The full canonical paths are under `/workspace/projects/personal projects/opensource projects/photo-organizer/_local/worktrees/` as shown in `git worktree list --porcelain`; do not replace abbreviated `...` paths by guessing. This handoff worktree is intentionally separate at `/home/shadowarch/.codex/worktrees/photo-organizer-handoff/photo-organizer`.

## Next safe steps

1. Check #118/#123 hosted CI and independent review on their newest heads; merge only when all required gates are green and security review is complete.
2. Resolve #173's macOS mutation/security failures on its own branch, with current CI evidence.
3. Triage the preserved dirty worktrees one by one against their existing issue/PR; commit only after confirming exact ownership and tests. Keep the protected handoff note untouched.
4. Refresh the complete worktree/PR/CI inventory before release planning. Then continue issue #180 exit criteria without moving or reusing `v0.0.1`.

## Updates after the inventory snapshot

- PR #123 advanced to `6d0806a5` after hosted Clippy found the newer `chunks_exact(2)` lint in `original_quarantine.rs`; the decoder now uses fixed-size array chunks. The 5 quarantine tests, `cargo fmt --check`, `git diff --check`, and full Clippy with warnings denied passed locally. The newer hosted run is pending.
- PR #118 advanced to `4c7378f8`; the config tests now call a pure parser and no longer mutate process environment. Full native tests passed (159 unit tests plus 4 integration tests), and Clippy, formatting, and diff checks passed locally. Hosted CI on this new head is pending. Review also noted initialization history is currently vault-directory-wide while markers are per key version; clarify/test this before supporting key rotation.
- PR #173 is rebased on `main` at `52243a83`, which includes the TLS dependency fix. Its new hosted CI run is queued. The previous macOS mutation run was canceled by a GitHub runner shutdown signal (not an assertion failure); its required check remained red.
- PR #118's run on `4c7378f8` has now passed required CI, including Windows and macOS encryption durability, the release matrix, security gates, and Rust analysis. The source review still recommends no stable merge until the documented legacy-key migration blocker and OS-keyring provider evidence are addressed.
- PR #123 advanced to `2f966ece` after CI caught one more real failure: the quarantine/backup restore test created a sibling temp directory outside its RAII cleanup root. It now gets its own `TestTempDir`; the focused test passes locally. A fresh hosted run is queued.
- PR #173's first post-rebase CI was again canceled by a runner shutdown signal during the macOS mutation suite. Failed jobs were rerun as attempt 2; wait for that result before concluding the shard-budget fix.
- The restart-map PR [#201](https://github.com/5h4d0wn1k/photo-organizer/pull/201) is published from commit `d6640b4d`; its checks were still running after the latest handoff update.
