#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
API_BASE="${API_BASE:-http://127.0.0.1:4821}"
BATCH_SIZE="${BATCH_SIZE:-5}"
MAX_BATCHES="${MAX_BATCHES:-200}"
SLEEP_SECONDS="${SLEEP_SECONDS:-10}"
REQUEST_TIMEOUT="${REQUEST_TIMEOUT:-900}"
PID_FILE="${OCR_AUTO_PID_FILE:-${ROOT_DIR}/runtime/ocr-auto.pid}"
LOG_FILE="${OCR_AUTO_LOG_FILE:-${ROOT_DIR}/runtime/ocr-auto.log}"

mkdir -p "$(dirname "${PID_FILE}")" "$(dirname "${LOG_FILE}")"

is_running() {
  [[ -f "${PID_FILE}" ]] && kill -0 "$(cat "${PID_FILE}")" 2>/dev/null
}

require_daemon() {
  python3 - "${API_BASE}" <<'PY'
import json
import sys
import urllib.request

api_base = sys.argv[1]
with urllib.request.urlopen(f"{api_base}/health", timeout=10) as response:
    health = json.loads(response.read().decode("utf-8"))
if health.get("status") != "ok":
    raise SystemExit(f"daemon health failed: {health}")
PY
}

start() {
  if is_running; then
    echo "OCR auto runner already running with PID $(cat "${PID_FILE}")"
    echo "Log: ${LOG_FILE}"
    return
  fi

  require_daemon
  {
    echo
    echo "=== OCR auto runner started at $(date --iso-8601=seconds) ==="
    echo "api_base=${API_BASE}"
    echo "batch_size=${BATCH_SIZE}"
    echo "max_batches=${MAX_BATCHES}"
    echo "sleep_seconds=${SLEEP_SECONDS}"
  } >>"${LOG_FILE}"

  nohup env PYTHONUNBUFFERED=1 python3 "${ROOT_DIR}/scripts/run_ocr_batches.py" \
    --api-base "${API_BASE}" \
    --batch-size "${BATCH_SIZE}" \
    --max-batches "${MAX_BATCHES}" \
    --sleep-seconds "${SLEEP_SECONDS}" \
    --request-timeout "${REQUEST_TIMEOUT}" \
    --yes >>"${LOG_FILE}" 2>&1 &

  echo "$!" >"${PID_FILE}"
  echo "OCR auto runner started with PID $(cat "${PID_FILE}")"
  echo "Log: ${LOG_FILE}"
}

stop() {
  if ! is_running; then
    echo "OCR auto runner is not running."
    return
  fi

  local pid
  pid="$(cat "${PID_FILE}")"
  kill "${pid}"
  echo "Stopped OCR auto runner PID ${pid}."
}

status() {
  if is_running; then
    echo "OCR auto runner: running with PID $(cat "${PID_FILE}")"
    echo "Log: ${LOG_FILE}"
    echo
    echo "Recent log:"
    tail -n 20 "${LOG_FILE}" || true
    echo
    echo "Daemon status can be temporarily busy while a local OCR batch is running."
    echo "Run '$0 tail' for live logs, or '$0 stop' to stop after the current process receives SIGTERM."
    return
  else
    echo "OCR auto runner: not running"
  fi
  echo "Log: ${LOG_FILE}"
  echo
  python3 "${ROOT_DIR}/scripts/run_ocr_batches.py" \
    --api-base "${API_BASE}" \
    --status-only | sed -n '1,20p'
}

tail_log() {
  touch "${LOG_FILE}"
  tail -n 80 -f "${LOG_FILE}"
}

case "${1:-status}" in
  start)
    start
    ;;
  stop)
    stop
    ;;
  status)
    status
    ;;
  tail)
    tail_log
    ;;
  *)
    echo "Usage: $0 {start|stop|status|tail}" >&2
    echo "Optional env: BATCH_SIZE=5 MAX_BATCHES=200 SLEEP_SECONDS=10 REQUEST_TIMEOUT=900" >&2
    exit 2
    ;;
esac
