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
- SQLCipher activation verifies an encrypted staging database, retains its
  verified recovery copy while replacing the live database and publishing
  encryption state, and reconciles the database header with that state during
  startup. This covers interrupted activation and process-crash recovery; it is
  not a guarantee against physical storage failure or sudden power loss after
  the operating system reports a successful sync. Apple documents
  `F_FULLFSYNC` as best effort and notes that data can still be lost on sudden
  power loss ([Apple file-system write guidance](https://developer.apple.com/documentation/xcode/reducing-disk-writes)).
  Users should keep independent backups of important libraries.
- Secure-storage integration for keys on each platform.
- Reset and delete flow for the People feature, including face templates and labels.
- Minimal permissions only, with no background location.
- Explicit separation between organization features, sync, and diagnostics.
- For Tailscale/HTTPS mobile access, expose only `/mobile/*`, `/local-web/*`, and `/health` while the daemon stays loopback-bound. For hotspot/LAN development access, non-loopback binding is allowed only when `PRIVATE_GALLERY_ALLOW_REMOTE_MOBILE=1` is set. Non-loopback clients are restricted to `/mobile/*`, `/local-web/*`, and `/health`; desktop control APIs remain loopback-only and should return `403` remotely. Tailscale Serve identity headers are also treated as remote access even when the proxy connects to the daemon over loopback.
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

### Vault key initialization and recovery

Production vault keys use OS secure storage only. Setting
`PRIVATE_GALLERY_VAULT_KEY_STORAGE=file` (or any value other than `keyring`)
refuses startup before database initialization. Existing `security/vault-keys`
material also blocks startup. Preserve that material and the library; this
version does not include an automatic plaintext-key migration tool. Recovery
requires the exact original key in the OS credential service
`private-gallery-vaults`, under `vault-key:<vault UUID>:v<version>`, followed by
verified decryption. Retain the old material in a separate private offline backup before retiring
its runtime directory; startup continues to refuse that legacy directory even
after the OS entry has been restored. Do not delete the recovery backup before
successful decryption verification.
Do not paste keys into issues, logs, or command-line arguments. A supported
operator migration/recovery UI is still outstanding under #110.
There is currently no supported in-app or command-line workflow to import a
legacy file key, verify it against every encrypted original, and retire the
plaintext copy safely. Keep the entire old runtime directory and a separate
offline backup intact; do not delete `security/vault-keys` or bypass the guard
with a plaintext backend. Existing file-key installations remain a release
blocker until that migration workflow is implemented and tested.

Sealing loads an existing key; it never provisions one implicitly. Before the
first seal, explicit provisioning checks catalog encryption history and the
vault's ciphertext directory. A per-version nonsecret initialization marker is
flushed before writing a new key to OS storage, under a per-version process lock.
An initialized or historically encrypted version with a missing key fails closed:
imports fail and ciphertext is preserved. Unlock an unavailable OS keychain or
restore the exact key from the user's own secure backup. Generating a replacement
under the same key reference cannot recover existing data and is forbidden.

An interrupted first provisioning attempt can leave a provisioning marker
without a stored key. A retry may provision the key only while there is no
encrypted-history record or ciphertext directory for that vault. A marker for
another key version is not proof that ambiguous legacy ciphertext is safe.
Existing OS-stored keys remain usable; automatic rotation into a missing new
key version on a populated vault is unsupported until explicit inventory and
allocation verification exists. Once
there is any such evidence, a missing key requires exact-key recovery and the
app will not generate a replacement. Recovery after actual key loss is
unavailable without a backup.
These changes protect key storage; they do not fix cross-vault isolation (#112)
or complete the remaining #110 recovery tooling.

Provider read/create is additionally serialized across runtime roots using
per-user application locks: `~/.local/share/photo-organizer/vault-key-provider-locks`
on Linux, `~/Library/Application Support/photo-organizer/vault-key-provider-locks`
on Apple platforms, and `%LOCALAPPDATA%/photo-organizer/vault-key-provider-locks`
on Windows. These contain only nonsecret lock files, never keys. Instances
sharing the OS credential store must use the same OS user application directory;
changing HOME/LOCALAPPDATA is not a supported way to isolate a shared key store.
