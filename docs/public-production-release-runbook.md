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
