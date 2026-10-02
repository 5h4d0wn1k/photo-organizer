# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Android release artifact gate: the exact APK that will be published is now
  installed, cold-launched, and proven to render a stable, visually-complex frame
  on real Android system images (API 30 and API 35) before the APK can be
  attached to the release. A crash entry in the Android crash buffer (including a
  native `galleryd` tombstone) or an adverse `ApplicationExitInfo` reason (crash /
  native crash / ANR / initialization failure) blocks the release. Screenshot,
  crash buffer, exit-info and logcat are retained as evidence, and a missing
  evidence directory fails the job instead of passing quietly. Two limits are
  stated rather than papered over: the images are x86_64, so the arm ABIs are
  checked structurally from the archive rather than installed on arm hardware; and
  on API 31+ a stable focused frame cannot be distinguished from the system
  splash, which is drawn inside the app's own window. This covers the APK only —
  the Linux, Windows, macOS and iOS artifacts are not install-tested in CI.
- `scripts/android_release_signing.sh`: a single, tested source of truth for
  Android release signing. All four `ANDROID_KEYSTORE_*` secrets are required;
  a partial configuration always fails rather than being silently ignored; no
  signing material at all fails the release with setup instructions instead of
  publishing an unsigned APK. A throwaway per-run key is possible only via the
  explicit `PRIVATE_GALLERY_RELEASE_ALLOW_EPHEMERAL_SIGNING` repository
  variable, and the release notes say so when it is used.
- `scripts/tests/` — device-free tests for the release gate itself, run in CI
  via the "Release gate" job and locally with `make release-gate`:
  `release_workflow_test.sh` (52 shell checks wrapping 166 assertions on the
  parsed release workflow), `android_release_signing_test.sh` (62),
  `apksigner_gate_test.sh` (27), `android_release_artifact_smoke_test.sh` (74),
  and `release_atomic_publish_mutation_test.sh` (42 mutations, each breaking one
  publication guarantee and required to go red). `release_workflow_test.sh`
  asserts the release
  workflow's safety properties structurally, so the guarantee cannot be removed
  by an unrelated edit. A suite that cannot run its assertions (for example, no
  Android SDK for the signature test) is reported as degraded and fails the run
  rather than passing quietly. The assertions exercise behaviour rather than
  source text wherever that is possible: a `keytool` shim records the real argv
  to prove the store password never reaches the command line, the real gate
  runner is executed to prove it fails when a suite fails, and every new
  assertion was mutation-tested — each was confirmed to fail when the code it
  protects is broken, and to pass when restored.
- The published APK now ships a `app-release.apk.sha256` checksum and the
  `apksigner-verify.txt` signature transcript alongside it. The checksum records
  the bare filename, not the CI build path, so a user who downloads the APK and
  the sidecar into one directory can verify it with `sha256sum -c`; the
  transcript records the signing certificate digest so a release is traceable to
  a key without exposing the key itself.

### Changed

- **Release publication is single-writer.** Previously every platform job
  published to the GitHub release itself, with no `needs:` between them, so a tag
  whose platform jobs were only partly green still produced a live, public,
  non-draft release carrying whatever the successful jobs had uploaded — and it
  became "Latest", consuming the tag. v0.1.7 is the observed instance: the
  Android, Windows and macOS jobs were green while Linux and iOS failed, and the
  release shipped exactly those three assets (no AppImage, no `.deb`, no `.app`,
  despite the APK being present). There was no guard anywhere — the `release-gate`
  check is required for merges only, the branch ruleset does not govern tags, and
  the workflow triggers on `push: tags: v*`, so a tag push bypassed every gate by
  construction. Now exactly one job (`release`) holds `contents: write` and
  publishes, and exactly one *step* performs the publish: a second publish call
  inside that same job would recreate the identical partial release, because the
  action drafts the release, uploads, then flips `draft: false`, so a step placed
  before staging leaves a live release with whatever it named while the staging
  refusals run too late. Every platform job uploads its build output as a
  workflow artifact instead. The publisher requires every platform job, stages the artifact set
  itself, and refuses to publish on a missing platform directory, a zero-byte
  payload, or two artifacts sharing a basename. The `android-publish` job, which
  held `contents: write` and was gated on `needs: [android, android-smoke]` while
  carrying none of the signing steps, becomes `android-verify` with
  `contents: read`, and a toolchain-free `release-signing-preflight` job fails a
  tag with no signing material in seconds, before any job holds
  `contents: write`. It had in fact never run: `android` had no `needs:` and its
  `actions/checkout` pin was unresolvable, so every `v*` tag died in `android`
  first (#133, fixed in #134).
- The release notes now state the signing mode of the published APK. An
  ephemeral-key build tells the reader that a future version needs an uninstall,
  which discards the device's paired identity, instead of promising a clean
  upgrade over it.

### Security

- `*.jks` and `*.keystore` are now ignored at the repository root. They were
  only ignored under `app/android/`, while the release runbook tells the
  maintainer to create `release.jks` in the working directory — one `git add .`
  from publishing the signing key to a public repository, permanently and
  irrecoverably. `scripts/tests/release_workflow_test.sh` now verifies this with
  `git check-ignore` and fails if any keystore is tracked.
- The CI keystore is written under a per-run random filename instead of a fixed
  one, and with `umask 077` so it is owner-only.
- The keystore store password is passed to `keytool` via `-storepass:env` rather
  than on the command line, where another local process could read it from
  `/proc/<pid>/cmdline`.
- The "never write signing material into the working tree" check compares
  canonical paths instead of string prefixes. A prefix test under-refuses for a
  path that leaves the workspace and returns (`…/elsewhere/../workspace/…`),
  which would have placed the keystore in the tree that later steps upload
  artifacts from.
- Removed a duplicate definition of `is_enabled` in
  `scripts/production-readiness-check.sh`; the second, narrower-looking copy was
  dead code that silently lost to the first.
- A lost adb connection was reported as a clean crash check. `adb_shell` ended in
  `|| true`, so an emulator that died mid-run produced an empty `dumpsys` and an
  empty crash buffer — and an empty string parses as "zero adverse exits" and "no
  FATAL EXCEPTION". The two gates whose failure direction is the dangerous one
  were therefore the two that could silently pass. The adb exit status is now
  propagated, and a dump that could not be read fails the gate rather than
  reporting nothing wrong. Three states are now distinguished that were
  previously collapsed into one: adverse, clean, and *could not ask*.
- **The crash check could switch itself off from inside a crash report.** Whether
  `ApplicationExitInfo` applies was decided by substring-matching the whole dump
  for `not found` / `Unknown command` / `Can't find service` / `No service`. An
  `ApplicationExitInfo` record carries a free-text `description=` field holding the
  crash or ANR message verbatim, and this app's daemon resolves paths and opens its
  index — so a description such as `SIGSEGV in galleryd opening /data/gallery.db:
  path not found` is ordinary. One such adverse record therefore read as "exit-info
  unavailable on this API level", disabled the crash check and returned clean. A
  native crash and an ANR both shipped green. This is the same false pass the gate
  exists to prevent, reached through a different door: the gate was reading its own
  evidence as a platform capability. The decision now comes from a dedicated
  API-level probe, and a dump carrying any record can never be reinterpreted as
  "unsupported" no matter what its text says. Four states are now distinguished —
  adverse, clean, feature-absent, and unreadable — and only a positively
  established pre-30 API level skips the check, with a warning.
- **The native-ABI check degraded to a warning in three separate ways**, and it is
  the only thing covering the real device ABIs, because the emulator matrix runs
  x86_64 images only. A missing `unzip`, an archive that could not be listed, and
  an APK with no `lib/` entries at all each passed with a `::warning::` and none of
  them is re-asserted anywhere downstream. The last one is the worst: an APK
  carrying no native libraries installs on the x86_64 emulator with no ABI mismatch,
  launches and renders, so a dropped `jniLibs` step shipped green. All three are now
  hard failures.
- **No smoke evidence was ever produced.** `ANDROID_SMOKE_NAME` and
  `ANDROID_SMOKE_EVIDENCE_DIR` were nested under the emulator runner's `with:`
  block, which is an *action input*, not a step environment. The pinned
  `android-emulator-runner` has no `env` input, so GitHub dropped both values with
  only an "Unexpected input(s)" warning; the gate then fell back to writing evidence
  into the workspace root, and the upload step — configured
  `if-no-files-found: warn` — reported a missing directory as a pass. The
  install/launch verdict was unaffected, so the gate still blocked correctly, but
  the mandatory "evidenced on the runner harness" half of the drop-gate never
  happened and the runbook's promise of retained evidence was false on every run.
  The variables are now step-level `env:`, and the upload fails when the evidence
  is absent.
- When the pre-launch `ApplicationExitInfo` baseline could not be read, the
  comparison silently degraded to "no worse than zero". The baseline is now
  recorded as `unavailable` and the gate applies the strictly stronger
  requirement of zero adverse entries outright, so a lost baseline can never make
  a check easier to pass.
- The signing key is now removed from the runner once the build no longer needs
  it. `materialize` deliberately leaves the keystore on disk — the Gradle build is
  a later process and reads it through `$GITHUB_ENV` — so the removal is an
  `if: always()` step in the build job, which also runs on a failed or cancelled
  build. It is a no-op when no key was materialized, so a failed build is not
  replaced by a confusing second failure.
- The APK is re-verified before it is published, by a job other than the one that
  built it. The re-verification runs on its own runner with its own checkout of
  the gate script, so it re-derives the checksum (`sha256sum -c`) and re-asserts
  the v2+v3 signature on exactly the artifact the release stages — both jobs fetch
  the same immutable `android-artifact` from the same run. Its evidence is
  written to a scratch directory: the gate is verifying, not regenerating, and
  must not be able to make a bad artifact look attested by replacing the file a
  reader is told to trust.
- The keystore size check and the permission assertion used `stat -c`, which is
  GNU coreutils and does not exist on macOS or BSD. Both use POSIX equivalents
  (`wc -c` and `ls -l`).
- The emulator matrix runs x86_64 images — there is no free hosted arm64 emulator
  — so it could only ever prove the x86_64 slice of the APK. An APK carrying only
  that slice installs perfectly on the runner and fails on every real phone with
  `INSTALL_FAILED_NO_MATCHING_ABIS`, and nothing in the pipeline would have
  noticed. The gate now reads the archive and requires `arm64-v8a` and
  `armeabi-v7a` before the device is touched, so the diagnosis is the packaging
  regression rather than an install failure minutes after boot. A Java-only APK
  still passes, but is reported: a dropped `jniLibs` step is visible instead of
  silent.
- The runbook and `AGENTS.md` now state plainly what the render gate does **not**
  prove. On API 31+ the system splash is drawn inside the app's own window, so it
  is focused, visually complex and stable — indistinguishable from the app's first
  frame by this method. That false pass is documented rather than papered over
  with a threshold loose enough to be wrong in the lenient direction.
- Values written to `$GITHUB_ENV` are rejected if they contain a newline or a
  carriage return. `GITHUB_ENV` is a newline-delimited `KEY=VALUE` file, so an
  embedded line break turns a value into additional environment variables for
  every later step of the release — the "rejecting newlines is the whole
  defence" case, since the format offers no escaping. Both the keystore file
  path, the store password, the key alias and the key password are checked, and
  the keystore path is checked before any directory is created, so a refused run
  leaves nothing behind in the working tree.

### Fixed

- The documentation claimed configuration prefixes (`PG_*`) that no longer
  exist anywhere in the tree, described the application-menu entry as still
  using the legacy *Private Gallery* name, and listed roughly a third of the
  local API surface. The API list in `docs/architecture.md` is now generated
  from `native_core/src/api.rs` by `scripts/generate-api-list.py`, which also
  verifies it with `--check`, so it cannot rot silently again. The changelog no
  longer advertises screenshots for an empty `docs/screenshots/` directory.
- The Android release APK was published completely unsigned, so stock Android
  refused to install it ("App not installed"). `build.gradle.kts` now resolves
  signing material from the CI environment, and CI refuses to publish without
  it.
- `apksigner verify` now runs as a hard gate before publication and asserts
  that APK Signature Scheme v2 and v3 are both present. This assertion is real
  protection, not ceremony: `apksigner` by itself returns 0 for a v2-only APK,
  so an exit-status-only check would publish an artifact the release notes
  describe as v3-signed. v1/JAR signing is no longer claimed in the release
  notes; it is off because minSdk is 24, and it switches on automatically if
  minSdk ever drops below 24.
- The signature gate is a committed, tested script
  (`scripts/android_release_verify_signature.sh`) rather than inline workflow
  logic. `scripts/tests/apksigner_gate_test.sh` links real APKs with `aapt2`,
  signs them with a throwaway key, and runs the real gate against an unsigned, a
  v1-only, a v2-only and a correct v2+v3 artifact.
- The published checksum now records the bare APK filename rather than the CI
  build path, so a user who downloads the APK and its `.sha256` can verify the
  pair with `sha256sum -c`.
- A half-configured keystore, or a configured keystore path that does not
  exist, now fails the Gradle build with an actionable message instead of
  silently producing an unsigned APK.
- Every platform job appended to the GitHub release body instead of replacing
  it, so the last platform to finish no longer erased the other platforms'
  signing warnings. Exactly one job generates the changelog, so it is no longer
  duplicated once per platform.
- The Android **build** job no longer holds `contents: write`; it only uploads an
  artifact. Publication is owned by a single dedicated job rather than by each
  platform job — see the single-writer entry under **Changed**.
- The Android artifact was staged for upload as a multi-path list. That does not
  produce a flat artifact: `actions/upload-artifact` documents that "if multiple
  paths are provided as input, the least common ancestor of all the search paths
  will be used as the root directory of the artifact", so the APK was archived
  at its full build path while the smoke gate and the publish step both looked
  for it at the artifact root. Every release would have failed the smoke gate on
  a missing file. The three files are now staged into one directory, and that
  directory is uploaded, so the layout is exactly what was staged and no longer
  depends on the action's path-hierarchy rules. The staging step refuses to copy
  a missing or empty file, so a bad input fails at the point of the mistake.
- The launch gate accepted the first screenshot that looked visually complex.
  Window focus was checked once *before* the render loop and never re-checked, so
  a window that lost focus mid-wait still passed, and a screen caught mid-
  transition counted as rendered. Focus is now re-asserted inside the loop, and a
  frame must be visually complex *and* identical across two consecutive captures
  before it counts as rendered. Both behaviours are mutation-tested: reverting
  either one fails a test.

  The gate still cannot distinguish the system splash screen — drawn inside the
  app's own window on API 31+ — from the app's own first frame, because both are
  stable, complex and focused. That limitation is now stated in the gate and the
  runbook instead of being papered over with a colour threshold that would be
  wrong in the lenient direction, which is the same false pass the gate exists to
  prevent.
- Encryption activation no longer bricks the daemon when interrupted between
  the database swap and the state write (#109). Startup now probes the
  database header: an encrypted database with no (or torn) state rebuilds
  the state from the stored key -- whose id is derived deterministically
  from the database path -- after proving the key opens the database, and a
  key that does not verify (or no key at all) fails loudly instead of
  opening silently. State writes are atomic (temp + fsync + rename), so torn
  state files cannot arise from future writes.
- The header probe that recovery depends on no longer reads the whole database
  file. It was `fs::read`, so a 16-byte question allocated a buffer the size of
  the entire library -- and it sits on the path taken by every state write, and
  therefore by every mutating request, on every install that has not activated
  encryption. Measured at +272 MB peak RSS on a 268 MB database; the probe now
  reads a fixed 16 bytes and a regression test asserts bounded peak RSS against
  a 512 MB file. The probe is also evaluated once per open instead of twice on
  the recovery path, where it was hidden inside a match guard.
- A file shorter than 16 bytes is no longer reported as an encrypted database.
  It is neither a valid SQLite header nor a valid SQLCipher page, and the old
  whole-file comparison classified it as encrypted and sent the operator to the
  OS keyring to look for a key that was never involved. It now fails as the
  corruption it is.
- Recovery after an interrupted activation now *verifies* each candidate key
  before accepting it and keeps looking if it does not open the database, rather
  than stopping at the first key it could find. A stale entry in one store no
  longer aborts the attempt before the store that holds the working key is
  tried. A key that is present but wrong is now reported distinctly from a key
  that is absent, and nothing is persisted in either case.
- The key-verification probe can no longer manufacture its own evidence: it
  opened the database with `SQLITE_OPEN_CREATE`, so a correct key against a
  path that did not exist created an empty database that answers the probe
  under any key. It is now read-write without create.
- Atomic state writes no longer leave a temp file behind when the write or the
  rename fails. The temp file is named like the state file and lives in the same
  security directory, so a failure previously deposited a stray copy of the
  state next to the state. The file handle is also closed before the rename, so
  the rename is valid on Windows.
- Atomic state writes no longer widen permissions. A new state file is created
  0600 instead of inheriting the process umask, and an existing mode is
  preserved, so an operator who tightened the state file does not silently get a
  looser one on the next write.
- The directory fsync after an atomic rename is compiled out on non-Unix
  platforms instead of being attempted unconditionally. There is no directory
  handle to sync on Windows, so the call could fail *after* the database swap
  had already replaced the live database -- turning the recovery path into the
  brick #109 exists to prevent.

## [0.1.0] - 2026-09-22

Ported from the *photos-and-videos-organizer* / Private Gallery MVP.

### Added

- Import: folder and removable-drive scan/commit with `copy` and `reference`
  modes, watch folders, and checksum-based dedupe.
- Timeline, places, and events views backed by persisted API state.
- Albums, archive/favorite/trash flags, manual asset tags, and smart folders.
- Search with local Tesseract OCR indexing and heuristic scene tags.
- Whole-library SQLCipher encryption and ChaCha20-Poly1305 sealed vault chunks
  with per-chunk nonces and hash verification.
- Desktop P2P vault sync over Iroh: vaults, device enrollment, storage policies,
  replica health, transfer plans, retry, and cancel.
- Android pairing with QR invites, resumable authenticated uploads, bounded-range
  downloads, session expiry/revocation, and optional encrypted storage
  contribution.
- Loopback-only API (`127.0.0.1:4821`) with `/mobile/*` restricted remote
  surface and `PRIVATE_GALLERY_ALLOW_REMOTE_MOBILE=1` LAN development mode.
- Local backup verify/export and non-destructive restorable restore staging.

### Changed

- Legacy Python face sorter relocated to `tools/quick-face-sort/`.