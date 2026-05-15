# Phase 1 Foundation Hardening

This slice prepares the local organizer for future faces, scenes, and semantic search while enabling encrypted local OCR.

## Implemented

- SQLite schema uses additive migrations instead of dropping all known tables on version mismatch.
- SQLCipher activation backs up plaintext DBs, exports to encrypted DBs, verifies row counts and integrity, and stores the per-library key through secure storage.
- Durable job records now include cancel/retry metadata, and job logs are persisted separately.
- Manual correction records are persisted for date, place, and event-title changes.
- Backup verification checks database hash, managed asset availability, encrypted vault chunk availability, and installed model-file availability. Backup export writes a manifest-backed copy layout, and restore staging is explicit and non-destructive.
- Privacy status reports the encryption gate and only allows sensitive-indexing eligibility after encrypted storage is active.
- Offline OCR indexing uses the local Tesseract CLI and stores OCR blocks in the encrypted database.

## Security Boundary

- No network is used by metadata, places, events, search, or blocked people-index jobs.
- OCR data must not be generated while `sensitive_indexing_allowed=false` or when the local Tesseract provider is missing.
- Real face/scene/semantic provider implementations remain gated behind approved local model files.

## Verification

- Migration preservation is covered by storage tests.
- Job logs/retry, correction application, backup verification, SQLCipher activation, OCR indexing/search, and offline rebuild behavior are covered by service tests.
- Real photo folders are not touched by automated tests.
