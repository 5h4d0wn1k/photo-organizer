#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME_DIR="${ROOT_DIR}/runtime"

is_enabled() {
  case "${1:-}" in
    1 | true | TRUE | yes | YES) return 0 ;;
    *) return 1 ;;
  esac
}

if ! is_enabled "${PRIVATE_GALLERY_ALLOW_REMOTE_MOBILE:-}"; then
  cat >&2 <<'EOF'
Refusing to bind the daemon for hotspot/LAN mobile access.

Set PRIVATE_GALLERY_ALLOW_REMOTE_MOBILE=1 when you intentionally want phones
on the local network to reach /health and /mobile/*:

  PRIVATE_GALLERY_ALLOW_REMOTE_MOBILE=1 scripts/private_gallery_mobile_lan_daemon.sh

Desktop/admin API routes remain blocked for non-loopback clients by the daemon.
EOF
  exit 1
fi

export PRIVATE_GALLERY_ALLOW_REMOTE_MOBILE
export PRIVATE_GALLERY_BIND_HOST="${PRIVATE_GALLERY_BIND_HOST:-0.0.0.0}"
export PRIVATE_GALLERY_BIND_PORT="${PRIVATE_GALLERY_BIND_PORT:-4821}"
export PRIVATE_GALLERY_RUNTIME_ROOT="${PRIVATE_GALLERY_RUNTIME_ROOT:-${RUNTIME_DIR}}"

if [[ -z "${PRIVATE_GALLERY_ML_SIDECAR:-}" && -f "${ROOT_DIR}/ml_sidecar/private_gallery_ml_sidecar.py" ]]; then
  export PRIVATE_GALLERY_ML_SIDECAR="${ROOT_DIR}/ml_sidecar/private_gallery_ml_sidecar.py"
fi

daemon_cmd=()
if [[ -n "${PRIVATE_GALLERY_DAEMON_BIN:-}" ]]; then
  if [[ ! -x "${PRIVATE_GALLERY_DAEMON_BIN}" ]]; then
    echo "PRIVATE_GALLERY_DAEMON_BIN is not executable: ${PRIVATE_GALLERY_DAEMON_BIN}" >&2
    exit 1
  fi
  daemon_cmd=("${PRIVATE_GALLERY_DAEMON_BIN}")
elif command -v cargo >/dev/null 2>&1 && [[ -f "${ROOT_DIR}/native_core/Cargo.toml" ]]; then
  daemon_cmd=(cargo run --manifest-path "${ROOT_DIR}/native_core/Cargo.toml" --bin galleryd)
else
  for candidate in \
    "${ROOT_DIR}/target/release/galleryd" \
    "${ROOT_DIR}/target/debug/galleryd" \
    "${ROOT_DIR}/native_core/target/release/galleryd" \
    "${ROOT_DIR}/native_core/target/debug/galleryd"; do
    if [[ -x "${candidate}" ]]; then
      daemon_cmd=("${candidate}")
      break
    fi
  done
fi

if [[ "${#daemon_cmd[@]}" -eq 0 ]]; then
  echo "Could not find galleryd and cargo is not available. Build with: cargo build --manifest-path native_core/Cargo.toml --bin galleryd" >&2
  exit 1
fi

mkdir -p "${RUNTIME_DIR}"

host_hints="$(hostname -I 2>/dev/null | tr ' ' '\n' | awk -v port="${PRIVATE_GALLERY_BIND_PORT}" 'NF {print "  http://" $1 ":" port}' | sed -n '1,5p' || true)"

cat >&2 <<EOF
Starting Private Gallery daemon for hotspot/LAN mobile sync.

Bind: ${PRIVATE_GALLERY_BIND_HOST}:${PRIVATE_GALLERY_BIND_PORT}
Runtime: ${PRIVATE_GALLERY_RUNTIME_ROOT}

Phone URL candidates:
${host_hints:-  Find the laptop hotspot IP, then use http://<laptop-hotspot-ip>:${PRIVATE_GALLERY_BIND_PORT}}

Expected remote checks:
  GET /health -> 200
  GET /library/status -> 403
EOF

cd "${ROOT_DIR}"
exec "${daemon_cmd[@]}"
