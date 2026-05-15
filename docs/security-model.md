# Security Model

## Default Trust Boundaries

- Media files and derived biometric artifacts stay on user-controlled devices.
- The laptop library is authoritative and should live on an encrypted volume.
- Vault/device membership, replica placement, and sync planning are local control-plane data.
- Desktop P2P sync moves encrypted vault chunks between enrolled devices over Iroh. Android sync currently uses an explicitly configured desktop LAN URL plus bearer-authenticated mobile endpoints; native Android Iroh transport is future work.
- Imported originals are sealed into authenticated encrypted vault chunks. The plaintext original may be restored through the local original endpoint when the local encrypted chunks are present.
- Backup export includes available encrypted vault chunks and writes a manifest; restore requires explicit confirmation and stages files into a separate restore root instead of overwriting the active library.
- No third-party analytics, crash reporters, or cloud AI endpoints are allowed in v1.

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
- For hotspot/LAN mobile access, non-loopback binding is allowed only when `PRIVATE_GALLERY_ALLOW_REMOTE_MOBILE=1` is set. Non-loopback clients are restricted to `/mobile/*` and `/health`; desktop control APIs remain loopback-only and should return `403` remotely. Tailscale Serve identity headers are also treated as remote access even when the proxy connects to the daemon over loopback.

## Current MVP Reality

- The current desktop MVP is local-only and does not perform remote network enrichment.
- Imports can either copy originals into the managed library or reference them in place.
- Distributed vault APIs persist vaults, devices, storage policies, encrypted blob records, key envelopes, transfer plans, mobile sessions, and mobile upload receipts, but they do not upload originals to hosted storage.
- Android upload/download is limited to paired local desktop daemon access over a trusted hotspot/LAN URL such as `http://<laptop-hotspot-ip>:4821`. Uploads are byte-count checked, content-hash verified when provided, deduped by checksum, then copied into the managed library and sealed into encrypted vault chunks. Hosted photo storage is not part of this path.
- The Flutter client avoids mock fallback data and only renders what the local daemon actually knows.
- The SQLite schema, derived entity metadata, SQLCipher activation, and secure key storage path are in place. Sensitive indexing still requires approved local models and provider implementations.

## Expansion Gate

If the product later adds cloud sync, shared libraries, or remote biometric processing, the system must be re-reviewed for:

- GDPR Article 6 and Article 9 processing.
- UK ICO biometric expectations around explicit consent.
- Illinois and Texas biometric obligations.
- India DPDP duties expected to matter by May 13, 2027.
