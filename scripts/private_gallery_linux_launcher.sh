#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
API_BASE="${PRIVATE_GALLERY_API_BASE:-http://127.0.0.1:4821}"
DAEMON_WAIT_SECONDS="${PRIVATE_GALLERY_DAEMON_WAIT_SECONDS:-180}"
RUNTIME_DIR="${ROOT_DIR}/runtime"
DAEMON_LOG="${PRIVATE_GALLERY_DAEMON_LOG:-${RUNTIME_DIR}/galleryd-launcher.log}"
APP_LOG="${PRIVATE_GALLERY_APP_LOG:-${RUNTIME_DIR}/private-gallery-app.log}"
APP_BIN="${PRIVATE_GALLERY_APP_BIN:-${ROOT_DIR}/app/build/linux/x64/release/bundle/private_gallery_app}"
APP_BUNDLE_DIR="$(dirname "${APP_BIN}")"

mkdir -p "${RUNTIME_DIR}"
export PRIVATE_GALLERY_RUNTIME_ROOT="${PRIVATE_GALLERY_RUNTIME_ROOT:-${RUNTIME_DIR}}"
if [[ -z "${PRIVATE_GALLERY_ML_SIDECAR:-}" && -f "${ROOT_DIR}/ml_sidecar/private_gallery_ml_sidecar.py" ]]; then
  export PRIVATE_GALLERY_ML_SIDECAR="${ROOT_DIR}/ml_sidecar/private_gallery_ml_sidecar.py"
fi

log() {
  printf '[%s] %s\n' "$(date --iso-8601=seconds)" "$*" | tee -a "${APP_LOG}" >&2
}

detach_command() {
  if command -v setsid >/dev/null 2>&1; then
    setsid -f "$@" >>"${DAEMON_LOG}" 2>&1 </dev/null
  else
    nohup "$@" >>"${DAEMON_LOG}" 2>&1 </dev/null &
  fi
}

notify_error() {
  local message="$1"
  log "ERROR: ${message}"
  if [[ -s "${DAEMON_LOG}" ]]; then
    log "Recent daemon log:"
    tail -n 20 "${DAEMON_LOG}" | tee -a "${APP_LOG}" >&2 || true
  fi
  if command -v zenity >/dev/null 2>&1; then
    zenity --error --title "Private Gallery" --text "${message}" || true
  elif command -v kdialog >/dev/null 2>&1; then
    kdialog --error "${message}" --title "Private Gallery" || true
  elif command -v notify-send >/dev/null 2>&1; then
    notify-send "Private Gallery" "${message}" || true
  fi
}

health_ok() {
  curl -fsS --max-time 2 "${API_BASE}/health" >/dev/null 2>&1
}

wait_for_health() {
  local waited=0
  while (( waited < DAEMON_WAIT_SECONDS )); do
    if health_ok; then
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done
  return 1
}

daemon_command() {
  if [[ -n "${PRIVATE_GALLERY_DAEMON_BIN:-}" && -x "${PRIVATE_GALLERY_DAEMON_BIN}" ]]; then
    printf '%s\n' "${PRIVATE_GALLERY_DAEMON_BIN}"
    return 0
  fi

  for candidate in \
    "${APP_BUNDLE_DIR}/galleryd" \
    "${ROOT_DIR}/target/release/galleryd" \
    "${ROOT_DIR}/target/debug/galleryd" \
    "${ROOT_DIR}/native_core/target/release/galleryd" \
    "${ROOT_DIR}/native_core/target/debug/galleryd"; do
    if [[ -x "${candidate}" ]]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done

  if command -v cargo >/dev/null 2>&1 && [[ -f "${ROOT_DIR}/native_core/Cargo.toml" ]]; then
    printf 'cargo run --manifest-path %q --bin galleryd\n' "${ROOT_DIR}/native_core/Cargo.toml"
    return 0
  fi

  return 1
}

start_daemon_if_needed() {
  if health_ok; then
    log "Local daemon already reachable at ${API_BASE}."
    return 0
  fi

  local command
  if ! command="$(daemon_command)"; then
    notify_error "Could not find galleryd. Build the Rust daemon first with: cargo build --manifest-path native_core/Cargo.toml --bin galleryd"
    return 1
  fi

  log "Starting local daemon: ${command}"
  if [[ "${command}" == cargo\ run* ]]; then
    (cd "${ROOT_DIR}" && detach_command bash -lc "${command}")
  else
    (cd "${ROOT_DIR}" && detach_command "${command}")
  fi

  if ! wait_for_health; then
    notify_error "galleryd did not become healthy within ${DAEMON_WAIT_SECONDS}s. See ${DAEMON_LOG}. If the log mentions secure key storage or DBus, start from a normal desktop session rather than a sandboxed terminal."
    return 1
  fi

  log "Local daemon is healthy."
}

write_status_snapshot() {
  {
    echo
    echo "=== Launcher status $(date --iso-8601=seconds) ==="
    curl -fsS --max-time 5 "${API_BASE}/privacy/status" || true
    echo
    curl -fsS --max-time 5 "${API_BASE}/search/status" || true
    echo
    curl -fsS --max-time 5 "${API_BASE}/models/runtime-status" || true
    echo
    curl -fsS --max-time 5 "${API_BASE}/diagnostics" || true
    echo
  } >>"${APP_LOG}" 2>&1
}

main() {
  start_daemon_if_needed
  write_status_snapshot

  if [[ ! -x "${APP_BIN}" ]]; then
    notify_error "Private Gallery app binary not found at ${APP_BIN}. Build it with: cd app && flutter build linux"
    return 1
  fi

  log "Launching Flutter app: ${APP_BIN}"
  exec "${APP_BIN}" "$@" >>"${APP_LOG}" 2>&1
}

main "$@"
