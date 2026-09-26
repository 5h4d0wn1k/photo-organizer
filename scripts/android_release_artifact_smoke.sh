#!/usr/bin/env bash
#
# Artifact-level release gate for the Android APK: prove the exact file we are
# about to publish can actually be installed, cold-launched, and survives long
# enough to render a real frame, on a real Android system image.
#
# Why this exists: issue #97. CI built the release APK, ran the full unit and
# integration suites, and shipped an artifact that no phone could install. Every
# one of those checks validated the *code*; none validated the *binary*. This
# script closes that gap.
#
# Design notes (each of these is a deliberate decision, not an accident):
#
#   * It is a committed script, not an inline `script:` block. The
#     reactivecircus/android-emulator-runner action splits its `script` input on
#     newlines and runs each line as an independent `sh -c`, which destroys
#     multi-line control flow, drops variables between lines, and cannot run
#     `set -o pipefail` (dash has no pipefail). A single `bash script.sh` line
#     sidesteps all of that.
#
#   * Crash detection reads the dedicated logcat *crash* buffer, not the main
#     buffer. A fresh AOSP image crashes unrelated system processes during boot,
#     so grepping the main buffer for "FATAL EXCEPTION" produces false failures
#     that train people to ignore red builds. The crash buffer only ever
#     contains Java and native (tombstone) crashes, so "non-empty" is a precise
#     signal. This app also ships a native Rust daemon (galleryd), so a
#     SIGSEGV in there never appears as a Java FATAL EXCEPTION; the crash buffer
#     covers both.
#
#   * Crash detection is ALSO cross-checked against
#     `dumpsys activity exit-info` (ApplicationExitInfo, API 30+), which is the
#     platform's own record of abnormal process exits, including ANRs that
#     never write a stack trace. Adverse reasons are compared against a
#     pre-launch baseline so a stale historical entry cannot fail the build.
#
#   * "Launched" is not the same as "rendered". `am start -W` and a live PID
#     both succeed while the app is still showing its launch theme, or stuck on
#     a blank frame. The gate therefore decodes the screenshot and requires real
#     image complexity, which proves pixels were drawn by the app.
#
#   * Flutter only populates the accessibility tree when an accessibility
#     service is active, so `uiautomator dump` cannot be relied on to assert on
#     widget text. The stable, implementation-independent signal is the focused
#     window plus a non-trivial screenshot.
#
# Usage: android_release_artifact_smoke.sh <path-to-apk>
#
# Tunables (all have safe defaults; override via env in tests):
#   ANDROID_SMOKE_ADB                     adb binary to use (default: adb)
#   ANDROID_SMOKE_PACKAGE                 applicationId under test
#   ANDROID_SMOKE_ACTIVITY                launch activity component
#   ANDROID_SMOKE_BOOT_TIMEOUT_SECONDS    emulator boot budget
#   ANDROID_SMOKE_LAUNCH_TIMEOUT_SECONDS  process-alive budget after am start
#   ANDROID_SMOKE_RENDER_TIMEOUT_SECONDS  first-real-frame budget
#   ANDROID_SMOKE_MIN_DISTINCT_COLORS     screenshot complexity threshold
#   ANDROID_SMOKE_EVIDENCE_DIR            where evidence files are written
#   ANDROID_SMOKE_NAME                    evidence file prefix (matrix-safe)

set -euo pipefail

PACKAGE="${ANDROID_SMOKE_PACKAGE:-com.privategallery.app}"
ACTIVITY="${ANDROID_SMOKE_ACTIVITY:-.MainActivity}"
ADB="${ANDROID_SMOKE_ADB:-adb}"
BOOT_TIMEOUT_SECONDS="${ANDROID_SMOKE_BOOT_TIMEOUT_SECONDS:-420}"
LAUNCH_TIMEOUT_SECONDS="${ANDROID_SMOKE_LAUNCH_TIMEOUT_SECONDS:-90}"
RENDER_TIMEOUT_SECONDS="${ANDROID_SMOKE_RENDER_TIMEOUT_SECONDS:-90}"
MIN_DISTINCT_COLORS="${ANDROID_SMOKE_MIN_DISTINCT_COLORS:-32}"
EVIDENCE_DIR="${ANDROID_SMOKE_EVIDENCE_DIR:-.}"
SMOKE_NAME="${ANDROID_SMOKE_NAME:-android-smoke}"
POLL_INTERVAL_SECONDS="${ANDROID_SMOKE_POLL_INTERVAL_SECONDS:-2}"

# Runtime permissions the app can ask for. Granting them up front keeps a system
# permission dialog from stealing window focus during the launch assertion. The
# app does not request anything on cold start, so this is belt-and-braces; each
# grant is allowed to fail because the permission may not exist at this API level.
RUNTIME_PERMISSIONS=(
  android.permission.CAMERA
  android.permission.READ_EXTERNAL_STORAGE
  android.permission.READ_MEDIA_IMAGES
  android.permission.READ_MEDIA_VIDEO
)

# ApplicationExitInfo reasons that mean the app died badly. Reference:
# frameworks/base/core/java/android/app/ApplicationExitInfo.java
#   REASON_CRASH=4 REASON_CRASH_NATIVE=5 REASON_ANR=6
#   REASON_INITIALIZATION_FAILURE=7
ADVERSE_EXIT_REASONS=("4" "5" "6" "7")

SCREENSHOT_PATH=""
CRASH_BUFFER_PATH=""
EXIT_INFO_PATH=""
LOGCAT_PATH=""
SUMMARY_PATH=""

log() {
  printf '[%s] %s\n' "${SMOKE_NAME}" "$*"
}

fail() {
  printf '[%s] ERROR: %s\n' "${SMOKE_NAME}" "$*" >&2
  exit 1
}

require_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    fail "missing required tool: $1"
  fi
}

contains() {
  local needle="$1" haystack="$2"
  [[ "${haystack}" == *"${needle}"* ]]
}

adb_shell() {
  "${ADB}" shell "$@" 2>/dev/null || true
}

trim() {
  local value="$1"
  value="${value//$'\r'/}"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "${value}"
}

is_blank() {
  [[ -z "$(trim "${1:-}")" ]]
}

is_device_booted() {
  [[ "$(trim "$(adb_shell getprop sys.boot_completed)")" == "1" ]]
}

app_pid() {
  trim "$(adb_shell pidof "${PACKAGE}")"
}

is_app_running() {
  [[ -n "$(app_pid)" ]]
}

# `head -n 1` is avoided throughout: closing a pipe early can SIGPIPE the writer,
# which `set -o pipefail` would report as a failure. Bash string surgery is used
# instead so no pipeline depends on a reader closing early.
first_line() {
  local value="$1"
  printf '%s' "${value%%$'\n'*}"
}

focused_window() {
  local dump line
  dump="$(adb_shell dumpsys window)"
  while IFS= read -r line; do
    if [[ "${line}" == *"mCurrentFocus"* || "${line}" == *"mFocusedApp"* ]]; then
      first_line "${line}"
      return 0
    fi
  done <<<"${dump}"
  return 0
}

is_app_focused() {
  contains "${PACKAGE}" "$(focused_window)"
}

wait_until() {
  local description="$1" timeout_seconds="$2"
  shift 2
  local deadline=$((SECONDS + timeout_seconds))
  while ((SECONDS < deadline)); do
    if "$@"; then
      return 0
    fi
    sleep "${POLL_INTERVAL_SECONDS}"
  done
  log "timed out after ${timeout_seconds}s waiting for ${description}"
  return 1
}

pregrant_runtime_permissions() {
  local permission
  for permission in "${RUNTIME_PERMISSIONS[@]}"; do
    # Not every permission exists at every API level, and a refusal here is
    # never itself a release-blocking condition.
    adb_shell pm grant "${PACKAGE}" "${permission}" >/dev/null 2>&1 || true
  done
}

diagnose_install_failure() {
  local output="$1"
  if contains "INSTALL_PARSE_FAILED_NO_CERTIFICATES" "${output}" ||
    contains "INSTALL_PARSE_FAILED_UNEXPECTED_EXCEPTION" "${output}" ||
    contains "INSTALL_PARSE_FAILED_NO_SIGNATURES" "${output}"; then
    printf '%s\n' "The APK is unsigned or its signature is unreadable. Stock Android refuses unsigned packages."
  elif contains "INSTALL_FAILED_UPDATE_INCOMPATIBLE" "${output}" ||
    contains "INSTALL_FAILED_VERSION_DOWNGRADE" "${output}"; then
    printf '%s\n' "An installed copy exists that was signed with a different key (or a lower versionCode)."
  elif contains "INSTALL_FAILED_NO_MATCHING_ABIS" "${output}"; then
    printf '%s\n' "The APK contains no native library for this device ABI. Check the jniLibs cross-compile."
  elif contains "INSTALL_FAILED_OLDER_SDK" "${output}"; then
    printf '%s\n' "The APK minSdkVersion is higher than this system image's API level."
  elif contains "INSTALL_FAILED_INSUFFICIENT_STORAGE" "${output}"; then
    printf '%s\n' "Not enough space on the emulator to install the package."
  else
    printf '%s\n' "See the raw package manager output above."
  fi
}

install_apk() {
  local apk="$1" output rc=0
  output="$("${ADB}" install -r --no-streaming "${apk}" 2>&1)" || rc=$?
  if ((rc != 0)) || contains "Failure" "${output}"; then
    printf '%s\n' "adb install failed (exit ${rc}):" >&2
    printf '%s\n' "${output}" >&2
    printf '%s\n' "Diagnosis:" >&2
    diagnose_install_failure "${output}" >&2
    fail "the release artifact is not installable on this system image"
  fi
  log "installed $(basename "${apk}"): $(trim "${output}")"
}

record_installed_version() {
  local dump version_name version_code abi api
  dump="$(adb_shell dumpsys package "${PACKAGE}")"
  version_name="$(first_line "$(printf '%s' "${dump}" | sed -n 's/.*versionName=\([^ ]*\).*/\1/p')")"
  version_code="$(first_line "$(printf '%s' "${dump}" | sed -n 's/.*versionCode=\([^ ]*\).*/\1/p')")"
  abi="$(trim "$(adb_shell getprop ro.product.cpu.abi)")"
  api="$(trim "$(adb_shell getprop ro.build.version.sdk)")"
  {
    printf 'package: %s\n' "${PACKAGE}"
    printf 'apk: %s\n' "$1"
    printf 'apk sha256: %s\n' "$(sha256_of "$1")"
    printf 'device: API %s (Android %s), abi %s\n' "${api}" "$(trim "$(adb_shell getprop ro.build.version.release)")" "${abi}"
    printf 'installed versionName: %s\n' "${version_name}"
    printf 'installed versionCode: %s\n' "${version_code}"
  } >"${SUMMARY_PATH}"
  cat "${SUMMARY_PATH}"
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

clear_log_buffers() {
  # Clears main, system and crash. Done immediately before launch so anything
  # found afterwards is attributable to this launch.
  "${ADB}" logcat -c >/dev/null 2>&1 || true
}

cold_launch() {
  local output rc=0
  output="$("${ADB}" shell am start -W -n "${PACKAGE}/${ACTIVITY}" 2>&1)" || rc=$?
  printf '%s\n' "${output}" >>"${SUMMARY_PATH}"
  if ((rc != 0)) || ! contains "Status: ok" "${output}"; then
    printf '%s\n' "am start did not report success (exit ${rc}):" >&2
    printf '%s\n' "${output}" >&2
    exit 1
  fi
  log "launch requested: $(trim "$(printf '%s' "${output}" | tr '\n' ' ')")"
}

capture_crash_baseline() {
  local dump
  dump="$(adb_shell dumpsys activity exit-info "${PACKAGE}")"
  printf '%s' "${dump}" >"${EXIT_INFO_PATH}"
  adverse_exit_reason_count "${dump}"
}

adverse_exit_reason_count() {
  local dump="$1" line count=0 reason
  while IFS= read -r line; do
    if [[ "${line}" =~ reason=([0-9]+) ]]; then
      reason="${BASH_REMATCH[1]}"
      for candidate in "${ADVERSE_EXIT_REASONS[@]}"; do
        if [[ "${reason}" == "${candidate}" ]]; then
          count=$((count + 1))
          break
        fi
      done
    fi
  done <<<"${dump}"
  printf '%s' "${count}"
}

assert_no_adverse_exits() {
  local baseline="$1" dump after
  dump="$(adb_shell dumpsys activity exit-info "${PACKAGE}")"
  printf '%s\n' "${dump}" >"${EXIT_INFO_PATH}"
  if is_blank "${dump}"; then
    log "exit-info unavailable on this API level; relying on the crash buffer"
    return 0
  fi
  after="$(adverse_exit_reason_count "${dump}")"
  if ((after > baseline)); then
    printf '%s\n' "Android recorded an abnormal exit of ${PACKAGE} (crash, native crash, ANR, or init failure):" >&2
    printf '%s\n' "${dump}" >&2
    fail "adverse ApplicationExitInfo entries: ${baseline} before launch, ${after} after"
  fi
  log "exit-info clean (${after} adverse entries, same as pre-launch baseline)"
}

assert_crash_buffer_clean() {
  local crash
  crash="$("${ADB}" logcat -b crash -d 2>/dev/null || true)"
  printf '%s\n' "${crash}" >"${CRASH_BUFFER_PATH}"
  if ! is_blank "${crash}"; then
    printf '%s\n' "The Android crash buffer is not empty after launch:" >&2
    printf '%s\n' "${crash}" >&2
    fail "crash/ANR detected during launch (includes native galleryd crashes)"
  fi
  log "crash buffer clean (no Java FATAL EXCEPTION, no native tombstone)"
}

collect_logs() {
  "${ADB}" logcat -d -v threadtime >"${LOGCAT_PATH}" 2>/dev/null || true
}

capture_screenshot() {
  local destination="$1"
  # `exec-out screencap -p` writes a PNG straight to stdout with no CRLF mangling.
  # Screenshot only succeeds while a surface is available, so a failure here is
  # not fatal on its own.
  "${ADB}" exec-out screencap -p >"${destination}" 2>/dev/null || return 1
  [[ -s "${destination}" ]] || return 1
  return 0
}

# Prints the number of distinct colours in a PNG (early-exits above the caller's
# threshold). Decodes only what `screencap -p` produces: 8-bit, non-interlaced,
# greyscale / RGB / greyscale+alpha / RGBA. Implemented in Python's stdlib so the
# gate needs no image tooling on the runner.
png_distinct_colors() {
  local file="$1" threshold="${2:-0}"
  python3 - "${file}" "${threshold}" <<'PY'
import struct
import sys
import zlib

path, threshold = sys.argv[1], int(sys.argv[2])

with open(path, "rb") as handle:
    data = handle.read()

if data[:8] != b"\x89PNG\r\n\x1a\n":
    sys.exit("not a PNG file")

offset = 8
width = height = depth = color_type = interlace = None
idat = bytearray()
while offset + 8 <= len(data):
    (length,) = struct.unpack(">I", data[offset : offset + 4])
    chunk_type = data[offset + 4 : offset + 8]
    payload = data[offset + 8 : offset + 8 + length]
    offset += 12 + length
    if chunk_type == b"IHDR":
        width, height, depth, color_type, _comp, _filt, interlace = struct.unpack(
            ">IIBBBBB", payload
        )
    elif chunk_type == b"IDAT":
        idat += payload
    elif chunk_type == b"IEND":
        break

channels = {0: 1, 2: 3, 4: 2, 6: 4}.get(color_type)
if width is None or channels is None:
    sys.exit(f"unsupported PNG header (color_type={color_type})")
if depth != 8:
    sys.exit(f"unsupported PNG bit depth {depth}; expected 8")
if interlace != 0:
    sys.exit("interlaced PNG is not supported")

raw = zlib.decompress(bytes(idat))
stride = width * channels
if len(raw) < (stride + 1) * height:
    sys.exit("truncated PNG image data")

seen = set()
previous = bytearray(stride)
pos = 0
for _ in range(height):
    filter_type = raw[pos]
    pos += 1
    line = bytearray(raw[pos : pos + stride])
    pos += stride
    if filter_type == 1:
        for i in range(channels, stride):
            line[i] = (line[i] + line[i - channels]) & 0xFF
    elif filter_type == 2:
        for i in range(stride):
            line[i] = (line[i] + previous[i]) & 0xFF
    elif filter_type == 3:
        for i in range(stride):
            left = line[i - channels] if i >= channels else 0
            line[i] = (line[i] + ((left + previous[i]) >> 1)) & 0xFF
    elif filter_type == 4:
        for i in range(stride):
            left = line[i - channels] if i >= channels else 0
            up = previous[i]
            up_left = previous[i - channels] if i >= channels else 0
            estimate = left + up - up_left
            da, db, dc = (
                abs(estimate - left),
                abs(estimate - up),
                abs(estimate - up_left),
            )
            if da <= db and da <= dc:
                predictor = left
            elif db <= dc:
                predictor = up
            else:
                predictor = up_left
            line[i] = (line[i] + predictor) & 0xFF
    elif filter_type != 0:
        sys.exit(f"unsupported PNG filter type {filter_type}")

    for start in range(0, stride, channels):
        seen.add(bytes(line[start : start + channels]))
        if len(seen) > threshold:
            print(len(seen))
            sys.exit(0)
    previous = line

print(len(seen))
PY
}

await_rendered_frame() {
  local deadline=$((SECONDS + RENDER_TIMEOUT_SECONDS)) colors=-1
  while ((SECONDS < deadline)); do
    if capture_screenshot "${SCREENSHOT_PATH}"; then
      if colors="$(png_distinct_colors "${SCREENSHOT_PATH}" "${MIN_DISTINCT_COLORS}" 2>/dev/null)"; then
        if [[ "${colors}" =~ ^[0-9]+$ ]] && ((colors >= MIN_DISTINCT_COLORS)); then
          log "rendered a real frame (${colors}+ distinct colours in screenshot)"
          return 0
        fi
      else
        log "screenshot could not be decoded yet; retrying"
      fi
    fi
    sleep "${POLL_INTERVAL_SECONDS}"
  done
  return 1
}

main() {
  local apk="${1:-}" baseline
  if [[ -z "${apk}" ]]; then
    echo "usage: $(basename "$0") <path-to-apk>" >&2
    exit 2
  fi
  [[ -f "${apk}" ]] || fail "APK not found: ${apk}"
  [[ -s "${apk}" ]] || fail "APK is empty: ${apk}"

  require_tool "${ADB}"
  require_tool python3

  mkdir -p "${EVIDENCE_DIR}"
  SCREENSHOT_PATH="${EVIDENCE_DIR}/${SMOKE_NAME}.png"
  CRASH_BUFFER_PATH="${EVIDENCE_DIR}/${SMOKE_NAME}-crash-buffer.txt"
  EXIT_INFO_PATH="${EVIDENCE_DIR}/${SMOKE_NAME}-exit-info.txt"
  LOGCAT_PATH="${EVIDENCE_DIR}/${SMOKE_NAME}-logcat.txt"
  SUMMARY_PATH="${EVIDENCE_DIR}/${SMOKE_NAME}-summary.txt"
  : >"${SUMMARY_PATH}"

  log "waiting for the emulator to finish booting"
  wait_until "device boot" "${BOOT_TIMEOUT_SECONDS}" is_device_booted ||
    fail "emulator did not report sys.boot_completed=1"

  install_apk "${apk}"
  record_installed_version "${apk}"
  pregrant_runtime_permissions

  baseline="$(capture_crash_baseline)"
  clear_log_buffers
  cold_launch

  wait_until "${PACKAGE} process" "${LAUNCH_TIMEOUT_SECONDS}" is_app_running ||
    fail "${PACKAGE} is not running after launch (crash on start)"
  log "process alive: pid $(app_pid)"

  wait_until "${PACKAGE} window focus" "${LAUNCH_TIMEOUT_SECONDS}" is_app_focused ||
    fail "${PACKAGE} never took window focus; focused window was: $(focused_window)"
  log "window focused: $(focused_window)"

  if ! await_rendered_frame; then
    collect_logs
    fail "no real frame rendered within ${RENDER_TIMEOUT_SECONDS}s (a blank or launch-theme-only screen is treated as a failure)"
  fi

  is_app_running || fail "${PACKAGE} died while rendering"
  assert_crash_buffer_clean
  assert_no_adverse_exits "${baseline}"
  collect_logs

  {
    printf 'result: PASS\n'
    printf 'focused window: %s\n' "$(focused_window)"
    printf 'final pid: %s\n' "$(app_pid)"
    printf 'screenshot: %s\n' "${SCREENSHOT_PATH}"
  } >>"${SUMMARY_PATH}"

  log "PASS: the release artifact installed, cold-launched and rendered on Android $(trim "$(adb_shell getprop ro.build.version.release)") (API $(trim "$(adb_shell getprop ro.build.version.sdk)"))"
  log "evidence: ${SUMMARY_PATH}, ${SCREENSHOT_PATH}, ${CRASH_BUFFER_PATH}, ${EXIT_INFO_PATH}, ${LOGCAT_PATH}"
}

main "$@"
