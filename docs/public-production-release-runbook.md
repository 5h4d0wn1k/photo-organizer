# Public Production Release Runbook

## Purpose

This runbook prepares a public release of Private Gallery without weakening the
local-first security model. Public production means users outside the project
team can install and use the release-scoped platform surfaces while the product
still has no hosted file/media, thumbnail, OCR, embedding, biometric, vault key,
pairing-token, bearer-token, or precise metadata storage by default.

## Release Ownership

- Release owner: names the release, owns the go/no-go call, and records evidence.
- Desktop owner: verifies release-scoped desktop startup, local daemon health,
  import, vault, backup, restore staging, packaging, signing, and rollback.
- Mobile owner: verifies release-scoped Android/iOS pairing, upload, download,
  revocation, store compliance, and remote route blocking.
- Web owner: verifies browser/local-web boundaries, session handling,
  upload/download behavior, and no default company-hosted content path when web
  is in scope.
- Storage owner: verifies encrypted chunk replication, phone storage
  contribution, repair, eviction, and backup/restore evidence.
- Security owner: verifies secret handling, local-first boundaries, optional
  bootstrap configuration, and network exposure.
- Entitlements owner: verifies subscription tiers, offline grace, billing
  identifiers, workspace limits, and privacy-preserving support flows when paid
  plans are in scope.
- Support owner: monitors incoming user reports and owns rollback communication.

If any owner is missing, do not call the release public-production ready.

## Supported Release Surface

- Current private-beta baseline: Linux desktop and Android.
- Full product target: Windows, Linux, macOS, Android/Play Store, iOS/App Store,
  web/browser access where privacy-compatible, optional local web UI, and direct
  desktop installers/packages.
- Every public release must name which surfaces are in scope and must satisfy the
  relevant evidence in
  [platform-release-and-entitlements.md](platform-release-and-entitlements.md).
- Supported local daemon exposure:
  - Default desktop: `127.0.0.1:4821` only.
  - Private mobile/local-web sync: Tailscale/HTTPS path-limited to `/health`,
    `/local-web/*`, and `/mobile/*`.
  - Trusted LAN HTTP: development mode only, explicitly enabled with
    `PRIVATE_GALLERY_ALLOW_REMOTE_MOBILE=1`.
- Optional cloud bootstrap: metadata-only group membership and invite records.
  It must not receive media, thumbnails, vault keys, desktop pairing tokens,
  mobile bearer tokens, OCR text, embeddings, or capture/GPS metadata.
- Optional relay/discovery may help devices find each other, but must not store
  or inspect user content.

## Release Inputs

- Release tag or commit SHA.
- Changelog or release notes with user-visible behavior, known limits, and
  upgrade instructions.
- Link to readiness evidence from `scripts/production-readiness-check.sh`.
- Platform completion evidence for every release-scoped surface.
- Entitlement and subscription evidence when paid tiers are in scope.
- Android smoke evidence from two authorized physical phones when mobile sync is
  in scope.
- Phone storage-node evidence showing every opted-in Android phone received
  encrypted chunk assignments, stored bytes locally, reported proof-of-possession
  healthy replicas, and restored an encrypted chunk to the laptop.
- Backup/restore drill evidence for one encrypted library fixture.
- Open blocker list with owner and decision.

## Preflight

1. Confirm the release branch contains no local media, runtime databases, env
   files, signing keys, service credentials, bearer tokens, pairing tokens, or
   generated backup exports.
2. Confirm every credential that appeared in a local workspace file has been
   rotated before release.
3. Run the local readiness script:

   ```bash
   scripts/production-readiness-check.sh
   ```

4. Review the skipped checks. A skipped optional tool is acceptable only when the
   release owner records why the signal is not needed for this release.
5. For mobile releases, run the deterministic two-phone API smoke:

   ```bash
   PRIVATE_GALLERY_SMOKE_DEVICE_BASE_URL=https://<tailnet-host-or-lan-host> \
   PRIVATE_GALLERY_SMOKE_REQUIRE_DEVICE_COUNT=2 \
   scripts/android_mobile_smoke.sh
   ```

6. Run the Flutter app smoke for the same two phones when Android UI changes are
   in scope:

   ```bash
   PRIVATE_GALLERY_SMOKE_DEVICE_BASE_URL=https://<tailnet-host-or-lan-host> \
   PRIVATE_GALLERY_SMOKE_DEVICE_SERIALS="serial1 serial2" \
   scripts/android_mobile_app_smoke.sh
   ```

## Build And Package

1. Build the release-scoped desktop bundles/packages. For the current Linux
   baseline:

   ```bash
   scripts/build_linux_release.sh
   ```

2. Start the bundle through the launcher:

   ```bash
   scripts/private_gallery_linux_launcher.sh
   ```

3. Confirm the daemon answers health locally:

   ```bash
   curl -fsS http://127.0.0.1:4821/health
   ```

4. Confirm the app can open a test library, import a fixture, show timeline
   content, and list jobs without mock fallback data.
5. Confirm new managed imports are sealed into encrypted vault chunks when
   encrypted-only originals are active.
6. Confirm app-store and direct-distribution signing does not use debug keys.
   Provide signing material through ignored local properties, secure local
   keychains, app-store tooling, or equivalent CI secrets; never commit
   keystores, certificates, provisioning profiles, or passwords. Run the
   readiness script with `PRIVATE_GALLERY_READINESS_REQUIRE_RELEASE_SIGNING=1`
   for Android release evidence and record equivalent evidence for other
   release-scoped platforms.

## Android Release Signing

The Android release APK is signed, and the signing key is the artifact's
identity: lose it and users can never install an upgrade over an existing copy.
CI therefore refuses to publish a release APK unless signing material is
configured. It never falls back to a debug key, and a degraded signing mode is
never silent: it needs an explicit opt-in variable and is called out in the
release notes.

Two operational rules follow from this. First, keep the keystore backed up
somewhere that is not this repository — and note that a root-level `release.jks`
is covered by `.gitignore`, but a keystore under any *other* name is not
guarded, so keep it outside the tree entirely. Second, turn
`PRIVATE_GALLERY_RELEASE_ALLOW_EPHEMERAL_SIGNING` back off as soon as the
throwaway tag is cut: a release pipeline does not currently compare the signing
certificate against the previous release, so a variable left switched on would
make the second consecutive ephemeral release indistinguishable from the first,
and that release would be uninstallable.

### One-time setup

Create the key once and keep it somewhere private and backed up:

```bash
keytool -genkeypair -v \
  -keystore release.jks -storetype PKCS12 \
  -keyalg RSA -keysize 4096 -validity 10000 \
  -alias photo-organizer \
  -storepass '<store password>' \
  -dname "CN=Photo Organizer, O=Photo Organizer, C=NA"
```

**Use one password for the store and the key.** This is not a simplification. A
PKCS12 keystore cannot hold two different passwords — `keytool` prints
`Different store and key passwords not supported for PKCS12 KeyStores. Ignoring
user-specified -keypass value.` and carries on, so passing `-keypass` with a
different value does not warn you afterwards, it just discards it. The key's
password then *is* the store password, and setting `ANDROID_KEY_PASSWORD` to
something else makes the Gradle build fail to load the key. If you genuinely need
two distinct passwords, use `-storetype JKS` and keep `-keypass`; either way, set
both secrets to the values the keystore actually has.

Then publish it to the repository as four secrets:

```bash
gh secret set ANDROID_KEYSTORE_BASE64   < <(base64 -w0 release.jks)
gh secret set ANDROID_KEYSTORE_PASSWORD -- '<store password>'
gh secret set ANDROID_KEY_ALIAS         -- 'photo-organizer'
gh secret set ANDROID_KEY_PASSWORD      -- '<the key password, which for PKCS12 is the store password>'
```

`release.jks` itself stays local and is never committed. The CI job decodes the
keystore into the runner's temp directory, never into the working tree, and
validates that the **store** password opens it before Gradle runs. The key alias
and the key password are not checked by that step — `keytool -list` ignores
`-keypass` — so a wrong key password surfaces as a Gradle failure, which still
blocks the release.

Verify locally without publishing anything:

```bash
PRIVATE_GALLERY_READINESS_REQUIRE_RELEASE_SIGNING=1 \
ANDROID_KEYSTORE_FILE="$PWD/release.jks" \
ANDROID_KEYSTORE_PASSWORD='<store password>' \
ANDROID_KEY_ALIAS=photo-organizer \
ANDROID_KEY_PASSWORD='<key password>' \
  bash scripts/production-readiness-check.sh
```

### Policy

`scripts/android_release_signing.sh` is the single source of truth, and it is
strict on purpose:

| Secrets present | Result |
| --- | --- |
| all four | `release` — upgrade-stable artifact |
| none | release **fails** with setup instructions |
| some but not all | release **always fails**; a half-configured keystore is a mistake, never a fallback |
| none, with `PRIVATE_GALLERY_RELEASE_ALLOW_EPHEMERAL_SIGNING=true` | `ephemeral` — installable, but a throwaway per-run key |

The ephemeral mode exists for deliberate throwaway tags only. Because the key
is regenerated every run, the next release cannot install over it, so Android
requires an uninstall first — and uninstalling discards `flutter_secure_storage`,
which holds the mobile bearer token and cloud group/device identity, forcing a
full re-pair with the desktop daemon. The release notes state this in as many
words whenever ephemeral signing is used.

### What the release pipeline proves

Before a tag can publish an APK, all of the following must pass:

1. `scripts/android_release_verify_signature.sh` succeeds, which means
   `apksigner verify` passed **and** APK Signature Scheme **v2 and v3** were both
   asserted present. The schemes are asserted explicitly because `apksigner`
   itself returns 0 for a v2-only APK — trusting the exit status alone would let
   an artifact ship that the release notes describe as v3. (v1/JAR signing is
   off because minSdk is 24; the Gradle config turns it on automatically if
   minSdk ever drops below 24, and the gate would then correctly reject a build
   with no v2 signature.)
2. The APK carries native libraries for **arm64-v8a** and **armeabi-v7a**. This is
   checked structurally, by reading the archive, *before* the device is touched —
   see *The APK installs on an arm device* under **What this does not prove** below
   for why it cannot be left to the emulator. The check runs on every path now: a
   missing `unzip`, an unlistable archive, and an APK with no `lib/` entries at all
   are all hard failures, not skips, because nothing downstream re-asserts it.
3. The exact APK is installed on Android system images at **API 30 and API 35**,
   cold-launched, and a window is proven to have rendered a stable, non-blank
   frame: a capture must be visually complex *and* byte-identical across two
   consecutive captures, which rejects a blank screen and a screen mid-transition.
4. No crash entry appears in the Android crash buffer — which also catches a native
   SIGSEGV in the Rust `galleryd` daemon, since a native crash never appears as a
   Java `FATAL EXCEPTION`. A bare `--------- beginning of crash` header with no
   entries under it is tolerated: some platform versions print one, and treating a
   header as a crash would fail every release.
5. Android recorded no adverse `ApplicationExitInfo` (crash, native crash, ANR,
   or initialization failure) relative to a pre-launch baseline. If the baseline
   itself could not be read, the comparison is replaced by the strictly stronger
   requirement of *zero* adverse entries, so an unreadable baseline can only ever
   make this check harder to pass. Whether the check applies at all is decided by a
   dedicated API-level probe, never by text found inside the dump: a crash
   description such as `...: /data/gallery.db not found` is ordinary for this app
   and must not be able to switch the check off.
6. Screenshot, crash buffer, exit-info dump, `apksigner` transcript and a
   `sha256` checksum are uploaded as evidence, and the checksum records the bare
   filename so a user can verify it with `sha256sum -c`. `android-verify` re-derives
   the checksum and re-asserts the v2+v3 signature, and the single `release` job
   `needs:` it, so nothing is published unless that passed. Both fetch the same
   immutable `android-artifact` from the same run, which is what makes the
   verified bytes the published bytes. `release` then stages every platform
   artifact into `dist/` and attaches that directory, so it does not itself
   re-derive anything. The materialized signing key is removed from the runner
   afterwards — including when the build fails.

Any failure blocks the release. Both gates are committed scripts rather than
inline workflow logic, and both are covered on every CI run by
`make release-gate`: `apksigner_gate_test.sh` links real APKs with `aapt2`, signs
them with a throwaway key and runs the real signature gate over an unsigned, a
v1-only, a v2-only and a correct v2+v3 artifact, while
`android_release_artifact_smoke_test.sh` does the same for the emulator gate.
`release_workflow_test.sh` additionally asserts structurally that the workflow
still delegates to those scripts, so the guarantee cannot be removed by an
unrelated edit.

### What this does not prove

Stated explicitly, because a gate that overstates itself is worse than no gate:

- **The rendered frame came from the app, not from the launch theme.** On API 31+
  the system splash is drawn *inside the app's own window*, so it is focused, it
  is far above the colour threshold, and it is perfectly stable across captures.
  The render check therefore cannot distinguish the two. Excluding it requires a
  Flutter-owned surface from `dumpsys SurfaceFlinger --list`, or the semantics
  tree via `uiautomator`, which requires an accessibility service and is
  unavailable in CI. This is a known, unmitigated false pass.
- **The APK installs on an arm device.** The matrix runs x86_64 images because
  there is no free hosted arm64 emulator. Point 2 is the structural substitute,
  and it checks *packaging*, not that the libraries load or link correctly on
  real hardware.
- **The app works.** The gate proves it installs, launches, does not crash, and
  draws something. It says nothing about whether the UI is correct, whether
  features work, or whether the daemon is reachable.
- **The signing key is the same one as the last release.** #101 tracks that. The
  pipeline records the certificate digest in the evidence so the comparison *can*
  be made, but it does not fail when the digest changes.

## Remote Boundary Verification

Use Tailscale/HTTPS for private mobile/local-web sync where available. Expose
only `/health`, `/local-web/*`, and `/mobile/*` while the daemon remains
loopback-bound.

For any remote base URL that phones can reach:

```bash
curl -fsS https://<remote-base>/health
curl -i https://<remote-base>/library/status
curl -i https://<remote-base>/pairing/sessions
```

Acceptance:

- `/health` returns success.
- Desktop control routes such as `/library/status` and `/pairing/sessions`
  return `403` to remote clients.
- Mobile routes require a valid paired bearer token.
- Storage-node routes under `/mobile/storage/*` require the same paired bearer
  token and only move encrypted vault chunks.
- No LAN HTTP endpoint is published for public production unless the release is
  explicitly labeled development-only.

## Backup And Restore Drill

1. Create or reuse a small encrypted test library with at least one photo and one
   video fixture.
2. Run backup verification from the app or API.
3. Export a backup to a release-test path that is not inside the active library.
4. Plan and run restore into a separate staging root.
5. Confirm the staged restore does not overwrite the active library.
6. Confirm missing or corrupt vault chunks are reported, not silently replaced
   with plaintext.
7. With one paired Android storage phone online, delete one encrypted chunk from
   the release fixture, restore that chunk from the phone, and verify the chunk
   hash before opening the original.

## Rollout Strategy

- Release from an immutable tag or signed artifact set.
- Start with a small public cohort or beta channel before broad announcement.
- Prefer direct desktop rollback and Android staged rollout controls over
  complex runtime feature flags.
- Keep optional cloud bootstrap disabled unless the release note explicitly
  describes it as metadata-only.

## Abort Criteria

Abort or halt rollout when any of these occur:

- Secret, token, key, media, OCR text, embedding, or precise metadata exposure.
- Remote clients can reach desktop control APIs.
- New copy/mobile imports leave unencrypted managed originals when encrypted-only
  originals are expected.
- Backup verification or restore staging fails on a clean encrypted fixture.
- Two-phone mobile smoke fails for pairing, upload, download, range hash,
  revocation, or route blocking.
- Phone storage-node smoke fails for encrypted chunk assignment, hash-verified
  local storage, proof-of-possession replica reporting, or restore-to-laptop
  repair.
- Crash or startup failure prevents opening the app or daemon on the supported
  Linux target.

## Post-Release Verification

Within the first release window:

- Re-run health and remote boundary probes.
- Verify support channels have no unresolved reports of data loss, accidental
  exposure, failed import, failed restore, or broken revocation.
- Sample one clean install and one upgrade install.
- Confirm the published release notes still match the supported surface.
- Record all skipped readiness checks and any accepted residual risks.

## Public Rollback Trigger

Use `docs/rollback-recovery-checklist.md` when abort criteria are met or when a
release creates material privacy, data-integrity, startup, import, mobile sync,
or restore risk.
