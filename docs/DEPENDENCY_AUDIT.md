# Dependency And Network I/O Audit

This audit tracks whether current production dependencies perform network I/O or introduce privacy-sensitive behavior.

## Rust Core

| Dependency | Purpose | Network I/O Expected | Notes |
|---|---|---:|---|
| `axum` | Local HTTP API | Server only | Bound to loopback by default. |
| `tower-http` | Trace/CORS layers | No client egress | CORS is restricted to local app origins. |
| `tokio` | Async runtime/TCP listener | Server only | Used for local daemon listener. |
| `rusqlite` / `libsqlite3-sys` | SQLite metadata storage | No | Compiled with bundled SQLCipher support and used for plaintext-to-encrypted DB activation. |
| `keyring` | OS secure key storage | No network expected | Built with native credential-store features (`linux-native-sync-persistent`, `apple-native`, `windows-native`) so SQLCipher keys are stored in OS secure storage; tests use an isolated test file store. |
| `chacha20poly1305` | Vault chunk encryption | No | Seals imported originals into authenticated encrypted chunks with per-chunk nonces and AAD. |
| `zeroize` | Secret memory hygiene | No | Clears in-memory vault keys after use where practical. |
| `reqwest` | Confirm-gated model downloads | Explicit model URLs only | Used only by `/models/install`; indexing jobs must not call it. TLS-only, no redirects, SHA-256 verified before install. |
| `chrono` | Timestamps | No | Local date/time handling. |
| `serde`, `serde_json` | Serialization | No | API/storage payloads. |
| `sha2` | Hashing | No | Media/model integrity checks. |
| `uuid` | IDs | No | Local identifiers. |
| `nom-exif` | Local metadata extraction | No | Parses local media metadata. |
| `thiserror` | Errors | No | No runtime I/O. |
| `tracing`, `tracing-subscriber` | Local logs | No configured remote sink | Keep logs local and avoid sensitive data in future logs. |

## Local System Tools

| Tool | Purpose | Network I/O Expected | Notes |
|---|---|---:|---|
| `tesseract` CLI | Offline OCR indexing | No | Invoked only by `/ocr/rebuild` after encryption is active; OCR text is stored in the encrypted DB. |
| `python3` sidecar | Local scene heuristics and future faces/semantic inference | No network expected | Invoked as a short-lived CLI process, not a server. The daemon sets offline environment guards before every probe/run. |
| `Pillow` / `PIL` | Built-in heuristic scene tagging | No | Reads committed local image files and emits coarse derived tags such as orientation, brightness, tone, and document/greenery/sky hints. |
| Optional Python ML packages (`numpy`, `onnxruntime`, `cv2`) | Future local inference providers | No network expected during app runtime | `/models/runtime-status` reports availability only. Missing packages do not break safe import/OCR/heuristic scenes; model-based inference remains blocked until provider commands and approved local models exist. |

## Flutter Client

| Dependency | Purpose | Network I/O Expected | Notes |
|---|---|---:|---|
| `http` | Calls local Rust daemon | Loopback only | Defaults to `http://127.0.0.1:4821`. |
| `intl` | Date formatting | No | UI formatting. |
| `cupertino_icons` | Icons | No | Build-time asset package. |
| `photo_manager` | Android media library discovery | No network expected | Used only after explicit OS media permission to enumerate local camera-roll assets for future upload queues. |
| `permission_handler` | OS permission prompts | No | Requests camera/media permissions from the user; does not grant access by itself. |
| `path_provider` | App-local filesystem paths | No | Finds the application support directory for local mobile cache/enrollment state. |
| `flutter_secure_storage` | Mobile secret storage | No network expected | Stores pending pairing payloads/session material in platform secure storage. |
| `mobile_scanner` | QR pairing scanner | No network expected | Uses the device camera only after camera permission is granted. |
| `qr_flutter` | Local QR rendering | No | Renders device enrollment claim previews without external services. |

## Policy Notes

- No remote analytics, telemetry, crash reporting, cloud AI, or geocoding dependencies are installed.
- Model download support exists only behind `/models/install`, explicit confirmation, reviewed URL matching, personal/family approval, and SHA-256 verification.
- Indexing jobs must remain isolated from downloader code paths and run from installed local model files only.
- Any future dependency that can perform network I/O must be added to this document before use.
- SQLCipher activation and OS key storage are implemented. Android pairing stores pending enrollment data in platform secure storage. OCR can use local Tesseract; heuristic scene indexing can use the local Python sidecar with Pillow; semantic and face indexing still require approved local model files and provider implementations.
