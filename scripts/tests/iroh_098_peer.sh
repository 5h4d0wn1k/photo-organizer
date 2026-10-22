#!/usr/bin/env bash
set -euo pipefail

export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-2}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd -P)"
CRATE_DIR="${REPO_ROOT}/native_core/tests/fixtures/iroh-098-peer"
MANIFEST="${CRATE_DIR}/Cargo.toml"
BASE_TARGET_DIR="${CARGO_TARGET_DIR:-${REPO_ROOT}/target}"
FIXTURE_TARGET_DIR="${BASE_TARGET_DIR}/iroh-098-peer"
PEER_BIN="${FIXTURE_TARGET_DIR}/debug/iroh-098-interop-peer"

usage() {
  cat <<'USAGE'
Build the isolated Iroh 0.98.2 test peer and run its loopback-only CLI.

  scripts/tests/iroh_098_peer.sh build
  scripts/tests/iroh_098_peer.sh --help
  scripts/tests/iroh_098_peer.sh server --key-file FILE --operation receive-push|serve-pull ...
  scripts/tests/iroh_098_peer.sh client --key-file FILE --operation push|pull ...

The fixture has its own Cargo.lock and target directory. Its stdout is JSONL:
server mode emits `ready`, then `complete`; client mode emits `complete` only.
USAGE
}

if (($# == 0)); then
  usage >&2
  exit 2
fi

if [[ "$1" == "--help" || "$1" == "-h" ]]; then
  usage
  exit 0
fi

if [[ ! -f "${CRATE_DIR}/Cargo.lock" ]]; then
  printf 'error: isolated fixture lockfile is missing: %s\n' "${CRATE_DIR}/Cargo.lock" >&2
  exit 1
fi

if [[ "$1" == "build" ]]; then
  shift
  if (($# != 0)); then
    printf 'error: build accepts no extra arguments\n' >&2
    exit 2
  fi
  cargo build --locked --manifest-path "${MANIFEST}" --target-dir "${FIXTURE_TARGET_DIR}"
  printf '%s\n' "${PEER_BIN}"
  exit 0
fi

cargo build --locked --quiet --manifest-path "${MANIFEST}" --target-dir "${FIXTURE_TARGET_DIR}"
exec "${PEER_BIN}" "$@"
