#!/usr/bin/env bash
#
# Tests for scripts/android_release_artifact_smoke.sh.
#
# The install/launch gate is the thing that would have caught issue #97, so it
# cannot itself be an untested blob of shell inside a CI workflow. A fake `adb`
# stands in for a device, and every failure mode the gate is supposed to detect
# is injected and asserted here: unsigned APK, wrong ABI, signature-mismatch
# upgrade, crash on start, native (tombstone) crash in the Rust daemon, ANR,
# a dead process, a permission dialog stealing focus, an unbooted emulator, and
# a blank screen that never rendered a real frame.
#
# It also unit-tests the PNG complexity decoder, because "did it actually render"
# is the one assertion in the gate with real logic behind it.

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="${ROOT_DIR}/scripts/android_release_artifact_smoke.sh"
WORK_DIR="$(mktemp -d)"
PASS_COUNT=0
FAIL_COUNT=0

cleanup() {
  rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

ok() {
  PASS_COUNT=$((PASS_COUNT + 1))
  printf '  ok   %s\n' "$1"
}

bad() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  printf '  FAIL %s\n' "$1" >&2
  if [[ -n "${2:-}" ]]; then
    printf '%s\n' "$2" | sed 's/^/        /' >&2
  fi
}

OUT="${WORK_DIR}/out"

expect_pass() {
  local name="$1"
  shift
  if "$@" >"${OUT}" 2>&1; then
    ok "${name}"
  else
    bad "${name}" "$(cat "${OUT}")"
  fi
}

expect_fail() {
  local name="$1" needle="${2:-}"
  shift 2
  if "$@" >"${OUT}" 2>&1; then
    bad "${name}" "expected a non-zero exit, got success: $(cat "${OUT}")"
    return
  fi
  if [[ -n "${needle}" ]] && ! grep -Fq "${needle}" "${OUT}"; then
    bad "${name}" "expected the failure to mention '${needle}'; got: $(cat "${OUT}")"
    return
  fi
  ok "${name}"
}

SCENARIO="${WORK_DIR}/scenario.env"
BASE_SCENARIO="${WORK_DIR}/scenario.base.env"
FAKE_STATE="${WORK_DIR}/fake-adb-launched"

# --- fake device -------------------------------------------------------------

# The fake adb is driven by a declarative KEY=VALUE scenario file. A second file
# (EXIT_INFO_AFTER) models "what the platform recorded after we launched",
# switched on by the same `logcat -c` call the real gate makes before launch.
install_fake_adb() {
  cat >"${WORK_DIR}/adb" <<'FAKE_ADB'
#!/usr/bin/env bash
set -uo pipefail

scenario_value() {
  local key="$1" line
  [[ -f "${FAKE_ADB_SCENARIO}" ]] || return 1
  while IFS= read -r line; do
    if [[ "${line}" == "${key}="* ]]; then
      printf '%s' "${line#*=}"
      return 0
    fi
  done <"${FAKE_ADB_SCENARIO}"
  return 1
}

value_or() {
  scenario_value "$1" || printf '%s' "${2:-}"
}

args=("$@")
verb=""
for candidate in shell exec-out logcat install getprop pidof pm; do
  if [[ "${args[0]:-}" == "${candidate}" ]]; then
    verb="${candidate}"
    args=("${args[@]:1}")
    break
  fi
done

emit_exit_info() {
  if [[ -f "${FAKE_ADB_STATE}" ]]; then
    local after
    after="$(scenario_value EXIT_INFO_AFTER || true)"
    if [[ -n "${after}" && -f "${after}" ]]; then
      cat "${after}"
      return 0
    fi
  fi
  local before
  before="$(scenario_value EXIT_INFO || true)"
  if [[ -n "${before}" && -f "${before}" ]]; then
    cat "${before}"
  fi
}

case "${verb}" in
  exec-out)
    if [[ "${args[0]:-}" == "screencap" ]]; then
      local shot
      shot="$(scenario_value SCREENSHOT || true)"
      [[ -n "${shot}" && -f "${shot}" ]] && cat "${shot}"
    fi
    exit 0
    ;;
  shell)
    rest="${args[*]}"
    case "${rest}" in
      *"getprop sys.boot_completed"*) printf '%s' "$(value_or BOOTED)"; exit 0 ;;
      *"getprop ro.build.version.release"*) printf '%s' "$(value_or ANDROID_RELEASE 14)"; exit 0 ;;
      *"getprop ro.build.version.sdk"*) printf '%s' "$(value_or ANDROID_SDK 34)"; exit 0 ;;
      *"getprop ro.product.cpu.abi"*) printf '%s' "$(value_or ABI x86_64)"; exit 0 ;;
      *"pidof"*) printf '%s' "$(value_or PID)"; exit 0 ;;
      *"am start"*)
        printf 'Starting: Intent { act=android.intent.action.MAIN cmp=%s/.MainActivity }\n' "$(value_or PACKAGE com.privategallery.app)"
        printf 'Status: %s\n' "$(value_or AM_STATUS ok)"
        printf 'LaunchState: COLD\nTotalTime: 812\nComplete\n'
        exit 0
        ;;
      *"dumpsys window"*)
        printf '  mCurrentFocus=Window{deadbeef u0 %s/.MainActivity}\n' "$(value_or FOCUS com.privategallery.app)"
        exit 0
        ;;
      *"dumpsys activity exit-info"*) emit_exit_info; exit 0 ;;
      *"dumpsys package"*)
        printf '  versionCode=%s minSdk=24 targetSdk=36\n' "$(value_or VERSION_CODE 1)"
        printf '  versionName=%s\n' "$(value_or VERSION_NAME 1.0.0)"
        exit 0
        ;;
      *"pm grant"*) exit 0 ;;
    esac
    exit 0
    ;;
  install)
    output="$(value_or INSTALL_OUTPUT Success)"
    printf '%s\n' "${output}"
    [[ "${output}" == Success* ]] && exit 0
    exit 1
    ;;
  logcat)
    if [[ "${args[0]:-}" == "-c" ]]; then
      : >"${FAKE_ADB_STATE}"
      exit 0
    fi
    if [[ " $* " == *" -b crash "* ]]; then
      local crash
      crash="$(scenario_value CRASH_BUFFER || true)"
      [[ -n "${crash}" && -f "${crash}" ]] && cat "${crash}"
      exit 0
    fi
    printf '09-26 00:00:00.000  1000  1000 I fake: general logcat capture\n'
    exit 0
    ;;
  *) exit 0 ;;
esac
FAKE_ADB
  chmod +x "${WORK_DIR}/adb"
}

# --- PNG fixtures ------------------------------------------------------------

make_png() {
  # make_png <path> <distinct-colour-count>
  python3 - "$1" "$2" <<'PY'
import struct
import sys
import zlib

path, colors = sys.argv[1], int(sys.argv[2])
width, height = 64, 64
raw = bytearray()
for y in range(height):
    raw.append(0)  # PNG filter type 0 (None)
    for x in range(width):
        index = (x + y * width) % colors
        raw += bytes(((index * 37) % 256, (index * 91) % 256, (index * 53) % 256))


def chunk(tag, payload):
    return (
        struct.pack(">I", len(payload))
        + tag
        + payload
        + struct.pack(">I", zlib.crc32(tag + payload) & 0xFFFFFFFF)
    )


png = b"\x89PNG\r\n\x1a\n"
png += chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
png += chunk(b"IDAT", zlib.compress(bytes(raw), 9))
png += chunk(b"IEND", b"")
with open(path, "wb") as handle:
    handle.write(png)
PY
}

# --- scenario plumbing -------------------------------------------------------

scenario_with() {
  # Always start from the pristine baseline so tests are order-independent: a
  # key that one case sets cannot silently leak into the next case.
  local line key work
  cp "${BASE_SCENARIO}" "${SCENARIO}"
  rm -f "${FAKE_STATE}"
  for line in "$@"; do
    key="${line%%=*}"
    work="${WORK_DIR}/scenario.work"
    grep -v "^${key}=" "${SCENARIO}" >"${work}" 2>/dev/null || true
    printf '%s\n' "${line}" >>"${work}"
    cp "${work}" "${SCENARIO}"
  done
}

run_smoke() {
  env \
    ANDROID_SMOKE_ADB="${WORK_DIR}/adb" \
    ANDROID_SMOKE_EVIDENCE_DIR="${WORK_DIR}/evidence" \
    ANDROID_SMOKE_NAME="case" \
    ANDROID_SMOKE_BOOT_TIMEOUT_SECONDS="${SMOKE_BOOT_TIMEOUT:-10}" \
    ANDROID_SMOKE_LAUNCH_TIMEOUT_SECONDS="${SMOKE_LAUNCH_TIMEOUT:-10}" \
    ANDROID_SMOKE_RENDER_TIMEOUT_SECONDS="${SMOKE_RENDER_TIMEOUT:-6}" \
    ANDROID_SMOKE_POLL_INTERVAL_SECONDS=1 \
    FAKE_ADB_SCENARIO="${SCENARIO}" \
    FAKE_ADB_STATE="${FAKE_STATE}" \
    bash "${SCRIPT}" "${WORK_DIR}/app-release.apk"
}

run_smoke_missing_apk() {
  env ANDROID_SMOKE_ADB="${WORK_DIR}/adb" FAKE_ADB_SCENARIO="${SCENARIO}" \
    bash "${SCRIPT}" "${WORK_DIR}/does-not-exist.apk"
}

run_smoke_no_args() {
  env ANDROID_SMOKE_ADB="${WORK_DIR}/adb" FAKE_ADB_SCENARIO="${SCENARIO}" bash "${SCRIPT}"
}

# --- fixtures ----------------------------------------------------------------

install_fake_adb
make_png "${WORK_DIR}/rich.png" 40
make_png "${WORK_DIR}/blank.png" 1
printf 'not a png at all' >"${WORK_DIR}/garbage.png"
printf 'fake apk bytes\n' >"${WORK_DIR}/app-release.apk"

: >"${WORK_DIR}/empty-exit-info.txt"

cat >"${WORK_DIR}/anr-exit-info.txt" <<'EOF'
  ApplicationExitInfo #0:
    reason=6 (ANR)
    timestamp=2026-09-26 00:00:00
EOF

cat >"${WORK_DIR}/crash-java.txt" <<'EOF'
09-26 00:00:01.000  1000  1000 E AndroidRuntime: FATAL EXCEPTION: main
09-26 00:00:01.000  1000  1000 E AndroidRuntime: Process: com.privategallery.app, PID: 1000
EOF

cat >"${WORK_DIR}/crash-native.txt" <<'EOF'
09-26 00:00:02.000  1000  1000 F libc: Fatal signal 11 (SIGSEGV), code 1 in tid 4242 (galleryd)
--------- beginning of tombstone
09-26 00:00:02.100  1000  1000 F DEBUG: signal 11 (SIGSEGV), code 1, fault addr 0x0 in galleryd
EOF

cat >"${WORK_DIR}/crash-other-app.txt" <<'EOF'
09-26 00:00:03.000  500  500 E AndroidRuntime: FATAL EXCEPTION: main
09-26 00:00:03.000  500  500 E AndroidRuntime: Process: com.android.systemui, PID: 500
EOF

cat >"${SCENARIO}" <<EOF
BOOTED=1
PACKAGE=com.privategallery.app
PID=4242
AM_STATUS=ok
FOCUS=com.privategallery.app
INSTALL_OUTPUT=Success
VERSION_CODE=1
VERSION_NAME=1.0.0
SCREENSHOT=${WORK_DIR}/rich.png
CRASH_BUFFER=${WORK_DIR}/empty-exit-info.txt
EXIT_INFO=${WORK_DIR}/empty-exit-info.txt
EXIT_INFO_AFTER=${WORK_DIR}/empty-exit-info.txt
EOF
cp "${SCENARIO}" "${BASE_SCENARIO}"

# --- tests -------------------------------------------------------------------

echo "android_release_artifact_smoke.sh"

echo " happy path"
expect_pass "installs, cold-launches, renders, and passes" run_smoke

echo " argument and input validation"
expect_fail "no APK argument is a usage error" "usage" run_smoke_no_args
expect_fail "a missing APK file fails fast" "APK not found" run_smoke_missing_apk

echo " install failures (the issue #97 class of failure)"
scenario_with "INSTALL_OUTPUT=Failure [INSTALL_PARSE_FAILED_NO_CERTIFICATES]"
expect_fail "an unsigned APK is rejected" "not installable" run_smoke
scenario_with "INSTALL_OUTPUT=Success"
expect_pass "the gate goes green once the artifact is signed" run_smoke

scenario_with "INSTALL_OUTPUT=Failure [INSTALL_PARSE_FAILED_NO_CERTIFICATES: Failed to collect certificates]"
expect_fail "an unsigned APK is diagnosed as unsigned" "unsigned" run_smoke
scenario_with "INSTALL_OUTPUT=Success"

scenario_with "INSTALL_OUTPUT=Failure [INSTALL_FAILED_NO_MATCHING_ABIS]"
expect_fail "a wrong-ABI APK is rejected" "no native library for this device ABI" run_smoke
scenario_with "INSTALL_OUTPUT=Success"

scenario_with "INSTALL_OUTPUT=Failure [INSTALL_FAILED_UPDATE_INCOMPATIBLE]"
expect_fail "a signature-mismatch upgrade is rejected" "signed with a different key" run_smoke
scenario_with "INSTALL_OUTPUT=Success"

scenario_with "INSTALL_OUTPUT=Failure [INSTALL_FAILED_OLDER_SDK]"
expect_fail "a too-new minSdk is rejected" "minSdkVersion" run_smoke
scenario_with "INSTALL_OUTPUT=Success"

echo " launch failures"
scenario_with "AM_STATUS=timeout"
expect_fail "am start that never completes fails" "did not report success" run_smoke
scenario_with "AM_STATUS=ok"
expect_pass "recovers when the launch succeeds" run_smoke

scenario_with "PID="
expect_fail "an app that dies immediately fails" "not running after launch" run_smoke
scenario_with "PID=4242"

scenario_with "FOCUS=com.android.permissioncontroller"
expect_fail "a permission dialog stealing focus fails" "never took window focus" run_smoke
scenario_with "FOCUS=com.privategallery.app"

scenario_with "BOOTED="
expect_fail "an unbooted emulator fails instead of hanging" "sys.boot_completed" run_smoke
scenario_with "BOOTED=1"

echo " crash, native-crash and ANR detection"
scenario_with "CRASH_BUFFER=${WORK_DIR}/crash-java.txt"
expect_fail "a Java FATAL EXCEPTION fails the gate" "crash/ANR detected" run_smoke
scenario_with "CRASH_BUFFER=${WORK_DIR}/empty-exit-info.txt"

scenario_with "CRASH_BUFFER=${WORK_DIR}/crash-native.txt"
expect_fail "a native galleryd SIGSEGV fails the gate" "crash/ANR detected" run_smoke
scenario_with "CRASH_BUFFER=${WORK_DIR}/empty-exit-info.txt"

scenario_with "CRASH_BUFFER=${WORK_DIR}/crash-other-app.txt"
expect_fail "crash-buffer content is never silently ignored" "crash/ANR detected" run_smoke
scenario_with "CRASH_BUFFER=${WORK_DIR}/empty-exit-info.txt"

scenario_with "EXIT_INFO_AFTER=${WORK_DIR}/anr-exit-info.txt"
expect_fail "an ANR recorded after launch fails the gate" "adverse ApplicationExitInfo" run_smoke
scenario_with "EXIT_INFO_AFTER=${WORK_DIR}/empty-exit-info.txt"

scenario_with "EXIT_INFO=${WORK_DIR}/anr-exit-info.txt" \
  "EXIT_INFO_AFTER=${WORK_DIR}/anr-exit-info.txt"
expect_pass "a pre-existing adverse entry does not fail the gate" run_smoke
scenario_with "EXIT_INFO=${WORK_DIR}/empty-exit-info.txt"

echo " rendering"
scenario_with "SCREENSHOT=${WORK_DIR}/blank.png"
expect_fail "a blank screen counts as never rendered" "no real frame rendered" run_smoke
scenario_with "SCREENSHOT=${WORK_DIR}/rich.png"

scenario_with "SCREENSHOT=${WORK_DIR}/garbage.png"
expect_fail "an undecodable screenshot counts as never rendered" "no real frame rendered" run_smoke
scenario_with "SCREENSHOT=${WORK_DIR}/rich.png"

echo " evidence"
expect_pass "a passing run writes evidence" run_smoke
for evidence in case.png case-summary.txt case-crash-buffer.txt case-exit-info.txt case-logcat.txt; do
  if [[ -s "${WORK_DIR}/evidence/${evidence}" ]]; then
    ok "evidence ${evidence} exists and is non-empty"
  else
    bad "evidence ${evidence} exists and is non-empty"
  fi
done
if grep -q "result: PASS" "${WORK_DIR}/evidence/case-summary.txt" 2>/dev/null; then
  ok "the summary records the verdict"
else
  bad "the summary records the verdict"
fi
if grep -q "apk sha256:" "${WORK_DIR}/evidence/case-summary.txt" 2>/dev/null; then
  ok "the summary records the exact artifact digest"
else
  bad "the summary records the exact artifact digest"
fi

echo " PNG complexity decoder"
sed -n '/^png_distinct_colors()/,/^}/p' "${SCRIPT}" >"${WORK_DIR}/decoder.sh"
if [[ -s "${WORK_DIR}/decoder.sh" ]]; then
  ok "the decoder is extractable for unit testing"
else
  bad "the decoder is extractable for unit testing"
fi
decode_colors() {
  bash -c "source '${WORK_DIR}/decoder.sh'; png_distinct_colors '$1' 100000" _ "$1"
}
count="$(decode_colors "${WORK_DIR}/blank.png" 2>/dev/null || echo -1)"
if [[ "${count}" == "1" ]]; then
  ok "a solid-colour PNG decodes to exactly 1 colour"
else
  bad "a solid-colour PNG decodes to exactly 1 colour" "got '${count}'"
fi
count="$(decode_colors "${WORK_DIR}/rich.png" 2>/dev/null || echo -1)"
if [[ "${count}" =~ ^[0-9]+$ ]] && ((count > 1)); then
  ok "a rendered PNG decodes to many colours (${count})"
else
  bad "a rendered PNG decodes to many colours" "got '${count}'"
fi
if decode_colors "${WORK_DIR}/garbage.png" >/dev/null 2>&1; then
  bad "a non-PNG file is rejected by the decoder"
else
  ok "a non-PNG file is rejected by the decoder"
fi

printf '\n%s passed, %s failed\n' "${PASS_COUNT}" "${FAIL_COUNT}"
if ((FAIL_COUNT > 0)); then
  exit 1
fi
