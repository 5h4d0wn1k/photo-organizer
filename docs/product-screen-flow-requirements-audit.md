# Private Gallery Product, Screen, Flow, And Roadmap Audit

This audit is based on the repository docs, Flutter screens, Rust API/domain surface, Supabase bootstrap schema, and local operating-system audit as of this checkout.

## Audited Sources

- `README.md`
- `app/README.md`
- `docs/architecture.md`
- `docs/security-model.md`
- `docs/PRIVACY.md`
- `docs/MODEL_REGISTRY.md`
- `docs/FOUNDATION_HARDENING.md`
- `docs/desktop-development.md`
- `docs/DEPENDENCY_AUDIT.md`
- Flutter app screens under `app/lib/src/features`
- Flutter data/repository/client layer under `app/lib/src/models`, `app/lib/src/repositories`, and `app/lib/src/api`
- Rust daemon API/domain/service/storage under `native_core/src`
- Supabase metadata bootstrap schema under `supabase/device_group_bootstrap.sql`
- Android/mobile smoke workflow under `scripts/android_mobile_smoke.sh`

## Product North Star

Private Gallery is a private, local-first Google Photos alternative. It should organize photos and videos intelligently while giving the user personal-cloud convenience across phone, desktop, and storage devices without forcing private media into hosted photo storage.

The product is not only a local cloud. The local-cloud layer is the access, sync, availability, and protection system. The larger product goal is media organization and rediscovery: timeline, albums, faces/people, occasions/events, places, OCR text, scenes, semantic search, duplicates, corrections, backup, and long-term preservation.

## Core Goals

- Organize photos and videos like Google Photos while keeping processing local-first.
- Let users create a private device group and join phones, desktops, and storage devices by QR.
- Show one unified library across joined devices when devices are reachable.
- Let a single device keep working independently when other devices are offline.
- Make unavailable media explicit instead of invisible: online, offline, out of network, missing, remote-only, under-replicated, protected.
- Keep originals, thumbnails, OCR text, embeddings, face templates, GPS metadata, vault keys, desktop pairing tokens, mobile bearer tokens, and raw LAN tokens out of cloud services by default.
- Use optional Supabase only for metadata bootstrap: group name, membership, invite hashes, capabilities, endpoint hints.
- Support safe local import, dedupe, move/copy/reference modes, sidecar handling, corrections, backup, restore staging, model governance, and encrypted sensitive indexes.
- Provide mature UI on every platform: phone should open a real gallery after joining, not a debug pairing utility.

## Product Principles

- Private by default: no analytics, cloud AI, remote geocoding, or hosted media storage in v1.
- Local intelligence: metadata, OCR, scene tags, people/faces, search, and future embeddings run from local files only.
- Honest capability: disabled/gated features must say why they are gated.
- Reversible organization: albums, people labels, place corrections, and event titles are metadata changes; media files are not silently moved or deleted.
- Evidence and control: users must understand where media lives, whether it is protected, and what action is needed.
- Device group is the user-facing name for local `Vault`.

## Primary Personas And Devices

- Phone owner: scans QR, uploads camera roll items, browses/searches gallery, sees device/media availability.
- Desktop owner: imports folders, runs indexing, manages vaults/devices, backup/restore, models, storage policy.
- Storage device/NAS: stores encrypted chunks, improves replica protection, may be storage-only.
- Family member/member device: browses and contributes if authorized; future role controls should distinguish owner/admin/contributor/viewer/storage-only.

## Current Desktop Information Architecture

The desktop shell has these top-level destinations:

- Library / Timeline
- Albums
- People
- Places
- Events
- Search
- Vaults
- Jobs
- Settings

Global desktop actions:

- Import media
- Refresh library
- Start daemon / retry when unavailable

## Current Mobile Information Architecture

Mobile starts in onboarding unless a bearer session is saved.

Mobile top-level onboarding:

- Create group
- Join group

Mobile paired workspace tabs:

- Library
- Albums
- People
- Places
- Events
- Search
- Devices
- Activity

## Required Screen Inventory

### 1. Desktop Daemon Unavailable

Purpose: recover when the local Rust daemon is not reachable.

Required UI:

- Status headline
- Failure reason
- Auto-retry state
- Attempted commands
- Start daemon action
- Manual retry action
- Loading/progress indicator
- Error detail area

States:

- Starting daemon
- Waiting for daemon
- Start failed
- API error
- Recovered

### 2. Desktop First-Run Setup

Purpose: initialize the local master library.

Required UI:

- Library root path
- Default import mode: copy, reference, move
- Initial watched folders multiline input
- Local-only/no-cloud safety indicators
- Save setup
- Retry API
- Start daemon
- Live daemon diagnostics

States:

- Not initialized
- Saving
- Invalid empty path
- Diagnostics available/unavailable
- Setup complete

### 3. Desktop Main Shell

Purpose: persistent desktop navigation and workspace context.

Required UI:

- Responsive navigation rail on wide desktop
- Bottom navigation on narrow layouts
- Page title
- Import action
- Refresh action
- Loading bar
- Toast/snackbar feedback

Design requirement:

- This shell should feel like a quiet, powerful media-management app, not a generic admin dashboard.

### 4. Library / Timeline

Purpose: browse the master media timeline.

Required UI:

- Total asset count
- Watch-folder count
- Default import mode summary
- Show archived toggle
- Timeline buckets by month/year
- Photo/video grid
- Load-more pagination
- Bulk selection mode
- Select visible
- Clear selection
- Bulk favorite
- Bulk archive
- Bulk add to album
- Empty state
- Archived-only hidden state
- Asset detail dialog/sheet

Asset detail requirements:

- Filename
- Media kind
- MIME type
- Captured date
- Date source
- Dimensions
- Place/folder hint
- GPS if present
- Import mode
- Availability
- Favorite/archive state
- Bytes
- Content hash
- Library path
- Source path
- Sidecar title/description
- Favorite/unfavorite
- Archive/unarchive
- Assign person
- Add to album

Future UI:

- Full-screen media viewer with swipe, zoom, video playback, metadata drawer, availability drawer, and keyboard shortcuts.

### 5. Import Media

Purpose: safely scan and commit local media imports.

Required UI:

- Source path
- Source kind: selected folder/removable drive
- Import mode: copy/reference/move
- Optional place hint
- Add as watched source toggle
- Recursive scan toggle
- Read-only scan action
- Organized archive presets
- Safety pills: local only, no cloud upload, sidecars kept, hash verified move
- Error panel
- Preflight summary
- Candidate list with selected/duplicate/unsupported states
- Move safety confirmation
- Commit action
- Select non-duplicates
- Commit result
- Recent import sessions

Import candidate requirements:

- Filename/path
- Media kind
- MIME
- Bytes
- Captured date
- Duplicate status
- Unsupported status
- Sidecar paths
- Selected state
- Destination or failure after commit

### 6. Albums

Purpose: manual local collections.

Required UI:

- Create album
- Album cards
- Favorites built-in collection
- Archive built-in collection
- Album detail grid
- Rename album
- Delete album
- Remove asset from album
- Empty album state

Rules:

- Album changes are metadata only.
- Media files must not move/delete/upload when changing album membership.

Future UI:

- Drag/drop or multi-select add/remove.
- Album covers.
- Shared/group-visible album permissions.

### 7. People / Faces

Purpose: organize by people, eventually face clustering.

Required UI:

- Face indexing gate card
- Encryption status
- Required model status chips
- Start local face indexing or check gate
- Confirm-gated reset people data
- Create manual person
- People list/cards
- Person detail grid
- Rename person
- Hide/unhide
- Reject match
- Merge person
- Split face template
- Remove asset assignment
- Empty state explaining model/encryption gate

Privacy requirements:

- Face indexing is biometric and must be blocked until encryption is active and local face models are approved with pinned hashes.
- Manual people assignment and person metadata edits must refresh the visible organization state before automatic face models exist.
- Delete/reset controls must remove sensitive people/face data.

Future UI:

- Face review queue.
- Suggested matches.
- Unknown people inbox.
- Consent-oriented family/person controls.
- Face cluster confidence and merge/split workflows designed for mistakes.

### 8. Places

Purpose: organize by location without online geocoding.

Required UI:

- Place clusters list
- Rebuild local places
- Place asset grid
- Correct place dialog
- Label input
- Optional latitude/longitude
- Hide exact GPS by default
- Empty state

Rules:

- Places come from EXIF GPS, Takeout sidecars, folder/place hints, or manual correction.
- No online geocoding in v1.
- UI should make exact GPS privacy clear.

Future UI:

- Map-like visual overview, but privacy-preserving.
- Coarse/private place labels.
- Travel grouping.

### 9. Events / Occasions

Purpose: organize by occasion/time/place/person.

Required UI:

- Event/occasion clusters list
- Rebuild local events
- Event detail asset grid
- Rename occasion/title event
- Title source chip
- Date range
- Asset count
- People count
- Empty state

Rules:

- Event title corrections must survive rebuilds.
- Events are derived from local timestamps and place hints.

Future UI:

- “Memories” and highlights.
- Event merge/split.
- Event cover selection.

### 10. Search

Purpose: unified local search and indexing control.

Required UI:

- Search field
- Find action
- Search index status card
- Filename/metadata/OCR/scenes/semantic readiness
- OCR coverage progress
- Run next OCR batch
- Run next scene-tag batch
- Search results grouped by assets, people, places, events
- Empty search state
- No results state
- Search failed state
- OCR batch success/failure
- Scene batch success/failure

Rules:

- Search must be honest: no demo results.
- OCR requires encryption and local Tesseract.
- Scenes currently use local heuristic image analysis.
- Semantic search remains future/gated until approved local embedding model exists.

Future UI:

- Filter chips: date range, people, place, media kind, device, favorites, archived, screenshots/documents.
- Natural language search once local semantic embeddings are approved.

### 11. Vaults / Device Groups

Purpose: manage local-cloud/device-group membership, availability, protection, and transfer state.

Required UI:

- Create group
- Add device
- Join group
- Run P2P sync
- Start/stop P2P network
- Copy local endpoint
- Paste peer endpoint
- Add storage placeholder
- Network status panel
- Protection repair panel with previewed under-replicated blobs, runnable transfers, and conflicts
- Vault/group status list
- Devices list
- Transfers list
- Retry transfer
- Cancel transfer
- Invite QR dialog
- Invite JSON copy
- Desktop LAN URL input
- Phone name input
- Cloud/hybrid invite paste dialog

Group status requirements:

- Group/vault name
- Storage policy mode
- Local available assets
- Total assets
- Under-replicated blobs
- Required replica count
- Protection satisfied/unsatisfied

Device requirements:

- Display name
- Platform
- Trust level
- Role/capability
- Active/revoked/offline state
- Accepts storage
- Last seen

Future UI:

- Role management: owner/admin/contributor/viewer/storage-only.
- Device revocation and rekeying.
- Storage policy editor.
- Per-device media availability.
- Real transfer details with source/target device names.

### 12. Jobs / Activity

Purpose: operational history and recovery.

Required UI:

- Jobs list
- Job status chip
- Progress bar
- Queued/started/completed timestamps
- Retry-of and attempt count
- View logs dialog
- Cancel queued/running job
- Retry failed/aborted job
- Empty state
- Refresh

Job types:

- Import
- Metadata
- OCR
- Scene
- People
- Search
- Backup
- Restore
- Sync

### 13. Settings

Purpose: advanced local library, privacy, backup, model, and watch-folder management.

Required UI:

- Library root
- Default import mode
- Save settings
- Backup export path
- Restore staging path
- Verify backup readiness
- Export restorable backup
- Plan restore
- Stage restore
- Watch folders list
- Add watch folder
- Remove watch folder
- Recursive toggle
- Open one-off import
- Privacy status
- Activate encrypted database
- Model runtime status
- Model id/path/hash inputs
- Import local model
- Verify installed model
- Model list and model status
- Local-only safety explanations

Backup/restore requirements:

- Restore must stage to a separate root, not overwrite active library.
- Backup verification must expose missing DB/assets/vault chunks/model files.

Model governance requirements:

- Manual local model import preferred.
- Exact SHA-256 required.
- Face/semantic/model-scene features stay disabled until approved.

### 14. Mobile Onboarding Overview

Purpose: start or join a device group from phone.

Required UI:

- Create group
- Join group
- Group name input
- Cloud bootstrap unavailable state
- Metadata-only group explanation
- Add desktop/storage next-step explanation
- Existing cloud group panel
- Invite QR display for cloud-created group

### 15. Mobile Join Group

Purpose: QR-first joining.

Required UI:

- Full QR scanner
- Stop scanning
- Manual fallback toggle
- Desktop URL input
- Invite JSON/token input
- Save invite
- Device name input
- Pair now / Join group
- Back
- Expired invite state
- Used invite state
- Wrong invite/group state
- Desktop offline state
- Cloud metadata-only join state

QR payload requirements:

- `type`
- `version`
- `action`
- `mode`
- `group_id`
- `group_name`
- `expires_at`
- For LAN: `base_url`, `pairing_token`, `vault_id`
- For cloud: `cloud_invite_id`, one-time invite secret

### 16. Mobile Paired Workspace

Purpose: proper gallery after joining.

Required UI:

- Refresh
- Upload
- Check session
- Group summary
- Library tab
- Albums tab
- People tab
- Places tab
- Events tab
- Search tab
- Devices tab
- Activity tab
- Error/offline banner

Mobile capabilities:

- Browse visible group library.
- Search local indexes through paired desktop.
- Upload camera-roll media.
- Download available originals with resumable byte-range requests.
- View albums/people/places/events.
- See group devices and protection.
- See recent jobs/activity.

Mobile restrictions:

- No storage policy management.
- No desktop folder imports.
- No model management.
- No backup/restore.
- No hosted media sync by default.

### 17. Mobile Gallery

Purpose: browse group media from phone.

Required UI:

- Photo/video grid
- Asset tile
- Preview image where available
- Video placeholder
- Available/unavailable indicator
- Empty state
- Upload prompt
- Loading indicator
- Error state

Future UI:

- Native gallery-grade viewer, not a bottom-sheet debug preview.
- Albums/people/place/event drilldowns.
- Filters and sorting.
- Camera roll backup queue.

### 18. Mobile Media Viewer

Purpose: view and save a single group asset.

Required UI:

- Full-screen preview
- Original filename
- Captured date
- Size
- Media kind
- Availability state
- Download/save original
- Favorite/archive
- Related person/place/event
- Unavailable/offline explanation

Future UI:

- Swipe navigation.
- Video playback.
- Pin local / evict local once mobile storage becomes supported.

## Required Design Components

Core primitives:

- App shell
- Navigation rail
- Mobile bottom navigation
- Top app bar
- Icon button
- Primary button
- Secondary button
- Destructive button
- Text field
- Text area
- Select/dropdown
- Segmented control
- Switch
- Checkbox
- Filter chip
- Status chip
- Progress bar
- Toast/snackbar
- Dialog
- Bottom sheet
- Full-screen media viewer

Media components:

- Asset tile
- Video tile
- Unavailable media tile
- Timeline bucket header
- Asset grid
- Media metadata row
- Favorite/archive controls
- Media availability badge

Organization components:

- Album card
- Person card
- Place row/card
- Event row/card
- Search result group
- Empty state panel
- Correction dialog
- Merge/split people dialog

Device/sync components:

- Device card
- Device status badge
- Storage meter
- Protection summary
- Transfer row
- Network status panel
- Invite QR card
- Endpoint JSON copy/paste panel

Security/ops components:

- Privacy status card
- Encryption gate card
- Model status card
- Backup readiness panel
- Restore plan panel
- Job card
- Job logs viewer

## State Matrix To Design

- Loading
- Saving
- Empty
- Partial data
- Error
- Offline desktop
- Offline phone
- Device out of network
- Session expired
- Invite expired
- Invite already used
- Wrong network
- Permission denied
- Permission limited
- Upload pending
- Upload failed
- Download unavailable
- Search index not ready
- OCR partially indexed
- Encryption not active
- Model not installed
- Model hash mismatch
- Under-replicated vault
- Protected vault
- Missing source file
- Duplicate import candidate
- Unsupported import candidate
- Restore blocked
- Revoked device

## Critical User Journeys

### Journey 1: First Desktop Setup To First Gallery

1. User opens desktop app.
2. App starts or reaches daemon.
3. User chooses library root and import mode.
4. User adds initial watched folder.
5. User opens import.
6. User scans source.
7. User reviews candidates.
8. User commits import.
9. App returns to library timeline.

Completion condition: imported photos/videos appear in timeline without duplicate/demo data.

Failure points: daemon missing, invalid paths, source contains managed library, duplicates only, move confirmation missing, missing source files, unsupported files.

### Journey 2: Organize Like Google Photos

1. User imports media.
2. Timeline groups by month/year.
3. Places/events derive locally.
4. User creates albums.
5. User assigns people manually or later runs face indexing.
6. User corrects place/event/person metadata.
7. User searches by filename, metadata, OCR, scene, people, place, event.

Completion condition: user can rediscover media by timeline, albums, people, places, events, and search.

Failure points: encryption gate, missing models, no OCR provider, weak filters, derived clusters wrong, corrections not obvious.

### Journey 3: Add Phone By QR

1. Desktop user opens Vaults.
2. User creates group if needed.
3. User taps Add Device.
4. Desktop creates vault-bound pairing session and QR.
5. Phone opens Join group.
6. Phone scans QR.
7. Phone pairs with desktop.
8. Phone lands directly in gallery workspace.

Completion condition: phone can browse/search/upload/download available originals. Original downloads use bounded byte ranges so interrupted saves can retry without forcing the daemon to materialize a whole encrypted-only original in memory.

Failure points: LAN URL wrong, desktop daemon not in remote mobile mode, QR expired, token used, phone camera permission denied, bearer session expired.

### Journey 4: Phone Upload Into Group

1. Phone has paired session.
2. User grants media permission.
3. User chooses upload action.
4. App reserves upload.
5. App sends file chunks by byte offset, shows active upload progress, and can query upload status before retrying or canceling.
6. App completes upload.
7. Daemon verifies size/hash, dedupes, imports asset, seals encrypted vault chunks.
8. Phone refreshes workspace.

Completion condition: uploaded media appears in desktop and phone gallery, or a canceled upload removes staged data and leaves a visible canceled state.

Failure points: permission denied, file unavailable, network interruption, duplicate upload, content hash mismatch, desktop offline.

### Journey 5: Protect Media With Another Device

1. Desktop creates/uses vault.
2. User enrolls storage-capable device or peer endpoint.
3. User starts network.
4. User previews the protection repair plan.
5. User runs P2P sync.
6. Encrypted chunks transfer.
7. Replica health updates.
8. Under-replicated warning clears.

Completion condition: vault policy is satisfied and assets are protected by required replicas.

Failure points: no storage device, peer offline, transfer failed, chunk missing, key missing, low storage, network not started.

### Journey 6: Backup And Restore

1. User opens Settings.
2. User verifies backup readiness.
3. User exports restorable backup.
4. User plans restore into separate staging root.
5. User stages restore.
6. User manually reviews restored files.

Completion condition: backup manifest exists and restore staging succeeds without overwriting active library.

Failure points: missing originals, missing vault chunks, missing model files, corrupt DB, restore root conflict.

## Key Data Flows

### Desktop Startup Flow

Flutter app -> `GET /health` -> `GET /library/status` -> setup required or workspace load. Workspace load gathers timeline, albums, people, places, events, jobs, models, privacy, diagnostics, and settings.

### Import Flow

Flutter Import screen -> `POST /imports/scan` -> candidate list -> `POST /imports/commit` -> asset records, job records, dedupe, sidecar metadata, encrypted vault chunks -> timeline/search/places/events update.

### Timeline And Asset Flow

Flutter Timeline -> `GET /timeline` paginated -> asset grid -> asset detail -> `POST /assets/:id/flags`, album assignment, person assignment, availability queries.

### Search And Intelligence Flow

Search screen -> `GET /search/status` -> optional `POST /ocr/rebuild` or `POST /scenes/rebuild` -> `GET /search` -> assets, people, places, events. Future face/semantic flows require encryption and approved local models.

### People Flow

Manual person creation/assignment is active. Automatic face indexing is gated by encryption and local approved face detector/embedding models. Future face templates and clusters must be encrypted and resettable.

### Vault Sync Flow

Imports create encrypted vault chunks and local replicas. Vaults screen tracks vaults/devices/storage policy/replica health/transfers. Desktop P2P moves encrypted chunks. Mobile LAN uses bearer-authenticated `/mobile/*` endpoints with resumable media upload chunks; native Android vault chunk sync is future.

### Mobile Pairing Flow

Desktop creates `DevicePairing` with optional `vault_id`. QR contains LAN URL and one-time pairing token. Phone scans QR, calls `/mobile/pair`, receives bearer token once, stores token in secure storage. Daemon stores only token hash.

### Mobile Workspace Flow

Phone calls `/mobile/workspace` with bearer token. Daemon validates session, scopes visible assets by vault, returns session, timeline, albums, people, places, events, jobs, vault status, devices, sync network, and mobile capabilities.

### Cloud Bootstrap Flow

Phone or desktop creates/joins metadata-only group through Supabase anonymous auth. Cloud stores group/membership/invite hash metadata only. Local protected backup/sync begins only when desktop/storage joins local vault.

## API Surface Groups

- Health/diagnostics: `/health`, `/diagnostics`, `/privacy/status`
- Library/settings: `/library/status`, `/library/settings`, `/watch-folders`
- Import: `/imports/scan`, `/imports/commit`, `/imports/sessions`
- Timeline/assets: `/timeline`, `/assets/*`
- Albums: `/albums/*`
- People: `/people/*`
- Places: `/places/*`
- Events: `/events/*`
- Search/intelligence: `/search`, `/search/status`, `/ocr/rebuild`, `/scenes/rebuild`, `/semantic/rebuild`
- Jobs: `/jobs/*`
- Vault/device/sync: `/vaults/*`, `/devices/*`, `/sync/*`
- Backup/security/models: `/backup/*`, `/security/*`, `/models/*`
- Mobile-only remote boundary: `/mobile/*`

## Current Implemented Features

- Rust daemon with persisted SQLite metadata.
- Flutter desktop app with daemon bootstrap.
- Setup, import, timeline, albums, people, places, events, search, vaults, jobs, settings screens.
- Folder/removable-drive scan and commit.
- Copy/reference/move import modes.
- Hash dedupe.
- Sidecar handling.
- Timeline pagination.
- Favorites and archive.
- Manual albums.
- Manual people creation/assignment.
- Place/event derivation and corrections.
- OCR batches through local Tesseract after encryption.
- Local heuristic scene tagging.
- Encrypted DB activation.
- Encrypted vault chunk storage.
- Backup verification/export/restore staging.
- Model governance and local model import/verify.
- Vault/device/sync control plane.
- Desktop P2P encrypted chunk sync through Iroh.
- Android QR/manual onboarding.
- Android secure session storage.
- Mobile upload/download/list/preview/workspace/search/availability/flags over authenticated LAN API. Upload uses offset chunks, status, complete, and cancel; original download uses bounded `Range` requests.
- Optional Supabase metadata-only bootstrap.

## Gated Or Partial Features

- Face clustering: API/model gates exist; real provider not active until local models are approved/imported.
- Semantic search: API/model gates exist; vector provider/index not active.
- Model-based scene classification: registry exists; current scene tags are heuristic.
- Native Android Iroh/background sync: deferred.
- File pickers: paths are manual.
- Offline mobile shadow cache: not implemented.
- Cloud relay/discovery/NAT traversal: optional future.
- Desktop QR scanning for join: not implemented.
- Mobile valid CRUD parity: browse/search/upload/download exists; advanced management remains desktop.
- Production release packaging/CI/operating docs: incomplete.

## Future Roadmap

### Phase 1: Product UX Redesign

- Redesign desktop and mobile IA around `Library`, `Organize`, `Search`, `Devices`, `Activity`, `Settings`.
- Build gallery-grade mobile viewer and desktop media viewer.
- Make availability/protection visible everywhere.
- Replace debug/admin-looking controls with user-centered workflows.
- Add visual design system and component library.

### Phase 2: Organizer Intelligence

- Improve local metadata extraction.
- Add robust screenshot/document/video filters.
- Expand OCR management and coverage.
- Add model-approved face detection and clustering.
- Add face review/merge/split UX.
- Add semantic embeddings once model review passes.
- Add memories/highlights/occasions polish.

### Phase 3: Real Multi-Device Local Cloud

- Native Android encrypted chunk transport.
- Background mobile upload queue.
- Per-device local cache.
- Pin local / evict local on phone.
- Device reachability heartbeats.
- Better conflict handling.
- Storage policy editor.
- Revocation/rekey flow.

### Phase 4: Optional Hosted Metadata/Relay

- Harden Supabase RLS and invite lifecycle.
- Add endpoint discovery/relay hints.
- Optional Tailscale/Cloudflare/Vercel invite landing page.
- Keep hosted media storage out of default product boundary.

### Phase 5: Production Readiness

- CI workflow.
- Release builds for Linux/macOS/Windows/Android.
- Installer/update flow.
- Crash-free local logging without telemetry.
- Product PRFAQ, critical user journeys, ADRs, SLOs, runbooks, rollback docs.
- Visual regression and accessibility test gates.

## Repo Operating-System Gaps

The repo has significant product and code progress but lacks mature operating docs. Highest-priority missing mechanisms:

- Product PRFAQ and critical user journey docs.
- ADRs for local-first sync, Supabase metadata bootstrap, encryption/model gates, and mobile capability boundaries.
- CI workflow and release quality gates.
- SLO/SLI definitions for local startup, import, search, sync, mobile pairing, and backup.
- Service ownership/runbook and deploy/rollback policy.
- Business/monetization/entitlement boundary if this becomes a packaged product.

## Figma/Stitch Deliverables Needed

Create these first:

- Desktop app shell at 1440x900 and 1728x1117.
- Mobile app shell at 390x844 and 430x932.
- Onboarding create/join group flow.
- Desktop library timeline.
- Mobile gallery workspace.
- Full-screen media viewer.
- Import flow.
- Search page.
- People/faces gate and people grid.
- Devices/protection page.
- Backup/settings page.
- Component library with all states in the state matrix.

The first design milestone should prioritize: `Mobile Join`, `Mobile Gallery`, `Media Viewer`, `Desktop Library`, `Import`, `Search`, `Devices/Protection`, and `People/Faces Gate`.
