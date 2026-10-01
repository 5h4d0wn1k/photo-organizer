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

# The runner detects a degraded suite by looking for this exact marker. A suite
# that cannot run an assertion must emit it, or a partial skip reads as a clean
# pass -- see the python3 guard below for the concrete case that motivated it.
DEGRADED_MARKER='RELEASE_GATE_SUITE_DEGRADED:'

# Guard first, before anything else runs. python3 builds this suite's APK and PNG
# fixtures *and* is the gate's own PNG complexity decoder, so without it most of
# the suite would run against empty fixtures. It must exit here, at the top,
# carrying the DEGRADED marker: the runner greps the whole log for that marker and
# fails on it, so a suite that cannot run reports itself as degraded rather than
# exiting 0 and reading as a clean pass over assertions that never executed.
if ! command -v python3 >/dev/null 2>&1; then
  printf '  SKIP %s\n' "the APK and PNG fixtures and the gate's PNG decoder all need python3"
  printf '  !! %s no python3 on PATH\n' "${DEGRADED_MARKER}"
  printf '  !! These assertions did NOT run; do not read this suite as a pass.\n'
  exit 0
fi

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

# True when haystack contains, contiguously, any of the ';'-separated patterns held
# in the named scenario variable. The haystack is passed in rather than read from
# "$*", because inside this function "$*" is the helper's own argument list -- the
# one key name -- not the adb command line being matched. Patterns contain spaces
# ("dumpsys activity exit-info"), so the split is done with IFS=';' rather than a
# bare unquoted expansion, which would also split on those spaces and never match a
# multi-word pattern.
matches_failure_pattern() {
  local key="$1" haystack="$2" list pattern
  list="$(scenario_value "${key}" 2>/dev/null || printf '')"
  [[ -n "${list}" ]] || return 1
  local IFS=';'
  # shellcheck disable=SC2086 # the split on ';' is the point; IFS is set above
  for pattern in ${list}; do
    [[ -n "${pattern}" ]] || continue
    if [[ "${haystack}" == *" ${pattern} "* ]]; then
      return 0
    fi
  done
  return 1
}

# Models a device that cannot answer: the emulator died, or the adb server was lost
# mid-run. The caller then sees an empty stdout and a non-zero status, which is
# exactly what a dead adb looks like.
#
# This is the case that used to be indistinguishable from a clean device. Both
# crash gates parse a string, and an empty string parses as "zero adverse exits" and
# "empty crash buffer" -- so a lost adb reported a *passing* crash check.
adb_should_fail() {
  # The launch boundary is the buffer clear the real gate makes immediately before
  # `am start`. ADB_FAIL_AFTER_LAUNCH_ONLY and ADB_FAIL_BEFORE_LAUNCH_ONLY hold
  # ';'-separated patterns scoped to one side of it, so the pre-launch and
  # post-launch halves of the exit-info gate can be broken independently to test
  # the baseline fallback. Scoping must be pattern-based: failing *every* command
  # after launch would break the focus and screenshot reads first, and the run
  # would fail long before the gate the scenario is meant to exercise.
  # "$*" here is the adb command line, which is what the pattern is matched
  # against. The leading and trailing spaces turn the match into a whole-token one.
  # Each arm ends in an explicit `return`, never a bare status: a trailing
  # `return 1` after the last call would silently discard the match it just made,
  # and the scenario would then be indistinguishable from the passing case.
  if [[ -f "${FAKE_ADB_STATE}" ]]; then
    if matches_failure_pattern ADB_FAIL " $* "; then
      return 0
    fi
    matches_failure_pattern ADB_FAIL_AFTER_LAUNCH_ONLY " $* "
    return $?
  fi
  if matches_failure_pattern ADB_FAIL " $* "; then
    return 0
  fi
  matches_failure_pattern ADB_FAIL_BEFORE_LAUNCH_ONLY " $* "
  return $?
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

if adb_should_fail "$@"; then
  printf 'adb: device offline (simulated)\n' >&2
  exit 1
fi

emit_exit_info() {
  if [[ -f "${FAKE_ADB_STATE}" ]]; then
    local after
    after="$(scenario_value EXIT_INFO_AFTER || true)"
    if [[ -n "${after}" && -f "${after}" ]]; then
      cat "${after}"
      return 0
    fi
  fi
  local before  before="$(scenario_value EXIT_INFO || true)"
  if [[ -n "${before}" && -f "${before}" ]]; then
    cat "${before}"
  fi
}

case "${verb}" in
  exec-out)
    if [[ "${args[0]:-}" == "screencap" ]]; then
      # The render loop has started: the launch checks (process wait, focus wait)
      # all run before the first screenshot, so this is the boundary between
      # "died on launch" and "died mid-render". Recorded for the PID_AFTER
      # mechanism below.
      : >"${SMOKE_WORK_DIR:-/tmp}/.rendering"
      # Not `local`: this heredoc body runs at the top level of the fake device,
      # so `local` would print "can only be used in a function" and leak a global.
      shot="$(scenario_value SCREENSHOT || true)"
      # Two visually complex but *different* frames, so no two consecutive
      # captures agree. This models a screen stuck mid-transition, which the gate
      # must reject: accepting the first complex frame is how a half-drawn screen
      # gets published.
      #
      # The fake device is a fresh process per adb call, so alternation needs state
      # on disk. Without it the two frames would never differ and this scenario
      # would be indistinguishable from the passing case.
      if [[ "$(scenario_value SCREENSHOT_DRIFT || true)" == "1" ]]; then
        # State has to live on disk: the fake device is a fresh process per adb
        # call, so an in-memory counter would reset every time and the two frames
        # would never differ.
        counter="${SMOKE_WORK_DIR:-/tmp}/.smoke-drift-counter"
        n=0
        if [[ -f "${counter}" ]]; then
          n="$(cat "${counter}" 2>/dev/null || printf 0)"
        fi
        printf '%s' "$((n + 1))" >"${counter}"
        if ((n % 2 == 1)); then
          drift_shot="${shot%.png}-drift.png"
          if [[ -f "${drift_shot}" ]]; then
            cat "${drift_shot}"
            exit 0
          fi
        fi
      fi
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
      # A process that dies mid-run: PID_AFTER, when set, replaces PID once the
      # render loop has started (the fake adb records that in .rendering on the
      # first screenshot). The device still answers -- adb is fine -- but the app
      # is gone. This is the only way to reach the `is_app_running || fail "died
      # while rendering"` check at the end of a passing render. The boundary
      # matters: the launch checks run before the first screenshot, so a PID that
      # vanishes at `am start` would fail at "not running after launch" instead,
      # and a PID absent from the start never reaches the render at all.
      *"pidof"*)
        if [[ -f "${SMOKE_WORK_DIR:-/tmp}/.rendering" ]] && grep -q '^PID_AFTER=' "${FAKE_ADB_SCENARIO}" 2>/dev/null; then
          printf '%s' "$(scenario_value PID_AFTER || true)"
        else
          printf '%s' "$(value_or PID)"
        fi
        exit 0
        ;;
      *"am start"*)
        printf 'Starting: Intent { act=android.intent.action.MAIN cmp=%s/.MainActivity }\n' "$(value_or PACKAGE com.privategallery.app)"
        printf 'Status: %s\n' "$(value_or AM_STATUS ok)"
        printf 'LaunchState: COLD\nTotalTime: 812\nComplete\n'
        exit 0
        ;;
      *"dumpsys window"*)
        # By default the app holds focus for the whole run. With
        # FOCUS_AFTER_FIRST_CHECK set, focus is held only for the first lookup and
        # is then stolen -- which is the case a single pre-loop focus check misses,
        # because the gate has already observed focus by the time it is stolen.
        focus_after="${SMOKE_WORK_DIR:-/tmp}/.focus-probe"
        probes=0
        [[ -f "${focus_after}" ]] && probes="$(cat "${focus_after}" 2>/dev/null || printf 0)"
        probes=$((probes + 1))
        printf '%s' "${probes}" >"${focus_after}"
        if [[ "$(scenario_value FOCUS_AFTER_FIRST_CHECK || true)" == "1" ]] && ((probes > 1)); then
          focus="com.android.permissioncontroller"
        else
          focus="$(value_or FOCUS com.privategallery.app)"
        fi
        printf '  mCurrentFocus=Window{deadbeef u0 %s/.MainActivity}\n' "${focus}"
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
      # Not `local`, for the same reason as the screencap branch above.
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
  # The fake device keeps its call counters on disk (it is a fresh process per adb
  # call). Reset them per case, or a counter left over from an earlier case makes
  # this one behave differently depending on test order.
  rm -f "${WORK_DIR}/.smoke-drift-counter" "${WORK_DIR}/.focus-probe" "${WORK_DIR}/.rendering"
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
    SMOKE_WORK_DIR="${WORK_DIR}" \
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

run_smoke_on() {
  local apk="$1"
  shift
  env \
    ANDROID_SMOKE_ADB="${WORK_DIR}/adb" \
    SMOKE_WORK_DIR="${WORK_DIR}" \
    ANDROID_SMOKE_EVIDENCE_DIR="${WORK_DIR}/evidence" \
    ANDROID_SMOKE_NAME="case" \
    ANDROID_SMOKE_BOOT_TIMEOUT_SECONDS="${SMOKE_BOOT_TIMEOUT:-10}" \
    ANDROID_SMOKE_LAUNCH_TIMEOUT_SECONDS="${SMOKE_LAUNCH_TIMEOUT:-10}" \
    ANDROID_SMOKE_RENDER_TIMEOUT_SECONDS="${SMOKE_RENDER_TIMEOUT:-6}" \
    ANDROID_SMOKE_POLL_INTERVAL_SECONDS=1 \
    FAKE_ADB_SCENARIO="${SCENARIO}" \
    FAKE_ADB_STATE="${FAKE_STATE}" \
    "$@" \
    bash "${SCRIPT}" "${apk}"
}

run_smoke_no_args() {
  env ANDROID_SMOKE_ADB="${WORK_DIR}/adb" FAKE_ADB_SCENARIO="${SCENARIO}" bash "${SCRIPT}"
}

# --- fixtures ----------------------------------------------------------------

install_fake_adb
make_png "${WORK_DIR}/rich.png" 40
make_png "${WORK_DIR}/blank.png" 1
# A second complex frame, for the never-settling scenario. It must be complex
# enough to clear the threshold -- otherwise the gate would reject it for being
# blank and the stability check would never be exercised.
make_png "${WORK_DIR}/rich-drift.png" 41
printf 'not a png at all' >"${WORK_DIR}/garbage.png"


# The gate reads the APK's native ABIs out of the archive before it touches the
# device, so the fixture has to be a real zip rather than arbitrary bytes --
# `unzip -Z1` on a non-archive either errors or prints nothing, and the check
# would then be skipped in every test rather than exercised.
#
# Built with Python's stdlib zipfile so the suite needs no `zip` tool. The
# three variants are the packaging regressions the check exists for: both real
# device ABIs present, only the emulator's ABI (installs on CI, fails on every
# real phone), and no native code at all (a dropped jniLibs step).
#
# The library is libflutter.so, which is what Flutter actually packages per ABI.
# The fixture used to be libgalleryd.so, mirroring a comment that claimed "the
# daemon ships native code" -- false, since native_core declares no crate-type and
# cargo-ndk therefore drops galleryd (see #140). A fixture that encodes a false
# premise makes the section untestable against reality.
#
# It is deliberately not libiroh.so. `iroh` and `iroh-relay` really do declare
# `crate-type = ["lib", "cdylib"]` and cargo really does emit those `.so`s, so
# this fixture is not asserting a fiction -- and asserting one would still be
# wrong, for three separate reasons: the name is governed by an upstream crate's
# `crate-type`, so the gate would fail for something outside this repo's
# packaging; cargo-ndk copies the emitted filename verbatim, so the packaged
# entry is `libiroh-<metadata-hash>.so` and no stable name to assert exists; and
# #140 will change what the right Rust witness is at all. libflutter.so is the
# ABI slice the gate actually exists to prove. The measurements behind all of
# this, and their limits, are recorded above REQUIRED_NATIVE_LIB in
# scripts/android_release_artifact_smoke.sh.
make_apk() {
  # Builds the fixture AND verifies it in the same process: testzip() reads
  # every entry back, and the namelist must contain exactly what the ABI
  # assertions below assume. A fixture truncated by a full disk (seen once:
  # the validation 50 lines below failed while the archive was later fine)
  # must fail here, at creation, with the true cause -- not downstream as a
  # misleading gate failure.
  python3 - "$1" "${@:2}" <<'PY'
import sys
import zipfile

path = sys.argv[1]
abis = sys.argv[2:]
with zipfile.ZipFile(path, "w") as archive:
    archive.writestr("AndroidManifest.xml", "<manifest package='com.privategallery.app'/>")
    archive.writestr("classes.dex", "fake dex")
    for abi in abis:
        archive.writestr(f"lib/{abi}/libflutter.so", f"fake native library for {abi}")
with zipfile.ZipFile(path) as archive:
    bad = archive.testzip()
    if bad is not None:
        print(f"FATAL: fixture {path} has a corrupt entry: {bad}", file=sys.stderr)
        sys.exit(1)
    names = set(archive.namelist())
    for abi in abis:
        entry = f"lib/{abi}/libflutter.so"
        if entry not in names:
            print(f"FATAL: fixture {path} is missing {entry}", file=sys.stderr)
            sys.exit(1)
PY
}

# An APK whose lib/<abi>/ directories exist and each hold a file, but not the
# native library. This is the case the gate used to accept: the check matched on
# the "^lib/<abi>/" directory prefix, so one stray file satisfied it for every ABI
# at once.
make_abi_dirs_only_apk() {
  python3 - "$1" "${@:2}" <<'PY'
import sys
import zipfile

path = sys.argv[1]
abis = sys.argv[2:]
with zipfile.ZipFile(path, "w") as archive:
    archive.writestr("AndroidManifest.xml", "<manifest package='com.privategallery.app'/>")
    archive.writestr("classes.dex", "fake dex")
    for abi in abis:
        archive.writestr(f"lib/{abi}/placeholder.txt", "not a native library")
with zipfile.ZipFile(path) as archive:
    bad = archive.testzip()
    if bad is not None:
        print(f"FATAL: fixture {path} has a corrupt entry: {bad}", file=sys.stderr)
        sys.exit(1)
    names = set(archive.namelist())
    for abi in abis:
        if f"lib/{abi}/placeholder.txt" not in names:
            print(f"FATAL: fixture {path} is missing lib/{abi}/placeholder.txt", file=sys.stderr)
            sys.exit(1)
PY
}

# An APK whose lib/<abi>/ entry is a *near miss* for the required library name --
# `libflutterXso`, one character different. This is not hypothetical: the check
# used `grep -q "^lib/<abi>/libflutter.so$"`, and `.` is a regex metacharacter, so
# `libflutterXso` satisfied it. The archive would be reported as carrying the
# Flutter engine while carrying something else. Its own fixture, so the assertion
# that rejects it cannot be satisfied by the missing-library or missing-directory
# guards.
make_abi_nearmiss_apk() {
  python3 - "$1" "${@:2}" <<'PY'
import sys
import zipfile

path = sys.argv[1]
abis = sys.argv[2:]
with zipfile.ZipFile(path, "w") as archive:
    archive.writestr("AndroidManifest.xml", "<manifest package='com.privategallery.app'/>")
    archive.writestr("classes.dex", "fake dex")
    for abi in abis:
        archive.writestr(f"lib/{abi}/libflutterXso", "not the engine")
with zipfile.ZipFile(path) as archive:
    bad = archive.testzip()
    if bad is not None:
        print(f"FATAL: fixture {path} has a corrupt entry: {bad}", file=sys.stderr)
        sys.exit(1)
    names = set(archive.namelist())
    for abi in abis:
        if f"lib/{abi}/libflutterXso" not in names:
            print(f"FATAL: fixture {path} is missing lib/{abi}/libflutterXso", file=sys.stderr)
            sys.exit(1)
PY
}

# Fixture creation is infrastructure, not an assertion: if it fails, nothing
# below can mean anything, so stop with a non-zero exit rather than cascading
# dozens of misleading failures. (A failing suite is honest; a suite that
# fails 40 unrelated assertions over one truncated fixture is noise.)
make_apk "${WORK_DIR}/app-release.apk" arm64-v8a armeabi-v7a x86_64 || exit 1
make_apk "${WORK_DIR}/apk-x86-only.apk" x86_64 || exit 1
make_apk "${WORK_DIR}/apk-no-native.apk" || exit 1
make_abi_dirs_only_apk "${WORK_DIR}/apk-abi-dirs-only.apk" arm64-v8a armeabi-v7a x86_64 || exit 1
make_abi_nearmiss_apk "${WORK_DIR}/apk-abi-nearmiss.apk" arm64-v8a armeabi-v7a x86_64 || exit 1


# How unzip's exit status is captured matters, and getting it wrong is silent.
#
#     out="$(unzip -Z1 "$f" || rc=$?)"   # rc stays 0 in this shell
#     out="$(unzip -Z1 "$f")" || rc=$?    # rc is the command's real status
#
# The first form looks like it records the status, but `$( ... )` is a subshell:
# the `rc=$?` runs and dies inside it, so the parent keeps whatever it had. With
# `rc=0` pre-initialised that is always 0, the guard below is always satisfied,
# and a *missing or broken unzip* is reported as a wrong-fixture failure -- the
# exact ambiguity this is here to remove. So the assignment stands alone and the
# `||` follows it. Each check keeps its own status variable because the `||`
# only reports the last command substitution's status.
#
# All three checks stay fail-closed: a non-zero status fails the assertion here
# and never falls through to a gate assertion below.

# The fixture must really contain what the passing test assumes, or every ABI
# assertion below would be satisfied by an empty archive. make_apk already
# verified this at creation; this re-checks through the same tool the gate
# uses (unzip), and reports the tool's own exit code and the file size on
# failure -- the previous version discarded stderr, which is why the one
# observed flake of this line arrived with no evidence at all.
unzip_rc=0
unzip_out="$(unzip -Z1 "${WORK_DIR}/app-release.apk" 2>"${WORK_DIR}/unzip-err.log")" || unzip_rc=$?
if ((unzip_rc == 0)) && grep -qFx 'lib/arm64-v8a/libflutter.so' <<<"${unzip_out}"; then
  ok "the default APK fixture is a real archive carrying an arm64-v8a library"
else
  bad "the default APK fixture is a real archive carrying an arm64-v8a library" \
    "unzip exit ${unzip_rc}, size $(wc -c <"${WORK_DIR}/app-release.apk" 2>/dev/null || echo '?') bytes, stderr: $(tr '\n' ' ' <"${WORK_DIR}/unzip-err.log" 2>/dev/null | cut -c1-160)"
fi

# The negative fixture must be negative in the specific way asserted below --
# lib/<abi>/ directories present, native library absent. A fixture that merely
# lacked lib/ would exercise the other guard and make the directory-prefix
# assertion pass for the wrong reason. Same unzip_rc treatment as above, so a
# tool failure is distinguishable from a wrong fixture.
dirs_rc=0
dirs_out="$(unzip -Z1 "${WORK_DIR}/apk-abi-dirs-only.apk" 2>"${WORK_DIR}/unzip-dirs-err.log")" || dirs_rc=$?
if ((dirs_rc == 0)) && grep -q '^lib/arm64-v8a/placeholder.txt$' <<<"${dirs_out}"; then
  ok "the ABI-dirs-only fixture has lib/<abi>/ entries but no native library"
else
  bad "the ABI-dirs-only fixture has lib/<abi>/ entries but no native library" \
    "unzip exit ${dirs_rc}, size $(wc -c <"${WORK_DIR}/apk-abi-dirs-only.apk" 2>/dev/null || echo '?') bytes, stderr: $(tr '\n' ' ' <"${WORK_DIR}/unzip-dirs-err.log" 2>/dev/null | cut -c1-160). Fixture shape is wrong either way, so the directory-prefix assertion below is vacuous."
fi

# The near-miss fixture must hold the almost-right name, or the assertion below
# could pass because the archive was empty rather than because the gate saw
# `libflutterXso`. Same unzip_rc treatment as above, for the same reason.
nearmiss_rc=0
nearmiss_out="$(unzip -Z1 "${WORK_DIR}/apk-abi-nearmiss.apk" 2>"${WORK_DIR}/unzip-nearmiss-err.log")" || nearmiss_rc=$?
if ((nearmiss_rc == 0)) && grep -qFx 'lib/arm64-v8a/libflutterXso' <<<"${nearmiss_out}"; then
  ok "the ABI near-miss fixture carries libflutterXso, not the engine"
else
  bad "the ABI near-miss fixture carries libflutterXso, not the engine" \
    "unzip exit ${nearmiss_rc}, size $(wc -c <"${WORK_DIR}/apk-abi-nearmiss.apk" 2>/dev/null || echo '?') bytes, stderr: $(tr '\n' ' ' <"${WORK_DIR}/unzip-nearmiss-err.log" 2>/dev/null | cut -c1-160). Fixture shape is wrong either way, so the near-miss assertion below is vacuous."
fi

: >"${WORK_DIR}/empty-exit-info.txt"

cat >"${WORK_DIR}/anr-exit-info.txt" <<'EOF'
  ApplicationExitInfo #0:
    reason=6 (ANR)
    timestamp=2026-09-26 00:00:00
EOF

# The healthy reply for a freshly installed app that is still running: the dumpsys
# section header, and no ApplicationExitInfo block under it, because the app has
# never been recorded as having exited. This is the real shape on API 30+, and the
# default scenario uses it, so the comparison path is what every ordinary run
# exercises. An empty file is NOT a valid stand-in for this: on a device whose API
# level supports exit-info, an empty reply is a failed read, and the gate now says
# so rather than treating it as a clean device.
printf 'ACTIVITY MANAGER LRU PROCESSES (dumpsys activity exit-info)\n' \
  >"${WORK_DIR}/header-only-exit-info.txt"

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

# A realistic exit-info dump that is *not* blank and contains no adverse reason.
# This is the case that exercises the baseline comparison: an empty file is
# indistinguishable from the service being absent, and the gate returns early for
# that. Without this fixture the "no baseline available, so zero is required"
# fallback is only ever reachable on a device that has no exit-info at all, which
# would make the fallback path untested.
cat >"${WORK_DIR}/clean-exit-info.txt" <<'EOF'
ACTIVITY MANAGER LRU PROCESSES (dumpsys activity exit-info)
  Historical Process Exit for com.privategallery.app
    ApplicationExitInfo #0:
      timestamp=2026-09-26T00:00:01.000Z
      reason=1 (REASON_USER_REQUESTED)
      status=0
      importance=1000
      pss=0KB
      rss=0KB
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
EXIT_INFO=${WORK_DIR}/header-only-exit-info.txt
EXIT_INFO_AFTER=${WORK_DIR}/header-only-exit-info.txt
EOF
cp "${SCENARIO}" "${BASE_SCENARIO}"

# Two PATHs, so the "the ABI check could not run" cases are exercised for real
# rather than simulated through a knob the gate would have to grow. A knob here
# would be worse than no test: it would be a new way to point the check at
# something harmless, which is the very failure being guarded against. Manipulating
# PATH exercises the real `command -v` and the real exit status of a real unzip.
#
# The farm lists only what the gate actually invokes. An earlier version symlinked
# every executable on the real PATH -- ~12,000 symlinks per suite run, which is
# slow enough to be a CI cost and to perturb the timing-sensitive render tests.
# Completeness is not assumed: the guard below runs the *unmodified* gate with the
# farm and a working unzip, and requires it to pass. If the list is missing a tool,
# that guard fails loudly instead of the two cases silently failing for the wrong
# reason.
#
# The farm is only in the gate's environment (via run_smoke_on), so the suite keeps
# using the real tools for its own fixtures.
GATE_TOOLS='bash sh env cat cp mv rm mkdir rmdir sleep grep sed awk tr cut head tail
wc sort uniq comm dirname basename date mktemp realpath readlink stat touch printf
echo id expr find python3 python sha256sum shasum unzip diff cmp od xxd'

make_path_farm() {
  local destination="$1" tool dir
  mkdir -p "${destination}"
  for tool in ${GATE_TOOLS}; do
    [[ -e "${destination}/${tool}" ]] && continue
    dir="$(command -v "${tool}" 2>/dev/null || true)"
    [[ -n "${dir}" ]] && ln -sf "${dir}" "${destination}/${tool}"
  done
}

NO_UNZIP_BIN="${WORK_DIR}/path-no-unzip"
UNZIP_FAIL_BIN="${WORK_DIR}/path-unzip-fail"
make_path_farm "${NO_UNZIP_BIN}"
# cp -a preserves the symlink, so the copy would point at the *system* unzip and
# writing the stub would then write through it into /usr/bin. Remove first, then
# write a real file.
cp -a "${NO_UNZIP_BIN}/." "${UNZIP_FAIL_BIN}/"
rm -f "${NO_UNZIP_BIN}/unzip" "${UNZIP_FAIL_BIN}/unzip"
# An unzip that is present but cannot list the archive -- a truncated download, a
# zip/busybox-only image, a variant without -Z1. Any non-zero exit must be fatal.
cat >"${UNZIP_FAIL_BIN}/unzip" <<'SH'
#!/bin/sh
echo "unzip: cannot find or open the archive (simulated unreadable archive)" >&2
exit 9
SH
chmod +x "${UNZIP_FAIL_BIN}/unzip"
# The stub must be a real file, not a symlink to the system unzip. Writing through
# such a link would either fail silently -- leaving the "stub" as the genuine
# unzip, so the case under test quietly tested nothing -- or, on a machine where
# the write succeeded, overwrite the system tool.
if [[ -L "${UNZIP_FAIL_BIN}/unzip" ]]; then
  bad "the stub unzip is a real file, not a symlink to the system unzip" \
    "it is a symlink to $(readlink "${UNZIP_FAIL_BIN}/unzip")"
else
  ok "the stub unzip is a real file, not a symlink to the system unzip"
fi

# Guard 1: the farm really removes unzip.
if PATH="${NO_UNZIP_BIN}" command -v unzip >/dev/null 2>&1; then
  bad "the missing-unzip fixture really removes unzip from PATH" "unzip is still visible"
else
  ok "the missing-unzip fixture really removes unzip from PATH"
fi
# Guard 2: the farm is complete. The unmodified gate, with the farm and a working
# unzip, must pass. This is what makes the two failing cases meaningful -- without
# it, a farm missing `sed` would make the ABI check "fail" for the wrong reason and
# the test would still report ok.
FARM_WITH_UNZIP="${WORK_DIR}/path-complete"
make_path_farm "${FARM_WITH_UNZIP}"
if run_smoke_on "${WORK_DIR}/app-release.apk" "PATH=${FARM_WITH_UNZIP}" \
  >"${WORK_DIR}/farm-complete.log" 2>&1; then
  ok "the restricted PATH is complete enough for the gate to pass"
else
  bad "the restricted PATH is complete enough for the gate to pass" \
    "the farm is missing a tool the gate needs, which would invalidate the two cases below: $(tr '\n' '|' <"${WORK_DIR}/farm-complete.log" | cut -c1-240)"
fi
# Guard 3: the stub unzip really fails on a real archive.
if PATH="${UNZIP_FAIL_BIN}" unzip -Z1 "${WORK_DIR}/app-release.apk" >/dev/null 2>&1; then
  bad "the unreadable-archive fixture really makes unzip fail" "the stub unzip succeeded"
else
  ok "the unreadable-archive fixture really makes unzip fail"
fi

# --- tests -------------------------------------------------------------------

echo "android_release_artifact_smoke.sh"

echo " happy path"
expect_pass "installs, cold-launches, renders, and passes" run_smoke

echo " argument and input validation"
expect_fail "no APK argument is a usage error" "usage" run_smoke_no_args
expect_fail "a missing APK file fails fast" "APK not found" run_smoke_missing_apk

echo " native ABIs (the emulator matrix is x86_64-only, so this cannot be caught by installing)"
# Both smoke legs run x86_64 system images, because there is no free hosted arm64
# emulator. So the emulator can only ever prove the x86_64 slice: an APK carrying
# just that slice installs perfectly on the runner and fails on every real phone
# with INSTALL_FAILED_NO_MATCHING_ABIS. The archive is therefore checked directly.
if run_smoke_on "${WORK_DIR}/apk-x86-only.apk" >"${WORK_DIR}/abi.log" 2>&1; then
  bad "an APK with only the emulator's ABI is rejected" \
    "the gate passed an APK that cannot install on any real device"
else
  if grep -q "missing libflutter.so for arm64-v8a" "${WORK_DIR}/abi.log"; then
    ok "an APK with only the emulator's ABI is rejected"
  else
    bad "an APK with only the emulator's ABI is rejected" \
      "it failed, but not for the ABI reason: $(tr '\n' '|' <"${WORK_DIR}/abi.log")"
  fi
fi
# The engine entry must match exactly. `grep` without -F treats the `.` in
# `libflutter.so` as "any character", so `libflutterXso` satisfied the old check --
# an archive reported as carrying the engine while carrying a different file. The
# near-miss fixture is the only input that distinguishes the two forms; the
# missing-library and missing-directory fixtures are rejected either way.
if run_smoke_on "${WORK_DIR}/apk-abi-nearmiss.apk" >"${WORK_DIR}/abi-nearmiss.log" 2>&1; then
  bad "an APK whose library is a near-miss name for the engine fails the gate" \
    "passed: libflutterXso was accepted as if it were libflutter.so"
else
  if grep -q "missing libflutter.so for arm64-v8a" "${WORK_DIR}/abi-nearmiss.log"; then
    ok "an APK whose library is a near-miss name for the engine fails the gate"
  else
    bad "an APK whose library is a near-miss name for the engine fails the gate" \
      "it failed, but not for the ABI reason: $(tr '\n' '|' <"${WORK_DIR}/abi-nearmiss.log")"
  fi
fi
# The failure has to name the ABI that is missing, or whoever reads the log cannot
# tell which cross-compile target to add back.
if grep -q "missing libflutter.so for armeabi-v7a" \
  <(ANDROID_SMOKE_REQUIRED_ABIS="armeabi-v7a" run_smoke_on "${WORK_DIR}/apk-x86-only.apk" 2>&1); then
  ok "the ABI failure names the missing ABI, not just 'install failed'"
else
  bad "the ABI failure names the missing ABI, not just 'install failed'" \
    "the message did not identify armeabi-v7a"
fi
# The 32-bit ABI is the one a cross-compile change drops first, so assert it
# individually rather than only as part of the combined default.
if ANDROID_SMOKE_REQUIRED_ABIS="armeabi-v7a" \
  run_smoke_on "${WORK_DIR}/app-release.apk" >/dev/null 2>&1; then
  ok "an APK carrying both real device ABIs passes the ABI check"
else
  bad "an APK carrying both real device ABIs passes the ABI check" "the good fixture was rejected"
fi
# An APK with no lib/ entries at all is a packaging regression, not a Java-only
# build: Flutter Android builds carry per-ABI native libraries. It used to pass
# with a warning, which was wrong for a reason specific to this gate -- an APK
# carrying no native libraries installs on the x86_64 emulator with no ABI
# mismatch, launches and renders, so nothing downstream compensates and a warning
# is not a control.
if run_smoke_on "${WORK_DIR}/apk-no-native.apk" >"${WORK_DIR}/no-native.log" 2>&1; then
  bad "an APK with no native code at all fails the gate" \
    "passed: with no lib/ entries there is no ABI mismatch on the x86_64 emulator, so nothing else would catch a dropped jniLibs step"
else
  if grep -qF "no lib/ entries" "${WORK_DIR}/no-native.log"; then
    ok "an APK with no native code at all fails the gate"
  else
    bad "an APK with no native code at all fails the gate" \
      "failed for the wrong reason: $(tr '\n' '|' <"${WORK_DIR}/no-native.log" | cut -c1-200)"
  fi
fi
# The lib/<abi>/ directories existing is not evidence that the ABI slice shipped.
# The check used to be a prefix match on "^lib/<abi>/", so an APK carrying one
# stray file per ABI directory satisfied every required ABI at once -- and on a
# real arm device that APK fails to install with INSTALL_FAILED_NO_MATCHING_ABIS,
# which is the exact bug this gate exists to stop. Asserted separately from the
# no-lib/ guard above, on a fixture that has lib/ entries precisely so the other
# guard cannot be what rejects it.
if run_smoke_on "${WORK_DIR}/apk-abi-dirs-only.apk" >"${WORK_DIR}/abi-dirs.log" 2>&1; then
  bad "an APK whose lib/<abi>/ directories exist but hold no native library fails the gate" \
    "passed: the directory prefix is not the native library, so a real arm install would fail"
else
  if grep -qF "no lib/arm64-v8a/libflutter.so" "${WORK_DIR}/abi-dirs.log"; then
    ok "an APK whose lib/<abi>/ directories exist but hold no native library fails the gate"
  else
    bad "an APK whose lib/<abi>/ directories exist but hold no native library fails the gate" \
      "failed for the wrong reason: $(tr '\n' '|' <"${WORK_DIR}/abi-dirs.log" | cut -c1-200)"
  fi
fi
# ...and the two ways the check itself cannot run must also fail, rather than
# degrading. Same reasoning: nothing downstream re-asserts the arm ABIs, so a
# missing tool or an unreadable archive is a release that cannot be shown to work.
if run_smoke_on "${WORK_DIR}/app-release.apk" "PATH=${NO_UNZIP_BIN}" \
  >"${WORK_DIR}/no-unzip.log" 2>&1; then
  bad "a missing unzip fails the gate rather than skipping the only arm-ABI check" \
    "passed: without unzip there is no verification of the real device ABIs at all"
else
  if grep -qF "unzip is not available" "${WORK_DIR}/no-unzip.log"; then
    ok "a missing unzip fails the gate rather than skipping the only arm-ABI check"
  else
    bad "a missing unzip fails the gate rather than skipping the only arm-ABI check" \
      "failed for the wrong reason: $(tr '\n' '|' <"${WORK_DIR}/no-unzip.log" | cut -c1-200)"
  fi
fi
if run_smoke_on "${WORK_DIR}/app-release.apk" "PATH=${UNZIP_FAIL_BIN}" \
  >"${WORK_DIR}/unzip-fail.log" 2>&1; then
  bad "an unreadable archive fails the gate rather than skipping the only arm-ABI check" \
    "passed: an unlistable archive cannot be shown to carry the arm ABIs"
else
  if grep -qF "could not list the APK archive" "${WORK_DIR}/unzip-fail.log"; then
    ok "an unreadable archive fails the gate rather than skipping the only arm-ABI check"
  else
    bad "an unreadable archive fails the gate rather than skipping the only arm-ABI check" \
      "failed for the wrong reason: $(tr '\n' '|' <"${WORK_DIR}/unzip-fail.log" | cut -c1-200)"
  fi
fi
# A passing run must say which ABIs it found, not just that nothing was missing.
# A reader diagnosing "does this build support my phone?" should be able to answer
# from the log without unzipping the artifact themselves.
if run_smoke_on "${WORK_DIR}/app-release.apk" >"${WORK_DIR}/abi-pass.log" 2>&1 &&
  grep -qF "native library present: lib/arm64-v8a/libflutter.so" "${WORK_DIR}/abi-pass.log" &&
  grep -qF "native library present: lib/armeabi-v7a/libflutter.so" "${WORK_DIR}/abi-pass.log"; then
  ok "the ABI check reports each ABI it found"
else
  bad "the ABI check reports each ABI it found" \
    "a passing run did not name both ABIs: $(tr '\n' '|' <"${WORK_DIR}/abi-pass.log")"
fi

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

# ...and an app that survives launch but dies during the render wait must fail at
# the end, not pass on the strength of the earlier checks. PID_AFTER replaces the
# PID once the launch boundary is crossed, so the launch checks see a live process
# and only the final `is_app_running` sees it gone. Without this the "died while
# rendering" line is dead code that no test reaches.
scenario_with "PID_AFTER="
expect_fail "an app that dies after launching fails instead of passing on its earlier checks" \
  "died while rendering" run_smoke
scenario_with "PID_AFTER=4242"

scenario_with "FOCUS=com.android.permissioncontroller"
expect_fail "a permission dialog stealing focus fails" "never took window focus" run_smoke
scenario_with "FOCUS=com.privategallery.app"

scenario_with "BOOTED="
expect_fail "an unbooted emulator fails instead of hanging" "sys.boot_completed" run_smoke
scenario_with "BOOTED=1"

echo " crash, native-crash and ANR detection"
# A logcat buffer header with no entries is not a crash. Some platform versions
# print one, and treating it as a crash would fail every release -- a false
# positive that gets the gate disabled.
printf -- '--------- beginning of crash\n' >"${WORK_DIR}/crash-header-only.txt"
scenario_with "CRASH_BUFFER=${WORK_DIR}/crash-header-only.txt"
expect_pass "a logcat buffer header alone does not fail the gate" run_smoke
printf -- '--------- beginning of crash\n\n' >"${WORK_DIR}/crash-header-and-blank.txt"
scenario_with "CRASH_BUFFER=${WORK_DIR}/crash-header-and-blank.txt"
expect_pass "a header followed by blank lines does not fail the gate" run_smoke

scenario_with "CRASH_BUFFER=${WORK_DIR}/crash-java.txt"
expect_fail "a Java FATAL EXCEPTION fails the gate" "crash/ANR detected" run_smoke
scenario_with "CRASH_BUFFER=${WORK_DIR}/empty-exit-info.txt"

# The header tolerance must not become a loophole: real content after a header
# is still a crash.
printf -- '--------- beginning of crash\n09-27 10:00:00.000  1000  1000 F DEBUG   : *** *** ***\n' \
  >"${WORK_DIR}/crash-header-then-native.txt"
scenario_with "CRASH_BUFFER=${WORK_DIR}/crash-header-then-native.txt"
expect_fail "a header followed by a real tombstone still fails the gate" "crash/ANR detected" run_smoke
scenario_with "CRASH_BUFFER=${WORK_DIR}/empty-exit-info.txt"

scenario_with "CRASH_BUFFER=${WORK_DIR}/crash-native.txt"
expect_fail "a native galleryd SIGSEGV fails the gate" "crash/ANR detected" run_smoke
scenario_with "CRASH_BUFFER=${WORK_DIR}/empty-exit-info.txt"

scenario_with "CRASH_BUFFER=${WORK_DIR}/crash-other-app.txt"
expect_fail "crash-buffer content is never silently ignored" "crash/ANR detected" run_smoke
scenario_with "CRASH_BUFFER=${WORK_DIR}/empty-exit-info.txt"

scenario_with "EXIT_INFO_AFTER=${WORK_DIR}/anr-exit-info.txt"
expect_fail "an ANR recorded after launch fails the gate" "adverse ApplicationExitInfo" run_smoke
scenario_with "EXIT_INFO_AFTER=${WORK_DIR}/header-only-exit-info.txt"

# The adverse entry's own free text must not be able to disable the check.
# `dumpsys activity exit-info` carries a `description=` field holding the crash or
# ANR message verbatim, and this is a photo library whose daemon resolves paths
# and opens its index -- so "...: no such file or directory", "...: /data/gallery.db
# not found" and friends are entirely ordinary strings in that field. The
# capability probe used to substring-match the whole dump for `not found`, which
# meant an adverse entry could suppress the very check meant to catch it: the
# gate logged "exit-info unavailable on this API level" and returned clean. That is
# the #97 bug class -- a crash shipping green -- reached through a different door.
# Each fixture below is byte-identical to anr-exit-info.txt except for a
# description line, so the only variable is the crash message text.
printf -- '  ApplicationExitInfo #0:\n    reason=6 (ANR)\n    description=Input dispatching timed out: galleryd IPC endpoint not found\n' \
  >"${WORK_DIR}/anr-descr-not-found.txt"
printf -- '  ApplicationExitInfo #0:\n    reason=5 (REASON_CRASH_NATIVE)\n    description=SIGSEGV in galleryd opening /data/gallery.db: No such file or directory (ENOENT), path not found\n' \
  >"${WORK_DIR}/native-descr-not-found.txt"
printf -- '  ApplicationExitInfo #0:\n    reason=6 (ANR)\n    description=Input dispatching timed out\n' \
  >"${WORK_DIR}/anr-descr-control.txt"
for descr_case in anr-descr-not-found native-descr-not-found anr-descr-control; do
  scenario_with "CRASH_BUFFER=${WORK_DIR}/empty-exit-info.txt" \
    "EXIT_INFO_AFTER=${WORK_DIR}/${descr_case}.txt"
  expect_fail "an adverse entry whose description says 'not found' still fails the gate" \
    "adverse ApplicationExitInfo" run_smoke
  scenario_with "EXIT_INFO_AFTER=${WORK_DIR}/header-only-exit-info.txt"
done

scenario_with "EXIT_INFO=${WORK_DIR}/anr-exit-info.txt" \
  "EXIT_INFO_AFTER=${WORK_DIR}/anr-exit-info.txt"
expect_pass "a pre-existing adverse entry does not fail the gate" run_smoke
scenario_with "EXIT_INFO=${WORK_DIR}/header-only-exit-info.txt"

echo " exit-info is skipped only where the platform truly has no exit-info"
# The capability decision now comes from a dedicated API-level probe. That means the
# four states a post-launch read can be in are each pinned, because a check that
# switches itself off silently is the failure this gate exists to prevent.
#   1. blank reply on API >= 30 -> a failed read, not a clean device.
scenario_with "EXIT_INFO_AFTER=${WORK_DIR}/empty-exit-info.txt"
expect_fail "a blank exit-info read on a device that supports it is a failed read, not clean" \
  "this is a failed read, not a clean result" run_smoke
scenario_with "EXIT_INFO_AFTER=${WORK_DIR}/header-only-exit-info.txt"
#   2. the dumpsys header with no records under it -> the real reply for a running
#      app, so clean. Every ordinary passing case above already asserts this; it is
#      repeated here so cases (1) and (2) cannot drift apart.
expect_pass "the dumpsys header with no records is a real clean reply" run_smoke
#   3. an unrecognised non-blank reply -> refused, because zero adverse entries
#      counted in something that was never a dump is not evidence of anything.
printf 'something went wrong and this is not a dump\n' >"${WORK_DIR}/garbage-exit-info.txt"
scenario_with "EXIT_INFO_AFTER=${WORK_DIR}/garbage-exit-info.txt"
expect_fail "an unrecognised exit-info reply is refused rather than counted as clean" \
  "refusing to report a crash check that never ran" run_smoke
scenario_with "EXIT_INFO_AFTER=${WORK_DIR}/header-only-exit-info.txt"
#   4. API < 30 -> the feature genuinely does not exist, so skipping is correct, and
#      the skip is recorded as a warning rather than being silent.
scenario_with "ANDROID_SDK=29" \
  "EXIT_INFO_AFTER=${WORK_DIR}/empty-exit-info.txt"
if run_smoke >"${WORK_DIR}/pre30.log" 2>&1; then
  if grep -qF '::warning::API level is below 30' "${WORK_DIR}/pre30.log"; then
    ok "a pre-30 device skips the exit-info check and says so with a warning"
  else
    bad "a pre-30 device skips the exit-info check and says so with a warning" \
      "passed without recording the skip: $(tr '\n' ' ' <"${WORK_DIR}/pre30.log" | cut -c1-200)"
  fi
else
  bad "a pre-30 device skips the exit-info check and says so with a warning" \
    "expected a pass on API 29; got: $(tr '\n' ' ' <"${WORK_DIR}/pre30.log" | cut -c1-200)"
fi
scenario_with "ANDROID_SDK="
# And the probe must not be satisfied by guessing. This only matters when the probe
# is actually consulted -- a valid dumpsys reply needs no capability check at all,
# so the unreadable API level is combined with the ambiguous blank read, which is
# the only state where the platform decides the outcome.
scenario_with "ADB_FAIL=getprop ro.build.version.sdk" \
  "EXIT_INFO_AFTER=${WORK_DIR}/empty-exit-info.txt"
expect_fail "an unreadable API level does not silently choose a side" \
  "refusing to report a crash check that never ran" run_smoke
scenario_with "ADB_FAIL="
scenario_with "EXIT_INFO_AFTER=${WORK_DIR}/header-only-exit-info.txt"

echo " a device that cannot answer is not a clean device"
# Both crash gates parse a string. An adb that died mid-run returns an empty string
# with a non-zero status, and empty parses as "zero adverse exits" and "empty crash
# buffer" -- so a lost adb used to produce a *passing* crash check. These are the
# two gates in the whole script whose failure direction is the dangerous one, so
# they must distinguish "the device said nothing is wrong" from "I could not ask".
scenario_with "ADB_FAIL=logcat -b crash"
expect_fail "an unreadable crash buffer fails the gate rather than reporting clean" \
  "refusing to report a crash check that never ran" run_smoke
scenario_with "ADB_FAIL="

scenario_with "ADB_FAIL=dumpsys activity exit-info"
expect_fail "an unreadable ApplicationExitInfo fails the gate rather than reporting clean" \
  "refusing to report a crash check that never ran" run_smoke
scenario_with "ADB_FAIL="

# Losing the device before the render wait must also fail rather than being read as
# "the app never took focus" -- it does fail, but for the right reason only if the
# focus check propagates the adb status instead of treating the empty dump as an
# unfocused window. Same verdict either way, so this asserts the status is
# propagated, not just that something failed.
scenario_with "ADB_FAIL=dumpsys window"
expect_fail "a failed focus probe does not read as a focused app" "never took window focus" run_smoke
scenario_with "ADB_FAIL="

# With the pre-launch read broken but the post-launch read working, the gate must
# fall back to the *stronger* requirement (zero adverse entries outright) rather
# than comparing against a baseline that was never taken. ADB_FAIL_BEFORE_LAUNCH_ONLY
# is what makes this case reachable: failing both reads would exercise the
# unreadable-dump path instead, and failing only the post-launch read has nothing to
# do with the baseline.
scenario_with "EXIT_INFO_AFTER=${WORK_DIR}/anr-exit-info.txt" \
  "ADB_FAIL_BEFORE_LAUNCH_ONLY=dumpsys activity exit-info"
expect_fail "an adverse exit with no baseline is not excused" \
  "no pre-launch baseline" run_smoke
scenario_with "EXIT_INFO_AFTER=${WORK_DIR}/clean-exit-info.txt" \
  "ADB_FAIL_BEFORE_LAUNCH_ONLY=dumpsys activity exit-info"
expect_pass "an unavailable baseline with no adverse entries still passes" run_smoke
scenario_with "ADB_FAIL_BEFORE_LAUNCH_ONLY="
scenario_with "EXIT_INFO_AFTER=${WORK_DIR}/header-only-exit-info.txt"

# ...and that fallback must actually be reachable, i.e. a working post-launch read
# with a broken pre-launch read must not be reported as a clean comparison. The
# exit-info fixture is set on both sides so the post-launch dump is real rather
# than blank: a blank dump is a different case (the API level has no exit-info) and
# would return before the baseline is ever consulted.
scenario_with "EXIT_INFO=${WORK_DIR}/clean-exit-info.txt" \
  "EXIT_INFO_AFTER=${WORK_DIR}/clean-exit-info.txt" \
  "ADB_FAIL_BEFORE_LAUNCH_ONLY=dumpsys activity exit-info"
if run_smoke >"${WORK_DIR}/baseline-lost.log" 2>&1; then
  if grep -q "no baseline available so zero is required" "${WORK_DIR}/baseline-lost.log"; then
    ok "a lost pre-launch baseline is stated in the run log, not silently treated as zero"
  else
    bad "a lost pre-launch baseline is stated in the run log, not silently treated as zero" \
      "the run passed without saying the baseline was unavailable; log: $(tr '\n' '|' <"${WORK_DIR}/baseline-lost.log")"
  fi
else
  bad "a lost pre-launch baseline is stated in the run log, not silently treated as zero" \
    "the run failed, so the fallback path is unreachable; log: $(tr '\n' '|' <"${WORK_DIR}/baseline-lost.log")"
fi
scenario_with "ADB_FAIL_BEFORE_LAUNCH_ONLY="
scenario_with "EXIT_INFO_AFTER=${WORK_DIR}/header-only-exit-info.txt"

echo " rendering"
# A blank (single-colour) screen is never accepted, however long it persists: two
# identical blank captures are stable but not visually complex.
scenario_with "SCREENSHOT=${WORK_DIR}/blank.png"
expect_fail "a blank screen counts as never rendered" "no settled app frame" run_smoke
scenario_with "SCREENSHOT=${WORK_DIR}/rich.png"

# An undecodable capture is not a frame. The old code retried on a decode failure
# and eventually reported a timeout, which is the right outcome but for the wrong
# reason; the message now names the real condition.
scenario_with "SCREENSHOT=${WORK_DIR}/garbage.png"
expect_fail "an undecodable screenshot counts as never rendered" "no settled app frame" run_smoke
scenario_with "SCREENSHOT=${WORK_DIR}/rich.png"

# A screen that never settles -- every capture differs -- must fail. A gate that
# accepts the first complex frame is accepting whatever the engine happened to be
# drawing mid-transition. DRIFT_A/DRIFT_B alternate, so no two consecutive
# captures ever agree and the frame is permanently unstable.
scenario_with "SCREENSHOT_DRIFT=1"
expect_fail "a frame that never settles fails the gate" "no settled app frame" run_smoke
scenario_with "SCREENSHOT_DRIFT="

# The two drift frames must genuinely differ, or the scenario above would be
# indistinguishable from the passing case and would prove nothing.
if cmp -s "${WORK_DIR}/rich.png" "${WORK_DIR}/rich-drift.png"; then
  bad "the never-settling fixture really alternates between two different frames" \
    "rich.png and rich-drift.png are byte-identical"
else
  ok "the never-settling fixture really alternates between two different frames"
fi

# Focus is checked *inside* the render loop, so a dialog that steals focus after
# the app has already taken it must fail the gate. Checking focus only once,
# before the loop, is exactly what let a stolen window pass.
#
# The fake device takes focus on its first `dumpsys window` call and loses it on
# the second, so the loss lands after the gate has already observed focus.
scenario_with "FOCUS_AFTER_FIRST_CHECK=1"
expect_fail "focus stolen during the render wait fails the gate" "lost window focus" run_smoke
scenario_with "FOCUS_AFTER_FIRST_CHECK="

echo " evidence"
expect_pass "a passing run writes evidence" run_smoke
for evidence in case.png case-summary.txt case-crash-buffer.txt case-exit-info.txt case-logcat.txt; do
  if [[ -s "${WORK_DIR}/evidence/${evidence}" ]]; then
    ok "evidence ${evidence} exists and is non-empty"
  else
    bad "evidence ${evidence} exists and is non-empty"
  fi
done

# `[[ -s ]]` above is weak for two of these. In a *passing* run the crash buffer
# and the exit-info dump are legitimately free of crash content, so a size check
# passes on an almost-empty file without proving the gate actually captured the
# device's state. These two assertions bind the evidence to a scenario where the
# pre-launch and post-launch dumps differ, so "the file is non-empty" cannot be
# satisfied by a stub, a header, or the wrong read.
#
# The gate writes EXIT_INFO_PATH twice: once for the pre-launch baseline
# (capture_crash_baseline) and once for the post-launch dump
# (assert_no_adverse_exits), the second overwriting the first. So a passing run
# whose baseline holds an ANR and whose post-launch state is clean must retain
# evidence containing the *clean* dump. If the post-launch write were dropped, the
# evidence would still hold the baseline ANR and this would fail -- which is the
# point: a release's retained evidence must describe the state the gate judged,
# not an earlier read of the same command.
scenario_with "EXIT_INFO=${WORK_DIR}/anr-exit-info.txt" \
  "EXIT_INFO_AFTER=${WORK_DIR}/clean-exit-info.txt" \
  "CRASH_BUFFER=${WORK_DIR}/crash-header-only.txt"
expect_pass "a run whose pre-launch baseline was adverse but which ended clean passes" run_smoke
crash_evidence="${WORK_DIR}/evidence/case-crash-buffer.txt"
exit_evidence="${WORK_DIR}/evidence/case-exit-info.txt"
if grep -qF "REASON_USER_REQUESTED" "${exit_evidence}" 2>/dev/null; then
  ok "the retained exit-info evidence is the post-launch dump, not the pre-launch baseline"
else
  bad "the retained exit-info evidence is the post-launch dump, not the pre-launch baseline" \
    "expected the clean post-launch dump; got: $(tr '\n' ' ' <"${exit_evidence}" 2>/dev/null | cut -c1-160)"
fi
if grep -qF "reason=6 (ANR)" "${exit_evidence}" 2>/dev/null; then
  bad "the retained exit-info evidence does not describe the pre-launch baseline" \
    "the pre-launch ANR is in the evidence, so this is the baseline read, not the judged state"
else
  ok "the retained exit-info evidence does not describe the pre-launch baseline"
fi
# The crash buffer here is the header-only fixture: non-blank, and legitimately
# clean, because a bare "beginning of crash" line is a platform quirk rather than
# a crash. A blank crash-buffer evidence file cannot be produced by a passing run
# either (the -s check above covers emptiness), so matching the header proves the
# file holds the device's actual buffer rather than a summary the gate wrote.
if grep -qF "beginning of crash" "${crash_evidence}" 2>/dev/null; then
  ok "the retained crash buffer is the device's actual buffer, not a stub"
else
  bad "the retained crash buffer is the device's actual buffer, not a stub" \
    "expected the scenario's buffer content; got: $(tr '\n' ' ' <"${crash_evidence}" 2>/dev/null | cut -c1-160)"
fi
scenario_with "EXIT_INFO_AFTER=${WORK_DIR}/header-only-exit-info.txt" \
  "CRASH_BUFFER=${WORK_DIR}/empty-exit-info.txt"
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
# One path policy: inside the workspace the summary records workspace-relative
# paths, so evidence is comparable across runners instead of embedding
# machine-specific prefixes. GITHUB_WORKSPACE is the workspace root here, and
# the APK lives directly under it, so `apk:` must read `app-release.apk`.
if run_smoke_on "${WORK_DIR}/app-release.apk" "GITHUB_WORKSPACE=${WORK_DIR}" \
  >"${WORK_DIR}/relpaths.log" 2>&1; then
  if grep -q '^apk: app-release.apk$' "${WORK_DIR}/evidence/case-summary.txt" 2>/dev/null; then
    ok "summary paths are workspace-relative when inside the workspace"
  else
    bad "summary paths are workspace-relative when inside the workspace" \
      "got: $(grep -E '^(apk|screenshot): ' "${WORK_DIR}/evidence/case-summary.txt" 2>/dev/null | tr '\n' '|' | cut -c1-160)"
  fi
  if grep -qE "^apk: /" "${WORK_DIR}/evidence/case-summary.txt" 2>/dev/null; then
    bad "no absolute runner path leaks into the summary" \
      "an absolute path makes evidence incomparable across machines"
  else
    ok "no absolute runner path leaks into the summary"
  fi
else
  bad "summary paths are workspace-relative when inside the workspace" \
    "the gate failed with GITHUB_WORKSPACE set: $(tr '\n' '|' <"${WORK_DIR}/relpaths.log" | cut -c1-200)"
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

# The gate's complexity threshold is 32. Both drift fixtures must clear it, or the
# never-settling scenario would be rejected for looking blank and the stability
# check would never actually be exercised. Asserted here, where the decoder the
# gate uses is available.
for frame in rich.png rich-drift.png; do
  colors="$(decode_colors "${WORK_DIR}/${frame}" 2>/dev/null || printf -1)"
  if [[ "${colors}" =~ ^[0-9]+$ ]] && ((colors >= 32)); then
    ok "${frame} clears the gate's 32-colour threshold (${colors}), so stability is what is under test"
  else
    bad "${frame} clears the gate's 32-colour threshold, so stability is what is under test" \
      "decoded ${colors} colours; too simple to exercise the stability check"
  fi
done

printf '\n%s passed, %s failed\n' "${PASS_COUNT}" "${FAIL_COUNT}"
if ((FAIL_COUNT > 0)); then
  exit 1
fi
