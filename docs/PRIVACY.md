# Privacy Policy For Local Intelligence

This project is designed for personal/family local organization. The default promise is simple: photos, videos, metadata, thumbnails, OCR text, embeddings, face templates, search queries, feedback events, and usage data must not leave the machine.

## Current Defaults

- The Rust daemon binds to `127.0.0.1` by default.
- Non-loopback daemon binding is rejected unless explicit developer mode is enabled in code.
- Runtime photo processing is local-only. Metadata, event, place, search, face, OCR, and scene jobs must not call network download or enrichment paths.
- No cloud AI, analytics SDKs, telemetry SDKs, remote geocoding, or model training on the private library are enabled.
- Model installation is separate from indexing. Models require explicit confirmation, reviewed URL matching, personal/family approval, and SHA-256 verification before being marked installed. OCR may also use an already-installed local Tesseract CLI.
- SQLCipher support is compiled into the Rust storage dependency. `/security/encryption/activate` backs up the plaintext DB, exports to an encrypted DB, verifies row counts and integrity, stores the library key through OS keychain storage, and then enables sensitive-indexing eligibility.
- Vault originals are sealed into local ChaCha20-Poly1305 encrypted chunks with per-chunk nonces, associated data, plaintext content hashes, and ciphertext hashes. Hosted services are not part of this path.
- Backup export copies local database and file material only to the user-selected path. Restore planning/running uses a separate staging root and does not send backup contents to a hosted service.
- Future face and semantic inference runs through a short-lived local Python sidecar process. `/models/runtime-status` only probes whether that sidecar is callable with offline guards; it does not scan media, open a listener, download models, or enable inference by itself.
- Scene indexing currently uses a built-in local heuristic image analyzer through the Python sidecar. It reads committed local photo files, writes derived tags into the encrypted DB, and never downloads models or sends labels/photos to a remote service.

## Model Use Rules

- Prefer audited open-source model files with pinned SHA-256 hashes and clear license notes.
- Remote model downloads are allowed only for approved registry entries with an exact reviewed URL, explicit confirmation, TLS, no redirect following, a pinned SHA-256, temp download, hash verification, and audit logging. Current model candidates are not approved, so practical installation still uses manual local import.
- `/models/import-local` records only the explicitly provided model file. It does not scan media folders.
- User photos are never uploaded to install, verify, or run models. OCR runs through the local Tesseract CLI only.
- The Python sidecar is a command-line boundary, not a background service. The daemon invokes it with `HF_HUB_OFFLINE=1`, `TRANSFORMERS_OFFLINE=1`, `HF_DATASETS_OFFLINE=1`, `WANDB_DISABLED=true`, `DO_NOT_TRACK=1`, and `NO_PROXY=*`.
- No training on the user library is allowed unless a future opt-in local-only training mode is separately designed.

## Sensitive Data Classes

- Originals and sidecars.
- Capture metadata, GPS, folder hints, and manual corrections.
- Future face templates and embeddings.
- OCR text and future semantic vectors.
- Search queries and feedback events.
- Sync keys and device-pairing secrets when mobile sync is added.

## Manual Offline Check

1. Install any needed model files while online, record expected hashes, then disconnect networking.
2. Start the daemon and app.
3. Import or scan a `/tmp` fixture first.
4. Run metadata/events/places/search rebuilds.
5. Confirm `/privacy/status` reports `photo_processing_network_allowed=false`.
6. Confirm model listing still works from local files only.

Full biometric delete/export controls and semantic/face model inference remain separate hardening milestones. OCR runs locally after encryption is active and the local Tesseract CLI is available; scene tags can run locally through the built-in heuristic analyzer after encryption is active.
