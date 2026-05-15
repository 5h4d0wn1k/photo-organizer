# Architecture Overview

## Topology

- `Flutter app` renders setup, import, timeline, people, places, events, search, jobs, and library settings.
- `Rust core` owns ingestion, metadata storage, derived views, and the local API.
- `Primary laptop` is the authoritative library host.
- `Vault/device sync control plane` tracks authorized devices, storage policy, encrypted blob placement, availability, and planned transfers.
- `Encrypted vault store` seals originals into authenticated chunks under the library root so local restore and storage-only replication can operate on ciphertext.
- `Mobile clients` and direct Iroh P2P transfer execution are deferred in this slice, but pairing/session and vault sync API types remain in the core model.

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
8. The daemon materializes imported originals as content-addressed encrypted vault chunks with a local replica record.
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
- `VaultKeyEnvelope`
- `SyncPlan`
- `SyncTransfer`
- `SyncConflict`
- `SyncNetworkStatus`
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
- `GET /sync/network/status`
- `POST /sync/network/start`
- `POST /sync/network/stop`
- `POST /sync/transfers/:id/retry`
- `POST /sync/transfers/:id/cancel`
- `POST /backup/verify`
- `POST /backup/export`
- `POST /backup/restore/plan`
- `POST /backup/restore/run`
- `GET /assets/:id/original`
- `GET /assets/:id/availability`
- `POST /assets/:id/pin-local`
- `POST /assets/:id/evict-local`

## Implementation Defaults

- `SQLite` in WAL mode as metadata storage for v1.
- Content-addressed object storage under the chosen library root plus authenticated encrypted vault chunks under `vaults/`.
- Local backup export copies the SQLite database, available managed/reference originals, encrypted vault chunks, and optional installed model files into a manifest-backed layout. Restore is a confirmed staging operation into a separate root, not an overwrite of the active library.
- Scan and import jobs recorded as first-class state.
- Place and event derivation from current metadata and manual hints.
- Default vault policy is `protected_min_2`; imported originals are immediately marked `under_replicated` until another healthy replica exists.
- Local chunk encryption uses ChaCha20-Poly1305 with per-chunk nonces, authenticated associated data, plaintext SHA-256 content IDs, and ciphertext hash verification before decrypt/restore.
- Hosted services are modeled only as discovery/relay fallback; hosted photo, thumbnail, OCR, face, embedding, metadata, and key storage remain out of scope.
- No remote ML, analytics, or geocoding by default.

## Current MVP Boundaries

- `People` and `search` are preserved as live API surfaces. OCR and heuristic scene tags can run locally after encryption; face and semantic providers still require approved local model imports plus provider commands.
- File selection is manual-path-based in the desktop client.
- Direct P2P networking is represented by sync/network status and durable transfer records; the runtime transport adapter is still pending.
- Desktop shells are generated for Linux, macOS, and Windows, but native platform build prerequisites must still be installed on the host machine.
