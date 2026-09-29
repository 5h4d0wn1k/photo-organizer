# Architecture Overview

## Topology

- `Flutter app` renders setup, import, timeline, people, places, events, search, jobs, and library settings.
- `Rust core` owns ingestion, metadata storage, derived views, and the local API.
- `Primary laptop` is the authoritative library host.
- `Vault/device sync control plane` tracks authorized devices, storage policy, encrypted blob placement, availability, and planned transfers.
- `Encrypted vault store` seals originals into authenticated chunks under the library root so local restore and storage-only replication can operate on ciphertext.
- `Iroh P2P sync runtime` moves encrypted vault chunks between enrolled desktop peers with direct addresses and relay descriptors.
- `Mobile clients` create or join a device group, pair to a desktop daemon with a vault-bound one-time token, and use bearer-authenticated local API calls for LAN upload/download in this slice.
- `Optional cloud bootstrap` can hold metadata-only group membership, device capabilities, endpoint hints, and hashed invite secrets for phone-created groups; it is not a media, thumbnail, key, or bearer-token store.

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
9. Desktop peers exchange encrypted chunks through the Iroh sync runtime and update replica health as transfers complete.
10. Android clients scan a desktop invite QR, pair with the daemon, reserve uploads, send original chunks, and fetch available originals with bounded `Range` requests through mobile-only bearer-authenticated endpoints.
11. Android clients may create a metadata-only group when a Supabase bootstrap is explicitly configured; private media sync still begins only after a local desktop/storage device joins.
12. Flutter reads timeline, places, events, people, search, jobs, vault status, and asset availability from the live local API.

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
- `MobileSession`
- `MobileUpload`
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

_Generated from `native_core/src/api.rs` by `scripts/generate-api-list.py` -- edit the routes, not this list._

### `/albums`

- `GET /albums`
- `GET /albums/{album_id}`
- `GET /albums/{album_id}/assets`
- `POST /albums/{album_id}/assets/remove`
- `POST /albums/{album_id}/rename`

### `/assets`

- `GET /assets/archived`
- `GET /assets/favorites`
- `POST /assets/flags/bulk`
- `GET /assets/{asset_id}/availability`
- `POST /assets/{asset_id}/evict-local`
- `POST /assets/{asset_id}/flags`
- `GET /assets/{asset_id}/original`
- `POST /assets/{asset_id}/pin-local`
- `POST /assets/{asset_id}/tags`

### `/audit`

- `GET /audit/events`

### `/backup`

- `POST /backup/export`
- `POST /backup/restore/plan`
- `POST /backup/restore/run`
- `POST /backup/restore/verify`
- `POST /backup/verify`

### `/devices`

- `GET /devices`
- `POST /devices/enroll`
- `POST /devices/{device_id}/revoke`

### `/diagnostics`

- `GET /diagnostics`

### `/duplicates`

- `GET /duplicates`

### `/entitlements`

- `GET /entitlements/status`

### `/events`

- `GET /events`
- `POST /events/rebuild`
- `GET /events/{event_id}/assets`
- `POST /events/{event_id}/title`

### `/feedback`

- `POST /feedback`

### `/files`

- `POST /files/folders`
- `GET /files/tree`
- `PATCH /files/{entry_id}`
- `POST /files/{entry_id}/move`
- `GET /files/{entry_id}/original`
- `POST /files/{entry_id}/restore`
- `POST /files/{entry_id}/trash`

### `/health`

- `GET /health`

### `/imports`

- `POST /imports/assets`
- `POST /imports/commit`
- `POST /imports/scan`
- `GET /imports/sessions`
- `GET /imports/sessions/{session_id}`

### `/jobs`

- `GET /jobs`
- `GET /jobs/{job_id}`
- `POST /jobs/{job_id}/cancel`
- `GET /jobs/{job_id}/logs`
- `POST /jobs/{job_id}/retry`

### `/library`

- `GET /library/settings`
- `GET /library/status`

### `/local-web`

- `GET /local-web`
- `GET /local-web/`
- `GET /local-web/{*asset_path}`

### `/metadata`

- `GET /metadata/assets/{asset_id}`
- `POST /metadata/assets/{asset_id}/correct-date`
- `POST /metadata/rebuild`

### `/mobile`

- `GET /mobile/assets`
- `GET /mobile/assets/{asset_id}/availability`
- `POST /mobile/assets/{asset_id}/flags`
- `GET /mobile/assets/{asset_id}/original`
- `GET /mobile/assets/{asset_id}/preview`
- `POST /mobile/assets/{asset_id}/tags`
- `POST /mobile/devices/{device_id}/sessions/revoke`
- `GET /mobile/files/tree`
- `GET /mobile/files/{entry_id}/original`
- `POST /mobile/pair`
- `GET /mobile/search`
- `GET /mobile/session`
- `POST /mobile/session/refresh`
- `POST /mobile/session/revoke`
- `GET /mobile/sessions`
- `POST /mobile/storage-profile`
- `GET /mobile/storage/blobs/{blob_id}/chunks/{chunk_index}`
- `POST /mobile/storage/blobs/{blob_id}/report`
- `GET /mobile/storage/plan`
- `POST /mobile/uploads`
- `GET /mobile/uploads/{upload_id}`
- `PUT /mobile/uploads/{upload_id}/chunks/{offset}`
- `POST /mobile/uploads/{upload_id}/complete`
- `GET /mobile/workspace`

### `/models`

- `GET /models`
- `POST /models/import-local`
- `POST /models/install`
- `GET /models/runtime-status`
- `POST /models/{model_id}/verify`

### `/ocr`

- `GET /ocr/assets/{asset_id}`
- `POST /ocr/rebuild`

### `/pairing`

- `POST /pairing/sessions`

### `/people`

- `GET /people`
- `POST /people/index`
- `POST /people/manual`
- `POST /people/reset`
- `GET /people/{person_id}`
- `GET /people/{person_id}/assets`
- `POST /people/{person_id}/assets/remove`
- `POST /people/{person_id}/hide`
- `POST /people/{person_id}/merge`
- `POST /people/{person_id}/reject-match`
- `POST /people/{person_id}/rename`
- `POST /people/{person_id}/split`

### `/places`

- `GET /places`
- `POST /places/rebuild`
- `GET /places/{place_id}/assets`
- `POST /places/{place_id}/correct`

### `/privacy`

- `GET /privacy/status`

### `/release`

- `GET /release/readiness`

### `/scenes`

- `POST /scenes/rebuild`

### `/search`

- `GET /search`
- `POST /search/rebuild`
- `GET /search/status`

### `/security`

- `GET /security/encryption-status`
- `POST /security/encryption/activate`
- `GET /security/encryption/status`

### `/semantic`

- `POST /semantic/rebuild`

### `/smart-folders`

- `GET /smart-folders`
- `DELETE /smart-folders/{folder_id}`
- `GET /smart-folders/{folder_id}/search`

### `/support`

- `POST /support/bundle`

### `/sync`

- `GET /sync/network/local-endpoint`
- `POST /sync/network/start`
- `GET /sync/network/status`
- `POST /sync/network/stop`
- `GET /sync/plan`
- `POST /sync/run`
- `GET /sync/transfers`
- `POST /sync/transfers/{transfer_id}/cancel`
- `POST /sync/transfers/{transfer_id}/retry`

### `/timeline`

- `GET /timeline`

### `/vaults`

- `GET /vaults`
- `GET /vaults/{vault_id}/status`
- `POST /vaults/{vault_id}/storage-policy`

### `/watch-folders`

- `GET /watch-folders`
- `DELETE /watch-folders/{watch_folder_id}`

## Implementation Defaults

- `SQLite` in WAL mode as metadata storage for v1.
- Content-addressed object storage under the chosen library root plus authenticated encrypted vault chunks under `vaults/`.
- Local backup export copies the SQLite database, available managed/reference originals, encrypted vault chunks, and optional installed model files into a manifest-backed layout. Restore is a confirmed staging operation into a separate root, not an overwrite of the active library.
- Scan and import jobs recorded as first-class state.
- Place and event derivation from current metadata and manual hints.
- Default vault policy is `protected_min_2`; imported originals are immediately marked `under_replicated` until another healthy replica exists.
- Local chunk encryption uses ChaCha20-Poly1305 with per-chunk nonces, authenticated associated data, plaintext SHA-256 content IDs, and ciphertext hash verification before decrypt/restore.
- Mobile sessions store only a SHA-256 bearer-token hash in SQLite; the bearer token is returned once to the Android client and then kept in Android secure storage.
- Mobile upload receives are reservation-based and support resumable offset chunks. Completion verifies size and optional content hash, dedupes by checksum, copies into the managed library, and immediately seals encrypted vault chunks.
- Abandoned or user-canceled mobile uploads can be canceled explicitly; the daemon marks the receipt canceled, removes staged chunk files, and rejects later chunks for that upload id.
- Original downloads advertise `Accept-Ranges: bytes`; mobile clients use bounded range requests so encrypted-only originals can be served by decrypting only the intersecting vault chunk instead of materializing the entire original.
- Daily-driver v1 mobile sync uses a trusted hotspot/LAN URL such as `http://<laptop-hotspot-ip>:4821`. `scripts/private_gallery_mobile_lan_daemon.sh` binds `0.0.0.0:4821` only when `PRIVATE_GALLERY_ALLOW_REMOTE_MOBILE=1` is set.
- Desktop invites are QR-first and include the current LAN URL, vault id, and one-time pairing token. The token is stored server-side only for pairing and sessions persist bearer-token hashes.
- Optional Supabase bootstrap is configured through Flutter `--dart-define` values and `supabase/device_group_bootstrap.sql`; it uses anonymous Auth, RLS-protected tables, and a Postgres RPC for invite claim. It stores only group names, anonymous membership records, client device ids, optional public keys/capabilities/endpoint hints, invite hashes, and timestamps.
- The daemon injects remote socket information at serve time and blocks non-loopback clients from desktop control routes. It also treats Tailscale Serve identity headers as remote, so path-limited Serve exposure for `/mobile`, `/local-web`, and `/health` does not expose desktop APIs through the loopback proxy. `/local-web/*` serves only the configured built web bundle from `PRIVATE_GALLERY_LOCAL_WEB_ROOT`.
- Hosted services are modeled only as discovery/relay fallback; hosted photo, thumbnail, OCR, face, embedding, metadata, and key storage remain out of scope.
- No remote ML, analytics, or geocoding by default.

## Current MVP Boundaries

- `People` and `search` are preserved as live API surfaces. OCR and heuristic scene tags can run locally after encryption; face and semantic providers still require approved local model imports plus provider commands.
- File selection is manual-path-based in the desktop client.
- Desktop P2P networking is implemented through the Iroh runtime. Mobile LAN media uploads support resumable offset chunks; native Android Iroh transport, background sync scheduling, native vault chunk sync, and hosted discovery/relay deployment remain future hardening work.
- Desktop shells are generated for Linux, macOS, and Windows, but native platform build prerequisites must still be installed on the host machine.
