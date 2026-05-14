# Model Registry

The app lists model candidates honestly before features are active. A model is not usable until its file, expected SHA-256, license, storage path, and review notes are recorded.

## Approval States

- `pending_review`: candidate only; do not run in production features.
- `installed`: local file was imported and matched the expected SHA-256.
- `hash_mismatch`: verification failed; do not run.
- `download_blocked`: network policy or downloader guard blocked installation.
- `not_installed`: reviewed candidate exists but no local file is installed.

## Current Candidates

| ID | Task | Source | License Status | Hash Status | Personal/Family Approved |
|---|---|---|---|---|---|
| `scrfd-face-detector` | Face detection | `https://github.com/deepinsight/insightface` | InsightFace/model license review required | Not pinned | No |
| `arcface-embedding` | Face embedding | `https://github.com/deepinsight/insightface` | InsightFace/model license review required | Not pinned | No |
| `tesseract-ocr-data` | OCR language data | `https://tesseract-ocr.github.io/` | Engine is Apache-2.0; language data varies | System install hashed at runtime | Local CLI allowed |
| `scene-classifier-onnx` | Scene tagging | Not selected | Not reviewed | Not pinned | No |
| `semantic-embedding-onnx` | Semantic embedding | Not selected | Not reviewed | Not pinned | No |

## Before Enabling A Model

1. Confirm the license permits personal/family local use and document restrictions.
2. Pin the exact model file URL and SHA-256.
3. Import the file through `/models/import-local` or the confirmation-gated downloader after the registry entry is approved.
4. Verify `/models/:id/verify` succeeds.
5. Add tests proving the feature runs without network access.

This registry intentionally does not pretend faces, model-based scene tagging, or semantic search are installed before model approval. OCR can run through an already-installed local Tesseract CLI after encrypted storage is active. A built-in heuristic scene tagger is available separately; it is not a downloaded model and only produces coarse local tags.

## Local Runtime Probe

- `/models/runtime-status` reports whether the Python ML sidecar script is present, callable, and launched with offline environment guards.
- A healthy runtime probe does not approve any model and does not unlock faces or semantic search.
- The current `scene-tags` provider is a built-in heuristic analyzer. Model-based scenes and semantic embeddings still require model license review and pinned SHA-256 verification.

## Downloader Guardrails

- `/models/install` fails unless `confirmed=true`, the requested URL exactly matches the reviewed registry URL, and `expected_sha256` is supplied by the request or registry.
- Downloads are blocked when `NetworkPolicy=offline_only`.
- The downloader uses TLS-only requests, does not follow redirects, writes to a temporary file, verifies SHA-256, then atomically installs the model file.
- Every accepted or rejected install attempt is appended to the local model install audit file.
- Indexing jobs never call downloader paths; they can only use already installed local files.
