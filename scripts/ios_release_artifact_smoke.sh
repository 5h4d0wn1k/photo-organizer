#!/usr/bin/env bash
#
# Artifact-level release gate for the iOS app bundle: prove the bundle we are
# about to publish can actually be installed, cold-launched, and survives long
# enough to render a real frame, on a real iOS Simulator runtime.
#
# This is the iOS half of issue #98. The Android half is
# scripts/android_release_artifact_smoke.sh (issue #97) and the discipline here
# is deliberately identical: same fail-closed posture, same "a read that could
# not happen is not a clean read" rule, same structural check for the thing the
# emulator/emulator-slice cannot prove, same evidence contract.
#
# ============================== READ THIS FIRST ==============================
#
# WHAT A GREEN RUN HERE MEANS, EXACTLY:
#
#   An **iOS Simulator** build of the app was installed on a booted iPhone
#   Simulator on a macOS runner, cold-launched, held window focus, painted a
#   stable, visually complex frame, and produced no crash report attributed to
#   it.
#
# WHAT A GREEN RUN HERE DOES **NOT** MEAN -- do not read it as any of these:
#
#   1. It says NOTHING about the **device archive** that the release job
#      actually ships (`Runner.app` built for the `iphoneos` SDK). The
#      simulator bundle is a *different binary*: it is built for the
#      `iphonesimulator` SDK, carries `aarch64-apple-ios-sim` (Apple silicon
#      runners) or `x86_64-apple-ios` (Intel runners) slices instead of
#      `aarch64-apple-ios`, and links a simulator dynamic loader. `simctl
#      install` physically cannot accept an iPhoneOS bundle and `simctl launch`
#      cannot exec a device binary in the simulator, so no amount of simulator
#      testing can say anything about the device slice's installability.
#   2. It is not a release-mode build. Flutter only supports `BuildMode.debug`
#      for simulators -- `--simulator` with `--release` or `--profile` exits
#      with "<MODE> mode is not supported for simulators". Verified by reading
#      flutter_tools on 2026-10-01 against master:
#        packages/flutter_tools/lib/src/commands/build_ios.dart
#          `if (environmentType == EnvironmentType.simulator &&
#              !buildInfo.supportsSimulator)
#             throwToolExit('${buildInfo.mode.uppercaseName} mode is not
#                            supported for simulators.');`
#        packages/flutter_tools/lib/src/build_info.dart
#          `bool get supportsSimulator => isEmulatorBuildMode(mode);`
#          `bool isEmulatorBuildMode(BuildMode mode) => mode == BuildMode.debug;`
#      NOTE: this was verified by reading the Flutter source over the network.
#      It was NOT verified by running `flutter build ios --simulator --release`
#      on a Mac, because this script was written on Linux where no iOS tooling
#      exists. The source is upstream's own guard, so it is authoritative, but
#      it is a source reading and not a reproduction.
#      So this gate exercises a JIT debug build. A device-only failure -- AOT
#      snapshotting, the dylib embedded in App.framework, bitcode/signing
#      flags, device-only plugins -- is invisible here.
#   3. It does not check the CPU architecture of the native daemon, only its
#      Mach-O *platform* (see EXPECTED_PLATFORM / assert_macho_platform:
#      `ios-simulator`). The workflow builds the simulator slice for
#      `aarch64-apple-ios-sim`, and `macos-latest` is Apple silicon, so the pair
#      is right today. On an Intel runner an arm64-sim daemon would pass this gate
#      and then fail to load -- the platform would read `ios-simulator` in both
#      cases, and that is the only thing compared. Recorded as a known gap rather
#      than implied coverage: this gate proves the daemon is a simulator binary,
#      not that it is the right simulator binary for the machine inspecting it.
#   3. It proves nothing about App Store or TestFlight acceptance, and nothing
#      about installation on a real iPhone.
#   4. It is not real hardware: no real camera, no real Photos library, no real
#      keychain under device lock, a different GPU/Metal path, and no memory or
#      thermal pressure. The simulator is also much more permissive about
#      sandbox/entitlement violations than a device is.
#   5. The render check cannot distinguish the LaunchScreen storyboard from the
#      app's own first frame. A launch storyboard is a complex, perfectly
#      stable image, exactly like a real first frame, and separating them needs
#      an accessibility/automation surface this gate does not have.
#   6. Only one CPU slice is exercised per runner, and the *simulator* slice,
#      never the device slice.
#   7. MOST IMPORTANT -- **the app on iOS has no working backend at all.** The
#      release job copies the `galleryd` daemon into `Runner.app/Frameworks/race`
#      (release.yml, "Package unsigned .app"), and this gate checks that file is
#      present, executable, and carries the expected Mach-O slice. It cannot be
#      more than that, because on iOS the app never runs it:
#        * `app/lib/src/services/local_daemon_launcher.dart` returns early with
#          `attempted: false, started: false` unless
#          `Platform.isLinux || Platform.isMacOS || Platform.isWindows`, so the
#          client never attempts to spawn it (this was read from the source on
#          Linux, not reproduced on a simulator).
#        * iOS does not permit an app to exec an arbitrary shipped executable
#          from inside its own bundle; `Frameworks/race` is an inert data file as
#          far as the OS is concerned.
#      So "the daemon shipped in the bundle and is structurally sound" is the
#      whole of what is established about it. A green install/launch/render run
#      means the *shell* of the app launches and paints -- not that the product
#      works on iOS.
#
#      This gate therefore does NOT treat install/launch/render as a pass. After
#      those succeed it runs `assert_backend_is_reachable`, which fails the
#      artifact unless a probe supplied through IOS_SMOKE_BACKEND_PROBE answers.
#      iOS forbids the app from spawning galleryd, so the harness must provide a
#      host daemon and point the debug build at it with
#      IOS_SMOKE_LAUNCH_ARGUMENTS; the probe must then prove the app reached it.
#      Without a probe the gate exits non-zero even after a perfect install,
#      launch and render. A gate that reported "installed and painted" as PASS
#      would be declaring a non-functional artifact healthy, which is the
#      partial-release shape these gates exist to prevent.
#
# WHAT A DEVICE ARCHIVE WOULD ADDITIONALLY REQUIRE -- none of it available on a
# free runner, which is why it is not attempted here rather than faked:
#   * An Apple Developer Program membership (paid, annual, per organisation).
#   * An Apple Distribution certificate in the runner keychain.
#   * A provisioning profile whose App ID, entitlements, device set and
#     distribution method match the bundle, downloaded from the developer
#     portal (an API key or a distribution certificate + profile).
#   * `codesign` of the nested frameworks, the app binary, and the final bundle
#     with `--options runtime`, plus the embedded `embedded.mobileprovision`.
#   * For TestFlight/App Store distribution, App Store Connect provisioning and
#     `xcrun notarytool submit` + `stapler` notarization of a zipped archive,
#     with the submission validated by Apple.
#   * And finally a real device (or a managed device farm with real signing) to
#     install it.
#
# The banner is printed on every run, pass or fail, and asserted by
# scripts/tests/ios_release_artifact_smoke_test.sh, so it cannot be quietly
# deleted while the rest of the gate still looks green.
#
# ============================== END OF WARNING ===============================
#
# Design notes (each is a deliberate decision, not an accident):
#
#   * It is a committed script, not an inline `run:` block. The logic has real
#     control flow, real deadlines and real parsing, and all of that has to be
#     reviewable and unit-testable off a Mac.
#
#   * "Launched" is not the same as "rendered". `simctl launch` returns 0 with
#     a pid while the app is still on its LaunchScreen, or on a blank frame.
#     The gate therefore requires THREE independent things before it will
#     accept a frame: the app is registered with launchd and alive, the frame
#     decodes and is visually complex, and the frame is byte-identical across
#     two consecutive captures (which rejects a screen caught mid-transition).
#
#   * The device/simulator slice is checked STRUCTURALLY, from the Mach-O
#     headers, before the simulator is touched. This is the direct analogue of
#     the Android arm64/armeabi-v7a ABI check, and it exists for the same
#     reason: the simulator only ever runs simulator slices, so a bundle
#     carrying the wrong slice installs perfectly on the runner and fails on
#     every real device, and nothing downstream re-asserts it. The check reads
#     `LC_BUILD_VERSION` (and the older `LC_VERSION_MIN_IPHONESIMULATOR`) out
#     of every slice rather than trusting the bundle's path -- `Runner.app`
#     under `build/ios/iphonesimulator/` and `build/ios/iphoneos/` have the
#     same name, so the path proves nothing.
#
#   * A read that could not happen is never reported as a clean read. Every
#     simctl call that feeds a gate either succeeds or fails the run; an empty
#     or unparseable answer is a failure, not a pass. This is the exact bug
#     class that shipped an adverse ApplicationExitInfo record green on
#     Android, and it is the same class of mistake.
#
#   * Nothing hangs. Every wait is a deadline; the one genuinely blocking
#     simctl subcommand (`bootstatus`) is wrapped in a deadline of its own. The
#     workflow's `timeout-minutes` is the outer backstop, not the primary
#     mechanism.
#
# Usage: ios_release_artifact_smoke.sh <path-to-Runner.app>
#
# Tunables (all have safe defaults; override via env in tests):
#   IOS_SMOKE_XCRUN                  xcrun binary to use (default: xcrun)
#   IOS_SMOKE_BUNDLE_ID              bundle identifier the bundle must declare
#   IOS_SMOKE_EXPECT_PLATFORM        Mach-O platform every binary must carry.
#                                    Must be a simulator platform: `ios-simulator`
#                                    (every arm64 simulator slice, the default),
#                                    `ios-simulator-x86_64` or
#                                    `ios-simulator-i386` for Intel slices. A
#                                    bundle carrying only an `iphoneos` slice
#                                    fails this check.
#   IOS_SMOKE_NATIVE_BINARY          path, inside the .app, of the native
#                                    daemon the release job ships (default:
#                                    Frameworks/race, which is where release.yml
#                                    copies galleryd -- see issue #82). The gate
#                                    cannot check that it is ever EXECUTED: iOS
#                                    does not allow it and this client does not
#                                    try, so only presence, the executable bit
#                                    and the Mach-O slice are asserted.
#   IOS_SMOKE_SIM_RUNTIME            CoreSimulator runtime version to pin. This
#                                    is the HYPHENATED form exactly as it
#                                    appears in the runtime id
#                                    `...SimRuntime.iOS-18-0` -- i.e. `18-0`,
#                                    NOT `18.0`. A dotted pin matches nothing and
#                                    fails closed, listing the available
#                                    spellings.
#   IOS_SMOKE_SIM_DEVICE             device name prefix to prefer (default iPhone)
#   IOS_SMOKE_BOOT_TIMEOUT_SECONDS   simulator boot budget
#   IOS_SMOKE_LAUNCH_TIMEOUT_SECONDS process-alive budget after simctl launch
#   IOS_SMOKE_RENDER_TIMEOUT_SECONDS first-settled-frame budget
#   IOS_SMOKE_MIN_DISTINCT_COLORS    screenshot complexity threshold
#   IOS_SMOKE_CRASH_DIR              host DiagnosticReports directory
#   IOS_SMOKE_EVIDENCE_DIR           where evidence files are written
#   IOS_SMOKE_SCREENSHOT_NAME        screenshot filename (default ios-home.png)
#   IOS_SMOKE_NAME                   evidence file prefix (matrix-safe)
#   IOS_SMOKE_BACKEND_PROBE          command that answers "is there a reachable
#                                    galleryd backend?". UNSET BY DEFAULT, and
#                                    that unset value is a FAILURE: without a
#                                    probe nothing establishes that the app
#                                    reaches a backend, and the gate refuses to
#                                    call the artifact healthy.
#   IOS_SMOKE_BACKEND_TIMEOUT_SECONDS backend probe deadline
#   IOS_SMOKE_LAUNCH_ARGUMENTS       extra `simctl launch` arguments. A debug
#                                    build accepts --private-gallery-desktop-url
#                                    and --private-gallery-bearer-token and then
#                                    talks to that daemon, which is what lets a
#                                    harness point the app at a real backend.
#                                    No value may contain whitespace.

set -euo pipefail

XCRUN="${IOS_SMOKE_XCRUN:-xcrun}"
BUNDLE_ID="${IOS_SMOKE_BUNDLE_ID:-com.privategallery.privateGalleryApp}"
NATIVE_BINARY="${IOS_SMOKE_NATIVE_BINARY:-Frameworks/race}"
EXPECTED_PLATFORM="${IOS_SMOKE_EXPECT_PLATFORM:-ios-simulator}"
SIM_RUNTIME="${IOS_SMOKE_SIM_RUNTIME:-}"
# `${VAR-default}`, NOT `${VAR:-default}`. The `:` form substitutes the default
# for an EMPTY value as well as an unset one, so `IOS_SMOKE_SIM_DEVICE=` -- an
# explicitly empty filter, which is what a mis-parameterised workflow step or an
# unset shell variable expands to -- silently became "match any device name"
# instead of reaching the emptiness check below. That made the check dead code
# and turned a typo in the runner configuration into a device chosen by accident.
SIM_DEVICE_PREFIX="${IOS_SMOKE_SIM_DEVICE-iPhone}"
BOOT_TIMEOUT_SECONDS="${IOS_SMOKE_BOOT_TIMEOUT_SECONDS:-900}"
LAUNCH_TIMEOUT_SECONDS="${IOS_SMOKE_LAUNCH_TIMEOUT_SECONDS:-120}"
RENDER_TIMEOUT_SECONDS="${IOS_SMOKE_RENDER_TIMEOUT_SECONDS:-180}"
MIN_DISTINCT_COLORS="${IOS_SMOKE_MIN_DISTINCT_COLORS:-32}"
# Unset by default. See `assert_backend_is_reachable`: this app has no working
# backend on iOS, so there is nothing that could legitimately be pointed at it
# today and the gate fails until an iOS-viable transport exists.
BACKEND_PROBE="${IOS_SMOKE_BACKEND_PROBE:-}"
BACKEND_TIMEOUT_SECONDS="${IOS_SMOKE_BACKEND_TIMEOUT_SECONDS:-60}"
# Extra arguments handed to `simctl launch`, so a harness can inject a paired
# session into a debug build (the app's AppDelegate reads
# --private-gallery-desktop-url / --private-gallery-bearer-token and serves the
# private_gallery/launch_invite channel). No value may contain whitespace: the
# gate splits on it. Empty by default, which launches the app bare.
LAUNCH_ARGUMENTS="${IOS_SMOKE_LAUNCH_ARGUMENTS:-}"
CRASH_DIR="${IOS_SMOKE_CRASH_DIR:-${HOME}/Library/Logs/DiagnosticReports}"
EVIDENCE_DIR="${IOS_SMOKE_EVIDENCE_DIR:-.}"
SMOKE_NAME="${IOS_SMOKE_NAME:-ios-smoke}"
SCREENSHOT_NAME="${IOS_SMOKE_SCREENSHOT_NAME:-ios-home.png}"
POLL_INTERVAL_SECONDS="${IOS_SMOKE_POLL_INTERVAL_SECONDS:-3}"
LOG_WINDOW_SECONDS="${IOS_SMOKE_LOG_WINDOW_SECONDS:-900}"

if [[ -z "${MIN_DISTINCT_COLORS}" || ! "${MIN_DISTINCT_COLORS}" =~ ^[0-9]+$ ]] || ((MIN_DISTINCT_COLORS < 2)); then
  # Refusing here rather than defaulting. A threshold of 0 or 1 would make the
  # "is this a blank screen" check incapable of failing, which is worse than no
  # check at all: it would read as render coverage while proving nothing.
  echo "ERROR: IOS_SMOKE_MIN_DISTINCT_COLORS must be an integer >= 2; got '${MIN_DISTINCT_COLORS}'" >&2
  exit 2
fi
if [[ -z "${SIM_DEVICE_PREFIX}" ]]; then
  echo "ERROR: IOS_SMOKE_SIM_DEVICE is set but empty; refusing to select any device" >&2
  exit 2
fi

SCREENSHOT_PATH=""
LOG_PATH=""
FAULT_LOG_PATH=""
LISTAPPS_PATH=""
CRASH_EVIDENCE_PATH=""
BUNDLE_REPORT_PATH=""
SUMMARY_PATH=""
BASELINE_CRASH_PATH=""
CRASH_REPORTS_DIR=""
SIM_UDID=""
SIM_NAME=""
SIM_RUNTIME_ID=""
SIM_RUNTIME_VERSION=""
LAUNCHED_PID=""
EXECUTABLE_NAME=""
LIMITS_PRINTED=0
BACKEND_EVIDENCE_PATH=""
# Set by `assert_backend_is_reachable` when it returns non-zero, so `main` can
# report the reason after writing the evidence file. Empty means "no reason
# recorded", which `main` never treats as success on its own.
BACKEND_REASON=""

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
  [[ "${2}" == *"${1}"* ]]
}

trim() {
  local value="$1"
  value="${value//$'\r'/}"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "${value}"
}



# `head -n 1` is avoided throughout: closing a pipe early can SIGPIPE the
# writer, which `set -o pipefail` would report as a failure. Bash string surgery
# is used instead so no pipeline depends on a reader closing early.
first_line() {
  local value="$1"
  printf '%s' "${value%%$'\n'*}"
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

# Runs a command with a wall-clock deadline.
#
# Needed because `set -euo pipefail` is worthless against a hang: every deadline
# in this script is either a poll loop (safe) or one of the few genuinely
# blocking external commands, and of those only `simctl bootstatus` can block
# indefinitely on a wedged CoreSimulator. macOS has no coreutils `timeout`, so
# this is the portable form.
#
# Kills only the direct child, not its descendants; a surviving grandchild is
# why the workflow also sets `timeout-minutes`. That is a documented residual,
# not a hidden one.
run_with_deadline() {
  local seconds="$1"
  shift
  local child killer rc=0 out
  out="$(scratch)"

  # The child's output goes to a FILE, not to this function's stdout.
  #
  # Callers read the result with a command substitution, which means the result
  # is a PIPE. A command that forks a grandchild leaves that grandchild holding
  # the write end of the pipe open, and command substitution does not return
  # until every writer has closed it. Killing the immediate child therefore did
  # NOT bound the wait: a probe that shelled out to `sleep 600` kept the pipe
  # open for the full 600s even after its parent was killed at the deadline, so
  # the deadline was unbounded in exactly the case it exists for -- a hung probe.
  # Collecting into a file first means only the direct child can hold us up, and
  # its exit is what `wait` reports.
  #
  # `set -m` puts the background job in its OWN process group, so the whole tree
  # is signalled with one negative pid. Best-effort: if the group signal is
  # refused, the direct child is signalled instead, which at least bounds the
  # child itself.
  set -m
  "$@" >"${out}" 2>&1 &
  child=$!
  set +m
  (
    sleep "${seconds}"
    kill -TERM -- "-${child}" 2>/dev/null ||
      kill -TERM "${child}" 2>/dev/null || true
  ) >/dev/null 2>&1 &
  killer=$!
  if wait "${child}"; then
    rc=0
  else
    rc=$?
  fi
  kill -TERM "${killer}" 2>/dev/null || true
  wait "${killer}" 2>/dev/null || true
  # Emitted only after `wait`, so the caller is never blocked on a live pipe.
  cat "${out}" 2>/dev/null || true
  return "${rc}"
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

# --- simctl plumbing --------------------------------------------------------
#
# Every wrapper here propagates the exit status. A simctl call that fails is an
# unanswered question, and a question with no answer must never be allowed to
# read as "nothing is wrong" -- that is the entire failure class this gate
# exists to prevent.

# Runs a simctl subcommand, sending stdout to <file> and stderr to <file>.err.
# Prints the captured stderr on failure so the diagnosis is in the run log.
simctl_to_file() {
  local file="$1"
  shift
  local rc=0
  if ! "${XCRUN}" simctl "$@" >"${file}" 2>"${file}.err"; then
    printf '[%s] xcrun simctl %s failed:' "${SMOKE_NAME}" "$*" >&2
    sed 's/^/    /' "${file}.err" >&2 || true
    return 1
  fi
  return 0
}

# Runs a simctl subcommand, prints stdout only, propagates the status. Used for
# probes whose answer is parsed (JSON, launch output); stderr is dropped so a
# service complaint can never be mistaken for a device's answer.
simctl_capture() {
  "${XCRUN}" simctl "$@" 2>/dev/null
}

# --- python helpers (stdlib only, so the runner needs no image tooling) ------

# Prints the value of a top-level string key from an XML or binary plist.
# Fail-closed: a plist it cannot read, or a key it cannot find, is an error the
# caller must turn into a failed run, not an empty string it will compare.
plist_value() {
  python3 - "$1" "$2" <<'PY'
import plistlib
import sys

path, key = sys.argv[1], sys.argv[2]
try:
    with open(path, "rb") as handle:
        plist = plistlib.load(handle)
except Exception as exc:  # noqa: BLE001 - the message is the assertion
    sys.exit(f"cannot read {path} as a property list: {exc}")
if not isinstance(plist, dict):
    sys.exit(f"{path} is not a dictionary property list")
if key not in plist:
    sys.exit(f"{path} has no {key}")
value = plist[key]
if not isinstance(value, str) or not value.strip():
    sys.exit(f"{path} has an empty or non-string {key}")
print(value.strip())
PY
}

# Prints one "<cpu>:<platform>" line per Mach-O slice in a binary.
#
# This is the load-bearing part of the structural check, so it reads the real
# load commands rather than guessing from the file name. `cputype` alone
# cannot tell a device slice from a simulator slice: both are CPU_TYPE_ARM64.
# The difference is the platform in LC_BUILD_VERSION (2 = iOS device,
# 7 = iOS simulator) or, for older binaries, which of the LC_VERSION_MIN_*
# commands is present at all (0x25 iPhoneOS vs 0x2B iPhoneSimulator).
macho_platforms() {
  python3 - "$1" <<'PY'
import struct
import sys

MH_MAGIC_64 = 0xFEEDFACF
MH_CIGAM_64 = 0xCFFAEDFE
FAT_MAGIC = 0xCAFEBABE
FAT_CIGAM = 0xBEBAFECA
FAT_MAGIC_64 = 0xCAFEBABF
FAT_CIGAM_64 = 0xBFBAFECA

CPU_NAMES = {
    7: "x86",
    0x01000007: "x86_64",
    12: "arm",
    0x0100000C: "arm64",
}

PLATFORMS = {
    1: "macos",
    2: "ios",
    3: "tvos",
    4: "watchos",
    5: "bridgeos",
    6: "maccatalyst",
    7: "ios-simulator",
    8: "tvos-simulator",
    9: "watchos-simulator",
}

# cmd -> implied platform, for pre-LC_BUILD_VERSION binaries.
VERSION_MIN_PLATFORMS = {
    0x25: "ios",
    0x2B: "ios-simulator",
    0x2C: "macos",
    0x2D: "tvos",
    0x2E: "watchos",
}

LC_BUILD_VERSION = 0x32

path = sys.argv[1]
with open(path, "rb") as handle:
    data = handle.read()
if len(data) < 8:
    sys.exit(f"{path} is too short to be a Mach-O file")

# big-endian reader over a little-endian-by-default file
def be32(buf, offset):
    return struct.unpack_from(">I", buf, offset)[0]

# A fat header is big-endian, so its magic reads as FAT_CIGAM/_64 through the
# little-endian reader. Both spellings are recognised explicitly rather than
# assumed: getting this wrong makes every real fat binary look like "not a
# Mach-O", which would fail the gate for a reason that has nothing to do with
# the artifact.
le_magic = struct.unpack_from("<I", data, 0)[0]
be_magic = struct.unpack_from(">I", data, 0)[0]
slices = []

if be_magic in (FAT_MAGIC, FAT_MAGIC_64):
    is64 = be_magic == FAT_MAGIC_64
    count = be32(data, 4)
    entry_size = 32 if is64 else 20
    for index in range(count):
        base = 8 + index * entry_size
        if base + entry_size > len(data):
            sys.exit(f"{path}: fat header is truncated at arch {index}")
        cputype = be32(data, base)
        if is64:
            offset = struct.unpack_from(">Q", data, base + 8)[0]
        else:
            offset = be32(data, base + 8)
        slices.append((cputype, offset))
elif le_magic == MH_MAGIC_64:
    slices.append((struct.unpack_from("<i", data, 4)[0], 0))
elif le_magic == MH_CIGAM_64 or be_magic == MH_MAGIC_64:
    sys.exit(f"{path} is a big-endian 64-bit Mach-O, which no Apple platform ships")
else:
    sys.exit(
        f"{path} is not a Mach-O binary (magic {le_magic:#x}); it may be a script, "
        "a symlink to nothing, or a truncated file"
    )

if not slices:
    sys.exit(f"{path} has no Mach-O slices")

for cputype, offset in slices:
    name = CPU_NAMES.get(cputype & 0xFFFFFFFF, f"cpu{cputype:#x}")
    header = offset
    if header + 32 > len(data):
        sys.exit(f"{path}: slice {name} header is truncated")
    magic_at = struct.unpack_from("<I", data, header)[0]
    if magic_at != MH_MAGIC_64:
        sys.exit(f"{path}: slice {name} is not a 64-bit Mach-O (magic {magic_at:#x})")
    ncmds = struct.unpack_from("<I", data, header + 16)[0]
    sizeofcmds = struct.unpack_from("<I", data, header + 20)[0]
    pos = header + 32
    end = pos + sizeofcmds
    if end > len(data):
        sys.exit(f"{path}: slice {name} load commands run past the end of the file")
    platforms = []
    for _ in range(ncmds):
        if pos + 8 > end:
            sys.exit(f"{path}: slice {name} has a truncated load command")
        cmd, cmdsize = struct.unpack_from("<II", data, pos)
        if cmdsize < 8 or pos + cmdsize > end:
            sys.exit(f"{path}: slice {name} has a malformed load command size {cmdsize}")
        if cmd == LC_BUILD_VERSION:
            if cmdsize < 24:
                sys.exit(f"{path}: slice {name} has a truncated LC_BUILD_VERSION")
            platform = struct.unpack_from("<I", data, pos + 8)[0]
            platforms.append(PLATFORMS.get(platform, f"platform{platform}"))
        elif cmd in VERSION_MIN_PLATFORMS:
            platforms.append(VERSION_MIN_PLATFORMS[cmd])
        pos += cmdsize
    if not platforms:
        # A Mach-O with no version/load command identifying its platform cannot
        # be shown to be a simulator binary, so it is reported as `unknown` and
        # the caller's requirement fails. Guessing here would be the false pass
        # this gate exists to prevent.
        platforms.append("unknown")
    for platform in sorted(set(platforms)):
        print(f"{name}:{platform}")
PY
}

# Prints the number of distinct colours in a PNG (early-exits above the
# caller's threshold). Decodes only what a screenshot produces: 8-bit,
# non-interlaced, greyscale / RGB / greyscale+alpha / RGBA.
png_distinct_colors() {
  python3 - "$1" "${2:-0}" <<'PY'
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

# Picks a simulator from `simctl list devices available --json` and prints
# "udid<TAB>name<TAB>runtime-id<TAB>os-version". Fails (non-zero) when nothing
# suitable exists, because "no device to test on" is not a pass.
#
# Selection order: available devices, iOS runtimes only, newest runtime first,
# then the newest runtime's devices in the order simctl reports them (which is
# the order the device types are declared in Xcode, so iPhones precede iPads).
# IOS_SMOKE_SIM_RUNTIME pins a specific runtime and IOS_SMOKE_SIM_DEVICE a
# device-name prefix; both are overrides for reproducibility, not gates.
pick_simulator() {
  python3 - "${1}" "${SIM_RUNTIME}" "${SIM_DEVICE_PREFIX}" <<'PY'
import json
import re
import sys

path, want_runtime, want_prefix = sys.argv[1], sys.argv[2], sys.argv[3]

try:
    with open(path, encoding="utf-8") as handle:
        listing = json.load(handle)
except Exception as exc:  # noqa: BLE001
    sys.exit(f"could not parse the simctl device list as JSON: {exc}")

devices = listing.get("devices")
if not isinstance(devices, dict) or not devices:
    sys.exit("the simctl device list has no `devices` object; nothing can be selected")

candidates = []
for runtime_id, entries in devices.items():
    if ".SimRuntime.iOS-" not in runtime_id:
        continue
    for entry in entries or []:
        if not isinstance(entry, dict):
            continue
        if entry.get("isAvailable") is False:
            continue
        if "unavailable" in str(entry.get("name", "")).lower():
            continue
        udid = str(entry.get("udid", "")).strip()
        name = str(entry.get("name", "")).strip()
        if not udid or not name:
            continue
        version = runtime_id.rsplit(".SimRuntime.iOS-", 1)[-1]
        candidates.append((version, name, udid, runtime_id))

if not candidates:
    sys.exit(
        "no available iOS simulator device was found. The macOS image must ship "
        "an iOS runtime and at least one device type; create one with "
        "`xcrun simctl create` and re-run. This is a gate failure, not a skip: "
        "there is no surface on which the artifact was proven."
    )


def version_key(value):
    # Split on '-' as well as '.'.
    #
    # CoreSimulator runtime identifiers are HYPHENATED: the keys in `simctl list
    # devices available --json` look like
    # "com.apple.CoreSimulator.SimRuntime.iOS-18-0", and the version substring
    # taken from one of those keys is "18-0", not "18.0". Splitting on '.' alone
    # therefore yields NO numeric parts for a real runtime, every candidate keys
    # to the empty tuple (), and `max()` returns the first candidate it was given
    # -- i.e. the "newest runtime wins" rule silently degraded to "whatever
    # order simctl happened to list". A suite fixture using dotted versions hid
    # this completely; the shape was corrected to the real hyphenated form so
    # the ordering is actually exercised.
    return tuple(int(part) for part in re.split(r"[.-]", value) if part.isdigit())


matching = [c for c in candidates if c[0] == want_runtime] if want_runtime else candidates
if not matching:
    available = sorted({c[0] for c in candidates}, key=version_key)
    sys.exit(
        f"no available iOS simulator for runtime {want_runtime!r}; "
        f"available runtime versions: {', '.join(available)}"
    )

newest = max(version_key(c[0]) for c in matching)
matching = [c for c in matching if version_key(c[0]) == newest]

named = [c for c in matching if c[1].startswith(want_prefix)]
chosen = (named or matching)[0]
version, name, udid, runtime_id = chosen
print(f"{udid}\t{name}\t{runtime_id}\t{version}")
PY
}

# Prints "<procName>\t<bundle-id-or-empty>" for an Apple crash report.
# Exits non-zero when the report cannot be parsed, because an unreadable crash
# report in the launch window cannot be cleared of suspicion.
crash_report_identity() {
  python3 - "$1" <<'PY'
import json
import sys

path = sys.argv[1]
try:
    with open(path, encoding="utf-8", errors="replace") as handle:
        first = handle.readline()
    header = json.loads(first)
except Exception as exc:  # noqa: BLE001
    sys.exit(f"could not parse the crash report header: {exc}")
if not isinstance(header, dict):
    sys.exit("crash report header is not a JSON object")

proc = header.get("procName") or header.get("app_name") or ""
proc = str(proc).strip()
if not proc:
    sys.exit("crash report header names no process")
bundle = ""
info = header.get("bundleInfo")
if isinstance(info, dict):
    bundle = str(info.get("CFBundleIdentifier") or info.get("CFBundleID") or "").strip()
print(f"{proc}\t{bundle}")
PY
}

# --- evidence ---------------------------------------------------------------

# One path policy, matching the Android gate: paths inside the workspace are
# recorded workspace-relative so evidence is comparable across runners, and
# absolute otherwise. Paths are never secrets; this is about comparability.
evidence_display_path() {
  local path="$1" workspace="${GITHUB_WORKSPACE:-}"
  if [[ -n "${workspace}" && "${path}" == "${workspace}/"* ]]; then
    printf '%s\n' "${path#"${workspace}/"}"
  else
    printf '%s\n' "${path}"
  fi
}

# --- the limitation banner --------------------------------------------------

# Printed on every run, pass or fail, and asserted by the test suite.
#
# The `trap` is the important half: a `set -e` exit from an unexpected place --
# a command failing outside `fail()` -- would otherwise skip the banner
# entirely, and the one run where a reader most needs the warning is the run
# that failed confusingly.
print_limitation() {
  if ((LIMITS_PRINTED != 0)); then
    return 0
  fi
  LIMITS_PRINTED=1
  cat >&2 <<'LIMITATION'

  ============================================================================
  !! THIS IS AN iOS **SIMULATOR** GATE. IT PROVES NOTHING ABOUT A DEVICE IPA. !!
  ============================================================================

  What a green run above established, and nothing more than this:
    an iOS *simulator* build installed on a booted iPhone Simulator, was
    cold-launched, held window focus, painted a stable visually-complex frame,
    and produced no crash report attributed to it.

  What it explicitly does NOT establish:
    * Nothing about the device archive the release job ships
      (`Runner.app` for the `iphoneos` SDK). The simulator bundle is a
      different binary: different SDK, and `aarch64-apple-ios-sim` /
      `x86_64-apple-ios` slices instead of `aarch64-apple-ios`. `simctl
      install` cannot accept an iPhoneOS bundle, so the device slice is
      untestable from here.
    * Nothing about a release build. Flutter only supports debug mode for
      simulators; `--simulator --release` is rejected by the tool. AOT,
      App.framework, signing flags and device-only plugins are untested.
    * Nothing about real hardware: no real camera, no real Photos library, no
      keychain under device lock, a different GPU/Metal path, and a far more
      permissive sandbox than a device enforces.
    * Nothing about App Store / TestFlight acceptance.
    * Nothing that the pixels came from the app's own UI rather than from the
      LaunchScreen storyboard, which is also complex and stable.
    * On its own, nothing about whether the product functions. The galleryd
      daemon copied into Frameworks/race is checked only for presence, the
      executable bit and its Mach-O slice. It is never run: iOS
      does not let an app exec a shipped executable, and this client refuses to
      try. local_daemon_launcher.dart returns attempted:false, started:false on
      every non-desktop platform.
      Install, launch and render are therefore NOT sufficient for a PASS. The
      gate additionally requires a backend probe (IOS_SMOKE_BACKEND_PROBE) that
      proves the app reached a host daemon the harness supplied; with it unset
      the gate exits non-zero even after a perfect render, which is the truthful
      verdict for an artifact nothing established a backend for.

  A device archive would additionally require an Apple Developer Program
  membership (paid), an Apple Distribution certificate in the runner keychain,
  a matching provisioning profile, `codesign --options runtime` of the bundle
  and its nested frameworks with the embedded profile, and -- for TestFlight or
  the App Store -- App Store Connect provisioning plus `xcrun notarytool`
  notarization and stapling validated by Apple. None of that exists on a free
  runner, and none of it is simulated here.

  ============================================================================

LIMITATION
}

# The banner is armed here and the trap that prints it is installed further
# down, where `shutdown_simulator` is also defined. See the comment there: a
# second `trap ... EXIT` silently REPLACES the first, so the two halves have to
# be installed together or the banner is lost on exactly the runs that need it.

# --- structural checks on the bundle ----------------------------------------

# Asserts a Mach-O carries the platform the simulator can execute.
#
# Fail-closed in every direction: unreadable, not-Mach-O, truncated, and
# "carries no platform-identifying load command" all fail. The last one matters
# most -- a binary we cannot classify is a binary we cannot claim is a
# simulator build.
#
# The result is appended to BUNDLE_REPORT_PATH when that is set, so the evidence
# file records what was actually parsed out of the headers rather than what this
# script claimed about them.
assert_macho_platform() {
  local path="$1" what="$2" platforms
  # `local -a unexpected` is declared up here rather than at its point of use
  # below, because `local` inside a function body after other commands is legal
  # but reads as if it were a statement rather than a declaration. Keeping every
  # declaration at the top is what lets shellcheck reason about the rest.
  local -a unexpected=()
  local line
  if ! platforms="$(macho_platforms "${path}" 2>&1)"; then
    [[ -n "${BUNDLE_REPORT_PATH}" ]] && printf '%s: UNREADABLE (%s)\n' "${what}" "${path}" >>"${BUNDLE_REPORT_PATH}"
    printf '%s\n' "${platforms}" >&2
    fail "${what}: could not read the Mach-O platform of ${path}"
  fi
  if [[ -n "${BUNDLE_REPORT_PATH}" ]]; then
    printf '%s: %s = %s\n' "${what}" "$(evidence_display_path "${path}")" \
      "$(paste -sd, <<<"${platforms}")" >>"${BUNDLE_REPORT_PATH}"
  fi
  # EVERY slice must be a simulator slice, not merely one of them.
  #
  # `grep -qxF "${EXPECTED_PLATFORM}"` -- "at least one slice matches" -- was the
  # original form and it was wrong. A fat binary carrying
  # {x86_64:ios-simulator, arm64:ios} contains a simulator slice, so that check
  # passed it, while the device slice would fail to load on the simulator and
  # the bundle would install and then die. Nothing downstream re-asserts the
  # per-slice platform, so a partial match would have been a false pass.
  #
  # `unknown` is rejected by the same comparison, which is intended: a slice the
  # reader cannot classify cannot be claimed to be a simulator slice.
  #
  # The two branches below are distinguished by whether ANY slice is a simulator
  # slice, so the count compared against is the number of SLICES. An earlier
  # version compared `${#unexpected[@]}` against `${#platforms}`, and `platforms`
  # is one newline-joined STRING, so `${#platforms}` is its length in CHARACTERS
  # ("arm64:ios" is 9, not 1). The comparison was therefore true only in a case
  # that cannot occur, and every device-slice binary was reported as "MIXED" --
  # telling a release reader that a bundle carrying a single device slice somehow
  # also carries a simulator one. The slice count is computed explicitly.
  local -a slices=()
  local total
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    slices+=("${line}")
    [[ "${line}" == *":${EXPECTED_PLATFORM}" ]] || unexpected+=("${line}")
  done <<<"${platforms}"
  total="${#slices[@]}"

  if ((${#unexpected[@]} > 0)); then
    printf '::error::%s (%s) carries [%s] but every slice must be [%s].\n' \
      "${what}" "${path}" "$(paste -sd, <<<"${platforms}")" "${EXPECTED_PLATFORM}" >&2
    if ((${#unexpected[@]} == total)); then
      fail "${what} is not a ${EXPECTED_PLATFORM} binary; the simulator only ever runs simulator slices, so a device-slice bundle installs nowhere but proves nothing here"
    fi
    fail "${what} is a MIXED binary: [$(paste -sd, <<<"${platforms}")]. The simulator can load the ${EXPECTED_PLATFORM} slice, but a slice carrying [$(IFS=,; echo "${unexpected[*]}")] cannot run there, so this bundle would install and then fail to launch. Every slice must be ${EXPECTED_PLATFORM}."
  fi
  log "${what}: $(paste -sd, <<<"${platforms}")"
}

# Checks the bundle's identity and that every executable in it is a simulator
# binary, before a simulator is touched.
#
# Order matters: a packaging regression should be reported as "wrong slice",
# not as a mysterious install failure fifteen minutes after the simulator boots.
assert_bundle_structure() {
  local app="$1" plist bundle_id executable exec_path native_path relative
  local -a optional=()
  plist="${app}/Info.plist"

  [[ -d "${app}" ]] || fail "not a directory: ${app}"
  [[ -f "${plist}" ]] || fail "the app bundle has no Info.plist: ${plist}"

  bundle_id="$(plist_value "${plist}" CFBundleIdentifier)" ||
    fail "cannot read CFBundleIdentifier from ${plist}"
  executable="$(plist_value "${plist}" CFBundleExecutable)" ||
    fail "cannot read CFBundleExecutable from ${plist}"

  if [[ "${bundle_id}" != "${BUNDLE_ID}" ]]; then
    fail "the bundle declares CFBundleIdentifier '${bundle_id}' but this gate is configured for '${BUNDLE_ID}'; refusing to prove the wrong artifact"
  fi

  exec_path="${app}/${executable}"
  [[ -f "${exec_path}" ]] || fail "the bundle's CFBundleExecutable is missing: ${exec_path}"
  [[ -x "${exec_path}" ]] || fail "the bundle's CFBundleExecutable is not executable: ${exec_path}"

  native_path="${app}/${NATIVE_BINARY}"
  [[ -f "${native_path}" ]] ||
    fail "the native daemon is missing from the bundle at ${NATIVE_BINARY} (${native_path}); the release job copies it there, so a missing entry means the packaging step did not do what it claims"
  [[ -x "${native_path}" ]] ||
    fail "the native daemon at ${NATIVE_BINARY} is not executable; the app cannot exec it"

  {
    printf 'bundle: %s\n' "$(evidence_display_path "${app}")"
    printf 'CFBundleIdentifier: %s\n' "${bundle_id}"
    printf 'CFBundleExecutable: %s\n' "${executable}"
    printf 'native binary: %s\n' "${NATIVE_BINARY}"
    printf 'expected platform: %s\n' "${EXPECTED_PLATFORM}"
    printf 'app executable sha256: %s\n' "$(sha256_of "${exec_path}")"
    printf 'native executable sha256: %s\n' "$(sha256_of "${native_path}")"
  } >"${BUNDLE_REPORT_PATH}"

  assert_macho_platform "${exec_path}" "the app executable"
  assert_macho_platform "${native_path}" "the native daemon"

  # The plugin frameworks are checked when present and skipped when absent: a
  # bundle legitimately has no Frameworks directory in some Flutter
  # configurations, but any framework binary that IS there must be a simulator
  # binary. Gating on presence would be a check that fails for reasons outside
  # the artifact's correctness; gating on a present file is not.
  optional=(
    "Frameworks/App.framework/App"
    "Frameworks/Flutter.framework/Flutter"
  )
  for relative in "${optional[@]}"; do
    if [[ -f "${app}/${relative}" ]]; then
      assert_macho_platform "${app}/${relative}" "framework ${relative}"
    else
      log "framework ${relative} not present in the bundle; not checked (and not required)"
    fi
  done

  EXECUTABLE_NAME="${executable}"
  log "bundle identity: ${bundle_id} (executable ${executable})"
}

# --- simulator selection, boot, install, launch -----------------------------

# The list is re-read on every poll, so `is_sim_booted` sees the live state
# rather than a value captured before the boot. The path is a scratch file
# allocated in `main`, not a literal here: an unset/empty path makes
# `simctl_to_file` fail its redirection on every call, `is_sim_booted` then
# answers "not booted" forever, and the gate fails at the boot deadline on a
# perfectly healthy simulator -- a false negative that looks exactly like a
# real one. `main` assigns it before anything calls this function.
#
# It starts empty rather than pointing at a real path, and `is_sim_booted`
# guards on it being set. That guard is load-bearing, not defensive noise: with
# an empty path every boot poll fails and the gate always dies at the boot
# deadline. `is_sim_booted` therefore returns "not booted" only because
# `main` has not run yet, which is the honest answer for a gate that has not
# selected a device.
DEVICE_LIST=""
device_list_is_allocated() {
  [[ -n "${DEVICE_LIST}" ]]
}
is_sim_booted() {
  local out
  device_list_is_allocated || return 1
  simctl_to_file "${DEVICE_LIST}" list devices available --json || return 1
  [[ -s "${DEVICE_LIST}" ]] || return 1
  out="$(python3 - "${DEVICE_LIST}" "${SIM_UDID}" <<'PY'
import json
import sys

path, udid = sys.argv[1], sys.argv[2]
try:
    with open(path, encoding="utf-8") as handle:
        listing = json.load(handle)
except Exception:  # noqa: BLE001 - a list that will not parse is not "Shutdown"
    sys.exit(1)
for entries in (listing.get("devices") or {}).values():
    for entry in entries or []:
        if isinstance(entry, dict) and entry.get("udid") == udid:
            if str(entry.get("state", "")) == "Booted":
                print("booted")
            sys.exit(0)
sys.exit(1)
PY
)" || return 1
  [[ "${out}" == "booted" ]]
}

select_simulator() {
  local list picked
  list="$(scratch)"
  simctl_to_file "${list}" list devices available --json ||
    fail "could not read the available simulator devices from xcrun; refusing to report an install+launch check that never ran"
  if ! picked="$(pick_simulator "${list}" 2>&1)"; then
    printf '%s\n' "${picked}" >&2
    fail "no usable iOS simulator could be selected"
  fi
  IFS=$'\t' read -r SIM_UDID SIM_NAME SIM_RUNTIME_ID SIM_RUNTIME_VERSION <<<"${picked}"
  [[ -n "${SIM_UDID}" && -n "${SIM_NAME}" && -n "${SIM_RUNTIME_VERSION}" ]] ||
    fail "simulator selection produced an incomplete record: '${picked}'"
  # The device list is polled on every boot poll, so it needs a real path. Allocated
  # here rather than in `is_sim_booted` because each call needs the same file: a
  # fresh mktemp per poll would litter the runner's TMPDIR with one file per
  # poll for the whole boot budget.
  DEVICE_LIST="$(scratch)"
  log "simulator: ${SIM_NAME} (${SIM_UDID}) on ${SIM_RUNTIME_ID}"
}

boot_simulator() {
  local out rc=0
  # `simctl boot` on an already-booted device is an error, not a no-op, so the
  # state is checked first. The whole boot is then confirmed from the device
  # list, which is a read we make repeatedly and can therefore trust.
  out="$(simctl_capture boot "${SIM_UDID}")" || rc=$?
  if ((rc != 0)); then
    log "simctl boot returned ${rc}; verifying actual state from the device list"
  fi
  wait_until "${SIM_NAME} to finish booting" "${BOOT_TIMEOUT_SECONDS}" is_sim_booted ||
    fail "the simulator never reached state Booted within ${BOOT_TIMEOUT_SECONDS}s"
  log "simulator booted: ${SIM_NAME}"
  # A second, independent confirmation that the runtime finished coming up
  # rather than merely being marked Booted. Under a deadline, because
  # CoreSimulator can wedge here and `set -e` cannot stop a hang.
  if ! run_with_deadline "${BOOT_TIMEOUT_SECONDS}" "${XCRUN}" simctl bootstatus "${SIM_UDID}"; then
    fail "simctl bootstatus did not complete for ${SIM_NAME} within ${BOOT_TIMEOUT_SECONDS}s"
  fi
}

# Is the app really registered with the simulator after the install?
#
# A second, independent, structural confirmation that the install did something:
# `get_app_container` exits non-zero when the bundle is not installed at all.
# This is deliberately a platform query rather than a look for an error string
# in the install output -- a bundle whose Info.plist is wrong, or whose
# executable cannot be loaded, can otherwise leave `simctl install` reporting
# something that reads like success.
app_is_registered() {
  local container
  container="$(simctl_capture get_app_container "${SIM_UDID}" "${BUNDLE_ID}")" || return 1
  [[ -n "${container}" ]] || return 1
  [[ -d "${container}" ]] || return 1
  return 0
}

# Installs the bundle, retrying once with `--no-verify` ONLY when the plain
# install failed for a code-signature reason.
#
# The simulator rejects some unsigned bundles and the release job builds
# `--no-codesign`, so a signature rejection is a real outcome here. The retry is
# narrowly scoped: it is reachable only from a signature-classified failure, its
# use is announced as a workflow warning, and it can only produce a clearer
# failure -- it never converts a failure into a pass on its own, because the
# retried install is judged by exactly the same two checks (exit status, then
# registration).
install_app() {
  local app="$1" output rc=0
  output="$("${XCRUN}" simctl install "${SIM_UDID}" "${app}" 2>&1)" || rc=$?
  if ((rc == 0)) && app_is_registered; then
    log "installed $(basename "${app}")"
    return 0
  fi
  if ((rc == 0)); then
    # Exit status said yes, the platform says the bundle is not installed. Both
    # readings are reported; trusting either one alone would be a guess.
    printf '%s\n' "simctl install exited 0 but ${BUNDLE_ID} is not installed on ${SIM_NAME}:" >&2
  else
    printf 'simctl install failed (exit %s):\n' "${rc}" >&2
  fi
  printf '%s\n' "${output}" >&2
  diagnose_install_failure "${output}"

  if ! install_looks_like_signature_failure "${output}"; then
    fail "the artifact is not installable on the simulator"
  fi

  printf '::warning::simctl install rejected the bundle as unsigned. Retrying once with --no-verify. This is the simulator refusing an un-signed bundle; it says nothing about the device archive, which needs a real Apple identity and a provisioning profile.\n'
  rc=0
  output="$("${XCRUN}" simctl install --no-verify "${SIM_UDID}" "${app}" 2>&1)" || rc=$?
  if ((rc == 0)) && app_is_registered; then
    log "installed with --no-verify (the bundle carries no usable signature)"
    return 0
  fi
  printf '%s\n' "the --no-verify install also failed (exit ${rc}):" >&2
  printf '%s\n' "${output}" >&2
  fail "the artifact is not installable on the simulator, with or without --no-verify"
}

install_looks_like_signature_failure() {
  local output="$1"
  contains "ApplicationVerificationFailed" "${output}" ||
    contains "code signature" "${output}" ||
    contains "code signing" "${output}" ||
    contains "not signed" "${output}" ||
    contains "unsigned" "${output}"
}

diagnose_install_failure() {
  local output="$1"
  if contains "No such file" "${output}" || contains "not a directory" "${output}"; then
    printf '%s\n' "The .app path could not be read. Check the build step produced a bundle at that path." >&2
  elif contains "Signature" "${output}" || contains "signature" "${output}"; then
    printf '%s\n' "The bundle's signature was rejected. The release job builds --no-codesign; on a real device this additionally needs an Apple Distribution certificate and a provisioning profile matching the bundle id and entitlements." >&2
  elif contains "Invalid bundle" "${output}" || contains "malformed" "${output}" ||
    contains "Info.plist" "${output}"; then
    printf '%s\n' "The bundle is malformed. Check Info.plist and the CFBundleExecutable it names." >&2
  elif contains "incompatible" "${output}" || contains "Incompatible" "${output}"; then
    printf '%s\n' "The bundle is not compatible with this simulator runtime. Check its minimum OS version and the architectures it carries." >&2
  elif contains "No devices are booted" "${output}"; then
    printf '%s\n' "No simulator was booted, so nothing could be installed. This is a boot problem, not an artifact problem." >&2
  else
    printf '%s\n' "See the raw simctl output above." >&2
  fi
}

# Is the app registered with the simulator's launchd?
#
# The launchd label for a UIKit app is `UIKitApplication:<bundle-id>[...]`, so
# the bundle id appearing in `launchctl list` is the platform's own record of a
# running app. A non-zero exit or an unreadable answer is reported as NOT
# running, which fails the gate -- the safe direction.
is_app_running() {
  local listing
  listing="$(simctl_capture spawn "${SIM_UDID}" launchctl list)" || return 1
  [[ -n "${listing}" ]] || return 1
  contains "${BUNDLE_ID}" "${listing}"
}

cold_launch() {
  local output rc=0 pid
  # Cold means cold: the app must not be running before the launch. A device
  # that was left with the app alive would turn this into a warm start, which
  # skips the code path most likely to be broken.
  if is_app_running; then
    fail "${BUNDLE_ID} is already running on ${SIM_NAME} before launch; this must be a cold launch"
  fi
  # Build the launch command as an array so empty LAUNCH_ARGUMENTS never expands
  # to a stray empty argument (and so `set -u` is happy). A harness uses this to
  # inject a debug session; see IOS_SMOKE_LAUNCH_ARGUMENTS.
  local -a launch_cmd=("${XCRUN}" simctl launch "${SIM_UDID}" "${BUNDLE_ID}")
  if [[ -n "${LAUNCH_ARGUMENTS}" ]]; then
    local -a launch_extra=()
    read -r -a launch_extra <<<"${LAUNCH_ARGUMENTS}"
    local arg
    for arg in "${launch_extra[@]}"; do
      [[ -n "${arg}" ]] && launch_cmd+=("${arg}")
    done
  fi
  output="$("${launch_cmd[@]}" 2>&1)" || rc=$?
  printf '%s\n' "${output}" >>"${SUMMARY_PATH}"
  if ((rc != 0)); then
    printf '%s\n' "${output}" >&2
    fail "simctl launch failed (exit ${rc})"
  fi
  # `simctl launch` prints "<bundle-id>: <pid>". The pid is parsed rather than
  # trusted, because a launch that reports no pid is a launch that was not
  # confirmed -- and the remaining process-alive check needs something to
  # attribute to.
  pid="$(trim "$(first_line "${output}" | sed 's/^[^:]*: *//')")"
  if [[ ! "${pid}" =~ ^[0-9]+$ ]] || ((pid <= 0)); then
    printf '%s\n' "${output}" >&2
    fail "simctl launch reported no usable pid; a launch that could not be confirmed is not a launch"
  fi
  LAUNCHED_PID="${pid}"
  log "launched ${BUNDLE_ID} as pid ${pid}"
}

# --- render -----------------------------------------------------------------

capture_screenshot() {
  local destination="$1"
  "${XCRUN}" simctl io "${SIM_UDID}" screenshot --type=png "${destination}" >/dev/null 2>&1 || return 1
  [[ -s "${destination}" ]] || return 1
  return 0
}

# How many consecutive polls the app may be missing from launchd before the
# render wait gives up. More than one, because a single unreadable launchd
# answer is exactly the "a read that failed, not a process that died" case this
# script refuses to confuse with a clean answer.
DEAD_POLL_TOLERANCE="${IOS_SMOKE_DEAD_POLL_TOLERANCE:-3}"
if [[ ! "${DEAD_POLL_TOLERANCE}" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: IOS_SMOKE_DEAD_POLL_TOLERANCE must be a positive integer; got '${DEAD_POLL_TOLERANCE}'" >&2
  exit 2
fi

# Wait for a settled frame.
#
# Three independent requirements, all of which must be able to fail:
#   1. the app is alive in launchd at the moment of capture;
#   2. the frame decodes and carries at least MIN_DISTINCT_COLORS distinct
#      colours, which rules out a solid blank screen and an undecodable
#      capture;
#   3. two consecutive captures are byte-identical, which rules out a screen
#      caught mid-transition while the engine is still starting.
#
# What it does NOT prove, and must not be claimed: that the pixels came from
# the app's own UI rather than from the LaunchScreen storyboard. A launch
# storyboard satisfies all three conditions. Separating them needs an
# accessibility/automation surface this gate does not have, and a heuristic
# loose enough to catch one would be wrong in the permissive direction -- the
# same false pass the gate exists to prevent.
await_settled_frame() {
  local deadline=$((SECONDS + RENDER_TIMEOUT_SECONDS))
  local colors=-1 current="" previous="" stable=0 absent=0

  while ((SECONDS < deadline)); do
    if ! is_app_running; then
      absent=$((absent + 1))
      log "${BUNDLE_ID} is not running (${absent}/${DEAD_POLL_TOLERANCE} consecutive polls)"
      if ((absent >= DEAD_POLL_TOLERANCE)); then
        fail "${BUNDLE_ID} died while rendering; it was alive at launch and is gone ${absent} polls later"
      fi
      previous=""
      stable=0
      sleep "${POLL_INTERVAL_SECONDS}"
      continue
    fi
    absent=0
    if capture_screenshot "${SCREENSHOT_PATH}"; then
      if colors="$(png_distinct_colors "${SCREENSHOT_PATH}" "${MIN_DISTINCT_COLORS}" 2>/dev/null)"; then
        if [[ "${colors}" =~ ^[0-9]+$ ]] && ((colors >= MIN_DISTINCT_COLORS)); then
          current="$(sha256_of "${SCREENSHOT_PATH}")"
          if [[ -n "${current}" && "${current}" == "${previous}" ]]; then
            stable=$((stable + 1))
          else
            stable=0
          fi
          if ((stable >= 1)); then
            log "settled frame: ${colors}+ distinct colours, identical across two consecutive captures"
            return 0
          fi
          previous="${current}"
        else
          log "frame is not yet visually complex (${colors} distinct colours); retrying"
          previous=""
          stable=0
        fi
      else
        log "screenshot could not be decoded yet; retrying"
        previous=""
        stable=0
      fi
    else
      log "screenshot could not be captured yet; retrying"
      previous=""
      stable=0
    fi
    sleep "${POLL_INTERVAL_SECONDS}"
  done
  return 1
}

# --- crash detection --------------------------------------------------------

# The host writes simulator crash reports to the user's DiagnosticReports
# directory. Listing that directory before and after the launch is what makes
# the comparison meaningful; without a baseline a pre-existing report on the
# runner would fail every build.
crash_report_listing() {
  local destination="$1"
  if [[ ! -d "${CRASH_DIR}" ]]; then
    return 1
  fi
  find "${CRASH_DIR}" -maxdepth 1 -type f \
    \( -name '*.ips' -o -name '*.crash' -o -name '*.diag' \) -print 2>/dev/null |
    LC_ALL=C sort >"${destination}"
  return 0
}

capture_crash_baseline() {
  if ! crash_report_listing "${BASELINE_CRASH_PATH}"; then
    printf '::error::the macOS crash-report directory %s does not exist, so no crash check can be run at all. Refusing to report a crash check that never ran.\n' \
      "${CRASH_DIR}" >&2
    return 1
  fi
  log "crash-report baseline: $(wc -l <"${BASELINE_CRASH_PATH}" | tr -d ' ') existing report(s) in ${CRASH_DIR}"
}

# Fails the run on any crash report that appeared during the launch window and
# is attributable to the app, or that cannot be attributed at all.
#
# A report this gate cannot parse is a failure, not a pass: the question "did
# our app crash?" and the answer "I could not read the evidence" are different
# answers, and only one of them is safe to publish.
assert_no_new_crash_reports() {
  local after new_file details identity proc bundle attributed=0 unparsed=0 unrelated=0
  after="$(scratch)"
  if ! crash_report_listing "${after}"; then
    fail "the macOS crash-report directory ${CRASH_DIR} disappeared during the run; refusing to report a crash check that never ran"
  fi
  new_file="$(scratch)"
  comm -13 "${BASELINE_CRASH_PATH}" "${after}" >"${new_file}"

  # The per-report detail is accumulated in a scratch file and the evidence file
  # is written ONCE, at the end, with the counters in its header.
  #
  # The previous version wrote the counts as a header first and then appended
  # the counters to the END of the file -- but only on the branch where a new
  # report existed. So a clean run produced an evidence file that simply did not
  # mention the attribution count at all, and "0 crashes" had to be inferred from
  # a line's absence. That is the same failure shape as the Android gate reading
  # an empty crash buffer as clean: the reader cannot tell "zero" from "not
  # measured". The counts are now always written, so zero is stated.
  details="$(scratch)"
  while IFS= read -r report; do
    [[ -n "${report}" ]] || continue
    if ! identity="$(crash_report_identity "${report}" 2>&1)"; then
      printf '%s\n' "${identity}" >&2
      cp "${report}" "${CRASH_REPORTS_DIR}/" 2>/dev/null || true
      unparsed=$((unparsed + 1))
      {
        printf 'new crash report: %s\n' "${report}"
        printf '  identity: COULD NOT BE PARSED (%s)\n' "${identity}"
        printf -- '---\n'
        cat "${report}"
        printf -- '---\n'
      } >>"${details}"
      continue
    fi
    IFS=$'\t' read -r proc bundle <<<"${identity}"
    {
      printf 'new crash report: %s\n' "${report}"
      printf '  procName: %s\n' "${proc}"
      printf '  bundle: %s\n' "${bundle:-unknown}"
      printf -- '---\n'
      cat "${report}"
      printf -- '---\n'
    } >>"${details}"
    cp "${report}" "${CRASH_REPORTS_DIR}/" 2>/dev/null || true
    if [[ "${proc}" == "${EXECUTABLE_NAME}" || "${bundle}" == "${BUNDLE_ID}" ]]; then
      attributed=$((attributed + 1))
    else
      unrelated=$((unrelated + 1))
    fi
  done <"${new_file}"

  {
    printf 'crash report directory: %s\n' "${CRASH_DIR}"
    printf 'pre-launch reports: %s\n' "$(wc -l <"${BASELINE_CRASH_PATH}" | tr -d ' ')"
    printf 'reports present at the end: %s\n' "$(wc -l <"${after}" | tr -d ' ')"
    printf 'new reports during the launch window: %s\n' "$(wc -l <"${new_file}" | tr -d ' ')"
    printf 'attributed to %s: %s\n' "${BUNDLE_ID}" "${attributed}"
    printf 'unattributable: %s\n' "${unparsed}"
    printf 'unrelated runner processes: %s\n' "${unrelated}"
    if [[ -s "${details}" ]]; then
      printf -- '--- per-report detail ---\n'
      cat "${details}"
    fi
  } >"${CRASH_EVIDENCE_PATH}"

  if [[ ! -s "${new_file}" ]]; then
    log "crash reports clean (no new report appeared during the launch window)"
    return 0
  fi

  if ((attributed > 0)); then
    fail "the simulator wrote ${attributed} crash report(s) for ${BUNDLE_ID} during the launch window; see ${CRASH_EVIDENCE_PATH}"
  fi
  if ((unparsed > 0)); then
    fail "the simulator wrote ${unparsed} crash report(s) during the launch window that this gate could not attribute; an unreadable crash report cannot be cleared of suspicion, so this is treated as a crash"
  fi
  if ((unrelated > 0)); then
    printf '::warning::%s crash report(s) from unrelated runner processes appeared during the launch window; they are listed in the evidence and were not attributed to %s.\n' \
      "${unrelated}" "${BUNDLE_ID}"
  fi
  log "crash reports clean (${unrelated} unrelated report(s) on the runner, none from the app)"
}

# --- logs and summary -------------------------------------------------------

# Best-effort by design: this is evidence, not a gate. There is deliberately no
# substring matching of log text anywhere in this script -- an app whose daemon
# resolves paths and opens its index logs "not found" and "path not found" as
# ordinary text, and a check that greps for error words is how the Android gate
# was once made to report an adverse exit as clean. Crash detection reads the
# platform's own crash reports, never the log text.
collect_logs() {
  local predicate
  predicate="process == \"${EXECUTABLE_NAME}\""
  if ! simctl_to_file "${LOG_PATH}" spawn "${SIM_UDID}" log show --style compact \
    --last "${LOG_WINDOW_SECONDS}s" --predicate "${predicate}"; then
    printf '::warning::could not collect the app log stream (see %s.err); the log is evidence only and the gate does not depend on it\n' \
      "${LOG_PATH}" >&2
  else
    log "collected the app log stream to ${LOG_PATH}"
  fi
  if ! simctl_to_file "${FAULT_LOG_PATH}" spawn "${SIM_UDID}" log show --style compact \
    --last "${LOG_WINDOW_SECONDS}s" \
    --predicate 'messageType == error OR messageType == fault'; then
    printf '::warning::could not collect the simulator error/fault log (see %s.err); evidence only\n' \
      "${FAULT_LOG_PATH}" >&2
  fi
  simctl_to_file "${LISTAPPS_PATH}" listapps "${SIM_UDID}" ||
    printf '::warning::could not list the installed apps; evidence only\n' >&2
}

# Can this artifact actually DO anything?
#
# Everything above this point proves the bundle installs, cold-launches, paints a
# settled frame and does not crash. All four of those are also true of a UI shell
# with no working backend behind it, and this one is.
#
# The backend is the Rust daemon at ${NATIVE_BINARY}. It is copied into the
# bundle by the release job, and it is the only thing that serves the library:
# the client is a thin shell over `galleryd`'s HTTP API. Two independent facts
# make that daemon unreachable on iOS, and this gate asserts BOTH rather than
# warning about them:
#
#   1. iOS does not permit an app to spawn an arbitrary executable. A Mach-O
#      carrying `aarch64-apple-ios-simulator` can be LOADED and its slices can be
#      verified, which is exactly why the structural checks above pass; that is
#      not the same as being EXECUTABLE as a child process.
#   2. app/lib/src/services/local_daemon_launcher.dart:24-32 returns
#      attempted:false, started:false unless Platform.isLinux || isMacOS ||
#      isWindows, so the client never even attempts the spawn.
#
# A green run of everything above therefore proves the app shell launches and
# paints -- not that the product works. Reporting that as "the iOS artifact is
# healthy" would be the false pass this gate exists to prevent, so the run FAILS
# here with the true reason and names both facts.
#
# IOS_SMOKE_BACKEND_PROBE names a command that answers "is there a reachable
# galleryd backend?". It is a hook for the future in which the client is fixed to
# use an iOS-viable transport (an embedded library, a remote host the user
# configures, or a companion app). Until such a probe exists and succeeds, this
# gate fails. That is the honest outcome; it is not a missing check, it is a
# failing check.
#
# The probe is deliberately fail-closed in BOTH directions: a probe that is
# unset, missing, non-executable, times out, exits non-zero, or prints nothing
# all fail. A probe that merely exists is not evidence of a backend.
# Returns non-zero and sets BACKEND_REASON rather than calling `fail` itself, so
# that `main` can write the evidence file with the correct verdict BEFORE it
# exits. Calling `fail` in here meant the summary was written twice on a passing
# run -- once as RENDER-ONLY and once as PASS -- leaving two contradictory
# `result:` lines in one evidence file, and a reader could not tell which was
# the verdict.
assert_backend_is_reachable() {
  local probe="${BACKEND_PROBE}" out rc=0
  BACKEND_REASON=""

  {
    printf -- '--- backend reachability ---\n'
    if [[ -z "${probe}" ]]; then
      printf 'probe: NONE CONFIGURED\n'
    elif [[ ! -x "${probe}" ]]; then
      printf 'probe: %s (not executable)\n' "${probe}"
    else
      printf 'probe: %s\n' "${probe}"
    fi
    printf 'daemon at %s: present, executable, and carries a simulator slice\n' "${NATIVE_BINARY}"
    printf 'what that establishes: the Mach-O can be LOADED by the loader.\n'
    printf 'It does NOT establish that it can be SPAWNED as a child process.\n'
    printf 'iOS forbids that, and local_daemon_launcher.dart refuses to try on a\n'
    printf 'non-desktop platform. A host daemon is reached only when the launch\n'
    printf 'injected a session (IOS_SMOKE_LAUNCH_ARGUMENTS) and the probe proved\n'
    printf 'the app used it.\n'
  } >>"${BACKEND_EVIDENCE_PATH}"

  if [[ -z "${probe}" ]]; then
    BACKEND_REASON="the artifact cannot be shown to reach a backend: IOS_SMOKE_BACKEND_PROBE is unset, so no probe could answer. iOS forbids the app from spawning galleryd, so a backend must be provided by the harness (IOS_SMOKE_LAUNCH_ARGUMENTS points a debug build at it) and a probe must prove the app reached it. Install+launch+render passed; usefulness did not."
    return 1
  fi
  if [[ ! -x "${probe}" ]]; then
    BACKEND_REASON="the backend probe is not executable: ${probe}. An unrunnable probe cannot establish that the artifact reaches a backend, so this gate fails rather than assuming it does."
    return 1
  fi
  if ! out="$(run_with_deadline "${BACKEND_TIMEOUT_SECONDS}" "${probe}" 2>&1)"; then
    rc=$?
    {
      printf 'probe exit status: %s\n' "${rc}"
      printf 'probe output: %s\n' "${out}"
    } >>"${BACKEND_EVIDENCE_PATH}"
    BACKEND_REASON="the backend probe did not succeed (exit ${rc} after ${BACKEND_TIMEOUT_SECONDS}s): ${out}. The artifact installed and rendered, but nothing established that it can reach a backend."
    return 1
  fi
  if [[ -z "${out//[[:space:]]/}" ]]; then
    printf 'probe exit status: 0\nprobe output: (empty)\n' >>"${BACKEND_EVIDENCE_PATH}"
    BACKEND_REASON="the backend probe exited 0 but printed nothing. An empty answer is the answer to no question, so it is treated as a failure rather than as a reachable backend."
    return 1
  fi
  {
    printf 'probe exit status: 0\n'
    printf 'probe output: %s\n' "${out}"
  } >>"${BACKEND_EVIDENCE_PATH}"
  log "backend probe reported: ${out}"
}

# record_summary <PASS-or-verdict> <app-bundle-path>
#
# Both arguments are required and the app path is NOT defaulted: an earlier
# version of this script read the bundle path out of $1 alongside the verdict,
# so a call of `record_summary PASS` recorded `app bundle: PASS` -- an evidence
# file that named the wrong artifact while looking completely well-formed. The
# second parameter is positional and mandatory so that mistake cannot be made
# again silently.
record_summary() {
  local verdict="$1" app="$2"
  [[ -n "${app}" ]] || fail "record_summary called without the app bundle path"
  {
    printf 'result: %s\n' "${verdict}"
    printf 'app bundle: %s\n' "$(evidence_display_path "${app}")"
    printf 'CFBundleIdentifier: %s\n' "${BUNDLE_ID}"
    printf 'CFBundleExecutable: %s\n' "${EXECUTABLE_NAME}"
    printf 'expected Mach-O platform: %s\n' "${EXPECTED_PLATFORM}"
    printf 'simulator: %s (%s)\n' "${SIM_NAME}" "${SIM_UDID}"
    printf 'simulator runtime: %s\n' "${SIM_RUNTIME_VERSION}"
    printf 'launched pid: %s\n' "${LAUNCHED_PID:-none}"
    printf 'screenshot: %s\n' "$(evidence_display_path "${SCREENSHOT_PATH}")"
    printf 'crash report directory: %s\n' "${CRASH_DIR}"
    printf 'SCOPE: iOS SIMULATOR ONLY. This run proves nothing about the device\n'
    printf 'SCOPE: archive (aarch64-apple-ios), real-device installability, a\n'
    printf 'SCOPE: release/AOT build, or App Store / TestFlight acceptance.\n'
    printf 'SCOPE: THIS APP HAS NO WORKING BACKEND ON iOS. The galleryd daemon at\n'
    printf 'SCOPE: %s was checked for presence, the executable bit and its\n' "${NATIVE_BINARY}"
    printf 'SCOPE: Mach-O slice, and that is all. iOS does not let an app exec a\n'
    printf 'SCOPE: shipped executable, and local_daemon_launcher.dart refuses to try\n'
    printf 'SCOPE: on any non-desktop platform. A green run proves the UI shell\n'
    printf 'SCOPE: launches and paints, NOT that the product works on iOS.\n'
  } >>"${SUMMARY_PATH}"
  cat "${SUMMARY_PATH}"
}

# --- shutdown ---------------------------------------------------------------

# Best effort. The runner is ephemeral, so this is hygiene, not a gate -- but a
# booted simulator left running would make the next step in the same job slower
# and would keep a GPU process alive.
shutdown_simulator() {
  if [[ -n "${SIM_UDID}" ]]; then
    "${XCRUN}" simctl shutdown "${SIM_UDID}" >/dev/null 2>&1 || true
  fi
}

# Scratch files made with `scratch` are removed here rather than at each call
# site. A `fail` in the middle of a phase would otherwise leave temp files in
# the runner's TMPDIR for the rest of the job; harmless, but it makes a failed
# run harder to read and it grows without bound if the gate is run repeatedly.
SCRATCH_FILES=()
scratch() {
  local path
  path="$(mktemp)"
  SCRATCH_FILES+=("${path}")
  printf '%s' "${path}"
}

on_exit() {
  shutdown_simulator
  if ((${#SCRATCH_FILES[@]} > 0)); then
    rm -f "${SCRATCH_FILES[@]}" 2>/dev/null || true
  fi
  print_limitation
}

# One EXIT trap, not two. A second `trap ... EXIT` would REPLACE the first, and
# the one it would replace is the limitation banner -- so the warning would
# disappear on exactly the runs that need it most.
trap on_exit EXIT

# --- main -------------------------------------------------------------------

main() {
  local app="${1:-}" backend_rc=0
  if [[ -z "${app}" ]]; then
    echo "usage: $(basename "$0") <path-to-Runner.app>" >&2
    exit 2
  fi
  [[ -d "${app}" ]] || fail "app bundle not found: ${app}"

  require_tool "${XCRUN}"
  require_tool python3

  mkdir -p "${EVIDENCE_DIR}"
  CRASH_REPORTS_DIR="${EVIDENCE_DIR}/${SMOKE_NAME}-crash-reports"
  mkdir -p "${CRASH_REPORTS_DIR}"
  SCREENSHOT_PATH="${EVIDENCE_DIR}/${SCREENSHOT_NAME}"
  LOG_PATH="${EVIDENCE_DIR}/${SMOKE_NAME}-log.txt"
  FAULT_LOG_PATH="${EVIDENCE_DIR}/${SMOKE_NAME}-error-log.txt"
  LISTAPPS_PATH="${EVIDENCE_DIR}/${SMOKE_NAME}-listapps.txt"
  CRASH_EVIDENCE_PATH="${EVIDENCE_DIR}/${SMOKE_NAME}-crash-reports.txt"
  SUMMARY_PATH="${EVIDENCE_DIR}/${SMOKE_NAME}-summary.txt"
  BASELINE_CRASH_PATH="${EVIDENCE_DIR}/${SMOKE_NAME}-crash-baseline.txt"
  BUNDLE_REPORT_PATH="${EVIDENCE_DIR}/${SMOKE_NAME}-bundle.txt"
  BACKEND_EVIDENCE_PATH="${EVIDENCE_DIR}/${SMOKE_NAME}-backend.txt"
  : >"${SUMMARY_PATH}"

  # Everything structural first, so a packaging regression is reported as a
  # wrong slice rather than as a mysterious install failure much later.
  assert_bundle_structure "${app}"

  if ! capture_crash_baseline; then
    fail "the crash-report baseline could not be taken; refusing to report a crash check that never ran"
  fi

  select_simulator
  boot_simulator
  install_app "${app}"
  cold_launch

  wait_until "${BUNDLE_ID} to appear in launchd" "${LAUNCH_TIMEOUT_SECONDS}" is_app_running ||
    fail "${BUNDLE_ID} is not running ${LAUNCH_TIMEOUT_SECONDS}s after launch (crash on start, or it was never really launched)"

  if ! await_settled_frame; then
    collect_logs
    fail "no settled app frame within ${RENDER_TIMEOUT_SECONDS}s (a blank, LaunchScreen-only or never-settling screen is a failure)"
  fi

  # Re-asserted after the render, not only before it: an app that survives launch,
  # paints a frame and then dies would otherwise pass on its earlier checks.
  is_app_running || fail "${BUNDLE_ID} died while rendering"

  assert_no_new_crash_reports
  collect_logs

  log "the simulator build installed, cold-launched, rendered and did not crash on ${SIM_NAME}"
  log "evidence: ${EVIDENCE_DIR} (screenshot ${SCREENSHOT_NAME}, log, crash reports, bundle report, summary)"

  # Everything above is "the app launches and paints". Whether it can DO anything
  # is a separate question, and on this artifact the answer is currently no.
  #
  # The verdict is computed FIRST and the summary written ONCE, so an evidence
  # file never contains two `result:` lines that disagree. A failing run still
  # leaves the evidence a human needs: the summary and the backend report are
  # both written before the non-zero exit below.
  #
  # Not `if ! assert_backend_is_reachable; then fail; fi` -- that would make the
  # backend question a soft check, which is precisely the v0.1.7 partial-release
  # shape this gate exists to prevent.
  backend_rc=0
  assert_backend_is_reachable || backend_rc=$?
  cat "${BUNDLE_REPORT_PATH}" >>"${SUMMARY_PATH}"
  if ((backend_rc != 0)); then
    record_summary "RENDER-ONLY (backend unproven)" "${app}"
    fail "${BACKEND_REASON}"
  fi

  record_summary PASS "${app}"
  log "PASS: the artifact installed, cold-launched, rendered, and reached a backend"
  print_limitation
}

main "$@"
