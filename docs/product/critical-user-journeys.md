# Critical User Journeys

This document maps customer-visible workflows for the full Private Gallery
vision. Components only matter when they make these journeys reliable.

## Journey Inventory

1. First local library to first organized files.
2. Create private device group and pair a trusted device.
3. Upload, download, and inspect availability across devices.
4. Organize and rediscover photos, videos, documents, and work files.
5. Protect storage with another device and repair missing chunks.
6. Backup and restore without overwriting the active library.
7. Remote access through Tailscale/private network or future relay/discovery.
8. Subscribe or renew without exposing content or breaking safe offline use.
9. Business/workspace sharing with roles, audit, and project/client organization.
10. Platform release install and update on Windows, Linux, macOS, Android, iOS,
    web, local web UI, and direct desktop packages.

## Most Important Journey: First Local Library To Protected Organized Cloud

### User-Visible Steps

1. User installs the desktop app on a supported platform.
2. App starts or connects to the local daemon.
3. User creates an encrypted library root.
4. User imports a folder containing photos, videos, documents, or mixed files.
5. App scans read-only and shows import candidates, duplicates, unsupported
   files, sidecars, size, and selected import mode.
6. User commits the import.
7. App creates asset/file records, encrypted chunks, job records, and initial
   organization views.
8. User sees files in timeline, files view, search, places/events where
   applicable, and organization controls.
9. User creates a device group.
10. User pairs a phone, desktop, NAS, external drive, or storage-only device by
    QR/manual invite.
11. User uploads or downloads one file from the paired device.
12. User sees availability: local, remote, under-replicated, protected, offline,
    missing, or transfer pending.
13. User runs backup verification or restore staging.

### Completion Condition

The user can confidently say: "This is my private cloud. My files are organized,
searchable, protected, and still mine."

### Failure-Sensitive Points

- Daemon cannot start or bind safely.
- Library root invalid, inside source folder, or not writable.
- Encryption activation fails or key storage is unavailable.
- Scan misses supported file types or silently imports unsupported files.
- Move mode deletes source before hash verification.
- Duplicate detection hides files without explanation.
- Import creates plaintext managed originals when encrypted-only policy applies.
- Timeline/search/files view uses demo data or stale cache instead of live API.
- Device pairing fails due to URL, token, QR, permission, or network mismatch.
- Remote routes expose desktop/admin APIs.
- Upload/download cannot resume or cancel.
- Availability state is hidden or misleading.
- Backup verify passes despite missing originals, chunks, DB, or model files.

### Metrics And SLO Candidates

- `first_library_created`: encrypted library created successfully.
- `first_import_completed`: at least one mixed file import committed.
- `first_organization_result_seen`: timeline/files/search view shows live data.
- `first_device_paired`: one trusted device joins a group.
- `first_transfer_completed`: upload or download completes with hash/size check.
- `availability_state_visible`: user can inspect local/remote/protected state.
- `backup_verify_success`: backup readiness returns complete evidence.

SLO candidates:

- 99% of supported desktop launches reach `/health` within 10 seconds.
- 99.9% of committed imports preserve checksum integrity and dedupe state.
- 100% of remote desktop/admin route probes return forbidden.
- 100% of encrypted-only managed imports have verified encrypted chunks.
- 100% of backup restore runs stage into a separate root unless explicitly
  designed otherwise.

### Rollout And Fallback

- Launch with a narrow fixture-backed release smoke before expanding platforms.
- Keep LAN HTTP labeled development-only.
- Prefer Tailscale/HTTPS for remote beta access.
- Show explicit "not indexed yet" or "model not approved" states rather than
  fake results.
- Keep local library access available when subscription checks are temporarily
  unreachable.

## Journey 2: Organize And Rediscover Files

### Steps

1. User imports photos, videos, PDFs, screenshots, documents, audio, archives,
   text files, or project folders.
2. App derives dates, file kinds, folder/source context, sidecar metadata, OCR,
   scenes, places/events where applicable, and future semantic signals.
3. User browses timeline and files.
4. User creates albums, tags, smart folders, project/client/workspace groupings,
   or manual people/place/event corrections.
5. User searches by filename, OCR text, type, date, place, person, project,
   client, workspace, tag, or event.
6. User opens a result and sees metadata, availability, and safe actions.

### Completion Condition

The user finds an important memory or work file faster than folder browsing
alone, without hosted search or AI.

### Failure Modes

- Search results are empty because indexing state is unclear.
- OCR/model gates block value without explanation.
- File types are treated as generic blobs with no organization affordances.
- Corrections are hard to make or are lost during rebuilds.
- Exact GPS or sensitive metadata is exposed too casually.

### Metrics

- Search success rate from local logs or user-consented reports.
- OCR/index coverage percentage.
- Correction count and correction survival after rebuild.
- Time from import completion to first successful search result.

## Journey 3: Pair Devices And Use Shared Storage

### Steps

1. User creates or opens a device group.
2. User invites a device by QR/manual invite.
3. Joining device verifies URL, token, group, and permissions.
4. Device receives a bearer session or equivalent local credential.
5. Device uploads/downloads a file or stores encrypted chunks.
6. App shows device status, storage contribution, transfer progress, and
   revocation controls.

### Completion Condition

At least two trusted devices can exchange or protect files without company-hosted
content storage.

### Failure Modes

- Invite expired, already used, or wrong network.
- Bearer token leaks or persists after revocation.
- Device role is unclear.
- Storage-only device receives searchable metadata it should not have.
- Transfer failure cannot resume or explain what happened.

### Metrics

- Pairing success rate.
- Transfer completion and retry rate.
- Revocation enforcement success.
- Encrypted chunk proof-of-possession success.

## Journey 4: Remote Access Without Hosted Content

### Steps

1. User chooses Tailscale/private network or future relay/discovery.
2. App exposes only approved routes for the remote surface.
3. Remote device pairs or resumes an existing session.
4. User browses, searches, uploads, downloads, or repairs encrypted chunks.
5. App makes network/offline limitations visible.

### Completion Condition

Remote devices work across distance while company systems still cannot inspect or
store user content.

### Failure Modes

- Desktop/admin API leaks remotely.
- Relay/discovery boundary is misunderstood as hosted storage.
- Long-distance transfers fail without retry/resume.
- Offline state hides remote-only files.

### Metrics

- Remote route forbidden checks.
- Remote transfer success rate.
- Relay/discovery lookup success without content exposure.

## Journey 5: Backup, Restore, And Repair

### Steps

1. User runs backup readiness verification.
2. App reports DB, originals/files, encrypted chunks, model files, and missing
   items.
3. User exports backup to a selected root.
4. User plans restore into a separate staging root.
5. User runs restore and reviews staged output.
6. If a chunk is missing locally, app repairs from a trusted replica when
   available.

### Completion Condition

The user can recover without silent corruption, hidden missing data, or
overwriting the active library.

### Failure Modes

- Backup includes secrets or private support material unintentionally.
- Restore overwrites active library.
- Missing/corrupt chunks are silently ignored.
- Model files or encrypted DB cannot be verified.

### Metrics

- Backup verify success.
- Restore staged success.
- Corrupt/missing chunk detection.
- Replica repair success.

## Journey 6: Subscribe Without Content Access

### Steps

1. User chooses a low-cost personal, family/remote, power/workspace, or business
   plan.
2. App records entitlements through privacy-preserving identifiers.
3. Existing local libraries keep safe offline grace.
4. App gates scale/convenience features without blocking core local access.
5. User can see tier limits and upgrade path without exposing content.

### Completion Condition

The company can charge for software and convenience without becoming a content
processor.

### Failure Modes

- Billing identifiers include file names, metadata, device secrets, or search
  content.
- Paid state loss breaks local library access.
- Lowest tier lacks essential features.
- App-store and direct billing rules conflict.

### Metrics

- Entitlement check success.
- Offline grace use and recovery.
- Conversion from activated local library.
- Support tickets caused by tier confusion.

## Journey 7: Business Workspace

### Steps

1. Admin creates a workspace.
2. Admin adds team devices and roles.
3. Team imports project/client folders.
4. Users organize files by project, client, workspace, date, type, OCR, tag, and
   smart folders.
5. Admin reviews device access, audit logs, storage policy, and revocation.
6. Team syncs across office and remote devices without hosted content.

### Completion Condition

A small business can share and find work files while keeping client/project data
on trusted devices.

### Failure Modes

- Role permissions are too coarse.
- Audit logs leak content or are too weak to be useful.
- Workspace search exposes data to unauthorized devices.
- Revocation does not remove access.

### Metrics

- Workspace activation.
- Role assignment completion.
- Unauthorized-access prevention tests.
- Audit event completeness.

## Platform Journey: Release, Install, Update

Each platform must prove the same customer promise with platform-specific
evidence:

- Windows: signed installer, secure storage, daemon launch, import/vault smoke.
- Linux: signed/checksummed package, daemon launch, import/search/vault/backup
  smoke.
- macOS: signing/notarization, keychain validation, privacy prompts, import/vault
  smoke.
- Android/Play Store: release signing, policy disclosures, pairing, upload,
  download, storage-node, revocation.
- iOS/App Store: signing, privacy labels, file/media permissions, secure storage,
  transfer behavior within iOS limits.
- Web/browser: no default company-hosted content, session model, upload/download,
  browser storage limits.
- Local web UI: trusted-device serving, CORS/CSRF review, route isolation,
  LAN/Tailscale exposure rules.
- Direct desktop: checksums/signing, update channel, rollback, support
  diagnostics.
