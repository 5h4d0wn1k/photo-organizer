# Iroh 0.98.2 sync interoperability peer

This isolated test fixture builds against exactly Iroh 0.98.2. It is not a
production executable and must not be used to handle personal libraries. It
independently implements the Photo Organizer v1 framed Push/Pull wire contract,
allowing the test to exercise a real 0.98.2 Iroh endpoint against the
production 1.x sync runtime. It does not build or run the historical 0.98.2
Photo Organizer application; full old-app/new-app compatibility remains an
open acceptance gate.

The peer binds only to `127.0.0.1`, disables relays and all hosted address lookup services, refuses non-loopback client
targets, and applies 15-second network operation timeouts. Key material is read
from a test-only file and is never printed. Its `Cargo.lock` is intentionally
local to this nested crate; the old dependency graph must not enter the main
workspace lockfile.

Run `scripts/tests/iroh_098_peer.sh --help` for the stable CLI contract. Use
`server --operation receive-push --output-dir DIR` to receive and verify one
Push, or `server --operation serve-pull --manifest FILE --chunks-dir DIR` to
serve one Pull. Use client `--operation push` with a manifest and chunk
directory, or `--operation pull` with a Pull request JSON and output directory.
Manifest chunk files are named `00000000.pgblob`, `00000001.pgblob`, and so on.

The server emits one JSON `ready` line before accepting one connection, then
emits one JSON `complete` line. Client mode emits one JSON `complete` line.
Completion reports `verified`, encrypted bytes verified, chunk count, and the
verified SHA-256 values. Errors go to stderr and return non-zero. The helper
enforces 15-second I/O timeouts and accepts only direct loopback targets.
