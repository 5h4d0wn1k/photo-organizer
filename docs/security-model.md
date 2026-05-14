# Security Model

## Default Trust Boundaries

- Media files and derived biometric artifacts stay on user-controlled devices.
- The laptop library is authoritative and should live on an encrypted volume.
- Vault/device membership, replica placement, and sync planning are local control-plane data.
- Phone uploads and P2P transfer execution are deferred in this slice; existing pairing/session and vault sync types remain future-facing for transport.
- No third-party analytics, crash reporters, or cloud AI endpoints are allowed in v1.

## Sensitive Data

- Face templates and labels.
- Exact GPS metadata and derived travel history.
- OCR text and semantic embeddings.
- Pairing secrets, session tokens, and export keys.
- Vault keys, device public keys, capability grants, replica health, relay endpoint IDs, and sync transfer state.
- Feedback events that can reveal family relationships or corrections.

## Required Controls

- App-scoped encryption at rest for the metadata database and sensitive indexes.
- Secure-storage integration for keys on each platform.
- Reset and delete flow for the People feature, including face templates and labels.
- Minimal permissions only, with no background location.
- Explicit separation between organization features, sync, and diagnostics.

## Current MVP Reality

- The current desktop MVP is local-only and does not perform remote network enrichment.
- Imports can either copy originals into the managed library or reference them in place.
- Distributed vault APIs persist vaults, devices, storage policies, blob records, and transfer plans, but they do not upload originals to hosted storage.
- The Flutter client avoids mock fallback data and only renders what the local daemon actually knows.
- The SQLite schema, derived entity metadata, SQLCipher activation, and secure key storage path are in place. Sensitive indexing still requires approved local models and provider implementations.

## Expansion Gate

If the product later adds cloud sync, shared libraries, or remote biometric processing, the system must be re-reviewed for:

- GDPR Article 6 and Article 9 processing.
- UK ICO biometric expectations around explicit consent.
- Illinois and Texas biometric obligations.
- India DPDP duties expected to matter by May 13, 2027.
