# Public Production Release Runbook

## Purpose

This runbook prepares a public release of Private Gallery without weakening the
local-first security model. Public production means users outside the project
team can install and use the Linux desktop app and Android pairing flow, but the
product still has no hosted media, thumbnail, OCR, embedding, biometric, vault
key, pairing-token, bearer-token, or precise metadata storage by default.

## Release Ownership

- Release owner: names the release, owns the go/no-go call, and records evidence.
- Desktop owner: verifies Linux bundle startup, local daemon health, import,
  vault, backup, and restore staging.
- Mobile owner: verifies Android pairing, upload, download, revocation, and
  remote route blocking.
- Security owner: verifies secret handling, local-first boundaries, optional
  bootstrap configuration, and network exposure.
- Support owner: monitors incoming user reports and owns rollback communication.

If any owner is missing, do not call the release public-production ready.

## Supported Release Surface

- Primary targets: Linux desktop and Android.
- Supported local daemon exposure:
  - Default desktop: `127.0.0.1:4821` only.
  - Private mobile sync: Tailscale/HTTPS path-limited to `/health` and
    `/mobile/*`.
  - Trusted LAN HTTP: development mode only, explicitly enabled with
    `PRIVATE_GALLERY_ALLOW_REMOTE_MOBILE=1`.
- Optional cloud bootstrap: metadata-only group membership and invite records.
  It must not receive media, thumbnails, vault keys, desktop pairing tokens,
  mobile bearer tokens, OCR text, embeddings, or capture/GPS metadata.

## Release Inputs

- Release tag or commit SHA.
- Changelog or release notes with user-visible behavior, known limits, and
  upgrade instructions.
- Link to readiness evidence from `scripts/production-readiness-check.sh`.
- Android smoke evidence from two authorized physical phones when mobile sync is
  in scope.
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

1. Build the Linux bundle:

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

## Remote Boundary Verification

Use Tailscale/HTTPS for private mobile sync where available. Expose only
`/health` and `/mobile/*` while the daemon remains loopback-bound.

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
