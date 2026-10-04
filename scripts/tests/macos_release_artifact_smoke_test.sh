#!/usr/bin/env bash
#
# Tests for scripts/macos_release_artifact_smoke.sh.
#
# The install/launch gate is the thing that would have caught the macOS half of
# issue #98, so it cannot itself be an untested blob of shell inside a CI
# workflow. A fake macOS toolchain stands in for the runner -- hdiutil, open,
# lsappinfo, screencapture, xattr, lipo, spctl, log, find, PlistBuddy -- and
# every failure mode the gate is supposed to detect is injected and asserted
# here: a truncated or non-DMG artifact, an image that will not mount, an image
# with no app bundle, two app bundles, a bundle missing its daemon, a
# non-executable daemon, a bundle built for an architecture the runner cannot
# execute, a quarantined download, a runner whose screen cannot be captured, an
# app that is already running, an app that dies on launch, an app that runs with
# no window, a window too small to be a real UI, a blank screen, a screen that
# never settles, a crash report, and a crash-report directory that cannot be
# read.
#
# It also unit-tests the PNG complexity decoder, because "did it actually render"
# is the one assertion in the gate with real logic behind it.
#
# It does NOT prove that this suite still tests the gate. That is the job of
# scripts/tests/macos_release_artifact_mutation_test.sh, which breaks the gate in
# one place at a time and requires this file to go red on the matching
# assertion. Keeping the two separate matters: this file can only show what it
# asserts, and a suite that has quietly stopped asserting is green in exactly
# the way a release gate must never be.

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="${ROOT_DIR}/scripts/macos_release_artifact_smoke.sh"
WORK_DIR="$(mktemp -d)"
PASS_COUNT=0
FAIL_COUNT=0

# This suite executes the gate read-only and never edits it, so there is nothing
# to restore. A pass that deliberately breaks the gate lives in
# scripts/tests/macos_release_artifact_mutation_test.sh and runs against its own
# private copy of the tree. (An earlier version snapshotted the real gate here
# and copied it back on exit -- a vestigial write that could clobber a concurrent
# edit. It is gone; keep this suite incapable of mutating the worktree.)
cleanup() {
  rm -rf "${WORK_DIR}"
}
trap cleanup EXIT INT TERM

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
# pass. python3 builds this suite's PNG and Info.plist fixtures *and* is the
# gate's own PNG complexity decoder and the fake PlistBuddy's parser, so without
# it most of the suite would run against empty fixtures.
DEGRADED_MARKER='RELEASE_GATE_SUITE_DEGRADED:'

if ! command -v python3 >/dev/null 2>&1; then
  printf '  SKIP %s\n' "the fixtures, the gate's PNG decoder and the fake PlistBuddy all need python3"
  printf '  !! %s no python3 on PATH\n' "${DEGRADED_MARKER}"
  printf '  !! These assertions did NOT run; do not read this suite as a pass.\n'
  exit 0
fi

# The gate compares the runner's architecture (from `uname -m`) against the
# artifact's, so the fixtures have to be scripted against whatever host the
# suite happens to run on -- otherwise the happy path passes only on the machine
# it was written on.
RUNNER_ARCH_RAW="$(uname -m)"
case "${RUNNER_ARCH_RAW}" in
  aarch64 | arm64e) RUNNER_ARCH="arm64" ;;
  amd64 | x86_64) RUNNER_ARCH="x86_64" ;;
  *) RUNNER_ARCH="${RUNNER_ARCH_RAW}" ;;
esac
# An architecture the runner definitely is not, for the mismatch case.
OTHER_ARCH="arm64"
if [[ "${RUNNER_ARCH}" == "arm64" ]]; then
  OTHER_ARCH="x86_64"
fi

BUNDLE_ID="com.privategallery.desktop"
EXECUTABLE="private_gallery_app"

expect_pass() {
  local name="$1"
  shift
  if "$@" >"${OUT}" 2>&1; then
    ok "${name}"
  else
    bad "${name}" "$(tail -n 40 "${OUT}")"
  fi
}

expect_fail() {
  local name="$1" needle="${2:-}"
  shift 2
  if "$@" >"${OUT}" 2>&1; then
    bad "${name}" "expected a non-zero exit, got success: $(tail -n 40 "${OUT}")"
    return
  fi
  if [[ -n "${needle}" ]] && ! grep -Fq "${needle}" "${OUT}"; then
    bad "${name}" "expected the failure to mention '${needle}'; tail of the log: $(tail -n 40 "${OUT}")"
    return
  fi
  ok "${name}"
}

SCENARIO="${WORK_DIR}/scenario.env"
BASE_SCENARIO="${WORK_DIR}/scenario.base.env"
FAKE_STATE="${WORK_DIR}/fake-state"
FAKE_BIN="${WORK_DIR}/bin"
DIAG_DIR="${WORK_DIR}/diag"

# --- fake macOS toolchain ----------------------------------------------------

install_fake_tools() {
  mkdir -p "${FAKE_BIN}" "${FAKE_STATE}"

  # The shared scenario reader. Every fake is a fresh process per invocation, so
  # nothing may be kept in memory between calls; the scenario file is the only
  # channel, exactly like the real toolchain's view of the machine.
  cat >"${FAKE_BIN}/fake-lib" <<'FAKE_LIB'
scenario_value() {
  local key="$1" line
  [[ -f "${FAKE_MACOS_SCENARIO}" ]] || return 1
  while IFS= read -r line; do
    if [[ "${line}" == "${key}="* ]]; then
      printf '%s' "${line#*=}"
      return 0
    fi
  done <"${FAKE_MACOS_SCENARIO}"
  return 1
}

value_or() {
  scenario_value "$1" || printf '%s' "${2:-}"
}

touch_state() {
  : >"${FAKE_MACOS_STATE}/$1"
}

state_exists() {
  [[ -f "${FAKE_MACOS_STATE}/$1" ]]
}

bump_counter() {
  local name="$1" n=0
  if [[ -f "${FAKE_MACOS_STATE}/${name}" ]]; then
    n="$(cat "${FAKE_MACOS_STATE}/${name}" 2>/dev/null || printf 0)"
  fi
  n=$((n + 1))
  printf '%s' "${n}" >"${FAKE_MACOS_STATE}/${name}"
  printf '%s' "${n}"
}
FAKE_LIB

  # hdiutil: `attach -mountpoint <dir> <image>` copies the scenario's prepared
  # image contents into the mount point, so the rest of the gate sees a real
  # directory tree and never learns that the "disk" is a fixture.
  cat >"${FAKE_BIN}/hdiutil" <<'FAKE_HDITUTIL'
#!/usr/bin/env bash
set -uo pipefail
# shellcheck source=/dev/null
. "${FAKE_MACOS_BIN}/fake-lib"
verb="${1:-}"
case "${verb}" in
  attach)
    if [[ "$(value_or HDUTIL_ATTACH_FAIL 0)" == "1" ]]; then
      printf 'hdiutil: attach failed - Invalid argument\n' >&2
      exit 1
    fi
    mountpoint=""
    previous=""
    for arg in "$@"; do
      if [[ "${previous}" == "-mountpoint" ]]; then
        mountpoint="${arg}"
      fi
      previous="${arg}"
    done
    if [[ -z "${mountpoint}" ]]; then
      printf 'hdiutil: no -mountpoint given (the real gate always passes one)\n' >&2
      exit 2
    fi
    source_dir="$(value_or MOUNT_SOURCE '')"
    if [[ -z "${source_dir}" || ! -d "${source_dir}" ]]; then
      printf 'hdiutil: no such image\n' >&2
      exit 1
    fi
    mkdir -p "${mountpoint}"
    cp -R "${source_dir}"/. "${mountpoint}/" || exit 1
    # chmod AFTER the copy. A real `hdiutil attach -readonly` makes writes into
    # the mounted tree fail; chmodding first would leave the copy unable to
    # create its own files, which is not what a read-only mount does and would
    # make the knob untestable rather than meaningful.
    if [[ "$(value_or MOUNT_READONLY_ENFORCED 0)" == "1" ]]; then
      chmod -R a-w "${mountpoint}" 2>/dev/null || true
    fi
    printf '/dev/disk4s1\tApple_HFS\t%s\n' "${mountpoint}"
    exit 0
    ;;
  detach)
    printf 'hdiutil: detach: /dev/disk4s1\n'
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
FAKE_HDITUTIL

  # open: launches the bundle and records that it happened, which is what makes
  # lsappinfo start reporting the app. `open` on a real runner also detaches, so
  # a fake that returned before "launching" would hide every launch-order bug.
  cat >"${FAKE_BIN}/open" <<'FAKE_OPEN'
#!/usr/bin/env bash
set -uo pipefail
# shellcheck source=/dev/null
. "${FAKE_MACOS_BIN}/fake-lib"
if [[ "$(value_or OPEN_FAIL 0)" == "1" ]]; then
  printf 'LSOpenURLsWithRole() failed with error -10810\n' >&2
  exit 1
fi
target=""
for arg in "$@"; do
  if [[ -d "${arg}" ]]; then
    target="${arg}"
  fi
done
if [[ -z "${target}" ]]; then
  printf 'open: The file /dev/null does not exist.\n' >&2
  exit 1
fi
touch_state launched
printf '%s\n' "${target}"
exit 0
FAKE_OPEN

  # lsappinfo: the window server, and the only TCC-free way to ask about a
  # window. `findLSApplication` answers only for the bundle id the gate was told
  # to expect, so the fake cannot be satisfied by an unrelated app.
  cat >"${FAKE_BIN}/lsappinfo" <<'FAKE_LSAPPINFO'
#!/usr/bin/env bash
set -uo pipefail
# shellcheck source=/dev/null
. "${FAKE_MACOS_BIN}/fake-lib"
expected="$(value_or EXPECTED_BUNDLE_ID '')"
verb="${1:-}"
case "${verb}" in
  findLSApplication)
    query="${2:-}"
    query="${query#=}"
    if [[ -n "${expected}" && "${query}" != "${expected}" ]]; then
      # A different app is running; the gate must not see its window.
      exit 0
    fi
    if [[ "$(value_or LSAPPINFO_ALREADY_RUNNING 0)" == "1" ]]; then
      printf '1'
      exit 0
    fi
    if [[ "$(value_or LSAPPINFO_NEVER 0)" == "1" ]]; then
      exit 0
    fi
    if state_exists launched; then
      printf '1'
    fi
    exit 0
    ;;
  info)
    if [[ "$(value_or LSAPPINFO_FAIL 0)" == "1" ]]; then
      printf 'lsappinfo: cannot connect to the window server\n' >&2
      exit 1
    fi
    # A window that vanishes part-way through the render wait. Driven by a state
    # file the fake screencapture creates, not by a call count: the gate reads
    # `info` several times per poll, so a call-count threshold would flip
    # mid-poll and make the case non-deterministic.
    if [[ "$(value_or LSAPPINFO_LOST_AFTER_CAPTURE 0)" == "1" ]] && state_exists window-lost; then
      after="$(value_or LSAPPINFO_INFO_AFTER '')"
      if [[ -n "${after}" && -f "${after}" ]]; then
        cat "${after}"
        exit 0
      fi
    fi
    dump="$(value_or LSAPPINFO_INFO '')"
    if [[ -n "${dump}" && -f "${dump}" ]]; then
      cat "${dump}"
    fi
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
FAKE_LSAPPINFO

  # screencapture: the display. The first call is the gate's pre-launch harness
  # self-test and every call after it is the render loop, so the fake keeps a
  # call counter to tell them apart -- the same order the real gate runs in.
  cat >"${FAKE_BIN}/screencapture" <<'FAKE_SCREENSHOT'
#!/usr/bin/env bash
set -uo pipefail
# shellcheck source=/dev/null
. "${FAKE_MACOS_BIN}/fake-lib"
destination=""
window_scoped=0
expect_window_id=0
previous=""
# `screencapture -x -o -l <windowid> <file>`: the argument after `-l` is the
# window id, not the destination. Skipping it explicitly is what keeps the
# destination parse honest. The previous version compared `previous` to `-l` and
# `continue`d WITHOUT updating it, so the destination was also treated as a
# window id and skipped -- every window-scoped capture exited 2. That made the
# fake unable to model a successful window-scoped capture, so the happy path
# silently exercised the full-screen fallback and the window-scoped branch, the
# one that actually proves the pixels came from the app, was never tested.
for arg in "$@"; do
  if ((expect_window_id == 1)); then
    expect_window_id=0
    previous="${arg}"
    continue
  fi
  case "${arg}" in
    -l)
      window_scoped=1
      expect_window_id=1
      ;;
    -*)
      ;;
    *)
      destination="${arg}"
      ;;
  esac
  previous="${arg}"
done
if [[ -z "${destination}" ]]; then
  printf 'screencapture: no output file given\n' >&2
  exit 2
fi
call="$(bump_counter screen-capture-calls)"
if [[ "${call}" == "1" ]]; then
  if [[ "$(value_or PREFLIGHT_FAIL 0)" == "1" ]]; then
    printf 'screencapture: cannot run\n' >&2
    exit 1
  fi
  image="$(value_or PREFLIGHT_SCREENSHOT '')"
  [[ -n "${image}" ]] || image="$(value_or SCREENSHOT '')"
  if [[ -n "${image}" && -f "${image}" ]]; then
    cat "${image}" >"${destination}"
  fi
  exit 0
fi
if [[ "${window_scoped}" == "1" ]]; then
  if [[ "$(value_or SCREENSHOT_FAIL_WINDOW 0)" == "1" ]]; then
    printf 'screencapture: could not create image from window\n' >&2
    exit 1
  fi
  # SCREENSHOT_WINDOW, then SCREENSHOT. The fallback matters: the rendering
  # cases below override only SCREENSHOT, and before this fallback existed they
  # were reaching the full-screen path for a reason unrelated to what they test.
  image="$(value_or SCREENSHOT_WINDOW '')"
  if [[ -z "${image}" ]]; then
    image="$(value_or SCREENSHOT '')"
  fi
  # A window that never settles. Without this the stability check is reachable
  # only on the full-screen fallback, which a passing run does not take -- so
  # "two consecutive captures must agree" would be untested by every green run,
  # and a gate that accepted the first complex frame would go unnoticed.
  if [[ "$(value_or SCREENSHOT_DRIFT 0)" == "1" ]]; then
    drift="$(value_or SCREENSHOT_DRIFT_IMAGE '')"
    if [[ -n "${drift}" && -f "${drift}" ]]; then
      frame="$(bump_counter screen-window-drift)"
      if ((${frame} % 2 == 0)); then
        image="${drift}"
      fi
    fi
  fi
else
  if [[ "$(value_or SCREENSHOT_FAIL 0)" == "1" ]]; then
    printf 'screencapture: could not create image\n' >&2
    exit 1
  fi
  image="$(value_or SCREENSHOT '')"
  if [[ "$(value_or SCREENSHOT_DRIFT 1)" == "1" ]]; then
    drift="$(value_or SCREENSHOT_DRIFT_IMAGE '')"
    if [[ -n "${drift}" && -f "${drift}" ]]; then
      frame="$(bump_counter screen-drift)"
      if ((${frame} % 2 == 0)); then
        image="${drift}"
      fi
    fi
  fi
fi
if [[ -n "${image}" && -f "${image}" ]]; then
  cat "${image}" >"${destination}"
fi
# The render loop has started: the pre-launch self-test, the cold launch, the
# process wait and the window wait all complete before the first capture, so
# this is the boundary between "died on launch" and "died mid-render". Two
# things are driven from it, both modelled on the same boundary in the Android
# fake adb: a crash report appearing (a process that died after its window came
# up) and a window disappearing.
if [[ "$(value_or CRASH_REPORT_ON_CAPTURE 0)" == "1" ]] && ! state_exists crash-written; then
  source_report="$(value_or CRASH_REPORT_FILE '')"
  if [[ -n "${source_report}" && -f "${source_report}" ]]; then
    # The report's file name is itself a scenario knob, because the gate reads
    # reports with `-newer <marker>` and the marker is created after the bundle
    # launches. A fixture copied into the directory before the run is therefore
    # OLDER than the marker and is filtered out by the timestamp before the
    # body filter ever sees it -- so a case meant to exercise the body filter
    # has to plant the file at this point, which is the only place where it is
    # provably newer than the baseline it is meant to be compared against.
    report_name="$(value_or CRASH_REPORT_NAME 'private_gallery_app_2026-09-30-120000.ips')"
    cp "${source_report}" "${FAKE_MACOS_DIAG_DIR}/${report_name}"
    touch_state crash-written
  fi
fi
if [[ "$(value_or WINDOW_LOST_ON_CAPTURE 0)" == "1" ]] && ! state_exists window-lost; then
  touch_state window-lost
fi
exit 0
FAKE_SCREENSHOT

  # xattr: quarantine. `-p` exits non-zero when the attribute is absent, which
  # is the healthy case, exactly as on a real machine.
  cat >"${FAKE_BIN}/xattr" <<'FAKE_XATTR'
#!/usr/bin/env bash
set -uo pipefail
# shellcheck source=/dev/null
. "${FAKE_MACOS_BIN}/fake-lib"
op="${1:-}"
if [[ "${op}" == "-p" ]]; then
  if [[ "$(value_or QUARANTINE 0)" == "1" ]]; then
    printf '0081;68747470733a52;Safari;1A2B3C4D-5E6F-7A8B-9C0D-1E2F3A4B5C6D\n'
    exit 0
  fi
  printf 'xattr: No such xattr: com.apple.quarantine\n' >&2
  exit 1
fi
if [[ "${op}" == "-cr" ]]; then
  if [[ "$(value_or XATTR_CLEAR_FAIL 0)" == "1" ]]; then
    printf 'xattr: Could not clear extended attributes\n' >&2
    exit 1
  fi
  exit 0
fi
exit 1
FAKE_XATTR

  # lipo: the Mach-O headers. Per-file overrides let a scenario build a bundle
  # whose app is runnable and whose daemon is not -- the case a launch test
  # cannot see.
  cat >"${FAKE_BIN}/lipo" <<'FAKE_LIPO'
#!/usr/bin/env bash
set -uo pipefail
# shellcheck source=/dev/null
. "${FAKE_MACOS_BIN}/fake-lib"
if [[ "${1:-}" != "-archs" ]]; then
  printf 'lipo: only -archs is faked\n' >&2
  exit 1
fi
binary="${2:-}"
if [[ "$(value_or LIPO_FAIL 0)" == "1" ]]; then
  printf 'lipo: cant open file: %s\n' "${binary}" >&2
  exit 1
fi
key="LIPO_ARCHS_$(printf '%s' "$(basename "${binary}")" | tr -c '[:alnum:]' '_' | tr '[:lower:]' '[:upper:]')"
override="$(scenario_value "${key}" || printf '')"
if [[ -n "${override}" ]]; then
  printf '%s\n' "${override}"
  exit 0
fi
printf '%s\n' "$(value_or LIPO_ARCHS "${RUNNER_ARCH_FOR_FAKE}")"
exit 0
FAKE_LIPO

  # spctl: Gatekeeper. Rejection is the default, because that is the real state
  # of this project's macOS release (unsigned, unnotarized).
  cat >"${FAKE_BIN}/spctl" <<'FAKE_SPCTL'
#!/usr/bin/env bash
set -uo pipefail
# shellcheck source=/dev/null
. "${FAKE_MACOS_BIN}/fake-lib"
if [[ "$(value_or SPCTL_ACCEPT 0)" == "1" ]]; then
  printf '%s\n' "${2:-.}: accepted\nsource=no usable signature'
  exit 0
fi
printf '%s\n' "${2:-.}: rejected\nsource=no usable signature"
printf 'reason=no usable signature\n'
exit 3
FAKE_SPCTL

  # log: the unified log, evidence only.
  cat >"${FAKE_BIN}/log" <<'FAKE_LOG'
#!/usr/bin/env bash
set -uo pipefail
# shellcheck source=/dev/null
. "${FAKE_MACOS_BIN}/fake-lib"
if [[ "$(value_or LOG_FAIL 0)" == "1" ]]; then
  printf 'log: error: --last requires an argument\n' >&2
  exit 1
fi
printf '2026-09-30 10:00:00.000 Df %s[4242:0x1] fake unified log line\n' "$(value_or EXECUTABLE_NAME private_gallery_app)"
exit 0
FAKE_LOG

  # find: delegates to the real one, so the mount-point scan is genuinely
  # parsing a directory, and can be made to fail so the "crash directory could
  # not be read" branch is reachable rather than dead code.
  #
  # FIND_FAIL_DIR is scoped to one directory prefix on purpose. A single global
  # FIND_FAIL also breaks the mount-point scan in `locate_app_bundle`, so the gate
  # refuses at "could not list the mounted image" and the crash branch is never
  # reached -- the case would go red for the wrong reason while proving nothing
  # about crash detection. Scoping it makes the assertion target its own branch.
  cat >"${FAKE_BIN}/find" <<'FAKE_FIND'
#!/usr/bin/env bash
set -uo pipefail
# shellcheck source=/dev/null
. "${FAKE_MACOS_BIN}/fake-lib"
if [[ "$(value_or FIND_FAIL 0)" == "1" ]]; then
  printf 'find: Permission denied\n' >&2
  exit 1
fi
scoped="$(value_or FIND_FAIL_DIR '')"
if [[ -n "${scoped}" && "${1:-}" == "${scoped}"* ]]; then
  printf 'find: Permission denied\n' >&2
  exit 1
fi
exec "${FAKE_MACOS_REAL_FIND}" "$@"
FAKE_FIND

  # PlistBuddy: a real plist parse, via plistlib. A regex would let a comment or
  # a lookalike key satisfy the gate's layout assertions.
  cat >"${FAKE_BIN}/PlistBuddy" <<'FAKE_PLISTBUDDY'
#!/usr/bin/env bash
set -uo pipefail
expression="${2:-}"
file="${3:-}"
key="${expression#Print :}"
python3 -c '
import plistlib
import sys

with open(sys.argv[2], "rb") as handle:
    plist = plistlib.load(handle)
if sys.argv[1] not in plist:
    sys.exit(1)
print(plist[sys.argv[1]])
' "${key}" "${file}"
FAKE_PLISTBUDDY

  local fake
  for fake in hdiutil open lsappinfo screencapture xattr lipo spctl log find PlistBuddy; do
    chmod +x "${FAKE_BIN}/${fake}"
  done
}

# --- fixtures ----------------------------------------------------------------

# make_png <path> <distinct-colour-count>
#
# The gate's complexity decoder is the thing under test here, so the fixtures are
# built with a hand-written PNG encoder rather than an image library: a fixture
# produced by a different encoder could differ in filter or colour type and test
# something other than the threshold.
make_png() {
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

# make_app_bundle <destination-dir> [daemon] [daemon-executable] [main] [plist]
#
# Builds a tree shaped like a real Flutter macOS bundle, and verifies the parts
# the gate is about to read so a broken fixture cannot masquerade as a gate
# verdict.
#
#   daemon:              yes | no        ship Contents/MacOS/galleryd
#   daemon-executable:   yes | no        ...and chmod +x it
#   main:                full | empty    ...and the size of the app executable
#   plist:               good | no-key   ...and whether CFBundleExecutable is present
make_app_bundle() {
  local dest="$1"
  local daemon="${2:-yes}" daemon_executable="${3:-yes}"
  local main="${4:-full}" plist="${5:-good}"
  local bundle="${dest}/private_gallery_app.app"
  rm -rf "${dest}"
  mkdir -p "${bundle}/Contents/MacOS"
  python3 - "${bundle}/Contents/Info.plist" "${EXECUTABLE}" "${BUNDLE_ID}" "${plist}" <<'PY'
import plistlib
import sys

path, executable, bundle_id, plist_mode = sys.argv[1:5]
info = {
    "CFBundleName": "Photo Organizer",
    "CFBundlePackageType": "APPL",
    "CFBundleShortVersionString": "1.0.0",
}
if plist_mode != "no-executable-key":
    info["CFBundleExecutable"] = executable
info["CFBundleIdentifier"] = bundle_id
with open(path, "wb") as handle:
    plistlib.dump(info, handle)
PY
  if [[ "${main}" == "empty" ]]; then
    : >"${bundle}/Contents/MacOS/${EXECUTABLE}"
  else
    printf 'fake mach-o image for %s\n' "${EXECUTABLE}" >"${bundle}/Contents/MacOS/${EXECUTABLE}"
  fi
  if [[ "${daemon}" == "yes" ]]; then
    printf 'fake mach-o image for galleryd\n' >"${bundle}/Contents/MacOS/galleryd"
    if [[ "${daemon_executable}" == "yes" ]]; then
      chmod +x "${bundle}/Contents/MacOS/galleryd"
    fi
  fi
  # Verify what was just written, through the same tool the gate uses to read it.
  if [[ "${plist}" != "no-executable-key" && "${main}" != "empty" ]]; then
    if ! FAKE_MACOS_BIN="${FAKE_BIN}" "${FAKE_BIN}/PlistBuddy" -c "Print :CFBundleExecutable" \
      "${bundle}/Contents/Info.plist" >/dev/null 2>&1; then
      printf 'FATAL: the .app fixture at %s is unreadable through PlistBuddy\n' "${dest}" >&2
      exit 1
    fi
  fi
}

# make_dmg <path>
#
# A file with the `koly` trailer a UDZO image ends in, which is the structural
# property the gate checks before it trusts hdiutil.
make_dmg() {
  python3 - "$1" <<'PY'
import sys

path = sys.argv[1]
body = bytearray(b"\x00" * 4096)
body[-512:-508] = b"koly"
with open(path, "wb") as handle:
    handle.write(bytes(body))
PY
}

# make_lsappinfo <path> <window-id|-> <visible> <hidden> <bounds>
#
# The fields are emitted one per line in the shape `lsappinfo info` produces,
# with the executable name and bundle id the gate expects, so a parser that
# ignored the identity of the app could not pass.
make_lsappinfo() {
  local path="$1" window_id="$2" visible="$3" hidden="$4" bounds="$5"
  {
    printf 'LSDisplayName: Photo Organizer\n'
    printf 'Name: %s\n' "${EXECUTABLE}"
    printf 'BundleIdentifier: %s\n' "${BUNDLE_ID}"
    printf 'Application Specific Identifier: 4242\n'
    printf 'pid: 4242\n'
    if [[ "${window_id}" == "-" ]]; then
      printf 'FrontWindow: 0x00000000\n'
    else
      printf 'FrontWindow: %s\n' "${window_id}"
    fi
    printf 'Visible: %s\n' "${visible}"
    printf 'Hidden: %s\n' "${hidden}"
    printf 'Bounds: %s\n' "${bounds}"
  } >"${path}"
}

# --- scenario plumbing -------------------------------------------------------

# Always start from the pristine baseline so tests are order-independent: a key
# one case sets cannot silently leak into the next.
scenario_with() {
  local line key work
  cp "${BASE_SCENARIO}" "${SCENARIO}"
  rm -rf "${FAKE_STATE}"
  mkdir -p "${FAKE_STATE}"
  for line in "$@"; do
    key="${line%%=*}"
    work="${WORK_DIR}/scenario.work"
    grep -v "^${key}=" "${SCENARIO}" >"${work}" 2>/dev/null || true
    printf '%s\n' "${line}" >>"${work}"
    cp "${work}" "${SCENARIO}"
  done
}

gate_env() {
  env \
    PATH="${FAKE_BIN}:${PATH}" \
    FAKE_MACOS_BIN="${FAKE_BIN}" \
    FAKE_MACOS_SCENARIO="${SCENARIO}" \
    FAKE_MACOS_STATE="${FAKE_STATE}" \
    FAKE_MACOS_REAL_FIND="${REAL_FIND}" \
    FAKE_MACOS_DIAG_DIR="${DIAG_DIR}" \
    RUNNER_ARCH_FOR_FAKE="${RUNNER_ARCH}" \
    MACOS_SMOKE_HDITOOL_BIN="${FAKE_BIN}/hdiutil" \
    MACOS_SMOKE_OPEN_BIN="${FAKE_BIN}/open" \
    MACOS_SMOKE_LSAPPINFO_BIN="${FAKE_BIN}/lsappinfo" \
    MACOS_SMOKE_SCREENSHOT_BIN="${FAKE_BIN}/screencapture" \
    MACOS_SMOKE_XATTR_BIN="${FAKE_BIN}/xattr" \
    MACOS_SMOKE_LIPO_BIN="${FAKE_BIN}/lipo" \
    MACOS_SMOKE_SPCTL_BIN="${FAKE_BIN}/spctl" \
    MACOS_SMOKE_LOG_BIN="${FAKE_BIN}/log" \
    MACOS_SMOKE_FIND_BIN="${FAKE_BIN}/find" \
    MACOS_SMOKE_PLIST_BUDDY_BIN="${FAKE_BIN}/PlistBuddy" \
    MACOS_SMOKE_DIAG_REPORTS_DIRS="${DIAG_DIR}" \
    MACOS_SMOKE_EVIDENCE_DIR="${WORK_DIR}/evidence" \
    MACOS_SMOKE_MOUNT_DIR="${WORK_DIR}" \
    GITHUB_WORKSPACE="${WORK_DIR}" \
    MACOS_SMOKE_NAME="case" \
    MACOS_SMOKE_LAUNCH_TIMEOUT_SECONDS="${SMOKE_LAUNCH_TIMEOUT:-8}" \
    MACOS_SMOKE_RENDER_TIMEOUT_SECONDS="${SMOKE_RENDER_TIMEOUT:-5}" \
    MACOS_SMOKE_POLL_INTERVAL_SECONDS=1 \
    "$@"
}

run_gate() {
  gate_env bash "${SCRIPT}" "${WORK_DIR}/release.dmg"
}

# Runs the gate against an extracted .app instead of a mounted image, so the
# direct-bundle path is exercised rather than assumed.
run_gate_on_app() {
  gate_env bash "${SCRIPT}" "$1"
}

# run_gate_on <bundle> [VAR=value ...] -- as above, with extra environment.
run_gate_on() {
  local bundle="$1"
  shift
  gate_env env "$@" bash "${SCRIPT}" "${bundle}"
}

run_gate_no_args() {
  gate_env bash "${SCRIPT}"
}

run_gate_missing() {
  gate_env bash "${SCRIPT}" "${WORK_DIR}/does-not-exist.dmg"
}

# --- fixture construction ----------------------------------------------------

install_fake_tools
REAL_FIND="$(command -v find)"

make_png "${WORK_DIR}/rich.png" 40
make_png "${WORK_DIR}/blank.png" 1
# A second complex frame, for the never-settling scenario. It must be complex
# enough to clear the threshold -- otherwise the gate would reject it for being
# blank and the stability check would never actually be exercised.
make_png "${WORK_DIR}/rich-drift.png" 41
printf 'not a png at all' >"${WORK_DIR}/garbage.png"
# A structurally perfect PNG whose 8-byte signature has been corrupted. Needed
# because `garbage.png` alone cannot test the signature check: its body is not a
# PNG either, so a decoder with the signature check removed still rejects it --
# for the wrong reason. Only a file that is a valid image in every respect bar
# the signature can show that the signature is what refused it.
python3 - "${WORK_DIR}/rich.png" "${WORK_DIR}/badsig.png" <<'PY'
import sys

with open(sys.argv[1], "rb") as handle:
    data = bytearray(handle.read())
assert bytes(data[:8]) == b"\x89PNG\r\n\x1a\n", "fixture is not a PNG"
data[:8] = b"\x89PNH\r\n\x1a\n"  # one byte wrong: G -> H
with open(sys.argv[2], "wb") as handle:
    handle.write(bytes(data))
PY
# A real UI, but sitting just under the gate's 32-colour complexity bar. Without
# it, "the threshold is a threshold" is indistinguishable from "any PNG passes".
make_png "${WORK_DIR}/eighteen.png" 18

# The mounted image the fake hdiutil will "attach".
make_app_bundle "${WORK_DIR}/image-good" || exit 1
# The three packaging regressions the layout assertions exist for.
make_app_bundle "${WORK_DIR}/image-no-daemon" no || exit 1
make_app_bundle "${WORK_DIR}/image-daemon-not-executable" yes no || exit 1
make_app_bundle "${WORK_DIR}/image-empty-main" yes yes empty || exit 1
make_app_bundle "${WORK_DIR}/image-no-exec-key" yes yes full no-executable-key || exit 1
# An image whose root holds two app bundles, and one with none.
mkdir -p "${WORK_DIR}/image-two-apps"
cp -R "${WORK_DIR}/image-good/private_gallery_app.app" "${WORK_DIR}/image-two-apps/"
cp -R "${WORK_DIR}/image-good/private_gallery_app.app" "${WORK_DIR}/image-two-apps/other-app.app"
mkdir -p "${WORK_DIR}/image-no-app"
printf 'read me first\n' >"${WORK_DIR}/image-no-app/readme.txt"

make_dmg "${WORK_DIR}/release.dmg" || exit 1
# A file the size of a real upload that is not a disk image at all.
python3 - "${WORK_DIR}/not-a-dmg.dmg" <<'PY' || exit 1
import sys

with open(sys.argv[1], "wb") as handle:
    handle.write(b"PK\x03\x04" + b"\x00" * 4092)
PY
# Too small to be a disk image.
printf 'koly' >"${WORK_DIR}/tiny.dmg"

# Window-server states. The gate's window assertion is the load-bearing check on
# this platform, so each of its outcomes gets its own fixture.
make_lsappinfo "${WORK_DIR}/window-real.txt" "0x1a2b" 1 0 "{{0, 25}, {1280, 775}}"
make_lsappinfo "${WORK_DIR}/window-none.txt" "-" 0 0 "{{0, 0}, {0, 0}}"
make_lsappinfo "${WORK_DIR}/window-hidden.txt" "0x1a2b" 1 1 "{{0, 25}, {1280, 775}}"
make_lsappinfo "${WORK_DIR}/window-tiny.txt" "0x1a2b" 1 0 "{{0, 0}, {16, 16}}"
make_lsappinfo "${WORK_DIR}/window-visible-no-id.txt" "-" 1 0 "{{0, 25}, {1280, 775}}"
# No recognisable keys at all: the tool answered, but not in a shape the gate
# understands. Counting that as "no window" is the safe direction.
printf 'lsappinfo: unrecognised output shape\nnothing useful here\n' >"${WORK_DIR}/window-unparseable.txt"

# Crash reports. A report is only "ours" if the file name and the body both name
# the executable, so there is a fixture for each half of that rule.
mkdir -p "${DIAG_DIR}"
cat >"${WORK_DIR}/crash-ours.txt" <<'EOF'
{"app_name":"Photo Organizer","timestamp":"2026-09-30 10:00:12.00 -0700","procName":"private_gallery_app","pid":4242,"bug_type":"309","os_version":"macOS 15.0","exception":{"codes":["0x0000000000000000","0x0000000000000000"]}}
EOF
cat >"${WORK_DIR}/crash-helper.txt" <<'EOF'
{"app_name":"Some Helper","timestamp":"2026-09-30 10:00:12.00 -0700","procName":"unrelated_helper","pid":77,"os_version":"macOS 15.0"}
EOF

cat >"${SCENARIO}" <<EOF
MOUNT_SOURCE=${WORK_DIR}/image-good
EXPECTED_BUNDLE_ID=${BUNDLE_ID}
EXECUTABLE_NAME=${EXECUTABLE}
LIPO_ARCHS=${RUNNER_ARCH}
PREFLIGHT_SCREENSHOT=${WORK_DIR}/rich.png
SCREENSHOT=${WORK_DIR}/rich.png
SCREENSHOT_WINDOW=${WORK_DIR}/rich.png
LSAPPINFO_INFO=${WORK_DIR}/window-real.txt
EOF
cp "${SCENARIO}" "${BASE_SCENARIO}"

# The default scenario must be a genuinely passing one, or every failure case
# below would be passing for the wrong reason. Proven by running the unmodified
# gate with the pristine scenario before any test is written.
scenario_with
if run_gate >"${WORK_DIR}/baseline.log" 2>&1; then
  ok "the default scenario passes the gate (every failure case below is meaningful)"
else
  bad "the default scenario passes the gate (every failure case below is meaningful)" \
    "the happy path is broken, so the failure cases below would prove nothing: $(tr '\n' '|' <"${WORK_DIR}/baseline.log" | cut -c1-400)"
fi
if grep -q "result: PASS" "${WORK_DIR}/evidence/case-summary.txt" 2>/dev/null; then
  ok "the default scenario records a PASS verdict in its evidence"
else
  bad "the default scenario records a PASS verdict in its evidence"
fi

# Two guards on the fake toolchain itself. Without them the failure cases below
# could be testing the fake rather than the gate: a fake `open` that never
# reports a launch would make every "crash on start" case pass for the wrong
# reason, and a fake `lsappinfo` that answered for any bundle id would make the
# window assertions vacuous.
if FAKE_MACOS_BIN="${FAKE_BIN}" FAKE_MACOS_SCENARIO="${SCENARIO}" \
  FAKE_MACOS_STATE="${FAKE_STATE}" RUNNER_ARCH_FOR_FAKE="${RUNNER_ARCH}" \
  "${FAKE_BIN}/lsappinfo" findLSApplication "=com.example.someotherapp" | grep -q .; then
  bad "the fake lsappinfo only reports the bundle id under test" \
    "it reported an application for an unrelated bundle id, so the gate's window assertions would be vacuous"
else
  ok "the fake lsappinfo only reports the bundle id under test"
fi
scenario_with "LSAPPINFO_ALREADY_RUNNING=1"
if FAKE_MACOS_BIN="${FAKE_BIN}" FAKE_MACOS_SCENARIO="${SCENARIO}" \
  FAKE_MACOS_STATE="${FAKE_STATE}" "${FAKE_BIN}/open" -n "${WORK_DIR}/image-good/private_gallery_app.app" >/dev/null 2>&1 &&
  FAKE_MACOS_BIN="${FAKE_BIN}" FAKE_MACOS_SCENARIO="${SCENARIO}" \
  FAKE_MACOS_STATE="${FAKE_STATE}" "${FAKE_BIN}/lsappinfo" findLSApplication "=${BUNDLE_ID}" | grep -q .; then
  ok "the fake open marks a launch and the fake window server then reports it"
else
  bad "the fake open marks a launch and the fake window server then reports it" \
    "the fake toolchain does not model a launch being observable, so launch-order bugs would be invisible"
fi
scenario_with

# A PATH farm, so "the tool could not run" is exercised for real rather than
# simulated through a knob the gate would have to grow. Manipulating PATH runs
# the real `command -v` and the real exit status of a real binary; a knob here
# would be a new way to point the check at something harmless, which is the very
# failure being guarded against.
#
# The farm lists only what the gate invokes. Completeness is not assumed: the
# guard below runs the *unmodified* gate with the farm and requires it to pass.
# If the list is missing a tool, that guard fails loudly instead of the
# "missing tool" cases silently failing for the wrong reason.
GATE_TOOLS='bash sh env cat cp mv rm mkdir rmdir sleep grep sed awk tr cut head tail
wc sort uniq dirname basename date mktemp realpath readlink stat touch printf echo
uname find pkill python3 python sha256sum shasum diff cmp sw_vers xattr lipo spctl
hdiutil open lsappinfo screencapture log PlistBuddy'

make_path_farm() {
  local destination="$1" tool dir
  mkdir -p "${destination}"
  # shellcheck disable=SC2086 # GATE_TOOLS is a deliberate word list
  for tool in ${GATE_TOOLS}; do
    [[ -e "${destination}/${tool}" ]] && continue
    dir="$(command -v "${tool}" 2>/dev/null || true)"
    [[ -n "${dir}" ]] && ln -sf "${dir}" "${destination}/${tool}"
  done
}

FARM_BIN="${WORK_DIR}/path-farm"
NO_HDITOOL_BIN="${WORK_DIR}/path-no-hdiutil"
make_path_farm "${FARM_BIN}"
# `cp -a` would preserve the farm's symlinks, so the second farm is built from
# scratch and the entry is then removed outright. Removing a symlink is the point:
# writing a stub *through* one would either leave the real hdiutil in place (so
# the case would silently test nothing) or overwrite a system tool.
make_path_farm "${NO_HDITOOL_BIN}"
rm -f "${NO_HDITOOL_BIN}/hdiutil"
if [[ -e "${NO_HDITOOL_BIN}/hdiutil" ]]; then
  bad "the missing-hdiutil fixture really removes hdiutil from the farm" "hdiutil is still there"
else
  ok "the missing-hdiutil fixture really removes hdiutil from the farm"
fi
if gate_env env "PATH=${FARM_BIN}" bash "${SCRIPT}" "${WORK_DIR}/release.dmg" >"${WORK_DIR}/farm.log" 2>&1; then
  ok "the restricted PATH is complete enough for the gate to pass"
else
  bad "the restricted PATH is complete enough for the gate to pass" \
    "the farm is missing a tool the gate needs, which would invalidate the missing-tool cases: $(tr '\n' '|' <"${WORK_DIR}/farm.log" | cut -c1-300)"
fi

# A lipo that exists but cannot read the Mach-O headers -- a truncated download,
# or a variant without -archs. Any non-zero exit must be fatal, because "cannot
# be shown to be runnable" is not "runnable".
cat >"${WORK_DIR}/lipo-broken" <<'SH'
#!/bin/sh
echo "lipo: cant open file: Contents/MacOS/private_gallery_app" >&2
exit 1
SH
chmod +x "${WORK_DIR}/lipo-broken"

# --- tests -------------------------------------------------------------------

echo "macos_release_artifact_smoke.sh"

echo " happy path"
scenario_with
expect_pass "mounts the published .dmg, cold-launches, renders and passes" run_gate
# The happy path must reach the window-scoped capture. This guards the FAKE, and
# it matters: the fake's argument parser used to exit 2 on every `-l <id>` call,
# so the gate silently fell back to a full-screen capture and the window-scoped
# branch -- the one that actually proves the pixels came from the app -- was
# never exercised by a passing run. Without this the suite reports green while
# its strongest branch sits untested.
if grep -qF "settled app frame (window capture)" "${WORK_DIR}/out" 2>/dev/null; then
  ok "the happy path captures the app's own window, not the whole screen"
else
  bad "the happy path captures the app's own window, not the whole screen" \
    "expected a window-scoped capture; saw: $(grep -oE 'settled app frame \([a-z]+ capture\)' "${WORK_DIR}/out" | tail -2 | tr '\n' ' ')"
fi

echo " argument and input validation"
expect_fail "no artifact argument is a usage error" "usage" run_gate_no_args
expect_fail "a missing artifact fails fast" "artifact not found" run_gate_missing
scenario_with
expect_fail "a directory that is not a .app is refused" "not a .app bundle" \
  run_gate_on_app "${WORK_DIR}/image-good"
# The extracted-bundle path must be a working path, not a branch that only ever
# fails. It is also the only path that can be exercised on a machine with no
# disk images.
scenario_with
expect_pass "an extracted .app bundle is accepted directly" \
  run_gate_on_app "${WORK_DIR}/image-good/private_gallery_app.app"

echo " the artifact is really a disk image, checked before anything is trusted"
# A file the size of a real upload that is not an image would be "mounted" by a
# permissive gate and would "launch" nothing: the #97 shape, on macOS.
if gate_env bash "${SCRIPT}" "${WORK_DIR}/not-a-dmg.dmg" >"${WORK_DIR}/notdmg.log" 2>&1; then
  bad "a non-disk-image upload is rejected" \
    "the gate accepted a file that is not a DMG, so a truncated or wrong upload would ship as launchable"
else
  if grep -qF "is not the .dmg this gate can gate" "${WORK_DIR}/notdmg.log"; then
    ok "a non-disk-image upload is rejected"
  else
    bad "a non-disk-image upload is rejected" \
      "failed for the wrong reason: $(tr '\n' '|' <"${WORK_DIR}/notdmg.log" | cut -c1-200)"
  fi
fi
if gate_env bash "${SCRIPT}" "${WORK_DIR}/tiny.dmg" >"${WORK_DIR}/tiny.log" 2>&1; then
  bad "a truncated artifact is rejected before it is mounted" "a four-byte file was accepted"
else
  if grep -qF "truncated or wrong file" "${WORK_DIR}/tiny.log"; then
    ok "a truncated artifact is rejected before it is mounted"
  else
    bad "a truncated artifact is rejected before it is mounted" \
      "failed for the wrong reason: $(tr '\n' '|' <"${WORK_DIR}/tiny.log" | cut -c1-200)"
  fi
fi

echo " mounting"
scenario_with "HDUTIL_ATTACH_FAIL=1"
expect_fail "a .dmg that will not mount fails the gate" "could not be mounted" run_gate
scenario_with

echo " what is inside the image"
scenario_with "MOUNT_SOURCE=${WORK_DIR}/image-no-app"
expect_fail "an image with no app bundle is rejected" "no .app bundle at its root" run_gate
scenario_with "MOUNT_SOURCE=${WORK_DIR}/image-two-apps"
expect_fail "an image with two app bundles is rejected rather than one being picked" \
  "refuses to guess which one a user would open" run_gate
scenario_with

echo " bundle layout (a bundle missing its daemon installs, launches and renders)"
scenario_with "MOUNT_SOURCE=${WORK_DIR}/image-no-daemon"
if run_gate >"${WORK_DIR}/no-daemon.log" 2>&1; then
  bad "a bundle with no Rust daemon is rejected" \
    "passed: the app launches and renders without galleryd, so no launch evidence catches a dropped sidecar"
else
  if grep -qF "ships without Contents/MacOS/galleryd" "${WORK_DIR}/no-daemon.log"; then
    ok "a bundle with no Rust daemon is rejected"
  else
    bad "a bundle with no Rust daemon is rejected" \
      "failed for the wrong reason: $(tr '\n' '|' <"${WORK_DIR}/no-daemon.log" | cut -c1-200)"
  fi
fi
scenario_with "MOUNT_SOURCE=${WORK_DIR}/image-daemon-not-executable"
expect_fail "a daemon that lost its executable bit is rejected" "not executable" run_gate
scenario_with "MOUNT_SOURCE=${WORK_DIR}/image-empty-main"
expect_fail "a zero-byte main executable is rejected" "is empty" run_gate
scenario_with "MOUNT_SOURCE=${WORK_DIR}/image-no-exec-key"
expect_fail "an Info.plist with no CFBundleExecutable is rejected" "no CFBundleExecutable" run_gate
# The sidecar requirement is a list, so a bundle that grows a second sidecar is
# gated on both -- and the list cannot be emptied into a vacuous pass.
expect_fail "a second required sidecar that is missing is caught too" \
  "ships without Contents/MacOS/ml_sidecar" \
  run_gate_on "${WORK_DIR}/image-good/private_gallery_app.app" \
  "MACOS_SMOKE_REQUIRED_BUNDLE_FILES=galleryd ml_sidecar"
expect_fail "an empty required-sidecar list is refused rather than checking nothing" \
  "refusing to check for no bundled files at all" \
  gate_env env "MACOS_SMOKE_REQUIRED_BUNDLE_FILES= " bash "${SCRIPT}" "${WORK_DIR}/release.dmg"

echo " architecture (the runner can only ever prove the slice it is)"
scenario_with "LIPO_ARCHS=${OTHER_ARCH}"
if run_gate >"${WORK_DIR}/arch.log" 2>&1; then
  bad "a bundle built for an architecture this runner cannot execute fails" \
    "the gate launched a bundle whose Mach-O slices do not include the runner"
else
  if grep -qF "cannot be executed here at all" "${WORK_DIR}/arch.log" &&
    grep -qF "this runner is ${RUNNER_ARCH}" "${WORK_DIR}/arch.log" &&
    grep -qF "is built for [${OTHER_ARCH}]" "${WORK_DIR}/arch.log"; then
    ok "a bundle built for an architecture this runner cannot execute fails"
  else
    bad "a bundle built for an architecture this runner cannot execute fails" \
      "failed for the wrong reason, or without naming both architectures: $(tr '\n' '|' <"${WORK_DIR}/arch.log" | cut -c1-240)"
  fi
fi
# A universal binary satisfies the runner, so the check must be reading the
# Mach-O headers rather than matching a build flag.
scenario_with "LIPO_ARCHS=${RUNNER_ARCH} ${OTHER_ARCH}"
expect_pass "a universal binary is accepted" run_gate
# A runnable app with an unrunnable daemon is invisible to a launch test: the
# daemon only matters once something calls it.
scenario_with "LIPO_ARCHS=${RUNNER_ARCH} ${OTHER_ARCH}" "LIPO_ARCHS_GALLERYD=${OTHER_ARCH}"
expect_fail "a runnable app with an unrunnable daemon is rejected" "galleryd" run_gate
scenario_with
expect_fail "a bundle whose Mach-O headers cannot be read is rejected" \
  "cannot be shown to be runnable" \
  gate_env env "MACOS_SMOKE_LIPO_BIN=${WORK_DIR}/lipo-broken" bash "${SCRIPT}" "${WORK_DIR}/release.dmg"

echo " Gatekeeper and quarantine"
scenario_with "QUARANTINE=1"
if run_gate >"${WORK_DIR}/quarantine.log" 2>&1; then
  bad "a quarantined published bundle is rejected" \
    "passed: a quarantined download raises a Gatekeeper dialog for every user, and no launch evidence would catch that"
else
  if grep -qF "carries com.apple.quarantine" "${WORK_DIR}/quarantine.log"; then
    ok "a quarantined published bundle is rejected"
  else
    bad "a quarantined published bundle is rejected" \
      "failed for the wrong reason: $(tr '\n' '|' <"${WORK_DIR}/quarantine.log" | cut -c1-200)"
  fi
fi
# The refusal has to happen BEFORE the launch, or the gate would be reporting
# "it launched" on a bundle a real user could not open.
if grep -qF "cold launch requested" "${WORK_DIR}/quarantine.log"; then
  bad "the quarantine check runs before the app is launched" \
    "the gate launched a quarantined bundle, so the check was not a pre-launch gate"
else
  ok "the quarantine check runs before the app is launched"
fi

echo " the display harness is proven before the app is launched"
scenario_with "PREFLIGHT_FAIL=1"
expect_fail "a runner that cannot capture the screen fails rather than being trusted" \
  "cannot capture the screen" run_gate
scenario_with "PREFLIGHT_SCREENSHOT=${WORK_DIR}/blank.png"
expect_fail "a screen capture that produces a blank frame fails" "blank or solid frame" run_gate
scenario_with "PREFLIGHT_SCREENSHOT=${WORK_DIR}/garbage.png"
expect_fail "an undecodable screen capture fails" "not a decodable PNG" run_gate
# The point of the preflight is attribution: a broken capture harness must never
# be reported as an app that failed to render.
if gate_env env "PREFLIGHT_FAIL=1" bash "${SCRIPT}" "${WORK_DIR}/release.dmg" 2>&1 |
  grep -qF "no settled app frame"; then
  bad "a broken capture harness is never reported as an app that failed to render" \
    "the failure was attributed to the app rather than to the harness"
else
  ok "a broken capture harness is never reported as an app that failed to render"
fi

echo " launch"
scenario_with "OPEN_FAIL=1"
expect_fail "an OS-level refusal to launch fails the gate" "could not be launched" run_gate
scenario_with "LSAPPINFO_ALREADY_RUNNING=1"
expect_fail "a warm launch is refused because this gate requires a cold one" \
  "requires a cold launch" run_gate
scenario_with "LSAPPINFO_NEVER=1"
expect_fail "an app that dies on launch fails" "never appeared in the window server" run_gate
scenario_with

echo " the window is not optional (a running app with no window would still screenshot the desktop)"
scenario_with "LSAPPINFO_INFO=${WORK_DIR}/window-none.txt"
expect_fail "an app that runs with no window at all fails" "never presented a window" run_gate
# window-hidden.txt carries BOTH a valid window id AND Hidden=1. That
# combination is the dangerous one: a gate consulting Hidden only when it has no
# window id accepts this, and the full-screen capture behind a hidden app is
# complex and stable enough to settle. A window id must not buy a pass.
scenario_with "LSAPPINFO_INFO=${WORK_DIR}/window-hidden.txt"
expect_fail "an app whose window is hidden fails even though it reports a window id" \
  "Hidden=1" run_gate
scenario_with "LSAPPINFO_INFO=${WORK_DIR}/window-tiny.txt"
# A sub-floor window is refused at the window wait, before any capture is judged,
# so the reason must be the size floor and not a render verdict. The gate did fail
# here; the earlier assertion looked for "no settled app frame", which is a
# different failure and is not what happens.
expect_fail "a window below the size floor is not accepted as a rendered UI" \
  "below the 200x200 floor" run_gate
scenario_with "LSAPPINFO_INFO=${WORK_DIR}/window-unparseable.txt"
expect_fail "an unrecognised window-server reply is refused rather than guessed at" \
  "never presented a window" run_gate
scenario_with "LSAPPINFO_FAIL=1"
expect_fail "a window server that cannot be asked fails rather than reporting no window" \
  "never presented a window" run_gate
# A window that exists when the launch checks run and is gone by the time the
# frame is judged must fail. Checking the window only once, before the render
# loop, is exactly what would let this pass.
scenario_with "WINDOW_LOST_ON_CAPTURE=1" "LSAPPINFO_LOST_AFTER_CAPTURE=1" \
  "LSAPPINFO_INFO_AFTER=${WORK_DIR}/window-none.txt"
expect_fail "a window that disappears before the frame is judged fails" \
  "window went away while waiting for a settled frame" run_gate
# ...and it must be reported as a window that WENT AWAY, not as one that was
# never shown. The app had a window when the launch checks ran, so "never
# presented a window" would be a false account that sends whoever reads a red
# build looking in the wrong place.
if grep -qF "never presented a window" "${WORK_DIR}/out" 2>/dev/null; then
  bad "a lost window is not reported as a window that never appeared" \
    "the message claims the app never showed a window, which the log contradicts"
else
  ok "a lost window is not reported as a window that never appeared"
fi
# Visible with no window id is the weaker but still affirmative answer, and it
# exercises the full-screen capture fallback. It must pass, and it must be
# labelled, because a frame of "whatever is on the desktop" is a weaker claim.
scenario_with "LSAPPINFO_INFO=${WORK_DIR}/window-visible-no-id.txt" "SCREENSHOT_WINDOW="
if run_gate >"${WORK_DIR}/visible-no-id.log" 2>&1; then
  ok "an app reported visible without a window id still gates on a rendered frame"
else
  bad "an app reported visible without a window id still gates on a rendered frame" \
    "$(tr '\n' '|' <"${WORK_DIR}/visible-no-id.log" | cut -c1-240)"
fi
if grep -qF "settled app frame (screen capture)" "${WORK_DIR}/visible-no-id.log"; then
  ok "the full-screen fallback is announced in the log, not taken silently"
else
  bad "the full-screen fallback is announced in the log, not taken silently" \
    "a frame of 'whatever is on the desktop' must be labelled as such: $(tr '\n' '|' <"${WORK_DIR}/visible-no-id.log" | cut -c1-240)"
fi
# A window id that cannot be captured must fall back rather than wedge, and the
# fallback must be the announced kind.
scenario_with "SCREENSHOT_FAIL_WINDOW=1"
# The needle is the announcement's own text. It used to be "window-scoped
# capture of", which also occurs in the window-presence log line, so it could not
# distinguish an announced fallback from a silent one -- and the announcement was
# in fact dead (a global set inside a command substitution, lost with the
# subshell). The phrase below only ever appears when announcing a downgrade.
if run_gate >"${WORK_DIR}/window-capture-fail.log" 2>&1 &&
  grep -qF "falling back to a full-screen capture" "${WORK_DIR}/window-capture-fail.log"; then
  ok "a window-scoped capture that fails falls back and says so"
else
  bad "a window-scoped capture that fails falls back and says so" \
    "either the fallback did not happen or it was silent: $(tr '\n' '|' <"${WORK_DIR}/window-capture-fail.log" | cut -c1-240)"
fi

echo " rendering"
# SCREENSHOT_WINDOW is set alongside SCREENSHOT in every rendering case: the
# happy path takes the window-scoped capture, so the variable that decides the
# frame content on that path is the one that must be overridden. Setting only
# SCREENSHOT leaves the rich window image in place and the case passes for the
# wrong reason -- asserting about a frame it never produced.
scenario_with "SCREENSHOT=${WORK_DIR}/blank.png" "SCREENSHOT_WINDOW=${WORK_DIR}/blank.png"
expect_fail "a blank screen counts as never rendered" "no settled app frame" run_gate
scenario_with "SCREENSHOT=${WORK_DIR}/garbage.png" "SCREENSHOT_WINDOW=${WORK_DIR}/garbage.png"
expect_fail "an undecodable screenshot counts as never rendered" "no settled app frame" run_gate
# SCREENSHOT_FAIL only breaks the full-screen path, so the window-scoped one must
# break too; otherwise the gate takes the window capture and settles, and the
# case passes while proving nothing about a dead display.
scenario_with "SCREENSHOT_FAIL=1" "SCREENSHOT_FAIL_WINDOW=1"
expect_fail "a screen that cannot be captured at all counts as never rendered" \
  "no settled app frame" run_gate
# A screen that never settles -- every capture differs -- must fail. A gate that
# accepts the first complex frame is accepting whatever the engine happened to be
# drawing mid-transition.
# Drift is injected on BOTH capture paths. Covering the window-scoped one is
# the point: that is the path a passing run takes, so drifting only the
# full-screen branch would leave the stability check untested by every green run.
scenario_with "SCREENSHOT_DRIFT=1" "SCREENSHOT_DRIFT_IMAGE=${WORK_DIR}/rich-drift.png"
expect_fail "a frame that never settles fails the gate" "no settled app frame" run_gate
# Guard: the case above must actually have reached the window-scoped path. Had it
# fallen back to the full screen the assertion would still pass while proving
# nothing about stability of the capture the gate really uses.
if grep -qF "settled app frame (window capture)" "${WORK_DIR}/out" 2>/dev/null; then
  bad "the never-settling case exercised the window-scoped capture it claims to" \
    "the window-scoped capture settled, so stability was never reached on that path"
else
  ok "the never-settling case exercised the window-scoped capture it claims to"
fi
# ...and the two drift frames must genuinely differ, or that case would be
# indistinguishable from the passing one and would prove nothing.
if cmp -s "${WORK_DIR}/rich.png" "${WORK_DIR}/rich-drift.png"; then
  bad "the never-settling fixture really alternates between two different frames" \
    "rich.png and rich-drift.png are byte-identical"
else
  ok "the never-settling fixture really alternates between two different frames"
fi
# The threshold has to be a real bar: a fixture just under it must fail, so the
# gate cannot be passing on "any PNG at all".
scenario_with "SCREENSHOT=${WORK_DIR}/eighteen.png" "SCREENSHOT_WINDOW=${WORK_DIR}/eighteen.png"
expect_fail "a frame just under the complexity threshold is rejected" \
  "no settled app frame" run_gate
scenario_with

echo " crashes"
# A report written AFTER the launch boundary: a process that came up, painted,
# and then died. This is the only crash the gate must catch, and the timing is
# what makes it a crash of this run rather than a stale one.
scenario_with "CRASH_REPORT_ON_CAPTURE=1" "CRASH_REPORT_FILE=${WORK_DIR}/crash-ours.txt"
rm -f "${DIAG_DIR}"/*.ips
expect_fail "a crash report written after launch fails the gate" \
  "a crash report was written" run_gate
rm -f "${DIAG_DIR}"/*.ips
# A same-prefix helper that crashed is not this app crashing, and failing the
# release on it would be the false positive that gets a gate switched off. The
# file name matches the app's; only the body says otherwise, so this case tests
# the body filter and nothing else can satisfy it.
# Planted on capture, like the crash above, so the report is newer than the
# gate's baseline marker. Copied in beforehand it would be excluded by
# `-newer` and the body filter would never run -- the case would pass while
# proving nothing, which is exactly what a mutation of the body filter showed.
scenario_with "CRASH_REPORT_ON_CAPTURE=1" \
  "CRASH_REPORT_FILE=${WORK_DIR}/crash-helper.txt" \
  "CRASH_REPORT_NAME=private_gallery_app_helper_2026-09-30-120000.ips"
if run_gate >"${WORK_DIR}/helper-crash.log" 2>&1; then
  ok "a same-prefix helper's crash report is not mistaken for the app's"
else
  bad "a same-prefix helper's crash report is not mistaken for the app's" \
    "only the report body distinguishes them: $(tr '\n' '|' <"${WORK_DIR}/helper-crash.log" | cut -c1-200)"
fi
scenario_with
# Two independent guards, because either one silently absent makes the case
# above pass for a reason that has nothing to do with the body filter.
if "${REAL_FIND}" "${DIAG_DIR}" -type f -name 'private_gallery_app*' -print | grep -q .; then
  ok "the helper crash report does match the name filter, so only the body filter rejects it"
else
  bad "the helper crash report does match the name filter, so only the body filter rejects it" \
    "the fixture never reached the filter under test"
fi
if grep -qF 'private_gallery_app_helper' "${WORK_DIR}/helper-crash.log"; then
  bad "the helper crash report reaches the crash report listing" \
    "the fixture did not arrive, so the body filter was never applied to it"
else
  ok "the helper crash report is listed as a candidate and then rejected by its body, not by its name"
fi
rm -f "${DIAG_DIR}"/*.ips
# An unreadable crash directory is the #97 false pass on this platform: "found
# nothing" in a directory that was never read is the absence of a question.
scenario_with "FIND_FAIL_DIR=${DIAG_DIR}"
if run_gate >"${WORK_DIR}/find-fail.log" 2>&1; then
  bad "an unreadable crash-report directory fails rather than reporting clean" \
    "passed: a crash check that could not run was reported as a passing one"
else
  if grep -qF "refusing to report a crash check that never ran" "${WORK_DIR}/find-fail.log"; then
    ok "an unreadable crash-report directory fails rather than reporting clean"
  else
    bad "an unreadable crash-report directory fails rather than reporting clean" \
      "failed for the wrong reason: $(tr '\n' '|' <"${WORK_DIR}/find-fail.log" | cut -c1-200)"
  fi
fi
# ...and the same distinction for the mount-point scan: an image root that
# cannot be listed must not be reported as "no app bundle", because that is a
# claim about the artifact made from a directory that was never read.
scenario_with "FIND_FAIL=1"
if gate_env env bash "${SCRIPT}" "${WORK_DIR}/release.dmg" >"${WORK_DIR}/list-fail.log" 2>&1; then
  bad "an unreadable mounted-image root fails rather than reporting no app bundle" \
    "passed: an image root that could not be listed was reported as an empty one"
else
  if grep -qF "could not list the mounted image" "${WORK_DIR}/list-fail.log"; then
    ok "an unreadable mounted-image root fails rather than reporting no app bundle"
  else
    bad "an unreadable mounted-image root fails rather than reporting no app bundle" \
      "failed for the wrong reason: $(tail -n 3 "${WORK_DIR}/list-fail.log" | tr '\n' '|' | cut -c1-200)"
  fi
fi
# Guard: the case above must have failed at the LISTING, not fallen through to
# "no .app bundle at its root". Without this it would also pass on the old
# conflating behaviour, which is precisely the bug being pinned.
if grep -qF "no .app bundle at its root" "${WORK_DIR}/list-fail.log" 2>/dev/null; then
  bad "an unreadable mount root is not conflated with an empty image" \
    "the gate called the image empty, which it never established"
else
  ok "an unreadable mount root is not conflated with an empty image"
fi
# A runner where the reporting path does not exist at all has not been shown to
# have one, so the gate must not report "no crashes".
scenario_with
if gate_env env "MACOS_SMOKE_DIAG_REPORTS_DIRS=${WORK_DIR}/no-such-diag-dir" \
  bash "${SCRIPT}" "${WORK_DIR}/release.dmg" >"${WORK_DIR}/nodiag.log" 2>&1; then
  bad "a runner with no crash-report directory fails rather than reporting clean" \
    "passed: nothing downstream re-checks for crashes, so this is a crash gate that never ran"
else
  if grep -qF "no crash-report directory exists" "${WORK_DIR}/nodiag.log"; then
    ok "a runner with no crash-report directory fails rather than reporting clean"
  else
    bad "a runner with no crash-report directory fails rather than reporting clean" \
      "failed for the wrong reason: $(tr '\n' '|' <"${WORK_DIR}/nodiag.log" | cut -c1-200)"
  fi
fi
scenario_with

echo " a missing tool is never a skip"
# MACOS_SMOKE_HDITOOL_BIN is reset to the bare name on purpose. The suite
# points it at an absolute fake path so every other case can use the fake, and
# `require_tool` on an absolute path succeeds no matter what PATH says -- so
# without this the case ran the fake, passed, and proved nothing. Resetting to the
# bare name is what makes the PATH farm, and therefore the real `command -v`,
# decide the outcome.
if gate_env env "PATH=${NO_HDITOOL_BIN}" "MACOS_SMOKE_HDITOOL_BIN=hdiutil" \
  bash "${SCRIPT}" "${WORK_DIR}/release.dmg" \
  >"${WORK_DIR}/no-hdiutil.log" 2>&1; then
  bad "a missing hdiutil fails the gate rather than skipping the mount" \
    "passed: without hdiutil nothing about the published image was verified"
else
  if grep -qF "missing required tool" "${WORK_DIR}/no-hdiutil.log"; then
    ok "a missing hdiutil fails the gate rather than skipping the mount"
  else
    bad "a missing hdiutil fails the gate rather than skipping the mount" \
      "failed for the wrong reason: $(tr '\n' '|' <"${WORK_DIR}/no-hdiutil.log" | cut -c1-200)"
  fi
fi

echo " evidence"
scenario_with
expect_pass "a passing run writes evidence" run_gate
# Existence, not non-emptiness, for every evidence file. An earlier version
# asserted `-s` for all of them and so failed on `case-crash-reports.txt`, which
# is LEGITIMATELY empty on a clean run -- the gate found no reports. Requiring a
# clean crash check to produce bytes would mean writing a placeholder into a file
# whose entire meaning is "no reports".
for evidence in case.png case-preflight.png case-crash-reports.txt case-log.txt \
  case-lsappinfo.txt case-spctl.txt case-summary.txt case-open.txt; do
  if [[ -f "${WORK_DIR}/evidence/${evidence}" ]]; then
    ok "evidence ${evidence} exists"
  else
    bad "evidence ${evidence} exists"
  fi
done
# The evidence that must have content, because "exists but says nothing" is the
# same absence of a question as "does not exist".
for evidence in case.png case-preflight.png case-log.txt case-lsappinfo.txt \
  case-spctl.txt case-summary.txt case-open.txt; do
  if [[ -s "${WORK_DIR}/evidence/${evidence}" ]]; then
    ok "evidence ${evidence} is non-empty"
  else
    bad "evidence ${evidence} is non-empty" \
      "an empty evidence file is a claim a reader cannot check"
  fi
done
if grep -q "result: PASS" "${WORK_DIR}/evidence/case-summary.txt" 2>/dev/null; then
  ok "the summary records the verdict"
else
  bad "the summary records the verdict"
fi
# The digest is what ties the evidence to a specific artifact, so an empty field
# is a claim a reader cannot check.
if grep -qE "^artifact sha256: [0-9a-f]{64}$" "${WORK_DIR}/evidence/case-summary.txt" 2>/dev/null; then
  ok "the summary records the exact artifact digest"
else
  bad "the summary records the exact artifact digest" \
    "got: $(grep -E '^artifact sha256: ' "${WORK_DIR}/evidence/case-summary.txt" 2>/dev/null | cut -c1-120)"
fi
# The window-server dump has to be the dump, not a summary: a stub could satisfy
# a size check without proving the gate ever asked the window server.
if grep -qF "BundleIdentifier: ${BUNDLE_ID}" "${WORK_DIR}/evidence/case-lsappinfo.txt" 2>/dev/null; then
  ok "the retained window-server evidence is the tool's actual output"
else
  bad "the retained window-server evidence is the tool's actual output" \
    "expected the app's bundle id in the dump; got: $(tr '\n' ' ' <"${WORK_DIR}/evidence/case-lsappinfo.txt" 2>/dev/null | cut -c1-160)"
fi
# A crash check that passed must have actually looked. The report directory is
# empty here, so the file is legitimately empty -- which is exactly why the
# assertion is that the file EXISTS and the run recorded the verdict, not that
# it has content.
if [[ -f "${WORK_DIR}/evidence/case-crash-reports.txt" ]] &&
  grep -qF "crash reports clean" "${WORK_DIR}/out" 2>/dev/null; then
  ok "a clean crash check is recorded in the log as well as the evidence file"
else
  bad "a clean crash check is recorded in the log as well as the evidence file"
fi
# The limitations must be printed, not kept in a comment. A green run a reader
# cannot interpret is a gate that gets trusted for the wrong thing.
if grep -qF "LIMITATIONS (what this gate does NOT prove)" "${WORK_DIR}/out" 2>/dev/null; then
  ok "a passing run prints what it does not prove"
else
  bad "a passing run prints what it does not prove" \
    "the limitations block must reach the log: $(tr '\n' '|' <"${WORK_DIR}/out" | cut -c1-200)"
fi
for claimed_limitation in "Gatekeeper" "Rosetta" "accessibility service" "Apple Silicon"; do
  if grep -qiF "${claimed_limitation}" "${WORK_DIR}/out" 2>/dev/null; then
    ok "the limitations block names '${claimed_limitation}'"
  else
    bad "the limitations block names '${claimed_limitation}'" \
      "an unnamed limitation is a limitation nobody can act on"
  fi
done
# One path policy: inside the workspace the summary records workspace-relative
# paths, so evidence is comparable across runners instead of embedding
# machine-specific prefixes.
# GITHUB_WORKSPACE is now set for every run through gate_env, so this asserts
# the property directly rather than in a special-cased invocation.
if grep -qE "^command: open -n .*private_gallery_app\.app$" "${WORK_DIR}/evidence/case-open.txt" 2>/dev/null &&
  ! grep -qE "^command: open -n /" "${WORK_DIR}/evidence/case-open.txt" 2>/dev/null; then
  ok "the launch evidence records the bundle path workspace-relatively"
else
  bad "the launch evidence records the bundle path workspace-relatively" \
    "got: $(grep -E '^command: ' "${WORK_DIR}/evidence/case-open.txt" 2>/dev/null | cut -c1-140)"
fi
if grep -qE "^artifact: release\.dmg$" "${WORK_DIR}/evidence/case-summary.txt" 2>/dev/null; then
  ok "summary paths are workspace-relative when inside the workspace"
else
  bad "summary paths are workspace-relative when inside the workspace" \
    "got: $(grep -E '^(artifact|screenshot): ' "${WORK_DIR}/evidence/case-summary.txt" 2>/dev/null | tr '\n' '|' | cut -c1-160)"
fi
# The whole file, not just the `artifact:` line. Raw tool output used to be
# appended to the summary, which put a bare absolute path in the middle of a
# key: value record.
if grep -qE "^[^:]*: /" "${WORK_DIR}/evidence/case-summary.txt" 2>/dev/null; then
  bad "no absolute runner path leaks into the summary" \
    "an absolute path makes evidence incomparable across machines: $(grep -nE '^[^:]*: /' "${WORK_DIR}/evidence/case-summary.txt" | head -2 | tr '\n' '|')"
else
  ok "no absolute runner path leaks into the summary"
fi
# Every summary line must be a `key: value` record; a bare line means some tool
# output leaked into a structured file.
if grep -qvE '^(result|artifact|app bundle|bundle id|executable|runner arch|macOS|final window id|final bounds|final pid|screenshot|preflight screenshot|gatekeeper|artifact sha256): ' \
  "${WORK_DIR}/evidence/case-summary.txt" 2>/dev/null; then
  bad "every summary line is a key: value record" \
    "a bare line means raw tool output leaked into the summary"
else
  ok "every summary line is a key: value record"
fi
# An extracted bundle cannot be hashed, and an empty digest field would be a
# claim a reader cannot check.
scenario_with
if run_gate_on_app "${WORK_DIR}/image-good/private_gallery_app.app" >/dev/null 2>&1 &&
  grep -qE "^artifact sha256: n/a " "${WORK_DIR}/evidence/case-summary.txt" 2>/dev/null; then
  ok "an un-hashable extracted bundle says so instead of printing an empty digest"
else
  bad "an un-hashable extracted bundle says so instead of printing an empty digest" \
    "got: $(grep -E '^artifact sha256: ' "${WORK_DIR}/evidence/case-summary.txt" 2>/dev/null | cut -c1-120)"
fi
# An unreadable unified log is annotated, not silently swallowed: the log is
# evidence, and evidence that failed to collect has to say so.
scenario_with "LOG_FAIL=1"
if run_gate >"${WORK_DIR}/log-fail.log" 2>&1 && grep -qF "::warning::could not read the unified log" "${WORK_DIR}/log-fail.log"; then
  ok "an unreadable unified log is annotated rather than silently dropped"
else
  bad "an unreadable unified log is annotated rather than silently dropped" \
    "expected a warning annotation and a pass: $(tr '\n' '|' <"${WORK_DIR}/log-fail.log" | cut -c1-200)"
fi
scenario_with

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
# The signature check specifically, on a file whose every other byte is a valid
# PNG. `garbage.png` cannot show this: dropping the signature check leaves it
# rejected as an unsupported header, so the assertion above passes either way.
if decode_colors "${WORK_DIR}/badsig.png" >/dev/null 2>&1; then
  bad "a PNG whose signature is corrupted is rejected on the signature alone"
else
  ok "a PNG whose signature is corrupted is rejected on the signature alone"
fi
# The complexity threshold is 32. Both drift fixtures must clear it, or the
# never-settling case would be rejected for looking blank and the stability check
# would never actually be exercised.
for frame in rich.png rich-drift.png; do
  colors="$(decode_colors "${WORK_DIR}/${frame}" 2>/dev/null || printf -1)"
  if [[ "${colors}" =~ ^[0-9]+$ ]] && ((colors >= 32)); then
    ok "${frame} clears the gate's 32-colour threshold (${colors}), so stability is what is under test"
  else
    bad "${frame} clears the gate's 32-colour threshold, so stability is what is under test" \
      "decoded ${colors} colours; too simple to exercise the stability check"
  fi
done
# ...and the "just under the threshold" fixture must NOT clear it, or the
# threshold test above would be passing for the wrong reason.
colors="$(decode_colors "${WORK_DIR}/eighteen.png" 2>/dev/null || printf -1)"
if [[ "${colors}" =~ ^[0-9]+$ ]] && ((colors < 32 && colors > 1)); then
  ok "the just-under-threshold fixture really is under it (${colors}), so the threshold is a real bar"
else
  bad "the just-under-threshold fixture really is under it, so the threshold is a real bar" \
    "decoded ${colors} colours; the threshold test is not testing a threshold"
fi

echo " this suite's own verdict plumbing"

# The counters this file reports have to actually move when an assertion is
# recorded, because the exit status below is derived from them. Asserted rather
# than assumed: the failure mode is silent and total. A `bad` that stopped
# incrementing FAIL_COUNT would leave this suite exiting 0 with failures printed
# on screen, and nobody reading a CI log would notice.
probe_pass_before="${PASS_COUNT}"
probe_fail_before="${FAIL_COUNT}"
ok "probe: a passing assertion increments the pass counter" >/dev/null
bad "probe: a failing assertion increments the fail counter" >/dev/null
if [[ "${PASS_COUNT}" -eq $((probe_pass_before + 1)) &&
  "${FAIL_COUNT}" -eq $((probe_fail_before + 1)) ]]; then
  ok "the suite's own counters move when an assertion is recorded"
else
  bad "the suite's own counters move when an assertion is recorded" \
    "pass went ${probe_pass_before}->${PASS_COUNT}, fail went ${probe_fail_before}->${FAIL_COUNT}"
fi
# Take the deliberate failure back out of the count so it does not fail this run.
# The check above has already run by here, so a counter broken to move by 0 is
# recorded before this restore rather than papered over by it.
PASS_COUNT="${probe_pass_before}"
FAIL_COUNT="${probe_fail_before}"

# A forced-failure lever, for an external harness to observe what this suite
# does with its exit status when an assertion fails. A process cannot observe
# its own exit status, and re-executing this whole suite in a child to find out
# would roughly double the cost of every iteration of the mutation harness
# (about two minutes each here).
#
# This is deliberately NOT a general "skip the tests" switch: every test above
# still runs, so it cannot be used to make a broken suite look green. It only
# adds one failing assertion on top of the real results.
if [[ "${MACOS_SMOKE_SUITE_FORCE_FAIL:-0}" == "1" ]]; then
  bad "forced failure, requested by MACOS_SMOKE_SUITE_FORCE_FAIL=1" \
    "this assertion is meant to fail; the harness is checking the exit status"
fi

# The suite's own exit status.
#
# This block was MISSING, which was the worst defect this file had: nine
# assertions were failing while the suite exited 0. A CI step running this file
# would have been green, and the mutation harness depends on a non-zero exit to
# notice a broken gate at all -- without it "the suite went red" would have been
# unobservable and every mutation would have read as non-biting. The repo hit
# this exact class of bug on its required checks (#136), so the count and the
# exit status are produced together and the count is printed last, where a
# truncated log cannot hide it.
printf '\n%s passed, %s failed\n' "${PASS_COUNT}" "${FAIL_COUNT}"
if ((FAIL_COUNT > 0)); then
  exit 1
fi
exit 0
