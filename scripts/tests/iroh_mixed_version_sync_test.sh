#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd -P)"
export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-2}"

# The historical Iroh dependency lives in a detached fixture crate and lockfile
# so it never enters the product's dependency graph or cargo-audit result.
FIXTURE_BIN="$("${SCRIPT_DIR}/iroh_098_peer.sh" build)"
export IROH_098_PEER_BIN="${FIXTURE_BIN}"

cd "${REPO_ROOT}"
cargo test --locked -p native_core --lib \
  sync_transport::tests::mixed_version_iroh_chunk_push_pull \
  -- --exact --ignored
