# Security Model

## Default Trust Boundaries

- Media files and derived biometric artifacts stay on user-controlled devices.
- The laptop library is authoritative and should live on an encrypted volume.
- Vault/device membership, replica placement, and sync planning are local control-plane data.
- Desktop P2P sync moves encrypted vault chunks between enrolled devices over Iroh. Android sync uses bearer-authenticated mobile endpoints through Tailscale/HTTPS by default where available; explicitly configured desktop LAN HTTP remains development mode. Native Android Iroh transport is future work.
- Imported managed originals are sealed into authenticated encrypted vault chunks. New libraries default to `encrypted_only`, which removes the managed plaintext original after decrypt/hash verification. A plaintext original may be restored through the local original endpoint when the local encrypted chunks are present. Reference imports remain external and are not protected until copied into the vault.
- Backup export includes available encrypted vault chunks and writes a manifest; restore requires explicit confirmation and stages files into a separate restore root instead of overwriting the active library.
- No third-party analytics, crash reporters, or cloud AI endpoints are allowed in v1.
- Supabase is an optional metadata-only bootstrap boundary for phone-created device groups. It uses anonymous Auth, RLS-protected Postgres tables, and a Postgres RPC for atomic invite claim; Edge Functions and hosted storage are not required for this milestone. It is not part of the default local LAN upload/download path and must not receive media, thumbnails, vault keys, desktop pairing tokens, LAN bearer tokens, OCR text, embeddings, or GPS/capture metadata.

## Sensitive Data

- Face templates and labels.
- Exact GPS metadata and derived travel history.
- OCR text and semantic embeddings.
- Pairing secrets, session tokens, and export keys.
- Mobile bearer tokens. The daemon stores only SHA-256 token hashes; Android keeps the returned token in secure storage.
- Vault keys, device public keys, capability grants, replica health, relay endpoint IDs, and sync transfer state.
- Feedback events that can reveal family relationships or corrections.

## Required Controls

- App-scoped encryption at rest for the metadata database and sensitive indexes.
- Secure-storage integration for keys on each platform.
- Reset and delete flow for the People feature, including face templates and labels.
- Minimal permissions only, with no background location.
- Explicit separation between organization features, sync, and diagnostics.
- For Tailscale/HTTPS mobile access, expose only `/mobile/*` and `/health` while the daemon stays loopback-bound. For hotspot/LAN development access, non-loopback binding is allowed only when `PRIVATE_GALLERY_ALLOW_REMOTE_MOBILE=1` is set. Non-loopback clients are restricted to `/mobile/*` and `/health`; desktop control APIs remain loopback-only and should return `403` remotely. Tailscale Serve identity headers are also treated as remote access even when the proxy connects to the daemon over loopback.
- Cloud bootstrap invites use random one-time secrets, store only SHA-256 secret hashes, expire quickly, and are claimed through a database-side function so acceptance is atomic.

## Current MVP Reality

- The current desktop MVP is local-only and does not perform remote network enrichment.
- Imports can either copy originals into the managed library or reference them in place.
- Distributed vault APIs persist vaults, devices, storage policies, encrypted blob records, key envelopes, transfer plans, mobile sessions, and mobile upload receipts, but they do not upload originals to hosted storage.
- Android upload/download is limited to paired local desktop daemon access over Tailscale/HTTPS or an explicitly enabled trusted hotspot/LAN development URL such as `http://<laptop-hotspot-ip>:4821`. Uploads are reservation-based, size-limited for beta, resumable through offset chunks, explicitly cancelable, byte-count checked at completion, content-hash verified when provided, deduped by checksum, then sealed into encrypted vault chunks. Downloads use bounded byte ranges; when only encrypted vault chunks are present, the daemon decrypts only the intersecting chunk for each range. Hosted photo storage is not part of this path.
- The Android "Create group" path can create only a metadata group until a desktop/storage device joins. It does not enable cloud media sync.
- The Flutter client avoids mock fallback data and only renders what the local daemon actually knows.
- The SQLite schema, derived entity metadata, SQLCipher activation, and secure key storage path are in place. Sensitive indexing still requires approved local models and provider implementations.

## Expansion Gate

If the product later adds cloud sync, shared libraries, or remote biometric processing, the system must be re-reviewed for:

- GDPR Article 6 and Article 9 processing.
- UK ICO biometric expectations around explicit consent.
- Illinois and Texas biometric obligations.
- India DPDP duties expected to matter by May 13, 2027.
