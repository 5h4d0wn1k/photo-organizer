# Production SLO And SLI Guide

## Purpose

Private Gallery is local-first, so production reliability is measured through
local runtime signals, release smokes, job records, and user-consented support
evidence instead of hosted telemetry. Do not add analytics, crash reporting, or
remote diagnostics that send files, media, thumbnails, OCR text, embeddings, face
data, project/client metadata, pairing tokens, bearer tokens, vault keys, or
precise metadata off-device.

## Critical User Journeys

- Open the desktop app and connect to the local daemon.
- Initialize or open an encrypted local library.
- Import media and general files without duplicates or unintended plaintext
  managed originals.
- Browse timeline, files, jobs, places, events, search, and vault status from
  live API data.
- Pair mobile/desktop/storage devices through Tailscale/HTTPS, private networks,
  or an explicitly enabled LAN development URL.
- Upload and download originals through authenticated `/mobile/*` routes.
- Revoke sessions and devices.
- Verify backup readiness and stage restore into a separate root.
- Release scoped surfaces for Windows, Linux, macOS, Android/Play Store,
  iOS/App Store, web/browser access, local web UI, and direct installers with
  platform-specific evidence.
- Enforce subscription entitlements without exposing content or breaking safe
  offline local use.

## Service Level Objectives

| Area | SLO | Measurement Window | Release Gate |
| --- | --- | --- | --- |
| Local daemon startup | 99% of supported Linux launches reach `/health` within 10 seconds. | Release smoke and support reports. | A clean Linux release bundle must pass before publish. |
| Desktop control boundary | 100% of remote probes to desktop control routes return `403`. | Every mobile release smoke. | Any remote access to desktop routes blocks release. |
| Local import integrity | 99.9% of committed copy/mobile imports complete with verified checksum, dedupe state, and vault chunk records. | Job records and release fixtures. | Any silent corruption or duplicate asset from one import blocks release. |
| Encrypted-only originals | 100% of new managed encrypted-only originals are sealed into authenticated vault chunks and do not require hosted storage. | Release fixture plus code review evidence. | Plaintext managed copy retention blocks release unless explicitly documented as a development-only mode. |
| Mobile sync correctness | 99% of paired upload/download attempts succeed when the daemon is reachable and the session is valid. | Two-phone smoke, user support reports. | Pair/upload/download/range hash/revocation failures block mobile release. |
| Backup and restore readiness | 100% of release fixture backups verify and restore only into a staging root. | Release drill. | In-place overwrite or unverifiable backup blocks release. |
| Token and key secrecy | 100% of logs, docs, artifacts, and support bundles exclude secrets and raw tokens. | Secret scan, manual review, support sampling. | Any exposure blocks release until rotated and remediated. |
| Platform release evidence | 100% of in-scope platform releases have signing/package/store/privacy/test evidence recorded. | Release checklist and owner signoff. | Missing evidence blocks that platform release. |
| Entitlement privacy | 100% of billing and entitlement checks avoid content, file names, OCR text, face data, exact metadata, keys, and tokens. | Code review, release checks, support-bundle review. | Any content-coupled billing path blocks paid launch. |

## Service Level Indicators

Track these locally during release smokes and from user-provided diagnostics:

- `daemon_health_success`: `/health` succeeds on `127.0.0.1:4821`.
- `daemon_startup_seconds`: launcher start until `/health` success.
- `remote_desktop_route_forbidden`: remote `/library/status` and
  `/pairing/sessions` return `403`.
- `import_commit_success`: import commit job reaches success state.
- `import_checksum_verified`: asset checksum matches the imported payload.
- `vault_chunk_verified`: encrypted chunk hash verification passes.
- `file_organization_available`: file tree, tags/folders, search, and correction
  workflows load from live local API data.
- `mobile_pair_success`: phone receives a valid session through one-time pairing.
- `mobile_upload_complete_success`: chunked upload completes with expected size
  and optional SHA-256 hash.
- `mobile_download_range_hash_match`: ranged original/preview download hash
  matches expected payload.
- `session_revocation_enforced`: revoked bearer token is rejected.
- `backup_verify_success`: backup verify reports required database, original,
  vault chunk, and model-file availability.
- `restore_staged_success`: restore run writes only to the selected staging root.
- `platform_release_evidence_complete`: release-scoped platform evidence is
  present in the checklist/runbook.
- `entitlement_content_exposure_absent`: subscription checks and support bundles
  exclude private content and metadata.

## Error Budget Policy

Treat the following as zero-budget reliability or security failures:

- Remote access to desktop control routes.
- Uploading media, thumbnails, OCR text, embeddings, vault keys, bearer tokens,
  pairing tokens, or precise metadata to hosted services by default.
- Uploading files, project/client metadata, workspace content, billing-linked
  content identifiers, or local search history to hosted services by default.
- Data loss, silent corruption, or restore over the active library.
- Secret material in release artifacts or support bundles.
- Inability to revoke a mobile session or device.
- Paid entitlement behavior that blocks already-local safe use during temporary
  billing connectivity loss.

For ordinary app defects, spend the error budget only when the issue has a clear
workaround, does not risk private data, and does not affect import, backup,
restore, or mobile session safety.

## Measurement Sources

- `scripts/production-readiness-check.sh`
- `scripts/android_mobile_smoke.sh`
- `scripts/android_mobile_app_smoke.sh`
- Daemon job history from the local API.
- Backup verify and restore staging results.
- Launcher and daemon logs under local runtime paths.
- User-attached diagnostics that have been reviewed for secrets and private
  media metadata before sharing.

## Alert And Response Expectations

This project has no hosted control plane by default, so public production alerts
come from release checks, support reports, and maintainer-run probes.

- Privacy or route-boundary failure: respond immediately, halt rollout, revoke
  exposed credentials, and publish rollback guidance.
- Data integrity or restore failure: halt rollout, preserve evidence without
  copying private media, and use the recovery checklist.
- Mobile pairing or revocation failure: halt mobile rollout and recommend users
  revoke affected sessions or disable remote exposure.
- Startup or import regression: stop broad rollout and publish the last known
  good version.

## Review Cadence

- Review SLOs before every public release.
- Re-run the mobile SLO gates when Android pairing, upload, download, auth, or
  networking changes.
- Re-run platform release gates when Windows, macOS, iOS, web, local-web,
  installers, signing, stores, or update flows change.
- Re-run entitlement gates when subscription tiers, billing, workspace limits,
  relay priority, support bundles, or audit logs change.
- Re-run backup and restore gates when storage, vault, schema, encryption, import,
  or backup code changes.
- Tighten objectives only after enough release evidence exists to support them.
