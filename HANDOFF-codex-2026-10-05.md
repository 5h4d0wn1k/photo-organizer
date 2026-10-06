# Handoff: photo-organizer `v0.0.1` release — OpenCode → Codex

**Written:** 2026-10-05, from OpenCode session `ses_f30e0627cffeb7u1ignquCCqxJ`
**Title:** `photo-organizer v0.0.1 release: #164 macOS harness blocker (PR #173)`
**Repo:** `/workspace/projects/personal projects/opensource projects/photo-organizer`
**Live worktree for #173:** `/home/shadowarch/.cache/po-tmp/chk164`

### Finding that session's transcript

The session was **renamed** to the title above, so it is findable by that string.
Reliable ways to reach it, without guessing at flags:

- In the OpenCode TUI: the **`/sessions`** command, then search the title.
- Session data lives in the service database —
  `sqlite3 "$(opencode debug paths db)"` — if a direct lookup is wanted.
- `opencode mini --help` documents Mini's own `--session` / replay options.

Note that OpenCode's sessions are **not** Codex sessions; this document is the
portable part of the handoff and does not depend on the transcript surviving.

> This file is a working note. **Do not commit it.** It lives outside the repo on
> purpose (see §10 — `/tmp` does not survive this machine's reboots).

---

## 1. Objective

Cut the first installable release as **`v0.0.1`** across all 5 platforms.

Blocked by exactly one thing: **PR #164's `macos_release_artifact_mutation_test.sh`
leg.** Everything else is green or merge-ready.

The immediate task was to land **PR #173** (issue #172) so #164 can go green.

**No release exists yet. Tag `v0.0.1` is unspent** — annotated tag object
`d4fa95ad` → commit `6188e943` ("chore(release): set product version to 0.0.1",
#155). It must be **deleted and recreated** after the PRs merge, then the release
re-run. No bypass.

---

## 2. Hard constraints (non-negotiable)

From `AGENTS.md` plus explicit user instruction this session:

- **No bypass, no workarounds, no degraded guarantees.** Gates fail closed or are
  explicitly degraded with a reported cause — never silently skipped.
- **Issue-first workflow:** issue → branch → PR → deep multi-agent review → green
  CI/security → squash-merge → board item moved to Shipped. **Never auto-close
  issues.**
- Every new/changed assertion must be **mutation-tested**. Reject vacuous
  assertions. Failure paths fail closed.
- **A test that would hang under the very mutation it guards is unacceptable.**
  Probes must be bounded.
- Local-first / privacy-first / security-first. Nothing off-device. Fully offline.
- QA tooling must run on public runners or locally with **no third party ingesting
  source or user data**.
- **Do not commit** the state brief's §4 "at-risk" files (user has seen the
  evidence and accepts this). **Do not commit** the two rescued `.ps1` files.
- **User instruction this session: run tests on the laptop only** (see §9).

---

## 3. Repo state

Default-branch checkout is on `test/release-gate-continue-on-error-and-evidence`
@ `80a36702` — that is PR **#161**'s branch, not `main`. Don't be surprised.

| PR | Branch | Head | Merge state | Notes |
|----|--------|------|-------------|-------|
| **#173** | `fix/172-macos-harness-signal-and-logs` | `ef8bae0a` | BLOCKED | **red — see §5** |
| **#164** | `fix/macos-gate-lsappinfo-verb` | `7914f5af` | BLOCKED | the release blocker |
| #170 | `fix/windows-lnk4099-build-warnings` | `c1655cff` | CLEAN | |
| #168 | `fix/ios-deployment-target-skew` | `69b7dad9` | CLEAN | |
| #166 | `fix/linux-cmake-compiler-cache-entry` | `dc6272a1` | CLEAN | |
| #161 | `test/release-gate-continue-on-error-and-evidence` | `80a36702` | CLEAN | |
| #160 | `fix/android-smoke-exit-info-header` | `5553653f` | CLEAN | |
| #157 | `fix/codeql-sqlcipher-false-positive` | `01c7fa8d` | CLEAN | |

Also open and **DIRTY/BEHIND** (need rebase, not merged): #146, #144, #129, #126,
#125, #123, #118.

**Proposed merge order once #173 is green:** #157, #160, #161, **#164**, #166,
#168, #170.

Worktree `chk164` is **clean**, 3 commits on top of `7914f5af` (#164's head):

```
ef8bae0a  fix(ci): upload the release-gate logs from the checkout, not /tmp
ce637956  fix(tests): signal the harness's process group, not just its pid
c1582bac  fix(tests): let the release-gate driver and mutation harnesses be signalled
7914f5af  test(macos-gate): re-anchor and extend the mutation harness ... (=#164 head)
```

---

## 4. What the three #173 commits do

Branch base is #164's head, so **#173 already contains #164**. Merging #173
carries #164's fix with it; #164 then needs a rebase or can be closed as
superseded (user's call — do not auto-close).

1. **`c1582bac` — signal handling.** `trap 'rm -rf "$WORK"' EXIT INT TERM HUP`
   *resumes the script* after a signal handler returns. A killed shard therefore
   carried on and reported mutations it never actually ran. Fixed in the driver
   **and all three** mutation harnesses (`macos`, `ios`, `windows`) — the shape
   was identical in all three, found by grepping siblings, not just macOS.
   Handlers now `trap -` and `exit $((128 + signo))`.
   Also: shard logs named per suite+shard under a job-scoped `LOG_DIR`, tailed
   **as each shard finishes** (combined log still built for the DEGRADED scan);
   `cleanup_logs`/`suite_logs` deleted; `timeout-minutes` 30 → 60 on
   `release-gate-suites`; empty/missing `apply.err` on `COULD NOT APPLY` is now a
   hard error (exit 3) because the reason is the only way to tell genuine anchor
   drift from a tree that vanished.

2. **`ce637956` — process-group signalling in the probe.** CI caught this: all
   three harnesses reported `rc=still-running`. The probe sent `kill -TERM` to the
   harness pid only, but a harness spends the run blocked in `wait` on a
   *foreground* child (the suite, ~120 s per mutation) and bash does not run a trap
   while waiting on a foreground child — it defers until the child returns. Fix:
   `setsid` + `kill -TERM -PID` (process group), `sleep 5`, bounded 20 s wait,
   `kill -KILL -PID` fallback.

3. **`ef8bae0a` — logs that survive the runner.** The previous commit's message
   claimed shard logs were "kept for diagnosis" when the runner was torn down.
   **That claim was false:** `LOG_DIR` defaulted under `TMPDIR`, and on a CI
   runner `/tmp` is part of the machine being destroyed — the one event the logs
   exist to record also erased them. `LOG_DIR` now defaults under `ROOT_DIR`, and
   the suite leg uploads it with `if: always()`.

**Known side effect of `ef8bae0a`: it broke `Security gates`. See §5.**

---

## 5. THE OPEN RED — `Security gates` fails on `ef8bae0a`, self-inflicted

**This is the immediate next task.** It is not flaky and not pre-existing; my
log-upload change caused it.

From the `Security gates` log (job `111695167128`, CI run `37289148128`):

```
NEEDLE PRECONDITION FAILED: the actions/upload-artifact pin in
/home/runner/work/photo-organizer/photo-organizer/.github/workflows/ci.yml
occurs 2 times as text, so rewriting the first occurrence is ambiguous.
This pin must be unique in the file.
...
mutations: 28 run, 27 bit, suite after restore: 434 passed, 0 failed
```

**Mechanism.** `scripts/tests/workflow_hygiene_mutation_test.sh` has a needle
helper `pin_expr` (~line 266-276) that derives a mutation expression from an
action pin. It refuses if the pin text occurs more than once, because `apply` uses
`text.replace(old, new, 1)` and the outcome would depend on which occurrence comes
first. `ci.yml` already had **one** `actions/upload-artifact` pin (~line 301, the
CodeQL/upload job). My new log-upload step added a **second**.

The mutation that dies is **#2, "a pin loses its version comment entirely"**
(~line 394-397). It cannot be applied, so 1 of 28 mutations never bites → the
suite fails. The suite itself restores to `434 passed, 0 failed`, so this is the
harness refusing, not a product regression.

**Why I missed it.** I verified the suites I *touched* (`release_workflow_test.sh`
81/0, `tests_wiring_test.sh` 39/0) but never ran
`workflow_hygiene_mutation_test.sh`, whose precondition my change broke. **Run the
full release-gate driver locally before pushing, not just the suites you edited.**

**Recommended fix (needs its own mutation coverage + a self-check that still
passes):** the precondition is over-conservative. Anchoring the needle at
`uses: actions/upload-artifact@<sha>` instead of free pin text removes the
ambiguity by construction — a `uses:` line is a real pin site, and a pin quoted in
a comment stops being a candidate. The comment at lines 266-271 explicitly wants
that guard preserved ("quoting a pin in a comment is an established habit"), so
**do not simply delete the uniqueness check** — that would let a comment mention
be mutated instead of the real pin. Alternative (weaker): extend the existing
upload step's `path:` list instead of adding a second step.

Then re-run the hygiene mutation suite locally **and** confirm the
`pin-major` / `pin-version` self-checks (lines 343-362) still hold.

---

## 6. The #164 blocker — what is actually known

**The harness is correct.** Positive control, shard 1 solo:
**`6 run, 6 bit`, suite restores to `120 passed, 0 failed`, exit 0, 772 s.**
That is the only trustworthy mutation measurement in this work — see §7.

The CI failure is the runner dying, not the test failing. It now **says so**:

```
==> macos_release_artifact_mutation_test.sh (8 shards, run concurrently)
##[error]The runner has received a shutdown signal. ...
FATAL: received signal TERM; the release-gate run did not finish.
       Per-shard logs are kept in <LOG_DIR> for diagnosis.
Error: Process completed with exit code 143.
```

The runner dies **first** and cascades `SIGTERM`.

Reproducible: **4m23s, then exactly 4m00s, then 4m18s** across three runs on
different runners. iOS and Windows mutation legs survive 9-13 min on the same
runner type, so it is **not** a blanket 4-minute cancellation.

**Ruled out with evidence:**

| Hypothesis | Verdict | Evidence |
|---|---|---|
| Job timeout | **Ruled out** | `timeout-minutes: 60` was active; died at 4 min |
| `concurrency` cancel-in-progress | Ruled out | no competing run in the group |
| Memory | Not supported | no OOM kill has *ever* occurred on the laptop; runner is 16 GiB |
| Disk | Ruled out | one suite run peaks **~0 MB**, 0 leftover entries (self-cleans) |
| Flake | Ruled out | reproduced on 3 runs, 3 runners |

**My `timeout-minutes` theory was wrong** and has been said so in the PR rather
than quietly kept.

**This remains unexplained.** Do not write it up as "infrastructure" — that is
exactly the unverified conclusion to avoid.

**The good news:** `ef8bae0a` uploads the per-shard logs as an artifact
(`if: always()`). The next run's failure will finally be *diagnosable* rather
than mysterious. Two earlier failures contained only eight
`cat: /tmp/tmp.XXXX: No such file or directory` lines and nothing to read.

Once §5 is fixed and a run produces the artifact, **read the shard logs before
forming any new theory.**

### On runner speed — the user's premise was wrong

Free runners are 4 cores; the laptop is 16. The leg is slow *because CI is slow*:

```
45 mutations x ~130 s = ~98 CPU-minutes of work
  laptop     16 cores ->  ~6.1 min
  ubuntu-24.04 4 cores -> ~24.4 min   (CI is ~4x slower in aggregate)
```

That is why `timeout-minutes: 30` sat *under* the measured work, and why the leg
was near its limit.

---

## 7. Corrections to carried-forward beliefs — read before trusting any number

- **Earlier local "45 run, 10 bit" and "6 run, 1 bit" results were artifacts** of
  server-restart kills hitting the old `trap`, **not** real non-biting mutations.
  The only valid positive control is **shard 1 solo: `6 run, 6 bit`**.
- The earlier **20 MiB peak RSS** figure sampled only *direct children* and missed
  grandchildren (python3, dd, cmp). Do not reuse it.
- **Do not lean on GitHub's machines being faster.** They are ~4x slower in
  aggregate for this test.
- §4 and §7 Q1 of the state brief at
  `/mnt/storage/.reorg/PO-PHOTO-ORGANIZER-BRIEF-2026-10-05.md` are **verified
  wrong**. Do not act on them.

---

## 8. Local verification status (laptop)

Green as of `ef8bae0a`:

| Suite | Result |
|---|---|
| `release_workflow_test.sh` | **81 passed, 0 failed** |
| `tests_wiring_test.sh` | **39 passed, 0 failed** |
| `macos_release_artifact_smoke_test.sh` | **120 passed, 0 failed** |
| `shellcheck` 0.9.0 (CI pin) | clean |
| `bash -n` on changed scripts | clean |
| mutation harness, shard 1 solo | **6 run, 6 bit**, restore 120/0, exit 0 |

**Not yet run locally:** the **full 8-shard / 45-mutation** macOS run, and the
other six suites (`windows`/`ios`/`linux`/`android` smoke, `android_signing`,
`apksigner`), and `workflow_hygiene_mutation_test.sh`. The all-45 run was killed
by the reboot (§9).

All assertions added this session were mutation-tested and **do** bite: revert
trap → 75/1; driver wipes log dir → 73/3; `timeout-minutes` 30 → 71/1; all three
traps reverted → wiring `38 passed, 1 failed`; drop upload step → 76/1;
`if: always()` → `success()` → 78/1; `LOG_DIR` under `TMPDIR` → 79/2;
`LOG_DIR=/tmp` hardcoded → 76/5.

---

## 9. Machine instability — and an honest answer about the reboots

The user asked whether I triggered the laptop shutdown/restart. **Evidence says
no, but I cannot prove a negative, so here is the evidence rather than a
reassuring sentence.**

- `last -x` shows **8 boots today**: 10:31, 10:37, 10:38, 11:37, 11:38, 11:43,
  12:12, 15:37. Three predate any heavy concurrent work of mine. The 11:37/11:38
  pair is 1 minute apart — a crash-and-immediate-retry pattern typical of an
  automated host, not a workload.
- `journalctl -k` shows **zero OOM kills, ever**. The only "OOM" line is the OOM
  killer socket listener (normal).
- No panic, no hardware error, no MCE, no thermal trip, no watchdog.
- The 12:12 boot ran 3 h 15 m; its journal's last entry is 15:27 and the reboot was
  15:37 — a 10-minute gap with no crash trace and no shutdown record.
- zram 7.5 GiB configured, peak swap used 1.7 GiB — memory pressure was survived,
  not fatal.

**My 8-shard run was active when the 15:37 reboot happened, so I am not claiming
immunity.** What I can say: I never finished measuring the real full-tree
footprint of a shard (the 20 MiB number was an underestimate), and the 8-shard
run I launched produced **0 completed shards**.

**Standing instruction from the user: run tests on the laptop only.** Given the
reboots, prefer to:

- launch long runs with `setsid nohup … </dev/null &` and a `DONE` marker so a
  reboot is detectable rather than silent;
- write logs to `/mnt/storage` or `$HOME/.cache`, **never `/tmp` or
  `/tmp/opencode`**;
- **cap concurrency.** Do not relaunch 8 shards unattended until one shard's real
  full-tree RSS/proc count has been measured. That measurement was interrupted by
  the reboot and is still **outstanding**.

---

## 10. Environment traps (each one cost real time this session)

- **This machine reboots every ~15-20 min and wipes `/tmp`.** Durable scratch:
  `/mnt/storage/` (127 G free) and `$HOME/.cache/po-tmp/`. `/tmp/opencode` does
  **not** survive — a backup there was lost mid-session. Keep backups on
  `/mnt/storage`.
- **`pkill -f 'release_artifact_mutation_test.sh'` kills the invoking shell too**
  (its own command line matches). This killed a shell once. Use `pgrep` with a
  `-a` filter you sanity-check, or match on a narrower pattern.
- `du -sc` double-counts — filter `$2=="total"`.
- Globs over ~22 k entries fail on `ARG_MAX` — use `find … -print0 | xargs -0`.
- `cat "$f" 2>/dev/null` **hides "does not exist"**. Never suppress stderr when
  asserting existence.
- `gh api` writes nothing for logs containing ANSI escapes unless
  `--allow-escape-sequences`.
- shellcheck **SC2034** false positives need the directive placed *before* the
  command.
- shellcheck **SC2242** rejects `exit "128+signo"` — pass numeric `signo` and
  compute `$((128 + signo))`.
- A **never-matching regex is indistinguishable from a correctly-passing
  assertion** if you only look at the green case. This bit me: `[^}]*` cannot
  capture the `LOG_DIR` default because the default itself contains `}`, so both
  new assertions were failing on a *correct* file (79/2). Always confirm the
  assertion **fails** when the thing it guards is broken.
- Shell heredocs in `shell` calls must escape `\${...}` or variables expand early.
- If you set `TMPDIR` to a directory, **`mkdir -p` it first** — otherwise `mktemp`
  falls back to bare `/` and you get `/scripts: Permission denied` noise that
  looks like real test failures.

---

## 11. Next steps, in order

1. **Fix the `Security gates` red** (§5). Recommended: anchor `pin_expr`'s needle
   at `uses: <action>@<sha>` so multiple legitimate pins are supported, keeping the
   comment-mention guard. Mutation-test it; keep the `pin-major`/`pin-version`
   self-checks passing.
2. **Run the FULL release-gate driver locally** (`make release-gate`, or
   `bash scripts/tests/run_release_gate_tests.sh`) — not just the edited suites.
   That is the step whose absence let §5 reach CI.
3. Measure one shard's real full-tree RSS/proc count before relaunching 8 shards.
4. Push; watch PR #173 for green. Then check the
   `release-gate-logs-macos_release_artifact_mutation_test.sh` artifact from the
   leg and finally diagnose the ~4 min runner death from real shard logs.
5. Get **#164** the fix (rebase onto #173's head, or merge #173 and rebase #164 —
   user's call, do not auto-close).
6. Merge in order: **#157, #160, #161, #164, #166, #168, #170**.
7. **Delete and recreate tag `v0.0.1`** (currently unspent at `6188e943`), then
   re-run the release. No bypass.
8. Multi-agent review the new commits (`c1582bac`, `ce637956`, `ef8bae0a`) — still
   outstanding.
9. Present the consolidated long-term QA plan for approval: QA tiers; Rust
   integration tests for `vault_store.rs` / `sync_transport.rs` / `api.rs`;
   iOS PR-time macOS job + `required-checks.json`; property tests on `read_frame` /
   `safe_relative_path`; mutation harnesses for the 7 uncovered suites; coverage
   tooling; separate website repo + Pages.

---

## 12. Open follow-ups

- **#171** — Rust `temp_runtime_root()` leaks a temp dir per test; 21,225 dirs /
  9.5 GB. **This is what filled the disk.** Unfixed, and it will keep filling it.
- #162, #153, #151, #149, #102, #98
- Security cluster: #148, #112, #110, #109, #57, #61, #60, #59
- Board automation is blocked until `PROJECTS_TOKEN` exists (**#81**) — the user
  must mint the fine-grained PAT.
- No mutation harness for `android_release_artifact_smoke_test.sh` (**#149**).
- `workflow_hygiene_test.sh` assertion floor 232 vs real 443 (pre-existing).
- Missing local tooling: `pwsh`, Xcode / `simctl` / `codesign` / `hdiutil`,
  `actionlint`.
- macOS/iOS artifact gates verified **locally only**, never on real
  `macos-latest`. Windows `/IGNORE:4099` unverifiable locally (no MSVC).
- **Known unmitigated false pass:** the CI matrix runs x86_64 images, so it cannot
  prove the APK installs on real arm hardware — the ABI check is the structural
  substitute. On API 31+ the system splash is drawn inside the app's own window, so
  it is focused, complex and stable, and the render check **cannot distinguish the
  splash from the app's first frame**. Do not claim otherwise.
- 70 open issues, including **#140** — the Android APK ships no daemon and cannot
  function (a product decision, not a build break).

Release run `37184543519`: Android APK ✅, macOS DMG ✅, signing preflight ✅.
Failed: Linux build, Windows build, iOS build, macOS smoke, Android smoke API 30 +
API 35.

---

## 13. File map

**Changed on #173** (worktree `/home/shadowarch/.cache/po-tmp/chk164`):

| File | What |
|---|---|
| `scripts/tests/run_release_gate_tests.sh` | driver: `LOG_DIR` (~L70, now `ROOT_DIR`-based), `on_signal`/`trap` (~L79-87), per-shard named logs + streaming in `run_suite` (~L124-174) |
| `scripts/tests/macos_release_artifact_mutation_test.sh` | `on_signal` + traps (~L105-116), hard-error empty `apply.err` (~L261-273), `MIN_MUTATIONS=45` |
| `scripts/tests/ios_release_artifact_mutation_test.sh` | same trap fix (~L77-88) |
| `scripts/tests/windows_release_artifact_mutation_test.sh` | same trap fix (~L109-120) |
| `scripts/tests/release_workflow_test.sh` | 7 new assertions: 4 driver (~L1155-1225), timeout floor/cap after `matrix_spec` (~L1247-1275), 3 log-upload/log-dir assertions added after `_matrix_steps` |
| `scripts/tests/tests_wiring_test.sh` | the `setsid` process-group probe (~L478-520) |
| `.github/workflows/ci.yml` | `release-gate-suites` `timeout-minutes: 60` (**L92**, verified); new `Upload release-gate logs` step at **L147-157**, inside `release-gate-suites`; the **pre-existing** `upload-artifact` pin at **L301** (the one that collides, §5); `concurrency: cancel-in-progress: true` (L12-14) |

Verified line refs: driver `LOG_DIR` at **L76**; hygiene `pin_expr` uniqueness
check at **L272**; hygiene failing mutation at **L394**; hygiene self-checks
**L343-362**; `setsid` probe **~L478-520** (`setsid` comment at L491).

**Read next for §5:** `scripts/tests/workflow_hygiene_mutation_test.sh` —
`pin_expr` and its uniqueness precondition at **L266-276**; the failing mutation
at **L394-397**; self-checks at **L343-362**.

**Do not commit / reference only:**

- `/mnt/storage/.reorg/po-rescue/` — rescued `gate-win2-scripts/` +
  `UNCOMMITTED-DIFFS.txt`
- `/mnt/storage/.reorg/PO-PHOTO-ORGANIZER-BRIEF-2026-10-05.md` — state brief; its
  §4 and §7 Q1 are **verified wrong** (§7 above)

**Backups / scratch on `/mnt/storage`:** `drv.bak`, `ci.bak`, `drv2.bak`,
`po-mut/{all8,solo}`, `po-sig*`, `verify/`, `verify-fast/`, `measure/`,
`prlogs/{sec173.log,sec173b.log,macleg.log,jobs.json}`, this handoff file.

---

## 14. Quick-start for Codex

```bash
cd /home/shadowarch/.cache/po-tmp/chk164      # #173 branch, clean, 3 commits
git log --oneline -4

# §5: the one red
sed -n '260,280p;390,400p' scripts/tests/workflow_hygiene_mutation_test.sh

# the full local gate -- this is the step that was missed
export TMPDIR=/mnt/storage/gate-tmp && mkdir -p "$TMPDIR"
bash scripts/tests/run_release_gate_tests.sh

# release blocker, once green
gh pr view 173 --json statusCheckRollup
gh run download --name release-gate-logs-macos_release_artifact_mutation_test.sh
```