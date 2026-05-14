# Architecture Overview

## Topology

- `Flutter app` renders setup, import, timeline, people, places, events, search, jobs, and library settings.
- `Rust core` owns ingestion, metadata storage, derived views, and the local API.
- `Primary laptop` is the authoritative library host.
- `Vault/device sync control plane` tracks authorized devices, storage policy, blob placement, availability, and planned transfers.
- `Mobile clients` and actual P2P transfer execution are deferred in this slice, but pairing/session and vault sync API types remain in the core model.

## Data Flow

1. Flutter checks the daemon health endpoint and loads `GET /library/status`.
2. If the library is not initialized, the app saves `library_root` and default import mode through `POST /library/settings`.
3. Users can add persistent watch folders with `POST /watch-folders`.
4. Imports happen in two steps:
   - `POST /imports/scan` for folders or removable drives
   - `POST /imports/commit` to import selected candidates
5. In `copy` mode, originals are copied into the library's content-addressed object store.
6. In `reference` mode, originals stay in place and the daemon stores an external path reference.
7. The daemon persists assets, sessions, jobs, and derived place/event groupings to SQLite.
8. The daemon materializes imported originals as content-addressed vault blobs with a local replica record.
9. Flutter reads timeline, places, events, people, search, jobs, vault status, and asset availability from the live local API.

## Core Domain Entities

- `Asset`
- `AssetVariant`
- `PersonCluster`
- `PlaceCluster`
- `EventCluster`
- `FaceTemplate`
- `FeedbackEvent`
- `DevicePairing`
- `SyncSession`
- `Vault`
- `VaultMember`
- `DeviceIdentity`
- `StoragePolicy`
- `BlobRecord`
- `BlobChunk`
- `BlobReplica`
- `SyncPlan`
- `SyncTransfer`
- `SyncConflict`
- `SearchQuery`
- `JobRecord`
- `LibrarySettings`
- `WatchFolder`
- `ImportSession`
- `ImportCandidate`

All derived entities carry:

- `model_name`
- `model_version`
- `created_at`
- `rebuildable = true`

## Local API Surface

- `GET /library/status`
- `GET /library/settings`
- `POST /library/settings`
- `GET /watch-folders`
- `POST /watch-folders`
- `DELETE /watch-folders/:id`
- `POST /pairing/sessions`
- `POST /imports/assets`
- `POST /imports/scan`
- `POST /imports/commit`
- `GET /imports/sessions/:id`
- `GET /timeline`
- `GET /people`
- `POST /people/:id/merge`
- `POST /people/:id/split`
- `GET /places`
- `GET /events`
- `POST /events/:id/title`
- `POST /feedback`
- `GET /search`
- `GET /jobs`
- `GET /vaults`
- `POST /vaults`
- `GET /vaults/:id/status`
- `POST /vaults/:id/storage-policy`
- `GET /devices`
- `POST /devices`
- `POST /devices/enroll`
- `POST /devices/:id/revoke`
- `GET /sync/plan`
- `POST /sync/run`
- `GET /sync/transfers`
- `GET /assets/:id/availability`
- `POST /assets/:id/pin-local`
- `POST /assets/:id/evict-local`

## Implementation Defaults

- `SQLite` in WAL mode as metadata storage for v1.
- Content-addressed object storage under the chosen library root.
- Scan and import jobs recorded as first-class state.
- Place and event derivation from current metadata and manual hints.
- Default vault policy is `protected_min_2`; imported originals are immediately marked `under_replicated` until another healthy replica exists.
- Hosted services are modeled only as discovery/relay fallback; hosted photo, thumbnail, OCR, face, embedding, metadata, and key storage remain out of scope.
- No remote ML, analytics, or geocoding by default.

## Current MVP Boundaries

- `People` and `search` are preserved as live API surfaces, but this slice does not yet compute face clusters, OCR, or semantic embeddings.
- File selection is manual-path-based in the desktop client.
- Desktop shells are generated for Linux, macOS, and Windows, but native platform build prerequisites must still be installed on the host machine.
