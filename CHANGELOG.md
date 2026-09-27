# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Screenshots for `docs/screenshots/`.
- Android release artifact gate: the exact APK that will be published is now
  installed, cold-launched, and proven to render a first frame on real Android
  system images (API 30 and API 35) before a release can be cut. A non-empty
  Android crash buffer (including a native `galleryd` tombstone) or an adverse
  `ApplicationExitInfo` reason (crash / native crash / ANR / initialization
  failure) blocks the release. Screenshot, crash buffer, exit-info and logcat
  are retained as evidence.
- `scripts/android_release_signing.sh`: a single, tested source of truth for
  Android release signing. All four `ANDROID_KEYSTORE_*` secrets are required;
  a partial configuration always fails rather than being silently ignored; no
  signing material at all fails the release with setup instructions instead of
  publishing an unsigned APK. A throwaway per-run key is possible only via the
  explicit `PRIVATE_GALLERY_RELEASE_ALLOW_EPHEMERAL_SIGNING` repository
  variable, and the release notes say so when it is used.
- `scripts/tests/` — device-free tests for the release gate itself (174
  assertions), run in CI via the "Release gate" job and locally with
  `make release-gate`. `release_workflow_test.sh` asserts the release
  workflow's safety properties structurally, so the guarantee cannot be removed
  by an unrelated edit. A suite that cannot run its assertions (for example, no
  Android SDK for the signature test) is reported as degraded and fails the run
  rather than passing quietly. The assertions exercise behaviour rather than
  source text wherever that is possible: a `keytool` shim records the real argv
  to prove the store password never reaches the command line, the real gate
  runner is executed to prove it fails when a suite fails, and every new
  assertion was mutation-tested — each was confirmed to fail when the code it
  protects is broken, and to pass when restored.
- The published APK now ships a `app-release.apk.sha256` checksum alongside it.
  It records the bare filename, not the CI build path, so a user who downloads
  the APK and the sidecar into one directory can verify it with `sha256sum -c`.

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
- The Android artifact was staged for upload as a multi-path list. That does not
  produce a flat artifact: `actions/upload-artifact` documents that "if multiple
  paths are provided as input, the least common ancestor of all the search paths
  will be used as the root directory of the artifact", so the APK was archived at
  its full build path while the smoke gate and the publish step both looked for
  it at the artifact root. Every release would have failed the smoke gate on a
  missing file. The three files are now staged into one directory and that
  directory is uploaded, so the layout is exactly what was staged and no longer
  depends on the action's path-hierarchy rules.
- The launch gate accepted the first screenshot that looked visually complex.
  Window focus was checked once *before* the render loop and never re-checked, so
  a window that lost focus mid-wait still passed; and a screen caught mid-
  transition was accepted as "rendered". Focus is now re-asserted inside the
  loop, and a frame must be visually complex *and* identical across two
  consecutive captures before it counts as rendered. Both new behaviours are
  mutation-tested.

  The gate still cannot distinguish the system splash screen (drawn inside the
  app's own window on API 31+) from the app's own first frame, because both are
  stable, complex, and focused. That is stated in the gate and the runbook rather
  than papered over with a colour threshold that would be wrong in the lenient
  direction — the same false pass the gate exists to prevent.
- A lost adb connection was reported as a clean crash check. `adb_shell` ended in
  `|| true`, so an emulator that died mid-run produced an empty `dumpsys` and an
  empty crash buffer — and an empty string parses as "zero adverse exits" and "no
  FATAL EXCEPTION". The two gates whose failure direction is the dangerous one
  were therefore the two that could silently pass. The adb exit status is now
  propagated, and a dump that could not be read fails the gate rather than
  reporting nothing wrong. Three states are now distinguished that were
  previously collapsed into one: adverse, clean, and *could not ask*.
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
- The job that publishes the APK now re-verifies it. That job is the last thing to
  run before the bytes become a download, on its own runner, with its own checkout
  of the gate script, so it re-derives the checksum (`sha256sum -c`) and
  re-asserts the v2+v3 signature on exactly the file it attaches. Its evidence is
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
- Build-only release jobs no longer hold `contents: write`.
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