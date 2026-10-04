#!/usr/bin/env bash
#
# Tests for scripts/ios_release_artifact_smoke.sh -- the iOS half of the
# release artifact gate (issue #98).
#
# The gate decides whether an iOS artifact users cannot install reaches a
# release, so it cannot be an untested blob of shell. A fake `xcrun` stands in
# for CoreSimulator and every failure mode the gate is supposed to detect is
# injected and asserted here.
#
# ============================ WHAT THIS SUITE CANNOT DO ============================
#
# This suite runs on Linux CI. It tests the gate's LOGIC, against synthetic
# fixtures and a fake `xcrun`. It does NOT test iOS, and a green run here is
# NOT evidence that the gate works on macOS. Specifically, never executed here:
#
#   * `xcrun`, `simctl`, `xcodebuild`, `codesign`, `notarytool`, `ditto`,
#     `simctl io ... screenshot`, `simctl spawn ... log show`.
#   * Any real iOS Simulator: boot, install, launch, render, crash reports.
#   * Any real Mach-O produced by a real Apple toolchain. The fixtures are
#     hand-built byte sequences (see make_macho) with correct magic numbers and
#     LC_BUILD_VERSION commands but no real code, no dyld, no code signature.
#   * Flutter's own `flutter build ios --simulator`.
#
# What a green run here DOES establish: that the gate's decision logic takes
# the right branch for every failure mode below, and that its Mach-O reader,
# PNG complexity decoder, plist reader and simulator selector compute the
# right answers. The first time this gate runs for real is the first macOS
# runner, and that run is genuinely unproven until then.
#
# ============================ MUTATION TESTING ============================
#
# The assertions in this file are themselves the thing that would catch a
# regression in the gate, so they need to be shown to bite. That is done by
# scripts/tests/ios_release_artifact_mutation_test.sh, which mutates a COPY of
# the gate and requires the named assertion here to go red.
#
# The mutation harness is a SEPARATE file on purpose. An earlier version of
# this suite carried its own `mutate()` function which depended on an
# `IOS_SMOKE_GATE_OVERRIDE`/`SCRIPT_OVERRIDE` pair of environment variables
# that the gate does not read. Every mutation therefore ran the *unmutated*
# gate, and the function reported that fact correctly -- but a reader skimming
# a mutation section inside the suite would have seen a section that existed
# and never bitten anything. Splitting it out means the harness cannot silently
# depend on a knob the gate lacks: it has to mutate a real file on disk.
#
# A suite that cannot run an assertion says so. These suites print the marker
# below when python3 is missing -- python3 builds this suite's Mach-O, plist and
# PNG fixtures AND is the gate's own decoder for all three, so without it the
# suite would be running against fixtures it never built. The release-gate
# runner greps the whole log for this marker and turns it red, so a degraded
# suite cannot read as a pass.

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="${ROOT_DIR}/scripts/ios_release_artifact_smoke.sh"
WORK_DIR="$(mktemp -d)"
PASS_COUNT=0
FAIL_COUNT=0
ASSERTION_COUNT=0
OUT="${WORK_DIR}/out"

cleanup() {
  rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

# gate_errors <log-file>
#
# The gate prints its verdict on one line prefixed `ERROR:`, and that line is the
# only thing a reader needs. Failure messages used to show a 240-character prefix
# of the run instead, which on a successful run is all bundle-report lines and
# contains no verdict at all -- so a red assertion here could not be diagnosed
# without re-running the gate by hand. Empty output means the run printed no
# ERROR line, which is itself worth seeing.
gate_errors() {
  local found
  found="$(grep -a 'ERROR:' "$1" 2>/dev/null | head -3 | sed 's/^[[:space:]]*//')"
  if [[ -z "${found}" ]]; then
    printf '(no ERROR line was printed; last output: %s)' \
      "$(tail -2 "$1" 2>/dev/null | tr '\n' '|' | cut -c1-160)"
  else
    printf '%s' "${found}" | tr '\n' '|'
  fi
}

ok() {
  PASS_COUNT=$((PASS_COUNT + 1))
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
  printf '  ok   %s\n' "$1"
}

bad() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  ASSERTION_COUNT=$((ASSERTION_COUNT + 1))
  printf '  FAIL %s\n' "$1" >&2
  if [[ -n "${2:-}" ]]; then
    printf '%s\n' "$2" | sed 's/^/        /' >&2
  fi
}

# Assertions that must be TRUE for the suite's own fixtures and fake to be
# meaningful. If one of these is red, every behavioural assertion below it is
# suspect, so they are reported rather than skipped.
meta_failure() {
  bad "$1" "${2:-}"
}

DEGRADED_MARKER='RELEASE_GATE_SUITE_DEGRADED:'

if [[ ! -f "${SCRIPT}" ]]; then
  printf '  FAIL the gate script exists\n' >&2
  printf '  !! %s no gate at %s\n' "${DEGRADED_MARKER}" "${SCRIPT}" >&2
  printf '  !! These assertions did NOT run; do not read this suite as a pass.\n'
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  printf '  SKIP %s\n' "the Mach-O/plist/PNG fixtures and the gate's three decoders all need python3"
  printf '  !! %s no python3 on PATH\n' "${DEGRADED_MARKER}" >&2
  printf '  !! These assertions did NOT run; do not read this suite as a pass.\n'
  exit 0
fi

BUNDLE_ID="com.privategallery.privateGalleryApp"
SIM_UDID="AAAAAAAA-1111-2222-3333-444444444444"
SIM_NAME="iPhone 16 Pro"
SIM_RUNTIME_ID="com.apple.CoreSimulator.SimRuntime.iOS-18-0"

# --- fake xcrun -------------------------------------------------------------

SCENARIO="${WORK_DIR}/scenario.env"
BASE_SCENARIO="${WORK_DIR}/scenario.base.env"
CRASH_DIR="${WORK_DIR}/DiagnosticReports"

# The fake is driven by a declarative KEY=VALUE scenario file, so every case is a
# scenario and none of them is a knob the gate would have to grow.
install_fake_xcrun() {
  cat >"${WORK_DIR}/xcrun" <<'FAKE_XCRUN'
#!/usr/bin/env bash
# Stands in for xcrun. Every verb the gate uses is implemented; anything else
# exits non-zero, so a gate change that reaches for an unmodelled verb fails
# loudly instead of silently reading as a clean device.
set -uo pipefail

state_dir() {
  printf '%s' "${FAKE_XCRUN_STATE:-/tmp}"
}

scenario_value() {
  local key="$1" line
  [[ -f "${FAKE_XCRUN_SCENARIO}" ]] || return 1
  while IFS= read -r line; do
    if [[ "${line}" == "${key}="* ]]; then
      printf '%s' "${line#*=}"
      return 0
    fi
  done <"${FAKE_XCRUN_SCENARIO}"
  return 1
}

value_or() {
  scenario_value "$1" || printf '%s' "${2:-}"
}

# Models a machine that cannot answer. A dead xcrun returns empty stdout and a
# non-zero status, which is exactly what a real failure looks like. This is the
# case that must never read as "clean", because every gate in the script either
# parses a string or compares against an empty one.
xcrun_should_fail() {
  local key="$1" needle="$2" list pattern
  list="$(scenario_value "${key}" 2>/dev/null || printf '')"
  [[ -n "${list}" ]] || return 1
  local IFS=';'
  # The split on ';' is the point: patterns contain spaces ("list devices").
  for pattern in ${list}; do
    [[ -n "${pattern}" ]] || continue
    if [[ "${needle}" == *" ${pattern} "* ]]; then
      return 0
    fi
  done
  return 1
}

# "$@" is the simctl subcommand line, which is what the failure patterns are
# matched against. The surrounding spaces make the match whole-token.
# Takes the simctl subcommand line as its arguments and matches XCRUN_FAIL
# against it. The argument is REQUIRED, not decorative: an earlier version was
# called as `verb_is_failing` with no arguments, so `$*` inside it expanded to the
# empty string and the whole XCRUN_FAIL mechanism matched nothing. Every
# "this machine cannot answer" case then exited 0 -- a whole class of
# fail-closed assertions passing for the wrong reason, and worse than no
# assertion at all because it looked covered.
verb_is_failing() {
  xcrun_should_fail XCRUN_FAIL " $* "
}

is_running() {
  local running

  # Liveness is tied to the launch marker, not to a constant. Before `simctl
  # launch` has been called the app is NOT running, which is the precondition
  # `cold_launch` checks. Returning a constant 1 made every run fail the
  # cold-launch check, and returning a constant 0 made every run fail the
  # post-launch liveness check; only a marker reproduces a real device.
  if [[ -f "$(state_dir)/.launched" ]]; then
    running="$(value_or RUNNING 1)"
  else
    running=0
  fi

  # DEATH_AFTER_SCREENSHOTS: the app dies once the device has served N
  # screenshots. N=1 is death *during* the render wait; N=2 is death after the
  # gate already has a settled frame, which is the only way to reach the
  # post-render liveness re-check. The count has to be on disk because this is a
  # fresh process per invocation.
  local death_after shots
  death_after="$(value_or DEATH_AFTER_SCREENSHOTS "")"
  if [[ -n "${death_after}" ]]; then
    shots="$(cat "$(state_dir)/.count-screenshot" 2>/dev/null || printf 0)"
    if [[ "${shots}" =~ ^[0-9]+$ ]] && ((shots >= death_after)); then
      running=0
    fi
  fi

  # RUNNING_BEFORE_LAUNCH: models an app that is somehow already alive before the
  # gate launches it, which would turn the cold launch into a warm start.
  if [[ "$(value_or RUNNING_BEFORE_LAUNCH 0)" == "1" ]]; then
    running=1
  fi

  # A device that cannot answer is NOT a running app. Reported as "not running"
  # rather than as an error, because that is the direction that fails the gate.
  if xcrun_should_fail SPAWN_FAIL " launchctl list "; then
    return 1
  fi

  if [[ "${running}" == "1" ]]; then
    printf 'PID\tStatus\tLabel\n'
    printf '4242\t0\tUIKitApplication:%s[0xdead][4242]\n' "${FAKE_XCRUN_BUNDLE_ID}"
  fi
  return 0
}

if [[ "${1:-}" != "simctl" ]]; then
  printf 'fake xcrun: unexpected invocation %s\n' "$*" >&2
  exit 64
fi
shift
[[ $# -gt 0 ]] || exit 64
verb="$1"
shift

# The verb is passed explicitly because it has already been shifted off `$@` by
# this point, and the scenario patterns name it ("bootstatus", "get_app_container").
#
# 70 rather than 1: `simctl` reports CoreSimulator failures as 70+, and the gate
# classifies install failures by exit code as well as by message. Exiting 1 made
# every "this machine cannot answer" case fail as a generic simctl failure, so
# each one was verified against the wrong needle -- and a case could have been
# green while testing the fallback classification instead of the one under test.
if verb_is_failing "${verb} $*"; then
  printf 'xcrun: error: unable to talk to CoreSimulator (simulated)\n' >&2
  exit 70
fi

# A counter that survives across invocations. In-memory would reset every call,
# which would make every "the Nth call" scenario behave like the first.
bump() {
  local name="$1" file n=0
  file="$(state_dir)/.count-${name}"
  [[ -f "${file}" ]] && n="$(cat "${file}" 2>/dev/null || printf 0)"
  n=$((n + 1))
  printf '%s' "${n}" >"${file}"
  printf '%s' "${n}"
}

case "${verb}" in
  list)
    if [[ "$*" == *"devices"* ]]; then
      if [[ "$*" == *"--json"* ]]; then
        device_json="$(value_or DEVICE_JSON "${FAKE_XCRUN_DEVICE_JSON}")"
        # The device only reports Booted once `simctl boot` has been called, and
        # the state lives in a marker file rather than in memory because this is
        # a fresh process per invocation -- the boot poll is a sequence of
        # separate processes, exactly as it is against a real simulator.
        #
        # Without this the fake reported "Shutdown" forever, the gate's boot wait
        # ran to its deadline, and every happy-path assertion failed for a reason
        # that had nothing to do with the gate.
        booted=0
        [[ -f "$(state_dir)/.booted" ]] && booted=1
        if [[ -n "${device_json}" && -f "${device_json}" ]]; then
          if ((booted == 1)); then
            sed -E 's/"state"[[:space:]]*:[[:space:]]*"[^"]*"/"state" : "Booted"/' \
              "${device_json}"
          else
            cat "${device_json}"
          fi
        elif [[ -n "${device_json}" ]]; then
          printf '%s' "${device_json}"
        else
          printf '{\n  "devices": {\n    "%s": [\n      {\n        "udid": "%s",\n        "name": "%s",\n        "state": "Shutdown",\n        "isAvailable": true\n      }\n    ]\n  }\n}\n' \
            "${FAKE_XCRUN_RUNTIME}" "${FAKE_XCRUN_UDID}" "${FAKE_XCRUN_NAME}"
        fi
        exit 0
      fi
      printf -- '-- iOS 18.0 --\n    %s (%s) (Shutdown)\n' "${FAKE_XCRUN_NAME}" "${FAKE_XCRUN_UDID}"
      exit 0
    fi
    if [[ "$*" == *"runtimes"* ]]; then
      printf 'iOS 18.0 (18.0 - 22A3354) - %s\n' "${FAKE_XCRUN_RUNTIME}"
      exit 0
    fi
    exit 0
    ;;
  boot)
    bump boot >/dev/null
    if [[ "$(value_or BOOT_STATE_ERROR 0)" == "1" ]]; then
      # A device that is already Booted. `simctl boot` errors in that state, and
      # the gate must verify the real state from the device list rather than
      # treating this error as a boot failure.
      printf 'Unable to boot device in current state: Booted\n' >&2
      exit 149
    fi
    # BOOT_NEVER=1 models a simulator that accepts the boot command and then
    # never comes up. The marker is deliberately not written, so the gate's poll
    # has to reach its own deadline.
    if [[ "$(value_or BOOT_NEVER 0)" != "1" ]]; then
      : >"$(state_dir)/.booted"
    fi
    exit 0
    ;;
  bootstatus)
    bump bootstatus >/dev/null
    if [[ "$(value_or BOOTSTATUS_FAIL 0)" == "1" ]]; then
      # Hangs forever. The gate must time this out rather than block the job.
      while true; do sleep 1; done
    fi
    printf 'Status: Booted\n'
    exit 0
    ;;
  install)
    bump install >/dev/null
    # Whether this invocation carries --no-verify is the whole point of the retry
    # modelling, so it is read positionally and not inferred.
    retry=0
    [[ "$*" == *"--no-verify"* ]] && retry=1
    if [[ "$(value_or INSTALL_FAIL 0)" == "1" ]]; then
      if [[ "$(value_or INSTALL_UNSIGNED 0)" == "1" ]]; then
        if ((retry == 0)); then
          # The FIRST attempt is rejected for a signature reason, which is the
          # only classification allowed to reach the retry.
          printf 'An error was encountered processing the command (domain=NSPOSIXErrorDomain):\nApplicationVerificationFailed: The executable of this bundle, %s, has an invalid (or unsigned) code signature.\n' \
            "${FAKE_XCRUN_APP}/Runner"
          exit 70
        fi
        if [[ "$(value_or INSTALL_NOVERIFY_FAIL 0)" == "1" ]]; then
          printf 'An error was encountered processing the command (domain=NSPOSIXErrorDomain):\nApplicationVerificationFailed: still unsigned.\n'
          exit 70
        fi
        # The retried install succeeded. An earlier version failed BOTH attempts
        # with the same signature error, which is precisely the case the retry
        # exists to survive -- so the retried-install assertion was exercising
        # the "with or without --no-verify" failure branch instead of a success,
        # and reported a healthy retry path as broken.
        : >"$(state_dir)/.installed"
        exit 0
      fi
      printf 'An error was encountered processing the command (domain=NSPOSIXErrorDomain, code=2):\nNo such file or directory: %s\n' "${FAKE_XCRUN_APP}"
      exit 70
    fi
    : >"$(state_dir)/.installed"
    exit 0
    ;;
  get_app_container)
    bump container >/dev/null
    if [[ "$(value_or INSTALLED 1)" != "1" ]]; then
      printf 'No such app: %s\n' "${FAKE_XCRUN_BUNDLE_ID}" >&2
      exit 3
    fi
    mkdir -p "$(state_dir)/app-container"
    printf '%s' "$(state_dir)/app-container"
    exit 0
    ;;
  launch)
    launch_n="$(bump launch)"
    # Record the full argv so the suite can assert exactly what the gate handed
    # to `simctl launch` -- in particular that a debug session is passed verbatim
    # and that no stray empty argument appears when none is configured.
    printf '%s\n' "$@" >"$(state_dir)/.launch-args"
    : >"$(state_dir)/.launched"
    if [[ "$(value_or LAUNCH_FAIL 0)" == "1" ]]; then
      printf 'An error was encountered processing the command (domain=NSPOSIXErrorDomain, code=3):\nUnable to lookup in current state: %s\n' "${FAKE_XCRUN_BUNDLE_ID}" >&2
      exit 3
    fi
    if [[ "$(value_or LAUNCH_NO_PID 0)" == "1" ]]; then
      # Exit 0, no pid. A launch that reports nothing must not be believed.
      printf 'Warning: launched but no pid was reported\n'
      exit 0
    fi
    printf '%s: %s\n' "${FAKE_XCRUN_BUNDLE_ID}" "$(value_or PID 4242)"

    # A crash that happens DURING the launch window.
    #
    # It has to be written HERE, not planted before the run. The gate snapshots
    # the crash-report baseline before it touches the simulator, so a report
    # planted up front is correctly counted as PRE-EXISTING and the run passes.
    # An earlier version of this fake had no way to create a mid-window crash,
    # so every crash-detection case was really testing the baseline comparison
    # and passing vacuously -- the most dangerous possible shape for the one
    # check whose job is to catch a dead app.
    #
    # CRASH_ON_LAUNCH names a fixture report to copy in; CRASH_DIES=0 models a
    # crash of some OTHER process, which leaves the app running.
    crash_fixture="$(value_or CRASH_ON_LAUNCH "")"
    if [[ -n "${crash_fixture}" ]]; then
      if [[ -z "${FAKE_XCRUN_CRASH_DIR:-}" ]]; then
        printf 'fake xcrun: CRASH_ON_LAUNCH is set but FAKE_XCRUN_CRASH_DIR is not\n' >&2
        exit 65
      fi
      if [[ ! -f "${crash_fixture}" ]]; then
        printf 'fake xcrun: CRASH_ON_LAUNCH fixture does not exist: %s\n' "${crash_fixture}" >&2
        exit 65
      fi
      cp "${crash_fixture}" \
        "${FAKE_XCRUN_CRASH_DIR}/Runner-midwindow-${launch_n}.ips"
      # A crash of the app itself means the process is gone. Leaving it "running"
      # would let the gate's post-render liveness re-check pass on a dead app.
      if [[ "$(value_or CRASH_DIES 1)" == "1" ]]; then
        rm -f "$(state_dir)/.launched"
      fi
    fi
    exit 0
    ;;
  spawn)
    # The gate's real invocation shape is `simctl spawn <udid> <tool> [args...]`,
    # so the device udid comes FIRST. Matching on "$1" being the tool name made
    # the fake answer "nothing" for every liveness check, and the gate correctly
    # reported the app as not running -- a harness fault that reads exactly like
    # a launch failure. The subcommand is therefore located positionally rather
    # than assumed to be first.
    spawn_tail=("${@:2}")
    spawn_verb="${spawn_tail[0]:-}"
    if [[ "${spawn_verb}" == "launchctl" && "${spawn_tail[1]:-}" == "list" ]]; then
      bump spawn >/dev/null
      is_running
      exit 0
    fi
    if [[ "${spawn_verb}" == "log" ]]; then
      bump log >/dev/null
      printf 'Timestamp (simulated)\tProcess\tMessage\n'
      printf '2026-09-30 00:00:00.000\tRunner\t[ios-smoke] fake log stream for Runner\n'
      printf '2026-09-30 00:00:01.000\tRunner\topen failed: /data/gallery.db: not found (ordinary app text, not a gate signal)\n'
      exit 0
    fi
    exit 0
    ;;
  io)
    # `simctl io <udid> screenshot --type=png <path>` -- again the udid comes first.
    if [[ "${2:-}" == "screenshot" ]]; then
      # The destination is argument 4: `io <udid> screenshot --type=png <path>`.
      # It is read positionally rather than by "last argument that is not a
      # flag", because that loop would also have picked up the udid and, if the
      # order ever changed, silently served the wrong file.
      # The frame the "device" displays. It is NOT the destination path the gate
      # asked to save to -- the destination is where simctl WRITES, and the frame
      # is what it writes THERE. Conflating the two meant that when the scenario
      # carried `SCREENSHOT=` (i.e. "no override"), the fake looked for the
      # gate's not-yet-created output file as its source, found nothing, wrote
      # nothing, and every capture looked like a failed screenshot.
      #
      # A scenario may override the displayed frame, which is how a blank, an
      # undecodable or an alternating pair is injected.
      destination="${4:-}"
      # An EMPTY SCREENSHOT means "the scenario names no override", not "serve
      # nothing". `scenario_value` returns success for a key present with an
      # empty value, so `value_or` would hand back the empty string and the
      # device would serve a blank screen -- which is the behaviour under test
      # for the blank-screen case and pure noise everywhere else. Restoring the
      # baseline scenario is therefore the way to reset this key.
      shot="$(value_or SCREENSHOT "")"
      [[ -n "${shot}" ]] || shot="${FAKE_XCRUN_DEFAULT_SCREENSHOT:-}"
      # SCREENSHOT_DRIFT: serve an alternating pair so that every capture differs
      # and the gate's stability requirement can never be met. Without this
      # mechanism the never-settling case is indistinguishable from the happy
      # path and asserts nothing at all -- the suite has a self-check for its
      # presence for exactly that reason.
      #
      # The counter is bumped EXACTLY ONCE per capture, below, and the drift
      # decision reads the value that bump returned. An earlier version bumped
      # once to pick the file and again unconditionally, so every capture
      # advanced the counter by two, the parity never changed, and every capture
      # served the same frame -- which made the never-settling screen look
      # perfectly settled.
      if [[ "$(value_or SCREENSHOT_DRIFT 0)" == "1" ]]; then
        drift="$(value_or SCREENSHOT_DRIFT_ALT "")"
        if [[ -n "${drift}" ]]; then
          n="$(bump screenshot)"
          if ((n % 2 == 1)); then
            shot="${drift}"
          fi
        else
          bump screenshot >/dev/null
        fi
      else
        bump screenshot >/dev/null
      fi
      # `simctl io screenshot <path>` WRITES THE FILE at <path>; it does not print
      # the PNG on stdout. The gate reflects that -- it sends stdout to /dev/null
      # and then tests `[[ -s "${destination}" ]]` -- so a fake that only echoed
      # the frame made every capture look like a failed screenshot and the render
      # wait ran to its deadline. Writing the destination is what makes this
      # model the real tool.
      if [[ -n "${shot}" && -f "${shot}" ]]; then
        if [[ -n "${destination}" ]]; then
          mkdir -p "$(dirname "${destination}")"
          cp "${shot}" "${destination}"
        fi
        cat "${shot}"
      elif [[ -n "${destination}" ]]; then
        # No frame available. Write nothing at all, so the gate's own emptiness
        # check is what rejects the capture, exactly as against a real device.
        rm -f "${destination}"
      fi
      exit 0
    fi
    exit 0
    ;;
  listapps)
    bump listapps >/dev/null
    printf '{\n  "%s" = {\n    ApplicationType = User;\n    CFBundleIdentifier = "%s";\n    Path = "%s/Runner.app";\n  };\n}\n' \
      "${FAKE_XCRUN_BUNDLE_ID}" "${FAKE_XCRUN_BUNDLE_ID}" "${FAKE_XCRUN_APP}"
    exit 0
    ;;
  shutdown)
    exit 0
    ;;
  *)
    printf 'fake xcrun: unmodelled simctl verb %s\n' "${verb}" >&2
    exit 64
    ;;
esac
FAKE_XCRUN
  chmod +x "${WORK_DIR}/xcrun"
}

# --- fixtures ---------------------------------------------------------------

# make_macho <path> <cpu> <platform-value>
#
# Builds a real 64-bit Mach-O with a real LC_BUILD_VERSION command. It has to be
# a real header, not a stub, because the gate parses the load-command stream and
# a fixture that only had the magic number would make the reader's platform
# lookup untested -- which is the one part of this check with real logic in it.
#
# cpu: x86_64 | arm64.  platform: 2 = iOS device, 7 = iOS simulator.
#
# NOT a real Apple binary: no code, no segments, no signature, no dyld info.
# It carries the fields the gate reads and nothing else.
make_macho() {
  python3 - "$1" "$2" "${3:-7}" <<'PY'
import struct
import sys

path, cpu, platform = sys.argv[1], sys.argv[2], int(sys.argv[3])
CPU_TYPES = {"x86_64": 0x01000007, "arm64": 0x0100000C}
cputype = CPU_TYPES[cpu]

LC_BUILD_VERSION = 0x32
MH_EXECUTE = 0x2
load = struct.pack(
    "<IIIII", LC_BUILD_VERSION, 24, platform, 0x000E0000, 0x000E0000
) + struct.pack("<I", 0)  # ntools
header = struct.pack(
    "<IiiIIIII", 0xFEEDFACF, cputype, 0, MH_EXECUTE, 1, len(load), 0x200085, 0
)
with open(path, "wb") as handle:
    handle.write(header)
    handle.write(load)
PY
}

# make_fat_macho <path> <cpu>:<platform> [<cpu>:<platform> ...]
#
# A universal ("fat") binary. This shape is the one that catches a per-slice
# check written as "does ANY slice match": a bundle carrying one simulator slice
# and one device slice passes such a check and then fails to launch.
make_fat_macho() {
  python3 - "$1" "${@:2}" <<'PY'
import struct
import sys

path = sys.argv[1]
CPU_TYPES = {"x86_64": 0x01000007, "arm64": 0x0100000C}


def thin(cpu: str, platform: int) -> bytes:
    load = struct.pack("<IIIII", 0x32, 24, platform, 0xE0000, 0xE0000) + struct.pack("<I", 0)
    header = struct.pack(
        "<IiiIIIII", 0xFEEDFACF, CPU_TYPES[cpu], 0, 0x2, 1, len(load), 0x200085, 0
    )
    return header + load


entries = []
for spec in sys.argv[2:]:
    cpu, _, platform = spec.partition(":")
    entries.append((cpu, thin(cpu, int(platform))))

# fat_header is big-endian: (magic, nfat_arch), then fat_arch records of
# (cputype, cpusubtype, offset, size, align), each 20 bytes.
header_size = 8 + 20 * len(entries)
arch = b""
body = b""
offset = header_size
for (cpu, blob), (name, _platform) in zip(entries, entries):
    arch += struct.pack(">iiIII", CPU_TYPES[name], 0, offset, len(blob), 14)
    body += blob
    offset += len(blob)
with open(path, "wb") as handle:
    handle.write(struct.pack(">II", 0xCAFEBABE, len(entries)) + arch + body)
PY
}

# make_app <path> <bundle-id> <exe-platform> <daemon-platform>
#   <exe-platform>/<daemon-platform>: 2 = iOS device, 7 = iOS simulator, 0 = absent
#
# Builds a .app directory with a real Info.plist and real Mach-O executables, and
# verifies each of those afterwards. A fixture that silently lost its daemon, or
# whose plistlib output was not readable, would make the structural assertions
# below pass for the wrong reason -- so creation and verification happen in the
# same process and a bad fixture stops the suite instead of producing a cascade
# of misleading failures.
make_app() {
  python3 - "${1}" "${2}" "${3}" "${4}" "${5:-thin}" <<'PY'
import os
import plistlib
import shutil
import struct
import sys

path, bundle, exe_platform, daemon_platform, shape = (
    sys.argv[1],
    sys.argv[2],
    int(sys.argv[3]),
    int(sys.argv[4]),
    sys.argv[5],
)
CPU_TYPES = {"x86_64": 0x01000007, "arm64": 0x0100000C}
LC_BUILD_VERSION = 0x32
MH_EXECUTE = 0x2


def thin(cpu: str, platform: int) -> bytes:
    load = struct.pack(
        "<IIIII", LC_BUILD_VERSION, 24, platform, 0x000E0000, 0x000E0000
    ) + struct.pack("<I", 0)
    header = struct.pack(
        "<IiiIIIII", 0xFEEDFACF, CPU_TYPES[cpu], 0, MH_EXECUTE, 1, len(load), 0x200085, 0
    )
    return header + load


def fat(specs):
    """specs: [(cpu, platform), ...] -> bytes of a universal binary."""
    blobs = [(cpu, thin(cpu, platform)) for cpu, platform in specs]
    header_size = 8 + 20 * len(blobs)
    arch = b""
    body = b""
    offset = header_size
    for (cpu, blob), (_c, _p) in zip(blobs, blobs):
        arch += struct.pack(">iiIII", CPU_TYPES[cpu], 0, offset, len(blob), 14)
        body += blob
        offset += len(blob)
    return struct.pack(">II", 0xCAFEBABE, len(blobs)) + arch + body


shutil.rmtree(path, ignore_errors=True)
os.makedirs(path, exist_ok=True)
frameworks = os.path.join(path, "Frameworks")
os.makedirs(frameworks, exist_ok=True)


def payload(specs):
    return fat(specs) if shape == "fat" else thin(specs[0][0], specs[0][1])


runner = os.path.join(path, "Runner")
with open(runner, "wb") as handle:
    handle.write(payload([("arm64", exe_platform)]))
os.chmod(runner, 0o755)

# The daemon carries its own platform independently, so a bundle whose app binary
# is a device slice but whose daemon is a simulator slice is representable -- and
# is exactly the half-wrong case that must still be caught.
if daemon_platform:
    daemon = os.path.join(frameworks, "race")
    with open(daemon, "wb") as handle:
        handle.write(payload([("arm64", daemon_platform)]))
    os.chmod(daemon, 0o755)

# A plugin framework, present so the "checked when present" path is exercised.
app_fw = os.path.join(frameworks, "App.framework")
os.makedirs(app_fw, exist_ok=True)
with open(os.path.join(app_fw, "App"), "wb") as handle:
    handle.write(payload([("arm64", exe_platform)]))
os.chmod(os.path.join(app_fw, "App"), 0o755)

plist = {
    "CFBundleExecutable": "Runner",
    "CFBundleIdentifier": bundle,
    "CFBundleName": "private_gallery_app",
    "CFBundlePackageType": "APPL",
    "CFBundleShortVersionString": "0.1.0",
    "CFBundleVersion": "1",
    "MinimumOSVersion": "15.0",
    "UILaunchStoryboardName": "LaunchScreen",
}
with open(os.path.join(path, "Info.plist"), "wb") as handle:
    plistlib.dump(plist, handle)

# Verify the fixture rather than trusting it.
with open(os.path.join(path, "Info.plist"), "rb") as handle:
    read_back = plistlib.load(handle)
if read_back.get("CFBundleIdentifier") != bundle:
    print(f"FATAL: fixture {path} has the wrong CFBundleIdentifier", file=sys.stderr)
    sys.exit(1)
for relative in ("Runner", "Frameworks/race", "Frameworks/App.framework/App"):
    full = os.path.join(path, relative)
    if daemon_platform == 0 and relative == "Frameworks/race":
        if os.path.exists(full):
            print(f"FATAL: fixture {path} should not have a daemon", file=sys.stderr)
            sys.exit(1)
        continue
    if not os.path.isfile(full) or not os.access(full, os.X_OK):
        print(f"FATAL: fixture {path} is missing executable {relative}", file=sys.stderr)
        sys.exit(1)
    # Both magics are accepted. A universal fixture starts with the big-endian
    # fat magic, so checking only for MH_MAGIC_64 made every fat bundle report
    # "not a Mach-O" -- a fixture error that reads exactly like a gate bug.
    with open(full, "rb") as handle:
        magic = handle.read(4)
    if magic not in (struct.pack("<I", 0xFEEDFACF), struct.pack(">I", 0xCAFEBABE)):
        print(f"FATAL: fixture {full} is not a Mach-O (magic {magic!r})", file=sys.stderr)
        sys.exit(1)
print("ok")
PY
}

# make_png <path> <distinct-colour-count>
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

# make_ips <path> <procName> <bundle-id>
# A crash report in Apple's real shape: a JSON header line, then the body.
make_ips() {
  python3 - "$1" "$2" "$3" <<'PY'
import json
import sys

path, proc, bundle = sys.argv[1], sys.argv[2], sys.argv[3]
header = {
    "app_name": proc,
    "procName": proc,
    "bundleID": bundle,
    "bug_type": "309",
    "os_version": "iPhone OS 18.0 (22A3354)",
    "incident_id": "AAAAAAAA-1111-2222-3333-444444444444",
    "bundleInfo": {
        "CFBundleIdentifier": bundle,
        "CFBundleShortVersionString": "0.1.0",
    },
}
with open(path, "w", encoding="utf-8") as handle:
    handle.write(json.dumps(header) + "\n")
    handle.write(json.dumps({"threads": [], "usedImages": []}) + "\n")
PY
}

install_fake_xcrun
mkdir -p "${CRASH_DIR}"
mkdir -p "${WORK_DIR}/evidence"

# --- bundle fixtures --------------------------------------------------------
#
# The good bundle: simulator slices throughout, daemon present and executable.
if make_app "${WORK_DIR}/Runner.app" "${BUNDLE_ID}" 7 7 >/dev/null; then
  ok "the good .app fixture is a real bundle with simulator Mach-O slices"
else
  meta_failure "the good .app fixture is a real bundle with simulator Mach-O slices" \
    "fixture creation failed; every assertion below would be meaningless"
  exit 1
fi

# A device-slice bundle: the exact slice the release job's `flutter build ios
# --release` produces for `app/build/ios/iphoneos/Runner.app`. `simctl install`
# cannot accept it, so the gate must say so structurally rather than via a
# long install failure.
make_app "${WORK_DIR}/Device.app" "${BUNDLE_ID}" 2 2 >/dev/null
# Only the app binary is wrong; the daemon is a simulator slice. Must still fail.
make_app "${WORK_DIR}/HalfDevice.app" "${BUNDLE_ID}" 2 7 >/dev/null
# A bundle with no native daemon at all: a dropped packaging step, which is
# exactly the shape of the release job's `Frameworks/race` copy going missing.
make_app "${WORK_DIR}/NoDaemon.app" "${BUNDLE_ID}" 7 0 >/dev/null
# The wrong application entirely.
make_app "${WORK_DIR}/Other.app" "com.example.Other" 7 7 >/dev/null
# A daemon that is present but not executable.
cp -R "${WORK_DIR}/Runner.app" "${WORK_DIR}/NoExecDaemon.app"
chmod -x "${WORK_DIR}/NoExecDaemon.app/Frameworks/race"
# A bundle with no Info.plist at all.
cp -R "${WORK_DIR}/Runner.app" "${WORK_DIR}/NoPlist.app"
rm -f "${WORK_DIR}/NoPlist.app/Info.plist"
# A bundle whose app binary is not executable.
cp -R "${WORK_DIR}/Runner.app" "${WORK_DIR}/NoExecApp.app"
chmod -x "${WORK_DIR}/NoExecApp.app/Runner"
# A framework carrying the device slice inside an otherwise-correct bundle.
cp -R "${WORK_DIR}/Runner.app" "${WORK_DIR}/BadFramework.app"
make_macho "${WORK_DIR}/BadFramework.app/Frameworks/App.framework/App" arm64 2
# The daemon carrying the device slice while the app binary is a simulator slice.
# This is the *other* half-wrong direction and the release job's real shape on a
# simulator build: the app binary is built for the simulator, but the daemon
# copied into Frameworks/ was cross-compiled for aarch64-apple-ios.
make_app "${WORK_DIR}/DeviceDaemon.app" "${BUNDLE_ID}" 7 2 >/dev/null
# A universal bundle where every slice is a simulator slice: the real shape of
# `flutter build ios --simulator` on an Intel runner. Must PASS.
make_app "${WORK_DIR}/FatSim.app" "${BUNDLE_ID}" 7 7 fat >/dev/null
# A universal bundle mixing a simulator slice with a device slice. Every "any
# slice matches" implementation accepts this one; it must be rejected.
cp -R "${WORK_DIR}/FatSim.app" "${WORK_DIR}/FatMixed.app"
make_fat_macho "${WORK_DIR}/FatMixed.app/Runner" x86_64:7 arm64:2
make_fat_macho "${WORK_DIR}/FatMixed.app/Frameworks/race" x86_64:7 arm64:2
make_fat_macho "${WORK_DIR}/FatMixed.app/Frameworks/App.framework/App" x86_64:7 arm64:2

# --- frame fixtures ---------------------------------------------------------

make_png "${WORK_DIR}/rich.png" 40
make_png "${WORK_DIR}/blank.png" 1
# A second complex frame for the never-settling scenario. It must clear the
# threshold, or the gate would reject it for being blank and the stability check
# would never actually be exercised.
make_png "${WORK_DIR}/rich-drift.png" 41
printf 'not a png at all' >"${WORK_DIR}/garbage.png"

# --- device-list fixtures ----------------------------------------------------
#
# Written to files so a scenario can point DEVICE_JSON at a different one (an
# empty list, a list with no available devices, unparseable junk) without the
# gate growing a knob.
cat >"${WORK_DIR}/devices.json" <<EOF
{
  "devices" : {
    "${SIM_RUNTIME_ID}" : [
      {
        "udid" : "${SIM_UDID}",
        "isAvailable" : true,
        "state" : "Shutdown",
        "name" : "${SIM_NAME}"
      }
    ]
  }
}
EOF
cat >"${WORK_DIR}/devices-empty.json" <<'EOF'
{
  "devices" : {
  }
}
EOF
cat >"${WORK_DIR}/devices-unavailable.json" <<EOF
{
  "devices" : {
    "${SIM_RUNTIME_ID}" : [
      {
        "udid" : "${SIM_UDID}",
        "isAvailable" : false,
        "state" : "Shutdown",
        "name" : "iPhone 16 Pro (unavailable, runtime profile not found)"
      }
    ]
  }
}
EOF
printf 'not json at all' >"${WORK_DIR}/devices-garbage.json"
# A list whose only device never leaves "Booting".
sed 's/"Shutdown"/"Booting"/' "${WORK_DIR}/devices.json" >"${WORK_DIR}/devices-never-boots.json"
# A list that is Booted from the first poll.
sed 's/"Shutdown"/"Booted"/' "${WORK_DIR}/devices.json" >"${WORK_DIR}/devices-prebooted.json"
# Two runtimes, so the "newest runtime wins" and the "pinned runtime" paths are
# both exercised rather than assumed.
cat >"${WORK_DIR}/devices-two-runtimes.json" <<EOF
{
  "devices" : {
    "com.apple.CoreSimulator.SimRuntime.iOS-17-5" : [
      { "udid" : "OLD-0000", "isAvailable" : true, "state" : "Shutdown", "name" : "iPhone 15" }
    ],
    "${SIM_RUNTIME_ID}" : [
      {
        "udid" : "${SIM_UDID}",
        "isAvailable" : true,
        "state" : "Shutdown",
        "name" : "${SIM_NAME}"
      }
    ]
  }
}
EOF
# Three runtimes whose ORDER in the file is the REVERSE of their version order.
# The real runtime identifiers are hyphenated ("...SimRuntime.iOS-18-0"), so an
# ordering routine that only splits on '.' finds no numeric parts in any of them,
# keys every candidate to the same empty tuple, and returns whichever one the JSON
# happened to list first. Listing them oldest-last is what makes that visible:
# a working selector must still pick the 18-2 device, and a broken one picks
# 17-5 because that is first in the file.
#
# The file also carries a NEWER non-iOS runtime (watchOS 26-0, which outranks
# every iOS version here). Selecting it would be a false pass of a different
# kind -- a check that ran on the wrong device family entirely -- so the fixture
# comes with an assertion that the iOS family filter is real and not decorative.
cat >"${WORK_DIR}/devices-three-runtimes.json" <<EOF
{
  "devices" : {
    "com.apple.CoreSimulator.SimRuntime.iOS-18-2" : [
      { "udid" : "NEWEST-333", "isAvailable" : true, "state" : "Shutdown", "name" : "iPhone 16" }
    ],
    "com.apple.CoreSimulator.SimRuntime.iOS-18-0" : [
      { "udid" : "MIDDLE-222", "isAvailable" : true, "state" : "Shutdown", "name" : "iPhone 15 Pro" }
    ],
    "com.apple.CoreSimulator.SimRuntime.iOS-17-5" : [
      { "udid" : "OLDEST-111", "isAvailable" : true, "state" : "Shutdown", "name" : "iPhone 14" }
    ],
    "com.apple.CoreSimulator.SimRuntime.watchOS-26-0" : [
      { "udid" : "WATCH-999", "isAvailable" : true, "state" : "Shutdown", "name" : "Apple Watch Series 11 (45mm)" }
    ]
  }
}
EOF

# --- crash-report fixtures ---------------------------------------------------
#
# The directory starts empty, so a passing run genuinely has no reports and the
# "new report" scenarios are unambiguous.
make_ips "${WORK_DIR}/crash-runner.ips" "Runner" "${BUNDLE_ID}"
make_ips "${WORK_DIR}/crash-other.ips" "SpringBoard" "com.apple.SpringBoard"
# Attribution has to work on EITHER header field. Apple's header carries both the
# process name and the bundle identifier, and a release binary whose executable
# name does not match CFBundleExecutable (a renamed wrapper, a helper process)
# would be missed by a check that only looks at the process name -- and vice versa
# for a crash logged under a name that happens to collide.
make_ips "${WORK_DIR}/crash-renamed-proc.ips" "SomeRenamedProc" "${BUNDLE_ID}"
make_ips "${WORK_DIR}/crash-other-bundle.ips" "Runner" "com.someother.App"
printf 'this is not a crash report at all\n' >"${WORK_DIR}/crash-garbage.ips"

# --- scenario plumbing ------------------------------------------------------

# The baseline exists as a file. It did NOT in an earlier version of this suite:
# `scenario_with` copied a file that nothing had ever created, so every case ran
# with NO scenario at all, every knob was silently at its default, and every
# scenario-specific assertion below was passing for the wrong reason. The
# fixture-creation assertions in this file exist to catch exactly that class of
# silent no-op.
cat >"${BASE_SCENARIO}" <<EOF
RUNNING=1
INSTALLED=1
SCREENSHOT=${WORK_DIR}/rich.png
EOF
cp "${BASE_SCENARIO}" "${SCENARIO}"

scenario_with() {
  # Always start from the pristine baseline so tests are order-independent: a
  # key one case sets cannot leak into the next.
  local line key work
  cp "${BASE_SCENARIO}" "${SCENARIO}"
  reset_state
  for line in "$@"; do
    key="${line%%=*}"
    work="${WORK_DIR}/scenario.work"
    grep -v "^${key}=" "${SCENARIO}" >"${work}" 2>/dev/null || true
    printf '%s\n' "${line}" >>"${work}"
    cp "${work}" "${SCENARIO}"
  done
}

# Clears ONLY the fake device's per-run state: the call counters, the install
# and launch markers, the boot marker and the app container.
#
# This is separated from `reset_state` and called at the start of every gate run
# because the fake persists liveness on disk across processes (which is how a real
# simulator behaves). Two consecutive cases that do not both go through
# `scenario_with` therefore leaked `.launched` from one into the next, and the
# second case failed with "is already running ... this must be a cold launch" --
# a device-state leak reported as a gate bug.
#
# It deliberately does NOT touch the crash-report directory or the evidence
# directory: several cases create a crash report or read evidence AFTER resetting
# the scenario, and clearing those here would delete the fixture under them.
reset_device_state() {
  rm -f "${WORK_DIR}"/.count-* "${WORK_DIR}/.installed" "${WORK_DIR}/.launched" \
    "${WORK_DIR}/.launch-args" "${WORK_DIR}/.booted"
  rm -rf "${WORK_DIR}/app-container"
}

reset_state() {
  # The fake keeps its call counters and its install/launch markers on disk (it
  # is a fresh process per invocation). A counter left over from an earlier case
  # would make the next one behave differently depending on test order.
  rm -f "${WORK_DIR}"/.count-* "${WORK_DIR}/.installed" "${WORK_DIR}/.launched" \
    "${WORK_DIR}/.launch-args" "${WORK_DIR}/.booted"
  rm -rf "${WORK_DIR}/app-container"
  rm -f "${CRASH_DIR}"/*.ips "${CRASH_DIR}"/*.crash "${CRASH_DIR}"/*.diag 2>/dev/null || true
  rm -f "${WORK_DIR}/evidence"/* 2>/dev/null || true
}

# The environment every gate invocation gets. Kept in one place so a knob added
# here reaches every case, and so a case cannot accidentally run the gate with a
# different environment from its neighbours.
smoke_env() {
  printf '%s\n' \
    "IOS_SMOKE_XCRUN=${WORK_DIR}/xcrun" \
    "FAKE_XCRUN_STATE=${WORK_DIR}" \
    "FAKE_XCRUN_SCENARIO=${SCENARIO}" \
    "FAKE_XCRUN_UDID=${SIM_UDID}" \
    "FAKE_XCRUN_NAME=${SIM_NAME}" \
    "FAKE_XCRUN_RUNTIME=${SIM_RUNTIME_ID}" \
    "FAKE_XCRUN_BUNDLE_ID=${BUNDLE_ID}" \
    "FAKE_XCRUN_DEVICE_JSON=${WORK_DIR}/devices.json" \
    "FAKE_XCRUN_APP=${WORK_DIR}/Runner.app" \
    "IOS_SMOKE_CRASH_DIR=${CRASH_DIR}" \
    "FAKE_XCRUN_CRASH_DIR=${CRASH_DIR}" \
    "IOS_SMOKE_EVIDENCE_DIR=${WORK_DIR}/evidence" \
    "IOS_SMOKE_NAME=case" \
    "IOS_SMOKE_BOOT_TIMEOUT_SECONDS=${SMOKE_BOOT_TIMEOUT:-8}" \
    "IOS_SMOKE_LAUNCH_TIMEOUT_SECONDS=${SMOKE_LAUNCH_TIMEOUT:-8}" \
    "IOS_SMOKE_RENDER_TIMEOUT_SECONDS=${SMOKE_RENDER_TIMEOUT:-5}" \
    "IOS_SMOKE_POLL_INTERVAL_SECONDS=1" \
    "FAKE_XCRUN_DEFAULT_SCREENSHOT=${SMOKE_DEFAULT_SCREENSHOT:-${WORK_DIR}/rich.png}" \
    "IOS_SMOKE_BACKEND_PROBE=${WORK_DIR}/backend-ok" \
    "IOS_SMOKE_BACKEND_TIMEOUT_SECONDS=8"
}

# run_smoke <app-path> [EXTRA=VALUE ...]
#
# The extra assignments go through `env`, so they override the defaults above.
#
# run_smoke runs the gate DIRECTLY. run_smoke_capped is the one that applies the
# wall-clock cap, and it deliberately does not wrap this function -- `timeout`
# needs an external command, and `timeout 90 run_smoke ...` fails with
# "failed to run command 'run_smoke': No such file or directory" on every case
# in the suite. An earlier version did exactly that, which is why the whole suite
# failed at once for a reason that had nothing to do with the gate.
run_smoke() {
  local app="$1"
  shift
  local -a assignments=()
  local line
  while IFS= read -r line; do
    assignments+=("${line}")
  done < <(smoke_env)
  env "${assignments[@]}" "$@" bash "${SCRIPT}" "${app}"
}

# A per-invocation wall-clock cap. A gate that hangs is a worse outcome than a
# gate that fails, because it burns the job budget and reports nothing -- and the
# "never hang" requirement has to be TESTED, not asserted in a comment. Without
# this cap a mutation that removed a deadline would hang the suite rather than
# fail it, which is exactly the case the mutation harness exists to catch.
#
# The cap applies to `env ... bash <gate>` -- a real external command -- for the
# reason given on run_smoke. macOS has no coreutils `timeout`, so the fallback
# is the same portable shape the gate itself uses.
with_cap() {
  local cap="$1"
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "${cap}" "$@"
    return $?
  fi
  local child killer rc=0
  "$@" &
  child=$!
  (sleep "${cap}"; kill -TERM "${child}" 2>/dev/null) >/dev/null 2>&1 &
  killer=$!
  if wait "${child}"; then
    rc=0
  else
    rc=$?
  fi
  kill -TERM "${killer}" 2>/dev/null || true
  wait "${killer}" 2>/dev/null || true
  return "${rc}"
}

# Builds the argv for `env ... bash <gate> <app>` so the cap can wrap it.
smoke_argv() {
  local app="$1"
  shift
  local -a assignments=()
  local line
  while IFS= read -r line; do
    assignments+=("${line}")
  done < <(smoke_env)
  printf '%s\0' env "${assignments[@]}" "$@" bash "${SCRIPT}" "${app}"
}

run_smoke_capped() {
  local app="$1"
  shift
  # Every gate invocation starts from a device that has nothing installed and
  # nothing running. See `reset_device_state` for why this is not part of
  # `scenario_with`.
  reset_device_state
  local -a argv=()
  mapfile -d '' -t argv < <(smoke_argv "${app}" "$@")
  with_cap "${SMOKE_CAP:-120}" "${argv[@]}"
}

expect_pass() {
  local name="$1"
  shift
  if run_smoke_capped "$@" >"${OUT}" 2>&1; then
    ok "${name}"
  else
    bad "${name}" "$(cat "${OUT}")"
  fi
}

# expect_fail <name> <needle|-> [gate args...]
expect_fail() {
  local name="$1" needle="${2:--}"
  shift 2
  if run_smoke_capped "$@" >"${OUT}" 2>&1; then
    bad "${name}" "expected a non-zero exit, got success: $(cat "${OUT}")"
    return
  fi
  if [[ "${needle}" != "-" ]] && ! grep -Fq "${needle}" "${OUT}"; then
    bad "${name}" "expected the failure to mention '${needle}'; got: $(cat "${OUT}")"
    return
  fi
  ok "${name}"
}

# --- tests ------------------------------------------------------------------

echo "ios_release_artifact_smoke.sh"

# ---------------------------------------------------------------------------
# The suite proves its own plumbing first. Every behavioural assertion below
# depends on these; if the fixture or the scenario file is broken, the rest of
# the suite reports confidently wrong verdicts.
# ---------------------------------------------------------------------------
echo " the suite's own plumbing (everything below depends on this)"
if [[ -s "${BASE_SCENARIO}" ]] && [[ -s "${SCENARIO}" ]]; then
  ok "the baseline scenario file exists and is non-empty"
else
  meta_failure "the baseline scenario file exists and is non-empty" \
    "scenario_with would silently run every case with no scenario at all"
fi
scenario_with "RUNNING=1"
if grep -Fq "RUNNING=1" "${SCENARIO}" && ! grep -Fq "RUNNING_BEFORE_LAUNCH" "${SCENARIO}"; then
  ok "setting a scenario key actually changes the scenario file"
else
  meta_failure "setting a scenario key actually changes the scenario file" \
    "scenario_with is a no-op, so every scenario assertion below is vacuous"
fi
# Setting a SECOND key must leave the first alone. The baseline legitimately
# contains `RUNNING=1`, so the check is that the new key lands *alongside* it,
# not that `RUNNING=` disappears.
scenario_with "DEATH_AFTER_SCREENSHOTS=2"
if grep -Fq "DEATH_AFTER_SCREENSHOTS=2" "${SCENARIO}" &&
  grep -Fq "RUNNING=1" "${SCENARIO}" &&
  grep -Fq "SCREENSHOT=${WORK_DIR}/rich.png" "${SCENARIO}"; then
  ok "setting a second scenario key does not disturb the first"
else
  meta_failure "setting a second scenario key does not disturb the first" \
    "a case would see another case's settings, making results order-dependent"
fi
# ...and re-setting an EXISTING key must replace it, not append a second copy.
# A file carrying both `RUNNING=0` and `RUNNING=1` is read by the fake as whichever
# line it matches first, so a duplicate is an order-dependent fixture.
scenario_with "RUNNING=0"
if grep -Fq "RUNNING=0" "${SCENARIO}" && ! grep -Fq "RUNNING=1" "${SCENARIO}" &&
  ! grep -Fq "DEATH_AFTER_SCREENSHOTS" "${SCENARIO}"; then
  ok "re-setting an existing scenario key replaces it rather than duplicating it"
else
  meta_failure "re-setting an existing scenario key replaces it rather than duplicating it" \
    "the scenario file would carry two values for one key and the fake would read an arbitrary one"
fi
scenario_with
if [[ "$(cat "${SCENARIO}")" == "$(cat "${BASE_SCENARIO}")" ]]; then
  ok "scenario_with with no arguments restores the pristine baseline"
else
  meta_failure "scenario_with with no arguments restores the pristine baseline" \
    "state leaks between cases; a case would depend on test order"
fi
# The harness must actually reach the gate. This assertion catches broken env
# plumbing, a wrong SCRIPT path, or a fixture the gate cannot see -- every one of
# which would otherwise make the ~130 behavioural assertions below report
# confidently wrong verdicts.
#
# The output is captured into a variable rather than piped into grep. Under
# `set -o pipefail` a pipeline's status is the worst of its members, so
# `gate 2>&1 | grep -q needle` is non-zero whenever the gate *fails* -- which is
# exactly what this case expects -- and the assertion then reported a correctly
# red gate as an unreachable harness. A failing producer and a matching consumer
# is a normal outcome here, so the two are not combined into one pipeline.
probe="$(env IOS_SMOKE_XCRUN="${WORK_DIR}/xcrun" bash "${SCRIPT}" \
  "${WORK_DIR}/nope-does-not-exist.app" 2>&1)"
if [[ "${probe}" == *"app bundle not found"* ]]; then
  ok "the harness really reaches the gate (a missing bundle is reported as such)"
else
  meta_failure "the harness really reaches the gate (a missing bundle is reported as such)" \
    "the gate said: $(tr '\n' '|' <<<"${probe}" | cut -c1-200)"
fi

# --- fake backend probes ---------------------------------------------------
#
# The gate's backend assertion is fail-closed on BOTH sides: with no probe
# configured it fails, and a probe that cannot answer also fails. That means the
# suite needs probes for every outcome, not just the passing one, or the check
# could be "always fail" and every case would be green for the wrong reason.
# The self-check below proves the happy-path probe actually succeeds, so a
# suite-wide regression to "always fail" is caught.
cat >"${WORK_DIR}/backend-ok" <<'PROBE'
#!/usr/bin/env bash
printf 'galleryd reachable at http://127.0.0.1:8787 (health 200)\n'
exit 0
PROBE
cat >"${WORK_DIR}/backend-unreachable" <<'PROBE'
#!/usr/bin/env bash
printf 'connection refused: no galleryd is listening\n' >&2
exit 7
PROBE
cat >"${WORK_DIR}/backend-silent" <<'PROBE'
#!/usr/bin/env bash
# Exits 0 and says nothing. An empty answer is the answer to no question, so the
# gate must treat it as a failure rather than as a reachable backend.
exit 0
PROBE
cat >"${WORK_DIR}/backend-hang" <<'PROBE'
#!/usr/bin/env bash
sleep 600
PROBE
# Not executable on purpose: an unrunnable probe must not read as a passing one.
cat >"${WORK_DIR}/backend-not-executable" <<'PROBE'
#!/usr/bin/env bash
printf 'would have succeeded\n'
PROBE
chmod +x "${WORK_DIR}/backend-ok" "${WORK_DIR}/backend-unreachable" \
  "${WORK_DIR}/backend-silent" "${WORK_DIR}/backend-hang"
chmod -x "${WORK_DIR}/backend-not-executable"

# Self-check: the happy-path probe must genuinely succeed, or every "the gate can
# go green" assertion below would pass against a permanently-failing gate.
if "${WORK_DIR}/backend-ok" >/dev/null 2>&1; then
  ok "the happy-path backend probe fixture succeeds when run directly"
else
  meta_failure "the happy-path backend probe fixture succeeds when run directly" \
    "the fixture is broken, so a green backend assertion would prove nothing"
fi
if "${WORK_DIR}/backend-unreachable" >/dev/null 2>&1; then
  meta_failure "the failing backend probe fixture fails when run directly" \
    "the fixture is broken, so the failure-path assertions would pass vacuously"
else
  ok "the failing backend probe fixture fails when run directly"
fi

echo " happy path"
expect_pass "installs, cold-launches, renders, and passes" "${WORK_DIR}/Runner.app"

# A universal bundle whose every slice is a simulator slice is the real shape of
# `flutter build ios --simulator` on an Intel runner, so it has to pass.
expect_pass "a universal bundle of only simulator slices passes" "${WORK_DIR}/FatSim.app"

echo " the limitation banner is unmissable"
# The single most important assertion in this suite. A green simulator gate read
# as "iOS is verified" is the failure mode this whole design exists to prevent,
# so the banner is asserted in BOTH a passing and a failing run: a banner that
# only appears on success would be exactly the run where nobody reads it.
if run_smoke_capped "${WORK_DIR}/Runner.app" >"${OUT}" 2>&1; then
  for needle in "iOS **SIMULATOR** GATE" "PROVES NOTHING ABOUT A DEVICE" \
    "Nothing about the device archive" "Apple Developer Program" \
    "notarytool" "LaunchScreen storyboard"; do
    if grep -Fq "${needle}" "${OUT}"; then
      ok "a passing run prints the banner line: ${needle}"
    else
      bad "a passing run prints the banner line: ${needle}" \
        "the green run did not say this: $(tr '\n' '|' <"${OUT}" | cut -c1-200)"
    fi
  done
  # The daemon caveat. This is the primary finding of the whole exercise: the
  # app on iOS has no backend, so a banner that omitted this would let a green
  # run be read as "iOS works".
  for needle in "NO WORKING BACKEND ON iOS" "does not let an app exec a shipped executable" \
    "local_daemon_launcher.dart refuses to try"; do
    if grep -Fq "${needle}" "${OUT}"; then
      ok "a passing run warns that the app has no backend on iOS: ${needle}"
    else
      bad "a passing run warns that the app has no backend on iOS: ${needle}" \
        "the green run did not say this: $(tr '\n' '|' <"${OUT}" | cut -c1-200)"
    fi
  done
  # And it goes to stderr, so it cannot be lost in a `> log` redirect.
  if run_smoke_capped "${WORK_DIR}/Runner.app" 2>"${WORK_DIR}/banner.err" >/dev/null; then
    if grep -Fq "PROVES NOTHING ABOUT A DEVICE" "${WORK_DIR}/banner.err"; then
      ok "the banner is written to stderr, so a stdout-only redirect cannot lose it"
    else
      bad "the banner is written to stderr, so a stdout-only redirect cannot lose it" \
        "stderr did not carry the banner"
    fi
  else
    bad "the banner is written to stderr, so a stdout-only redirect cannot lose it" \
      "the run failed, so the assertion was not exercised"
  fi
else
  bad "a passing run prints the banner line" \
    "the happy path failed, so the banner assertions are unreachable: $(tr '\n' '|' <"${OUT}" | cut -c1-200)"
fi
scenario_with "INSTALL_FAIL=1"
if run_smoke_capped "${WORK_DIR}/Runner.app" >"${OUT}" 2>&1; then
  bad "a failing run also prints the banner" "the install scenario passed unexpectedly"
else
  if grep -Fq "PROVES NOTHING ABOUT A DEVICE" "${OUT}"; then
    ok "a failing run also prints the banner"
  else
    bad "a failing run also prints the banner" \
      "a red run is the one a reader most needs the warning on, and it was silent: $(tr '\n' '|' <"${OUT}" | cut -c1-200)"
  fi
fi
scenario_with "INSTALL_FAIL="
# The summary is the file a release reader opens, so the scope caveats have to be
# in the file too, not only in the console banner.
scenario_with "SCREENSHOT=${WORK_DIR}/rich.png"
# The run happens HERE rather than being left over from an earlier case:
# `scenario_with` calls `reset_state`, which clears the evidence directory,
# so a summary asserted after a fresh reset with no intervening run is
# always missing, and every assertion below then reports on an empty file.
if run_smoke_capped "${WORK_DIR}/Runner.app" >"${OUT}" 2>&1; then
  ok "a passing run still passes right after the banner assertions"
else
  bad "a passing run still passes right after the banner assertions" \
    "$(tr '\n' '|' <"${OUT}" | cut -c1-200)"
fi
if grep -Fq "SIMULATOR ONLY" "${WORK_DIR}/evidence/case-summary.txt" 2>/dev/null; then
  ok "the evidence summary records the simulator-only scope"
else
  bad "the evidence summary records the simulator-only scope" \
    "got: $(cat "${WORK_DIR}/evidence/case-summary.txt" 2>/dev/null | head -5)"
fi
if grep -Fq "NO WORKING BACKEND ON iOS" "${WORK_DIR}/evidence/case-summary.txt" 2>/dev/null; then
  ok "the evidence summary records that the app has no backend on iOS"
else
  bad "the evidence summary records that the app has no backend on iOS" \
    "got: $(cat "${WORK_DIR}/evidence/case-summary.txt" 2>/dev/null | tr '\n' '|' | cut -c1-200)"
fi
# The summary must name the artifact it judged. An earlier version of the gate
# called `record_summary PASS`, so `app bundle:` recorded the literal string
# "PASS" -- an evidence file that named the wrong artifact while looking
# completely well formed.
if grep -Fq "app bundle: ${WORK_DIR}/Runner.app" "${WORK_DIR}/evidence/case-summary.txt" 2>/dev/null; then
  ok "the evidence summary names the exact bundle it judged"
else
  bad "the evidence summary names the exact bundle it judged" \
    "got: $(grep -F 'app bundle:' "${WORK_DIR}/evidence/case-summary.txt" 2>/dev/null)"
fi

echo " argument and input validation"
if env IOS_SMOKE_XCRUN="${WORK_DIR}/xcrun" FAKE_XCRUN_STATE="${WORK_DIR}" \
  bash "${SCRIPT}" >"${OUT}" 2>&1; then
  bad "no .app argument is a usage error" "exited 0 with no argument"
elif grep -Fq "usage" "${OUT}"; then
  ok "no .app argument is a usage error"
else
  bad "no .app argument is a usage error" "got: $(cat "${OUT}")"
fi
expect_fail "a missing .app path fails fast" "app bundle not found" "${WORK_DIR}/nope.app"
# A missing `xcrun` must be a HARD failure, not a skip. `require_tool` is the only
# thing standing between "this host cannot run the check at all" and a green release, so a
# gate that quietly skips when its tool is absent is exactly the partial-release
# shape. The mutation pass breaks this line by itself.
expect_fail "a missing xcrun fails instead of skipping the gate" \
  "missing required tool" "${WORK_DIR}/Runner.app" "IOS_SMOKE_XCRUN=${WORK_DIR}/no-such-xcrun"
# A threshold that cannot fail would make the blank-screen check decorative. The
# script has to refuse it at startup rather than quietly falling back to a
# default that happens to work.
expect_fail "a colour threshold below 2 is refused, not defaulted" \
  "must be an integer >= 2" "${WORK_DIR}/Runner.app" "IOS_SMOKE_MIN_DISTINCT_COLORS=0"
expect_fail "a non-numeric colour threshold is refused" \
  "must be an integer >= 2" "${WORK_DIR}/Runner.app" "IOS_SMOKE_MIN_DISTINCT_COLORS=lots"
expect_fail "an empty device-name filter is refused rather than matching everything" \
  "IOS_SMOKE_SIM_DEVICE is set but empty" "${WORK_DIR}/Runner.app" "IOS_SMOKE_SIM_DEVICE="
expect_fail "a non-positive dead-poll tolerance is refused" \
  "must be a positive integer" "${WORK_DIR}/Runner.app" "IOS_SMOKE_DEAD_POLL_TOLERANCE=0"

echo " malformed and truncated artifacts fail closed"
# The release job zips the bundle with `ditto`, so a truncated upload reaches CI
# as a small, wrong or empty .app. Every one of these must be a non-zero exit,
# not a silent skip.
: >"${WORK_DIR}/Empty.app"
if run_smoke_capped "${WORK_DIR}/Empty.app" >"${OUT}" 2>&1; then
  bad "a zero-byte .app file is rejected" "exited 0"
else
  ok "a zero-byte .app file is rejected"
fi
mkdir -p "${WORK_DIR}/EmptyDir.app"
expect_fail "an empty .app directory is rejected" "has no Info.plist" "${WORK_DIR}/EmptyDir.app"
# A directory holding an Info.plist but no executable at all.
mkdir -p "${WORK_DIR}/NoExe.app"
cp "${WORK_DIR}/Runner.app/Info.plist" "${WORK_DIR}/NoExe.app/Info.plist"
expect_fail "a bundle with a plist but no executable is rejected" \
  "CFBundleExecutable is missing" "${WORK_DIR}/NoExe.app"
# A truncated Mach-O where a real one should be: the platform cannot be read, so
# it must be a failure rather than an "unknown" that happens to pass.
cp -R "${WORK_DIR}/Runner.app" "${WORK_DIR}/TruncRunner.app"
head -c 20 "${WORK_DIR}/Runner.app/Runner" >"${WORK_DIR}/TruncRunner.app/Runner"
expect_fail "a truncated app executable is rejected" \
  "could not read the Mach-O platform" "${WORK_DIR}/TruncRunner.app"
cp -R "${WORK_DIR}/Runner.app" "${WORK_DIR}/TruncDaemon.app"
head -c 20 "${WORK_DIR}/Runner.app/Frameworks/race" >"${WORK_DIR}/TruncDaemon.app/Frameworks/race"
expect_fail "a truncated native daemon is rejected" \
  "could not read the Mach-O platform" "${WORK_DIR}/TruncDaemon.app"
# An Info.plist that is not a property list at all.
cp -R "${WORK_DIR}/Runner.app" "${WORK_DIR}/JunkPlist.app"
printf 'this is not a plist\n' >"${WORK_DIR}/JunkPlist.app/Info.plist"
expect_fail "an unreadable Info.plist is rejected" \
  "cannot read CFBundleIdentifier" "${WORK_DIR}/JunkPlist.app"
# An Info.plist with no CFBundleExecutable key at all.
cp -R "${WORK_DIR}/Runner.app" "${WORK_DIR}/NoExeKey.app"
python3 - "${WORK_DIR}/NoExeKey.app/Info.plist" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "rb") as handle:
    plist = plistlib.load(handle)
del plist["CFBundleExecutable"]
with open(sys.argv[1], "wb") as handle:
    plistlib.dump(plist, handle)
PY
expect_fail "an Info.plist with no CFBundleExecutable is rejected" \
  "cannot read CFBundleExecutable" "${WORK_DIR}/NoExeKey.app"

echo " the device-slice check (the simulator only runs simulator slices)"
# The direct analogue of the Android arm-ABI check, and the reason it exists:
# `simctl install` cannot accept an iPhoneOS bundle, so a bundle carrying device
# slices must be rejected BEFORE a simulator is touched. If this check were
# removed the gate would boot a simulator, fail to install, and report an install
# failure -- a *true* verdict for the wrong reason, which would not catch a
# bundle that installs but carries a device-slice daemon.
expect_fail "a bundle with only device slices is rejected" \
  "is not a ios-simulator binary" "${WORK_DIR}/Device.app"
expect_fail "a bundle whose app binary is a device slice is rejected even when its daemon is not" \
  "is not a ios-simulator binary" "${WORK_DIR}/HalfDevice.app"
expect_fail "a bundle whose DAEMON is a device slice is rejected even when its app binary is not" \
  "is not a ios-simulator binary" "${WORK_DIR}/DeviceDaemon.app"
# ...and the reason has to name the slice, or the reader cannot tell which
# cross-compile target to go fix.
if run_smoke_capped "${WORK_DIR}/Device.app" >"${WORK_DIR}/slice.log" 2>&1; then
  bad "the slice failure names the platform it found" "the device bundle passed"
else
  if grep -Fq "arm64:ios" "${WORK_DIR}/slice.log" && ! grep -Fq "arm64:ios-simulator" "${WORK_DIR}/slice.log"; then
    ok "the slice failure names the platform it found"
  else
    bad "the slice failure names the platform it found" \
      "expected arm64:ios and no arm64:ios-simulator; got: $(tr '\n' '|' <"${WORK_DIR}/slice.log" | cut -c1-240)"
  fi
fi
expect_fail "a device-slice plugin framework is rejected" \
  "is not a ios-simulator binary" "${WORK_DIR}/BadFramework.app"
# A MIXED universal binary. This is the assertion that "every slice matches" is
# the implemented rule and not "some slice matches": a mixed fat binary
# contains a simulator slice, so an "any slice" check accepts it, and the bundle
# would install and then fail to launch on the device slice.
expect_fail "a universal bundle mixing simulator and device slices is rejected" \
  "is a MIXED binary" "${WORK_DIR}/FatMixed.app"
# The slice check must run before the simulator is touched, so it reports a
# packaging fault rather than a boot or install fault.
if run_smoke_capped "${WORK_DIR}/Device.app" 2>&1 | grep -q "simulator:"; then
  bad "the slice check runs before any simulator is touched" \
    "a simulator was selected before the slice check failed"
else
  ok "the slice check runs before any simulator is touched"
fi

echo " bundle identity and the native daemon"
expect_fail "a bundle declaring a different bundle id is rejected" \
  "refusing to prove the wrong artifact" "${WORK_DIR}/Other.app"
expect_fail "a bundle with no Info.plist is rejected" \
  "has no Info.plist" "${WORK_DIR}/NoPlist.app"
expect_fail "a bundle whose app binary is not executable is rejected" \
  "CFBundleExecutable is not executable" "${WORK_DIR}/NoExecApp.app"
expect_fail "a bundle missing its native daemon is rejected" \
  "the native daemon is missing from the bundle" "${WORK_DIR}/NoDaemon.app"
expect_fail "a bundle whose daemon is not executable is rejected" \
  "the native daemon at Frameworks/race is not executable" "${WORK_DIR}/NoExecDaemon.app"
# A pass must SAY which slices it found, not merely that nothing was missing: a
# reader asking "is this a simulator build?" should be able to answer from the
# evidence without unpacking the bundle themselves.
scenario_with "SCREENSHOT=${WORK_DIR}/rich.png"
expect_pass "the good bundle passes the structural checks" "${WORK_DIR}/Runner.app"
if grep -Fq "the native daemon: " "${WORK_DIR}/evidence/case-bundle.txt" 2>/dev/null &&
  grep -Fq "arm64:ios-simulator" "${WORK_DIR}/evidence/case-bundle.txt" 2>/dev/null; then
  ok "the bundle report records the platform parsed out of each Mach-O"
else
  bad "the bundle report records the platform parsed out of each Mach-O" \
    "got: $(cat "${WORK_DIR}/evidence/case-bundle.txt" 2>/dev/null | tr '\n' '|' | cut -c1-200)"
fi
if grep -Fq "app executable sha256:" "${WORK_DIR}/evidence/case-bundle.txt" 2>/dev/null; then
  ok "the bundle report records a digest of the executables it judged"
else
  bad "the bundle report records a digest of the executables it judged" \
    "got: $(cat "${WORK_DIR}/evidence/case-bundle.txt" 2>/dev/null | tr '\n' '|' | cut -c1-200)"
fi

echo " simulator selection and boot"
scenario_with "DEVICE_JSON=${WORK_DIR}/devices-empty.json"
expect_fail "a machine with no simulator devices fails instead of skipping" \
  "no usable iOS simulator could be selected" "${WORK_DIR}/Runner.app"
scenario_with "DEVICE_JSON=${WORK_DIR}/devices-unavailable.json"
expect_fail "a device marked unavailable is not selected" \
  "no usable iOS simulator could be selected" "${WORK_DIR}/Runner.app"
scenario_with "DEVICE_JSON=${WORK_DIR}/devices-garbage.json"
expect_fail "an unparseable device list is refused rather than read as empty" \
  "no usable iOS simulator could be selected" "${WORK_DIR}/Runner.app"
scenario_with "DEVICE_JSON="
expect_fail "a runtime filter that matches nothing fails and names what is available" \
  "available runtime versions" "${WORK_DIR}/Runner.app" "IOS_SMOKE_SIM_RUNTIME=99.0"
scenario_with "DEVICE_JSON="
# With two runtimes present the newest must win, and the older device must not be
# the one chosen. Without this the selector's ordering is untested.
scenario_with "DEVICE_JSON=${WORK_DIR}/devices-three-runtimes.json"
if run_smoke_capped "${WORK_DIR}/Runner.app" >"${WORK_DIR}/newest.log" 2>&1; then
  ok "the newest available iOS runtime is selected"
else
  bad "the newest available iOS runtime is selected" \
    "got: $(tr '\n' '|' <"${WORK_DIR}/newest.log" | cut -c1-200)"
fi
if grep -Fq "NEWEST-333" "${WORK_DIR}/newest.log" &&
  ! grep -Fq "OLDEST-111" "${WORK_DIR}/newest.log" &&
  ! grep -Fq "MIDDLE-222" "${WORK_DIR}/newest.log"; then
  ok "the device from an older runtime is not selected"
else
  bad "the device from an older runtime is not selected" \
    "got: $(grep -E 'simulator:' "${WORK_DIR}/newest.log" | cut -c1-160)"
fi
scenario_with

# A simulator that never leaves "Booting" must hit a deadline and fail with a
# message, never hang. Run under the per-invocation cap so a mutation that
# removed the deadline shows up as a failure here rather than a hung suite.
scenario_with "DEVICE_JSON=${WORK_DIR}/devices-never-boots.json" "BOOT_NEVER=1"
expect_fail "a simulator that never boots fails on the deadline instead of hanging" \
  "never reached state Booted" "${WORK_DIR}/Runner.app"
# ...and a wedged `bootstatus` is the one command that can block forever, so it
# has its own deadline. This is the case a plain `simctl bootstatus` hangs on.
scenario_with "DEVICE_JSON=${WORK_DIR}/devices-prebooted.json" "BOOTSTATUS_FAIL=1"
if SMOKE_BOOT_TIMEOUT=4 SMOKE_CAP=60 run_smoke_capped "${WORK_DIR}/Runner.app" >"${OUT}" 2>&1; then
  bad "a wedged simctl bootstatus times out instead of hanging the job" \
    "exited 0; the gate did not enforce its own deadline"
else
  if grep -Fq "bootstatus did not complete" "${OUT}"; then
    ok "a wedged simctl bootstatus times out instead of hanging the job"
  else
    bad "a wedged simctl bootstatus times out instead of hanging the job" \
      "failed for the wrong reason: $(tr '\n' '|' <"${OUT}" | cut -c1-200)"
  fi
fi
scenario_with "DEVICE_JSON=" "BOOTSTATUS_FAIL="
# An already-booted device is the normal case on a warm runner: `simctl boot`
# errors on it, and that error must not be mistaken for a boot failure.
scenario_with "DEVICE_JSON=${WORK_DIR}/devices-prebooted.json" "BOOT_STATE_ERROR=1"
if run_smoke_capped "${WORK_DIR}/Runner.app" >"${WORK_DIR}/prebooted.log" 2>&1; then
  ok "an already-booted simulator does not fail the gate on simctl boot's error"
else
  bad "an already-booted simulator does not fail the gate on simctl boot's error" \
    "got: $(tr '\n' '|' <"${WORK_DIR}/prebooted.log" | cut -c1-200)"
fi
# And the device list has to be polled for real state, not read once. If the
# gate captured the state before the boot it would either never see Booted (a
# false negative on a healthy simulator) or accept a device that never booted.
scenario_with "DEVICE_JSON=${WORK_DIR}/devices-prebooted.json" "BOOT_STATE_ERROR="
if run_smoke_capped "${WORK_DIR}/Runner.app" >/dev/null 2>&1; then
  ok "a simulator already at Booted passes the boot wait"
else
  bad "a simulator already at Booted passes the boot wait" \
    "the boot poll is not reading live device state"
fi

echo " install failures"
scenario_with "INSTALL_FAIL=1" "INSTALL_UNSIGNED=0"
expect_fail "a rejected install fails the gate" \
  "not installable on the simulator" "${WORK_DIR}/Runner.app"
# The retry is scoped to signature failures, so a plain rejection must NOT reach
# it. If it did, the warning below would appear in this run's log.
if run_smoke_capped "${WORK_DIR}/Runner.app" >"${WORK_DIR}/plain-install.log" 2>&1; then
  bad "a non-signature install failure does not trigger the --no-verify retry" \
    "the gate passed a rejected install"
else
  if grep -Fq "no-verify" "${WORK_DIR}/plain-install.log"; then
    bad "a non-signature install failure does not trigger the --no-verify retry" \
      "the retry ran on a non-signature failure, so the classification is not doing its job"
  else
    ok "a non-signature install failure does not trigger the --no-verify retry"
  fi
  if grep -Fq "No such file" "${WORK_DIR}/plain-install.log"; then
    ok "a non-signature install failure is diagnosed from its own message"
  else
    bad "a non-signature install failure is diagnosed from its own message" \
      "got: $(tr '\n' '|' <"${WORK_DIR}/plain-install.log" | cut -c1-200)"
  fi
fi
# An unsigned bundle is a real outcome: the release job builds --no-codesign. The
# retry must be reached, must be announced, and must still be judged strictly.
scenario_with "INSTALL_FAIL=1" "INSTALL_UNSIGNED=1" "INSTALL_NOVERIFY_FAIL=0"
if run_smoke_capped "${WORK_DIR}/Runner.app" >"${WORK_DIR}/unsigned.log" 2>&1; then
  ok "an unsigned bundle installs via the announced --no-verify retry"
else
  bad "an unsigned bundle installs via the announced --no-verify retry" \
    "got: $(tr '\n' '|' <"${WORK_DIR}/unsigned.log" | cut -c1-200)"
fi
if grep -Fq "::warning::simctl install rejected the bundle as unsigned" "${WORK_DIR}/unsigned.log" 2>/dev/null; then
  ok "the unsigned retry is announced as a workflow warning, not done silently"
else
  bad "the unsigned retry is announced as a workflow warning, not done silently" \
    "got: $(tr '\n' '|' <"${WORK_DIR}/unsigned.log" | cut -c1-200)"
fi
scenario_with "INSTALL_FAIL=1" "INSTALL_UNSIGNED=1" "INSTALL_NOVERIFY_FAIL=1"
expect_fail "an unsigned bundle that also fails --no-verify fails the gate" \
  "with or without --no-verify" "${WORK_DIR}/Runner.app"
# Exit 0 but not actually installed. simctl's exit status cannot be the only
# signal, or a silently-not-installed bundle reads as a pass.
scenario_with "INSTALL_FAIL=0" "INSTALLED=0"
expect_fail "an install that exits 0 without registering the app is rejected" \
  "not installed on" "${WORK_DIR}/Runner.app"
scenario_with "INSTALLED=" "INSTALL_FAIL="

echo " launch failures"
scenario_with "LAUNCH_FAIL=1"
expect_fail "a launch simctl refuses fails the gate" "simctl launch failed" "${WORK_DIR}/Runner.app"
scenario_with "LAUNCH_FAIL="
scenario_with "LAUNCH_NO_PID=1"
expect_fail "a launch that reports no pid is not believed" "reported no usable pid" "${WORK_DIR}/Runner.app"
scenario_with "LAUNCH_NO_PID="
# A pid of zero is not a pid. `simctl launch` printing "<id>: 0" would otherwise
# sail past the numeric test and leave the liveness checks nothing to attribute.
scenario_with "PID=0"
expect_fail "a launch reporting pid 0 is not believed" "reported no usable pid" "${WORK_DIR}/Runner.app"
scenario_with "PID=4242"

# "Cold launch" has to mean cold. A device where the app is somehow already alive
# would skip the code path most likely to be broken, and the word "cold" in the
# log would be a lie.
scenario_with "RUNNING_BEFORE_LAUNCH=1"
expect_fail "an app that is already running is not a cold launch" \
  "already running" "${WORK_DIR}/Runner.app"
scenario_with "RUNNING_BEFORE_LAUNCH="

echo " launch arguments (debug-session injection)"
# The gate exists to prove the app reaches a backend, and on iOS the only path
# that lets a simulator build be pointed at one is extra `simctl launch` argv:
# AppDelegate serves them over its debug-only channel. If the gate drops or
# mangles those arguments the app opens bare and the backend probe can never be
# satisfied, so each property here is asserted against the argv `simctl launch`
# actually received, not against a comment.
# Read the recorded argv as one marked line per argument. A plain `cat` would
# strip a TRAILING blank line, which is exactly where a stray empty argument
# hides: `simctl launch udid bundle ""` records `udid\nbundle\n\n`, and command
# substitution collapses that back to `udid\nbundle`, so the empty argument
# reads as absent. The marker keeps an empty argument visible, which is what
# makes the two "no extra argument" cases below load-bearing.
launch_argv_recorded() {
  sed -e 's/^/arg:/' "${WORK_DIR}/.launch-args" 2>/dev/null || printf ''
}

scenario_with "SCREENSHOT=${WORK_DIR}/rich.png"
if run_smoke_capped "${WORK_DIR}/Runner.app" \
  "IOS_SMOKE_LAUNCH_ARGUMENTS=--private-gallery-desktop-url http://127.0.0.1:4821 --private-gallery-bearer-token tok123" \
  >"${OUT}" 2>&1; then
  recorded="$(launch_argv_recorded)"
  expected="$(printf 'arg:%s\n' "${SIM_UDID}" "${BUNDLE_ID}" \
    --private-gallery-desktop-url "http://127.0.0.1:4821" \
    --private-gallery-bearer-token tok123)"
  if [[ "${recorded}" == "${expected}" ]]; then
    ok "a configured debug session is passed to simctl launch verbatim, in order"
  else
    bad "a configured debug session is passed to simctl launch verbatim, in order" \
      "expected argv [$(tr '\n' ' ' <<<"${expected}")]; got [$(tr '\n' ' ' <<<"${recorded}")]"
  fi
else
  bad "a configured debug session is passed to simctl launch verbatim, in order" \
    "the gate failed: $(cat "${OUT}")"
fi

scenario_with "SCREENSHOT=${WORK_DIR}/rich.png"
if run_smoke_capped "${WORK_DIR}/Runner.app" >"${OUT}" 2>&1; then
  recorded="$(launch_argv_recorded)"
  expected="$(printf 'arg:%s\n' "${SIM_UDID}" "${BUNDLE_ID}")"
  if [[ "${recorded}" == "${expected}" ]]; then
    ok "no debug session means simctl launch receives no extra argument"
  else
    bad "no debug session means simctl launch receives no extra argument" \
      "expected argv [$(tr '\n' ' ' <<<"${expected}")]; got [$(tr '\n' ' ' <<<"${recorded}")]"
  fi
else
  bad "no debug session means simctl launch receives no extra argument" \
    "the gate failed: $(cat "${OUT}")"
fi

scenario_with "SCREENSHOT=${WORK_DIR}/rich.png"
if run_smoke_capped "${WORK_DIR}/Runner.app" "IOS_SMOKE_LAUNCH_ARGUMENTS= " >"${OUT}" 2>&1; then
  recorded="$(launch_argv_recorded)"
  expected="$(printf 'arg:%s\n' "${SIM_UDID}" "${BUNDLE_ID}")"
  if [[ "${recorded}" == "${expected}" ]]; then
    ok "a whitespace-only debug session does not become a stray empty argument"
  else
    bad "a whitespace-only debug session does not become a stray empty argument" \
      "expected argv [$(tr '\n' ' ' <<<"${expected}")]; got [$(tr '\n' ' ' <<<"${recorded}")]"
  fi
else
  bad "a whitespace-only debug session does not become a stray empty argument" \
    "the gate failed: $(cat "${OUT}")"
fi

scenario_with "RUNNING=0"
expect_fail "an app that never appears in launchd fails" \
  "is not running" "${WORK_DIR}/Runner.app"
scenario_with "RUNNING=1"

# A device that cannot answer the liveness question is NOT a running app, and
# must not be reported as one.
scenario_with "SPAWN_FAIL=launchctl list"
expect_fail "an unreadable launchd listing fails rather than reading as a clean device" \
  "is not running" "${WORK_DIR}/Runner.app"
scenario_with "SPAWN_FAIL="

echo " rendering"
scenario_with "SCREENSHOT=${WORK_DIR}/blank.png"
expect_fail "a blank screen counts as never rendered" "no settled app frame" "${WORK_DIR}/Runner.app"
scenario_with

scenario_with "SCREENSHOT=${WORK_DIR}/garbage.png"
expect_fail "an undecodable screenshot counts as never rendered" "no settled app frame" "${WORK_DIR}/Runner.app"
scenario_with

# A screen that never settles -- every capture differs. A gate that accepts the
# first complex frame is accepting whatever the engine happened to be drawing
# mid-transition.
scenario_with "SCREENSHOT=${WORK_DIR}/rich.png" \
  "SCREENSHOT_DRIFT=1" "SCREENSHOT_DRIFT_ALT=${WORK_DIR}/rich-drift.png"
if ! grep -q "SCREENSHOT_DRIFT" "${WORK_DIR}/xcrun"; then
  # The fake has no drift mechanism, so the scenario below would be
  # indistinguishable from the passing case and would prove nothing. Fail loudly
  # rather than reporting a pass that tested nothing.
  bad "the fake xcrun really alternates two different frames (it has no drift mechanism)" \
    "SCREENSHOT_DRIFT is unmodelled, so the never-settling test would be vacuous"
else
  ok "the fake xcrun really alternates two different frames (it has no drift mechanism)"
fi
if cmp -s "${WORK_DIR}/rich.png" "${WORK_DIR}/rich-drift.png"; then
  bad "the never-settling fixture really alternates between two different frames" \
    "rich.png and rich-drift.png are byte-identical"
else
  ok "the never-settling fixture really alternates between two different frames"
fi
expect_fail "a screen that never settles counts as never rendered" \
  "no settled app frame" "${WORK_DIR}/Runner.app"
scenario_with

echo " an app that dies"
# Death DURING the render wait: the app is alive at launch, so it passes the
# launch checks, and gone by the time the gate is waiting for a frame.
scenario_with "DEATH_AFTER_SCREENSHOTS=1"
expect_fail "an app that dies during the render wait fails" \
  "died while rendering" "${WORK_DIR}/Runner.app"
scenario_with "DEATH_AFTER_SCREENSHOTS="
# Death AFTER a settled frame: the render wait succeeds, and only the post-render
# liveness re-check can catch this. Without it the gate would pass on the
# strength of checks that happened before the crash.
scenario_with "DEATH_AFTER_SCREENSHOTS=2"
# The run's own stdout is captured, not just its exit status, because the frame
# acceptance is logged there and nowhere else: `case-log.txt` is the SIMULATOR's
# app log pulled with `simctl spawn log`, which is a different stream entirely and
# never contains the gate's own progress lines.
if run_smoke_capped "${WORK_DIR}/Runner.app" >"${WORK_DIR}/death2.log" 2>&1; then
  bad "an app that dies after painting a frame still fails" \
    "the run exited 0: a late crash is invisible to this gate"
elif grep -Fq "died while rendering" "${WORK_DIR}/death2.log"; then
  ok "an app that dies after painting a frame still fails"
else
  bad "an app that dies after painting a frame still fails" \
    "gate said: $(gate_errors "${WORK_DIR}/death2.log")"
fi
# The frame must genuinely have been accepted BEFORE the death, otherwise this
# case is a duplicate of the N=1 one above and the post-render re-check is
# untested -- it would be passing on a run that never painted anything.
if grep -Fq "settled frame:" "${WORK_DIR}/death2.log"; then
  ok "the death-after-frame case really settled a frame before the app died"
else
  bad "the death-after-frame case really settled a frame before the app died" \
    "the post-render liveness re-check was reached with no frame in hand, so it proved nothing"
fi
scenario_with "DEATH_AFTER_SCREENSHOTS="
# A frame IS captured in the death-during-render case, so the fixture must
# genuinely paint something -- otherwise the test would pass for the wrong reason
# (a blank screen, not a dead app).
#
# The setting goes in the SCENARIO, not in the gate's environment. The fake reads
# a scenario file, so passing it as an env assignment reached only the gate --
# which ignores it -- and the app never died, so the run passed and this
# meta-assertion reported "the scenario passed".
scenario_with "DEATH_AFTER_SCREENSHOTS=1"
if run_smoke_capped "${WORK_DIR}/Runner.app" >"${WORK_DIR}/death.log" 2>&1; then
  bad "the death-during-render case really painted a frame first" "the scenario passed"
else
  if grep -Fq "not yet visually complex" "${WORK_DIR}/death.log"; then
    bad "the death-during-render case really painted a frame first" \
      "the frame was blank, so this case tested the blank-screen path instead of the death path"
  else
    ok "the death-during-render case really painted a frame first"
  fi
fi
# ...and it must have died for the RIGHT reason. With N=1 the app is already gone
# by the SECOND poll, so the gate never gets two identical captures and the run
# never settles a frame -- requiring "settled frame:" here would demand the
# impossible. The distinction that actually matters is which check reported the
# failure: the liveness poll must, not the render deadline. A blank screen
# produces the same exit status, which is why the message is asserted.
if grep -Fq "died while rendering" "${WORK_DIR}/death.log" &&
  ! grep -Fq "no settled app frame" "${WORK_DIR}/death.log"; then
  ok "the death-during-render case is reported by the liveness poll, not by the render deadline"
else
  bad "the death-during-render case is reported by the liveness poll, not by the render deadline" \
    "gate said: $(gate_errors "${WORK_DIR}/death.log")"
fi
scenario_with "DEATH_AFTER_SCREENSHOTS="

echo " crash reports"
# The platform's own crash records, compared against a pre-launch baseline. A
# report for the app is a failure; a pre-existing report on the runner is not.
# The scenario is set FIRST and the report written SECOND. `scenario_with` calls
# `reset_state`, which deletes every .ips in the crash directory, so a report
# created before it is gone by the time the gate runs -- and the run then passes
# because there was never a report to find. The assertion that follows, which
# checks the baseline counted it, exists precisely to catch that mistake.
scenario_with "SCREENSHOT=${WORK_DIR}/rich.png"
make_ips "${CRASH_DIR}/Runner-2026-09-30-000000.ips" "Runner" "${BUNDLE_ID}"
if run_smoke_capped "${WORK_DIR}/Runner.app" >"${WORK_DIR}/preexisting.log" 2>&1; then
  ok "a crash report that predates the launch does not fail the gate"
else
  bad "a crash report that predates the launch does not fail the gate" \
    "the baseline comparison is not working: $(tr '\n' '|' <"${WORK_DIR}/preexisting.log" | cut -c1-200)"
fi
# ...and the baseline must have actually seen it. A baseline captured from the
# wrong directory would also report zero new reports, so "no failure" alone is
# not enough.
if grep -Fq "pre-launch reports: 1" "${WORK_DIR}/evidence/case-crash-reports.txt" 2>/dev/null; then
  ok "the crash baseline actually counted the pre-existing report"
else
  bad "the crash baseline actually counted the pre-existing report" \
    "got: $(cat "${WORK_DIR}/evidence/case-crash-reports.txt" 2>/dev/null | tr '\n' '|' | cut -c1-200)"
fi
scenario_with
rm -f "${CRASH_DIR}"/*.ips

# A report that appears DURING the launch window, attributed to the app.
#
# Every case below names a fixture via CRASH_ON_LAUNCH, which the fake copies
# into the crash directory WHEN simctl launch runs -- i.e. after the gate has
# already taken its baseline. Writing the report up front instead would make the
# gate classify it as pre-existing and pass, which is correct gate behaviour and
# the wrong test: every "new report" case would silently degrade into a repeat of
# the baseline case above.
#
# CRASH_DIES=0 for the attribution cases below, and that is deliberate. A report
# attributed to the app plus a dead process is caught EARLIER, by the launch
# liveness wait, so a case that models both is verifying that wait rather than
# the crash-report comparison -- and it did, until the needle was corrected. The
# crash-report path is reached only by a report that appears while the process is
# still alive, which is what CRASH_DIES=0 models: a report written during the
# launch window for a process the device still lists as running.
scenario_with "CRASH_ON_LAUNCH=${WORK_DIR}/crash-runner.ips" "CRASH_DIES=0"
expect_fail "a crash report for the app fails the gate" \
  "crash report(s) for" "${WORK_DIR}/Runner.app"
# The run must genuinely produce a NEW report, or the assertion above would pass
# on a crash check that never fired.
if grep -Fq "new reports during the launch window: 1" \
  "${WORK_DIR}/evidence/case-crash-reports.txt" 2>/dev/null &&
  grep -Fq "attributed to ${BUNDLE_ID}: 1" \
    "${WORK_DIR}/evidence/case-crash-reports.txt" 2>/dev/null; then
  ok "a mid-window crash is counted as a new report attributed to the app"
else
  bad "a mid-window crash is counted as a new report attributed to the app" \
    "evidence said: $(tr '\n' '|' <"${WORK_DIR}/evidence/case-crash-reports.txt" 2>/dev/null | cut -c1-240)"
fi
scenario_with
# The other real crash shape: the process dies on start, so the launch liveness
# wait catches it before the report is ever compared. This is asserted separately
# because it is a different check firing, and a reader who sees only the
# attribution cases would not know the liveness path was covered at all.
scenario_with "CRASH_ON_LAUNCH=${WORK_DIR}/crash-runner.ips" "CRASH_DIES=1"
expect_fail "an app that crashes on start fails the launch liveness wait" \
  "crash on start" "${WORK_DIR}/Runner.app"
scenario_with

# Attribution on either header field. See the fixture comment.
scenario_with "CRASH_ON_LAUNCH=${WORK_DIR}/crash-renamed-proc.ips" "CRASH_DIES=0"
expect_fail "a crash report is attributed by bundle id even under another process name" \
  "crash report(s) for" "${WORK_DIR}/Runner.app"
scenario_with
scenario_with "CRASH_ON_LAUNCH=${WORK_DIR}/crash-other-bundle.ips" "CRASH_DIES=0"
expect_fail "a crash report is attributed by process name even under another bundle id" \
  "crash report(s) for" "${WORK_DIR}/Runner.app"
scenario_with

# An unrelated process crashing on the runner is not our app crashing. It must
# be reported (a runner with random crashes is worth knowing about) but must not
# fail the gate. CRASH_DIES=0 because the app is unaffected.
scenario_with "CRASH_ON_LAUNCH=${WORK_DIR}/crash-other.ips" "CRASH_DIES=0"
if run_smoke_capped "${WORK_DIR}/Runner.app" >"${WORK_DIR}/unrelated.log" 2>&1; then
  ok "an unrelated runner crash report does not fail the gate"
else
  bad "an unrelated runner crash report does not fail the gate" \
    "got: $(tr '\n' '|' <"${WORK_DIR}/unrelated.log" | cut -c1-200)"
fi
# Recorded as a count, so a reviewer can see it was classified rather than missed.
if grep -Fq "new reports during the launch window: 1" \
  "${WORK_DIR}/evidence/case-crash-reports.txt" 2>/dev/null &&
  grep -Fq "unrelated runner processes: 1" \
    "${WORK_DIR}/evidence/case-crash-reports.txt" 2>/dev/null &&
  grep -Fq "attributed to ${BUNDLE_ID}: 0" \
    "${WORK_DIR}/evidence/case-crash-reports.txt" 2>/dev/null; then
  ok "an unrelated crash report is counted separately, not attributed to the app"
else
  bad "an unrelated crash report is counted separately, not attributed to the app" \
    "evidence said: $(tr '\n' '|' <"${WORK_DIR}/evidence/case-crash-reports.txt" 2>/dev/null | cut -c1-240)"
fi
scenario_with
rm -f "${CRASH_DIR}"/*.ips

# A report this gate cannot parse cannot be cleared of suspicion. Treating it as
# clean is the exact false-pass shape the whole crash check exists to prevent.
scenario_with "CRASH_ON_LAUNCH=${WORK_DIR}/crash-garbage.ips" "CRASH_DIES=0"
expect_fail "an unparseable crash report is treated as a crash, not as clean" \
  "could not attribute" "${WORK_DIR}/Runner.app"
scenario_with
rm -f "${CRASH_DIR}"/*.ips

# The machine cannot answer, so no crash check can run at all. An empty listing
# would read as "no crashes", which is the answer to a question never asked.
if run_smoke_capped "${WORK_DIR}/Runner.app" \
  "IOS_SMOKE_CRASH_DIR=${WORK_DIR}/no-such-crash-dir" >"${WORK_DIR}/nocrashdir.log" 2>&1; then
  bad "a missing crash-report directory fails instead of skipping the crash check" \
    "passed: without that directory there is no crash verification at all"
else
  if grep -Fq "crash-report directory" "${WORK_DIR}/nocrashdir.log"; then
    ok "a missing crash-report directory fails instead of skipping the crash check"
  else
    bad "a missing crash-report directory fails instead of skipping the crash check" \
      "failed for the wrong reason: $(tr '\n' '|' <"${WORK_DIR}/nocrashdir.log" | cut -c1-200)"
  fi
fi

echo " a machine that cannot answer is not a clean machine"
# Every gate in this script either parses a string or compares against an empty
# one, so a dead xcrun is the case that most easily produces a FALSE PASS. These
# are the assertions that make it a failure instead.
scenario_with "XCRUN_FAIL=list devices"
# Two different failure modes with two different messages, and the needle has to
# name the right one. `XCRUN_FAIL=list devices` kills the xcrun call, so the
# gate cannot even READ the list; a list that reads fine but contains nothing
# usable is the separate case exercised by the DEVICE_JSON fixtures above. Using
# the "no usable simulator could be selected" needle here verified the wrong
# failure path, and would have stayed green if that path were deleted.
expect_fail "an unreadable device list fails rather than selecting nothing quietly" \
  "could not read the available simulator devices" "${WORK_DIR}/Runner.app"
scenario_with "XCRUN_FAIL="
scenario_with "XCRUN_FAIL=bootstatus"
expect_fail "a bootstatus that cannot be answered fails rather than reading as booted" \
  "bootstatus did not complete" "${WORK_DIR}/Runner.app"
scenario_with "XCRUN_FAIL="
scenario_with "XCRUN_FAIL=install"
expect_fail "an install that could not be attempted fails the gate" \
  "not installable on the simulator" "${WORK_DIR}/Runner.app"
scenario_with "XCRUN_FAIL="
scenario_with "XCRUN_FAIL=launch"
expect_fail "a launch that could not be attempted fails the gate" \
  "simctl launch failed" "${WORK_DIR}/Runner.app"
scenario_with "XCRUN_FAIL="
scenario_with "XCRUN_FAIL=io"
expect_fail "a screenshot that could not be captured fails rather than reading as clean" \
  "no settled app frame" "${WORK_DIR}/Runner.app"
scenario_with "XCRUN_FAIL="
# The gate must never claim a launch it could not perform. `get_app_container` is
# the gate's independent confirmation that the install landed; if that read
# cannot happen, the install has to be treated as unconfirmed.
scenario_with "XCRUN_FAIL=get_app_container"
expect_fail "an install that cannot be independently confirmed fails the gate" \
  "not installable on the simulator" "${WORK_DIR}/Runner.app"
scenario_with "XCRUN_FAIL="

echo " the artifact has to be able to DO something"
#
# The headline finding. Everything above proves the bundle installs, cold-launches
# and paints a settled frame -- all four of which are also true of a UI shell with
# no backend behind it. This app's only backend is the Rust daemon copied into
# Frameworks/race, iOS forbids an app from spawning a child process, and
# local_daemon_launcher.dart:24-32 returns attempted:false on every non-desktop
# platform. So the gate must FAIL on a healthy render, and it must say why.
#
# The default suite env supplies a probe that succeeds, so the pass/fail
# assertions above are unaffected; the cases below remove or break it.

# With no probe at all, nothing can establish a reachable backend.
if run_smoke_capped "${WORK_DIR}/Runner.app" "IOS_SMOKE_BACKEND_PROBE=" \
  >"${WORK_DIR}/noprobe.log" 2>&1; then
  bad "an artifact with no demonstrable backend fails the gate" \
    "the gate PASSED an artifact whose only backend cannot be reached on iOS"
else
  ok "an artifact with no demonstrable backend fails the gate"
fi
# ...and for the RIGHT reason: it must get all the way through the render and
# then fail on the backend, not short-circuit somewhere earlier and leave the
# reader guessing which check rejected it.
if grep -Fq "did not crash on" "${WORK_DIR}/noprobe.log" &&
  grep -Fq "cannot be shown to reach a backend" "${WORK_DIR}/noprobe.log"; then
  ok "the no-backend failure happens AFTER install, launch and render"
else
  bad "the no-backend failure happens AFTER install, launch and render" \
    "gate said: $(gate_errors "${WORK_DIR}/noprobe.log")"
fi
# The message has to name both independent reasons, because either one alone
# could be fixed and the other would still leave the artifact broken.
if grep -Fq "local_daemon_launcher.dart" "${WORK_DIR}/noprobe.log" &&
  grep -Fq "cannot be shown to reach a backend" "${WORK_DIR}/noprobe.log"; then
  ok "the no-backend failure names the launcher that refuses to spawn it"
else
  bad "the no-backend failure names the launcher that refuses to spawn it" \
    "gate said: $(gate_errors "${WORK_DIR}/noprobe.log")"
fi
# A failing render must NOT be reported as a backend failure, or the two failure
# classes become indistinguishable. Here the render genuinely fails and the
# backend check must not be the thing that reported it.
scenario_with "SCREENSHOT=${WORK_DIR}/blank.png"
if run_smoke_capped "${WORK_DIR}/Runner.app" "IOS_SMOKE_BACKEND_PROBE=" \
  >"${WORK_DIR}/blankfirst.log" 2>&1; then
  bad "a render failure is reported as a render failure, not as a backend failure" \
    "exited 0"
else
  if grep -Fq "no settled app frame" "${WORK_DIR}/blankfirst.log" &&
    ! grep -Fq "cannot be shown to reach a backend" "${WORK_DIR}/blankfirst.log"; then
    ok "a render failure is reported as a render failure, not as a backend failure"
  else
    bad "a render failure is reported as a render failure, not as a backend failure" \
      "gate said: $(gate_errors "${WORK_DIR}/blankfirst.log")"
  fi
fi
scenario_with

# A probe that runs and reports failure.
expect_fail "a backend probe that reports unreachable fails the gate" \
  "the backend probe did not succeed" "${WORK_DIR}/Runner.app" \
  "IOS_SMOKE_BACKEND_PROBE=${WORK_DIR}/backend-unreachable"
# A probe that succeeds but says nothing: an empty answer is the answer to no
# question, so exit 0 alone must not be believed.
expect_fail "a backend probe that exits 0 with no output fails the gate" \
  "exited 0 but printed nothing" "${WORK_DIR}/Runner.app" \
  "IOS_SMOKE_BACKEND_PROBE=${WORK_DIR}/backend-silent"
# A probe that cannot be executed at all.
expect_fail "a backend probe that is not executable fails the gate" \
  "the backend probe is not executable" "${WORK_DIR}/Runner.app" \
  "IOS_SMOKE_BACKEND_PROBE=${WORK_DIR}/backend-not-executable"
# A probe that never returns. Under a deadline, or it hangs the release job.
if run_smoke_capped "${WORK_DIR}/Runner.app" \
  "IOS_SMOKE_BACKEND_PROBE=${WORK_DIR}/backend-hang" \
  "IOS_SMOKE_BACKEND_TIMEOUT_SECONDS=4" >"${WORK_DIR}/hangprobe.log" 2>&1; then
  bad "a backend probe that hangs is cut off by the gate's own deadline" \
    "exited 0; the deadline is not enforced"
else
  if grep -Fq "the backend probe did not succeed" "${WORK_DIR}/hangprobe.log"; then
    ok "a backend probe that hangs is cut off by the gate's own deadline"
  else
    bad "a backend probe that hangs is cut off by the gate's own deadline" \
      "gate said: $(gate_errors "${WORK_DIR}/hangprobe.log")"
  fi
fi

# The verdict must not read PASS while the backend is unproven. An earlier
# version wrote `result: PASS` before the backend question was even asked, so
# the evidence file asserted a verdict the run had not earned.
scenario_with "SCREENSHOT=${WORK_DIR}/rich.png"
run_smoke_capped "${WORK_DIR}/Runner.app" "IOS_SMOKE_BACKEND_PROBE=" >"${WORK_DIR}/np2.log" 2>&1 || true
failing_results="$(grep -c '^result:' "${WORK_DIR}/evidence/case-summary.txt" 2>/dev/null || printf 0)"
if grep -Fq "result: RENDER-ONLY" "${WORK_DIR}/evidence/case-summary.txt" 2>/dev/null &&
  ! grep -Fq "result: PASS" "${WORK_DIR}/evidence/case-summary.txt" 2>/dev/null &&
  [[ "${failing_results}" == "1" ]]; then
  ok "the summary verdict is RENDER-ONLY, never PASS, when the backend is unproven"
else
  bad "the summary verdict is RENDER-ONLY, never PASS, when the backend is unproven" \
    "${failing_results} 'result:' line(s): $(grep -F 'result:' "${WORK_DIR}/evidence/case-summary.txt" 2>/dev/null | tr '\n' '|')"
fi
# A failing run must still leave the evidence needed to diagnose it.
if [[ -s "${WORK_DIR}/evidence/case-backend.txt" ]] &&
  grep -Fq "does NOT establish that it can be SPAWNED" "${WORK_DIR}/evidence/case-backend.txt" 2>/dev/null; then
  ok "a failing run still writes backend evidence explaining what was not proven"
else
  bad "a failing run still writes backend evidence explaining what was not proven" \
    "evidence said: $(tr '\n' '|' <"${WORK_DIR}/evidence/case-backend.txt" 2>/dev/null | cut -c1-240)"
fi
# And with a working probe the same artifact DOES go green, which is what proves
# the check above is not just "always fail".
scenario_with "SCREENSHOT=${WORK_DIR}/rich.png"
if run_smoke_capped "${WORK_DIR}/Runner.app" \
  "IOS_SMOKE_BACKEND_PROBE=${WORK_DIR}/backend-ok" >"${WORK_DIR}/probe-ok.log" 2>&1; then
  ok "the same artifact passes once a backend probe actually answers reachable"
else
  bad "the same artifact passes once a backend probe actually answers reachable" \
    "gate said: $(gate_errors "${WORK_DIR}/probe-ok.log")"
fi
if grep -Fq "result: PASS" "${WORK_DIR}/evidence/case-summary.txt" 2>/dev/null; then
  ok "the summary verdict is PASS only when the backend probe answered"
else
  bad "the summary verdict is PASS only when the backend probe answered" \
    "summary said: $(grep -F 'result:' "${WORK_DIR}/evidence/case-summary.txt" 2>/dev/null | tr '\n' '|')"
fi
# EXACTLY ONE verdict line. The gate once called `record_summary` twice on a
# passing run -- once as RENDER-ONLY and once as PASS -- which put two
# contradictory `result:` lines in one evidence file with no indication of which
# was the verdict. A summary that can be read both ways is not evidence.
result_lines="$(grep -c '^result:' "${WORK_DIR}/evidence/case-summary.txt" 2>/dev/null || printf 0)"
if [[ "${result_lines}" == "1" ]]; then
  ok "the summary states its verdict exactly once"
else
  bad "the summary states its verdict exactly once" \
    "found ${result_lines} 'result:' lines: $(grep -F 'result:' "${WORK_DIR}/evidence/case-summary.txt" 2>/dev/null | tr '\n' '|')"
fi

echo " evidence"
scenario_with "SCREENSHOT=${WORK_DIR}/rich.png"
expect_pass "a passing run writes evidence" "${WORK_DIR}/Runner.app"
# The screenshot filename is fixed by issue #98's acceptance criteria
# ("per-platform and machine-readable, e.g. ios-home.png"), so a rename that
# breaks the contract has to fail rather than be noticed downstream.
if [[ -s "${WORK_DIR}/evidence/ios-home.png" ]]; then
  ok "the screenshot is written as the machine-readable ios-home.png"
else
  bad "the screenshot is written as the machine-readable ios-home.png" \
    "got: $(ls -1 "${WORK_DIR}/evidence" 2>/dev/null | tr '\n' '|')"
fi
# `case-crash-baseline.txt` is deliberately EXCLUDED from the non-empty check.
# On a runner with no pre-existing reports -- which is every clean CI run --
# the baseline listing is an empty file by construction, so `-s` would fail
# against a perfectly correct gate. Its existence is asserted below, and what
# it actually contains is bound to a real state difference by the
# "baseline counted the pre-existing report" assertion in the crash section.
for evidence in case-summary.txt case-bundle.txt case-crash-reports.txt \
  case-listapps.txt case-log.txt case-error-log.txt case-backend.txt; do
  if [[ -s "${WORK_DIR}/evidence/${evidence}" ]]; then
    ok "evidence ${evidence} exists and is non-empty"
  else
    bad "evidence ${evidence} exists and is non-empty" \
      "got: $(ls -1 "${WORK_DIR}/evidence" 2>/dev/null | tr '\n' '|')"
  fi
done
if [[ -e "${WORK_DIR}/evidence/case-crash-baseline.txt" ]]; then
  ok "evidence case-crash-baseline.txt exists (empty on a clean runner is correct)"
else
  bad "evidence case-crash-baseline.txt exists (empty on a clean runner is correct)" \
    "got: $(ls -1 "${WORK_DIR}/evidence" 2>/dev/null | tr '\n' '|')"
fi

# `[[ -s ]]` is weak for two of these. In a passing run the crash-report listing
# is legitimately empty and the baseline too, so a size check proves nothing.
# These assertions bind the evidence to a scenario where the pre-launch and
# post-launch states DIFFER, so "the file is non-empty" cannot be satisfied by a
# stub or by the wrong read.
if grep -Fq "pre-launch reports: 0" "${WORK_DIR}/evidence/case-crash-reports.txt" 2>/dev/null &&
  grep -Fq "new reports during the launch window: 0" "${WORK_DIR}/evidence/case-crash-reports.txt" 2>/dev/null; then
  ok "the crash evidence records the pre-launch and post-launch counts separately"
else
  bad "the crash evidence records the pre-launch and post-launch counts separately" \
    "got: $(cat "${WORK_DIR}/evidence/case-crash-reports.txt" 2>/dev/null | tr '\n' '|' | cut -c1-200)"
fi
# All three counters, because a clean run is exactly the case where an omitted
# line is indistinguishable from a line that was never computed. An earlier
# version of the gate appended the counters only on the branch where a new
# report existed, so a clean run produced evidence that never mentioned them
# and "zero crashes" had to be inferred from a line's absence -- the same
# failure shape as the Android gate reading an empty crash buffer as clean.
if grep -Fq "attributed to ${BUNDLE_ID}: 0" "${WORK_DIR}/evidence/case-crash-reports.txt" 2>/dev/null &&
  grep -Fq "unattributable: 0" "${WORK_DIR}/evidence/case-crash-reports.txt" 2>/dev/null &&
  grep -Fq "unrelated runner processes: 0" "${WORK_DIR}/evidence/case-crash-reports.txt" 2>/dev/null; then
  ok "a clean run states all three crash counters explicitly, not by omission"
else
  bad "a clean run states all three crash counters explicitly, not by omission" \
    "got: $(cat "${WORK_DIR}/evidence/case-crash-reports.txt" 2>/dev/null | tr '\n' '|' | cut -c1-200)"
fi
# The app's own log must be the device's log, not something the gate wrote.
if grep -Fq "fake log stream for Runner" "${WORK_DIR}/evidence/case-log.txt" 2>/dev/null; then
  ok "the log evidence is the simulator's actual app log"
else
  bad "the log evidence is the simulator's actual app log" \
    "got: $(cat "${WORK_DIR}/evidence/case-log.txt" 2>/dev/null | cut -c1-160)"
fi
# The fake's app log deliberately contains "not found", and the gate must not
# treat that as a failure. This is the exact false-pass shape that shipped an
# adverse exit green on Android.
if grep -Fq "no settled app frame" "${WORK_DIR}/evidence/case-log.txt" 2>/dev/null; then
  bad "app log text saying 'not found' does not fail the gate" \
    "the log was used as a gate signal"
else
  ok "app log text saying 'not found' does not fail the gate"
fi
if grep -Fq "result: PASS" "${WORK_DIR}/evidence/case-summary.txt" 2>/dev/null; then
  ok "the summary records the verdict"
else
  bad "the summary records the verdict" \
    "got: $(cat "${WORK_DIR}/evidence/case-summary.txt" 2>/dev/null | tr '\n' '|' | cut -c1-200)"
fi
if grep -Fq "launched pid: 4242" "${WORK_DIR}/evidence/case-summary.txt" 2>/dev/null; then
  ok "the summary records the pid simctl reported"
else
  bad "the summary records the pid simctl reported" \
    "got: $(cat "${WORK_DIR}/evidence/case-summary.txt" 2>/dev/null | tr '\n' '|' | cut -c1-200)"
fi
if grep -Fq "simulator: ${SIM_NAME} (${SIM_UDID})" "${WORK_DIR}/evidence/case-summary.txt" 2>/dev/null; then
  ok "the summary names the exact simulator the artifact was proven on"
else
  bad "the summary names the exact simulator the artifact was proven on" \
    "got: $(cat "${WORK_DIR}/evidence/case-summary.txt" 2>/dev/null | tr '\n' '|' | cut -c1-200)"
fi

echo " Mach-O platform reader"
# Extracted and unit-tested directly, because it is the one piece of real logic
# behind the structural check: if it silently reported "ios-simulator" for a
# device binary, every structural assertion above would be satisfied by a stub.
#
# The extraction stops at the line `^}` -- the last one, not the first. Both
# functions embed a Python heredoc, and a Python dict literal closes with a `}`
# at column 0 inside the heredoc, so an extraction that stopped at the FIRST
# `^}` cut the function off mid-heredoc and every reader test failed with
# "here-document delimited by end-of-file". Taking the LAST `^}` in the function
# is what makes this work; `assert_macho_reader_extraction_is_complete` below
# fails loudly if the shape of the gate changes and that stops being true.
extract_gate_function() {
  # Two `local` statements, not one. In a single `local a=1 b="${a}"` the second
  # assignment is expanded BEFORE `a` is set, so `out` would end up as the
  # literal string `${WORK_DIR}/.extract-`. shellcheck flags it (SC2318) and it
  # is right to listen: the result would be a file named after a variable
  # instead of after the function.
  local name="$1" line
  local out="${WORK_DIR}/.extract-${name}"
  local started=0 saw_heredoc_end=0
  : >"${out}"
  while IFS= read -r line; do
    if ((started == 0)); then
      [[ "${line}" == "${name}() {" ]] || continue
      started=1
    fi
    printf '%s\n' "${line}" >>"${out}"
    # All three functions under test embed a Python heredoc whose terminator is a
    # bare `PY` line. A function's own closing brace is the first `}` at column 0
    # that comes AFTER that terminator.
    #
    # Stopping at the first `}` instead is a real bug, not a hypothetical: the
    # embedded Python has dict literals (`PLATFORMS = {`, `CPU_NAMES = {`) that
    # close with a `}` at column 0, so a naive range extraction cuts the function
    # off mid-heredoc and every reader test then dies with "here-document
    # delimited by end-of-file". Requiring the heredoc to be closed first is what
    # makes the extraction correct, and the assertions below re-verify it on every
    # run, so a change to the gate's shape cannot silently re-break it.
    if [[ "${line}" == "PY" ]]; then
      saw_heredoc_end=1
      continue
    fi
    if [[ "${line}" == "}" ]] && ((saw_heredoc_end == 1)); then
      # Emitted on STDOUT as well as accumulated in `out`. Callers redirect stdout
      # to a file (`extract_gate_function macho_platforms >macho.sh`), so a
      # version that only appended to `out` produced an EMPTY file and every
      # reader unit test failed with "the extraction is truncated or does not
      # parse" -- a harness fault that reads exactly like a gate fault.
      cat "${out}"
      return 0
    fi
  done <"${SCRIPT}"
  return 1
}

extract_gate_function macho_platforms >"${WORK_DIR}/macho.sh"
if [[ -s "${WORK_DIR}/macho.sh" ]] && bash -n "${WORK_DIR}/macho.sh" 2>/dev/null; then
  ok "the Mach-O reader is extractable for unit testing"
else
  bad "the Mach-O reader is extractable for unit testing" \
    "the extraction is truncated or does not parse: $(bash -n "${WORK_DIR}/macho.sh" 2>&1 | head -2)"
fi
# Explicit guard, so a future edit that reintroduces the truncation fails here
# rather than as a wall of confusing reader failures.
if grep -Fq "PY" "${WORK_DIR}/macho.sh" && bash -n "${WORK_DIR}/macho.sh" 2>/dev/null; then
  ok "the extracted Mach-O reader includes its complete Python heredoc"
else
  bad "the extracted Mach-O reader includes its complete Python heredoc" \
    "the heredoc was cut short"
fi
macho_of() {
  bash -c "source '${WORK_DIR}/macho.sh'; macho_platforms '$1'" _ "$1"
}
make_macho "${WORK_DIR}/sim-arm64" arm64 7
make_macho "${WORK_DIR}/dev-arm64" arm64 2
make_macho "${WORK_DIR}/sim-x86" x86_64 7
make_macho "${WORK_DIR}/dev-x86" x86_64 2
if [[ "$(macho_of "${WORK_DIR}/sim-arm64" 2>&1)" == "arm64:ios-simulator" ]]; then
  ok "an arm64 simulator Mach-O reads as arm64:ios-simulator"
else
  bad "an arm64 simulator Mach-O reads as arm64:ios-simulator" \
    "got: $(macho_of "${WORK_DIR}/sim-arm64" 2>&1)"
fi
if [[ "$(macho_of "${WORK_DIR}/dev-arm64" 2>&1)" == "arm64:ios" ]]; then
  ok "an arm64 DEVICE Mach-O reads as arm64:ios, which is the distinction that matters"
else
  bad "an arm64 DEVICE Mach-O reads as arm64:ios, which is the distinction that matters" \
    "got: $(macho_of "${WORK_DIR}/dev-arm64" 2>&1)"
fi
if [[ "$(macho_of "${WORK_DIR}/dev-x86" 2>&1)" == "x86_64:ios" ]]; then
  ok "an x86_64 device Mach-O reads as x86_64:ios"
else
  bad "an x86_64 device Mach-O reads as x86_64:ios" \
    "got: $(macho_of "${WORK_DIR}/dev-x86" 2>&1)"
fi
if [[ "$(macho_of "${WORK_DIR}/sim-x86" 2>&1)" == "x86_64:ios-simulator" ]]; then
  ok "an x86_64 simulator Mach-O reads as x86_64:ios-simulator"
else
  bad "an x86_64 simulator Mach-O reads as x86_64:ios-simulator" \
    "got: $(macho_of "${WORK_DIR}/sim-x86" 2>&1)"
fi
# The reader must reject a non-Mach-O rather than reporting something. A reader
# that printed a default on a text file would let a wrong-slice check pass on a
# file that is not a binary at all.
printf '#!/bin/sh\necho hello\n' >"${WORK_DIR}/script.sh"
if macho_of "${WORK_DIR}/script.sh" >/dev/null 2>&1; then
  bad "a shell script is rejected by the Mach-O reader" "it reported a platform for a non-Mach-O file"
else
  ok "a shell script is rejected by the Mach-O reader"
fi
printf '' >"${WORK_DIR}/empty.bin"
if macho_of "${WORK_DIR}/empty.bin" >/dev/null 2>&1; then
  bad "an empty file is rejected by the Mach-O reader" "it reported a platform for an empty file"
else
  ok "an empty file is rejected by the Mach-O reader"
fi
# A Mach-O truncated mid-load-command must be rejected, not read as carrying no
# platform and therefore "unknown" -> a clean-looking pass.
head -c 20 "${WORK_DIR}/sim-arm64" >"${WORK_DIR}/truncated"
if macho_of "${WORK_DIR}/truncated" >/dev/null 2>&1; then
  bad "a truncated Mach-O is rejected rather than reported as platformless" \
    "the reader returned success for a file with a truncated load command stream"
else
  ok "a truncated Mach-O is rejected rather than reported as platformless"
fi
# A Mach-O whose load command claims to run past the end of the file.
python3 - "${WORK_DIR}/oversized-cmds" <<'PY'
import struct
import sys

load = struct.pack("<IIIII", 0x32, 24, 7, 0xE0000, 0xE0000) + struct.pack("<I", 0)
header = struct.pack("<IiiIIIII", 0xFEEDFACF, 0x0100000C, 0, 0x2, 1, 99999, 0x200085, 0)
with open(sys.argv[1], "wb") as handle:
    handle.write(header + load)
PY
if macho_of "${WORK_DIR}/oversized-cmds" >/dev/null 2>&1; then
  bad "a Mach-O whose load commands run past the file is rejected" \
    "the reader returned success for a file whose command stream is out of bounds"
else
  ok "a Mach-O whose load commands run past the file is rejected"
fi
# A Mach-O with no version load command at all is unclassifiable, and must say
# so explicitly rather than being counted as a match.
python3 - "${WORK_DIR}/noplatform" <<'PY'
import struct
import sys

load = struct.pack("<II", 0x1B, 16) + b"\x00" * 8  # LC_SEGMENT_64-ish filler
header = struct.pack("<IiiIIIII", 0xFEEDFACF, 0x0100000C, 0, 0x2, 1, len(load), 0x200085, 0)
with open(sys.argv[1], "wb") as handle:
    handle.write(header + load)
PY
if [[ "$(macho_of "${WORK_DIR}/noplatform" 2>&1)" == "arm64:unknown" ]]; then
  ok "a Mach-O with no platform load command reports arm64:unknown, not a false match"
else
  bad "a Mach-O with no platform load command reports arm64:unknown, not a false match" \
    "got: $(macho_of "${WORK_DIR}/noplatform" 2>&1)"
fi
# A fat binary: both slices listed, so a fat bundle carrying only the device
# slice is still caught. This is the shape a real universal simulator bundle has.
make_fat_macho "${WORK_DIR}/fat-sim" x86_64:7 arm64:7
make_fat_macho "${WORK_DIR}/fat-dev" x86_64:2 arm64:2
make_fat_macho "${WORK_DIR}/fat-mixed" x86_64:7 arm64:2
if [[ "$(macho_of "${WORK_DIR}/fat-sim" 2>&1 | LC_ALL=C sort | paste -sd, -)" == "arm64:ios-simulator,x86_64:ios-simulator" ]]; then
  ok "a universal simulator Mach-O lists both simulator slices"
else
  bad "a universal simulator Mach-O lists both simulator slices" \
    "got: $(macho_of "${WORK_DIR}/fat-sim" 2>&1 | tr '\n' '|')"
fi
if [[ "$(macho_of "${WORK_DIR}/fat-dev" 2>&1 | LC_ALL=C sort | paste -sd, -)" == "arm64:ios,x86_64:ios" ]]; then
  ok "a universal DEVICE Mach-O lists no simulator slice, so it is rejected"
else
  bad "a universal DEVICE Mach-O lists no simulator slice, so it is rejected" \
    "got: $(macho_of "${WORK_DIR}/fat-dev" 2>&1 | tr '\n' '|')"
fi
# The mixed case is the reason `assert_macho_platform` requires EVERY slice to
# match rather than any: the reader must be able to see the disagreement.
if [[ "$(macho_of "${WORK_DIR}/fat-mixed" 2>&1 | LC_ALL=C sort | paste -sd, -)" == "arm64:ios,x86_64:ios-simulator" ]]; then
  ok "a MIXED universal Mach-O reports BOTH platforms, so the caller can see the disagreement"
else
  bad "a MIXED universal Mach-O reports BOTH platforms, so the caller can see the disagreement" \
    "got: $(macho_of "${WORK_DIR}/fat-mixed" 2>&1 | tr '\n' '|')"
fi

echo " PNG complexity decoder"
extract_gate_function png_distinct_colors >"${WORK_DIR}/decoder.sh"
if [[ -s "${WORK_DIR}/decoder.sh" ]] && bash -n "${WORK_DIR}/decoder.sh" 2>/dev/null; then
  ok "the decoder is extractable for unit testing"
else
  bad "the decoder is extractable for unit testing" \
    "the extraction is truncated or does not parse: $(bash -n "${WORK_DIR}/decoder.sh" 2>&1 | head -2)"
fi
decode_colors() {
  bash -c "source '${WORK_DIR}/decoder.sh'; png_distinct_colors '$1' 100000" _ "$1"
}
count="$(decode_colors "${WORK_DIR}/blank.png" 2>/dev/null || printf -- '-1')"
if [[ "${count}" == "1" ]]; then
  ok "a solid-colour PNG decodes to exactly 1 colour"
else
  bad "a solid-colour PNG decodes to exactly 1 colour" "got '${count}'"
fi
count="$(decode_colors "${WORK_DIR}/rich.png" 2>/dev/null || printf -- '-1')"
if [[ "${count}" =~ ^[0-9]+$ ]] && ((count > 1)); then
  ok "a rendered PNG decodes to many colours (${count})"
else
  bad "a rendered PNG decodes to many colours" "got '${count}'"
fi
if decode_colors "${WORK_DIR}/garbage.png" >/dev/null 2>&1; then
  bad "a non-PNG file is rejected by the decoder" "it reported a colour count"
else
  ok "a non-PNG file is rejected by the decoder"
fi
if decode_colors "${WORK_DIR}/script.sh" >/dev/null 2>&1; then
  bad "a shell script is rejected by the decoder" "it reported a colour count"
else
  ok "a shell script is rejected by the decoder"
fi
# The threshold is 32. Both render fixtures must clear it, or the never-settling
# case would be rejected for looking blank and the stability check would never be
# exercised at all.
for frame in rich.png rich-drift.png; do
  colors="$(decode_colors "${WORK_DIR}/${frame}" 2>/dev/null || printf -- '-1')"
  if [[ "${colors}" =~ ^[0-9]+$ ]] && ((colors >= 32)); then
    ok "${frame} clears the gate's 32-colour threshold (${colors}), so stability is what is under test"
  else
    bad "${frame} clears the gate's 32-colour threshold, so stability is what is under test" \
      "decoded ${colors} colours; too simple to exercise the stability check"
  fi
done
# A real screenshot is 8-bit RGBA with PNG filters applied per scanline. The
# fixtures above are all filter-0 RGB, so without this the whole filter-unwinding
# block would be untested.
python3 - "${WORK_DIR}/filtered.png" <<'PY'
import struct
import sys
import zlib

width, height = 16, 16
# Filter types 0-4 on consecutive rows, so every branch of the un-filter loop runs.
raw = bytearray()
palette = [(i * 17 % 256, i * 5 % 256, i * 29 % 256) for i in range(width * height)]
for y in range(height):
    raw.append(y % 5)
    row = bytearray()
    for x in range(width):
        row += bytes(palette[y * width + x])
    if y % 5 == 0:
        raw += row
    elif y % 5 == 1:  # Sub: needs a pixels-per-byte offset of 3
        encoded = bytearray(len(row))
        for i in range(len(row)):
            left = row[i - 3] if i >= 3 else 0
            encoded[i] = (row[i] - left) & 0xFF
        raw += encoded
    elif y % 5 == 2:  # Up
        prev = palette[(y - 1) * width : y * width]
        prev_row = bytearray()
        for px in prev:
            prev_row += bytes(px)
        encoded = bytearray(len(row))
        for i in range(len(row)):
            encoded[i] = (row[i] - prev_row[i]) & 0xFF
        raw += encoded
    elif y % 5 == 3:  # Average
        encoded = bytearray(len(row))
        for i in range(len(row)):
            left = row[i - 3] if i >= 3 else 0
            up = prev_row[i]
            raw_left = up
            encoded[i] = (row[i] - ((left + up) >> 1)) & 0xFF
            raw_left = raw_left
        raw += encoded
    else:  # Paeth
        encoded = bytearray(len(row))
        for i in range(len(row)):
            left = row[i - 3] if i >= 3 else 0
            up = prev_row[i]
            up_left = prev_row[i - 3] if i >= 3 else 0
            estimate = left + up - up_left
            da, db, dc = abs(estimate - left), abs(estimate - up), abs(estimate - up_left)
            if da <= db and da <= dc:
                predictor = left
            elif db <= dc:
                predictor = up
            else:
                predictor = up_left
            encoded[i] = (row[i] - predictor) & 0xFF
        raw += encoded
    prev_row = bytearray(row)


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
with open(sys.argv[1], "wb") as handle:
    handle.write(png)
PY
count="$(decode_colors "${WORK_DIR}/filtered.png" 2>/dev/null || printf -- '-1')"
# Every pixel is a distinct colour by construction, so an un-filtered decoder that
# reads raw bytes would report a wildly different (and much larger) count.
if [[ "${count}" =~ ^[0-9]+$ ]] && ((count >= 32 && count <= 256)); then
  ok "a PNG using all five filter types decodes to a plausible colour count (${count})"
else
  bad "a PNG using all five filter types decodes to a plausible colour count" \
    "got '${count}'; the filter-unwinding path is wrong or untested"
fi
# A truncated PNG (the shape a half-flushed screenshot takes) must be an error,
# not a colour count computed from whatever pixels happened to be present.
head -c 120 "${WORK_DIR}/rich.png" >"${WORK_DIR}/png-truncated.png"
if decode_colors "${WORK_DIR}/png-truncated.png" >/dev/null 2>&1; then
  bad "a truncated PNG is rejected rather than partially decoded" \
    "it returned a colour count for a PNG whose image data was cut short"
else
  ok "a truncated PNG is rejected rather than partially decoded"
fi
# The early-exit path: given a threshold below the real count, the decoder must
# stop and report something at or just above the threshold rather than counting
# all 40 colours. This is the code path the gate uses on every poll.
early="$(bash -c "source '${WORK_DIR}/decoder.sh'; png_distinct_colors '${WORK_DIR}/rich.png' 5" 2>/dev/null || printf -- '-1')"
if [[ "${early}" =~ ^[0-9]+$ ]] && ((early > 5 && early < 40)); then
  ok "the decoder early-exits above the threshold without counting every colour (${early})"
else
  bad "the decoder early-exits above the threshold without counting every colour" \
    "got '${early}'; the threshold argument is not being honoured"
fi

echo " simulator selector"
extract_gate_function pick_simulator >"${WORK_DIR}/pick.sh"
if [[ -s "${WORK_DIR}/pick.sh" ]] && bash -n "${WORK_DIR}/pick.sh" 2>/dev/null; then
  ok "the simulator selector is extractable for unit testing"
else
  bad "the simulator selector is extractable for unit testing" \
    "the extraction is truncated or does not parse: $(bash -n "${WORK_DIR}/pick.sh" 2>&1 | head -2)"
fi
pick_from() {
  # pick_from <device-json-file> [SIM_RUNTIME] [SIM_DEVICE_PREFIX]
  SIM_RUNTIME="${2:-}" SIM_DEVICE_PREFIX="${3:-iPhone}" \
    bash -c "source '${WORK_DIR}/pick.sh'; pick_simulator '$1'" _ "$1" 2>&1
}
picked="$(pick_from "${WORK_DIR}/devices.json")"
# The fourth field is the version slice of the runtime identifier, verbatim. It
# is "18-0" and NOT "18.0", because that is literally what
# `simctl list devices available --json` puts in the key. Rewriting the last
# component into a marketing version would be an inference, and an inferred value
# is exactly what a gate must not print as if it were measured.
#
# Consequence, stated rather than hidden: IOS_SMOKE_SIM_RUNTIME must be given the
# hyphenated spelling ("18-0"). A dotted pin finds no match and the gate FAILS,
# printing the available spellings. That is fail-closed and self-correcting, so
# it is left as-is rather than being made forgiving with a silent
# dots-to-dashes rewrite.
if [[ "${picked}" == "${SIM_UDID}"$'\t'"${SIM_NAME}"$'\t'"${SIM_RUNTIME_ID}"$'\t'"18-0" ]]; then
  ok "the selector picks the only available device and reports its runtime"
else
  bad "the selector picks the only available device and reports its runtime" \
    "got: ${picked@Q}"
fi
picked="$(pick_from "${WORK_DIR}/devices-two-runtimes.json")"
if [[ "${picked}" == "${SIM_UDID}"$'\t'* ]]; then
  ok "the selector prefers the newest runtime"
else
  bad "the selector prefers the newest runtime" "got: ${picked@Q}"
fi
# The hyphenated-identifier regression. See the fixture comment: the versions are
# listed newest-first but carry the real "18-2"/"18-0"/"17-5" spelling, so a
# selector that only splits on '.' cannot order them at all.
picked="$(pick_from "${WORK_DIR}/devices-three-runtimes.json")"
if [[ "${picked}" == "NEWEST-333"$'\t'* ]]; then
  ok "the selector orders real hyphenated runtime ids (18-2 beats 18-0 beats 17-5)"
else
  bad "the selector orders real hyphenated runtime ids (18-2 beats 18-0 beats 17-5)" \
    "got: ${picked@Q}"
fi
# ...and it must be choosing among iOS runtimes at all. The same fixture lists a
# NEWER watchOS runtime, so a selector that dropped the `SimRuntime.iOS-` filter
# would pick the watch. Without this the family filter could be deleted and the
# ordering assertion above would still pass.
if grep -Fq "watchOS-26-0" "${WORK_DIR}/devices-three-runtimes.json"; then
  ok "the non-iOS runtime really is present in the fixture (the check below is not vacuous)"
else
  bad "the non-iOS runtime really is present in the fixture (the check below is not vacuous)" \
    "devices-three-runtimes.json carries no non-iOS runtime, so the family filter is untested"
fi
picked="$(pick_from "${WORK_DIR}/devices-three-runtimes.json")"
if [[ "${picked}" == "NEWEST-333"$'\t'* ]]; then
  ok "the selector considers only iOS runtimes (a newer watchOS runtime is ignored)"
else
  bad "the selector considers only iOS runtimes (a newer watchOS runtime is ignored)" \
    "got: ${picked@Q}; a newer watchOS runtime is also listed, so a selector that ignores the runtime family picks the watch"
fi
picked="$(pick_from "${WORK_DIR}/devices-three-runtimes.json" "18-0")"
if [[ "${picked}" == "MIDDLE-222"$'\t'* ]]; then
  ok "a hyphenated pin selects the requested runtime, not merely the first one"
else
  bad "a hyphenated pin selects the requested runtime, not merely the first one" \
    "got: ${picked@Q}"
fi
# The pin is the hyphenated form, because that is what the runtime identifier
# actually contains. A dotted "17.5" would match nothing and the test would pass
# for the wrong reason.
picked="$(pick_from "${WORK_DIR}/devices-two-runtimes.json" "17-5")"
if [[ "${picked}" == "OLD-0000"$'\t'* ]]; then
  ok "an explicitly pinned runtime overrides the newest-runtime choice"
else
  bad "an explicitly pinned runtime overrides the newest-runtime choice" "got: ${picked@Q}"
fi
picked="$(pick_from "${WORK_DIR}/devices.json" "" "iPad")"
if [[ "${picked}" == "${SIM_UDID}"$'\t'* ]]; then
  ok "a device-name prefix that matches nothing falls back rather than selecting nothing"
else
  bad "a device-name prefix that matches nothing falls back rather than selecting nothing" \
    "got: ${picked@Q}"
fi
for broken in devices-empty.json devices-garbage.json; do
  if pick_from "${WORK_DIR}/${broken}" >/dev/null 2>&1; then
    bad "the selector refuses ${broken} rather than inventing a device" \
      "it returned a device for an unusable list"
  else
    ok "the selector refuses ${broken} rather than inventing a device"
  fi
done

printf '\n%s assertions, %s passed, %s failed\n' \
  "${ASSERTION_COUNT}" "${PASS_COUNT}" "${FAIL_COUNT}"
if ((FAIL_COUNT > 0)); then
  exit 1
fi