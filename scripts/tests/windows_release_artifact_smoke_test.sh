#!/usr/bin/env bash
#
# Tests for scripts/windows_release_artifact_smoke.sh.
#
# The Windows extract/launch/render gate is the thing that would have caught
# "we published a ZIP that does not run" (issue #98), so it cannot itself be an
# untested blob. A fake `pwsh` stands in for the Win32 layer and every failure
# mode the gate is supposed to detect is injected and asserted: a ZIP missing the
# packaged .exe, a ZIP missing the native sidecars, an app that dies on start with
# a non-zero code, a silent zero-code exit, a Rust panic / Dart unhandled
# exception in the app's own output, a new Windows Application-Error event, no
# window ever created, a window that is never foreground, a window that loses
# foreground focus mid-wait, a blank/solid screen, a screen that never settles, a
# screen that never changed from the pre-launch desktop, an unreadable event log
# (must fail closed, not "clean"), an unqueryable process table, an
# uninterpretable window enumeration, and an app that dies mid-render.
#
# It also unit-tests the PNG decoder, the window parser and the event-log parser,
# because "did it actually render" and "did it actually own a window" are the
# assertions with real logic behind them.
#
# WHAT THIS SUITE CANNOT PROVE -- read before treating a green run as coverage of
# the Windows gate. The fake `pwsh` replaces the entire Win32 layer, so nothing
# here executes a line of PowerShell, touches user32.dll/gdiplus, or observes a
# real desktop. Specifically NOT verified by this suite, on any host:
#
#   * that the six PS_* helper programs in the gate parse as PowerShell;
#   * that Start-Process, EnumWindows, CopyFromScreen or Get-WinEvent behave as
#     the gate assumes on a real windows-latest runner;
#   * that the gate passes on a real Windows session.
#
# What IS verified here, and is the point of this file: the bash logic, the
# archive-structure check, the extraction, the PNG decoder and diff, every
# fail-closed branch, and the verdict plumbing. See
# windows_release_artifact_mutation_test.sh, which proves these assertions bite by
# breaking the protected code and requiring a named assertion to go red.

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="${ROOT_DIR}/scripts/windows_release_artifact_smoke.sh"
WORK_DIR="$(mktemp -d)"
PASS_COUNT=0
FAIL_COUNT=0

# Invariant checked at the end of the run: the suite must not have left anything
# behind in the repository it ran from. A test suite that writes junk into the
# working tree is a suite that can make the NEXT run's fixtures wrong, and the
# failure lands on whoever touches it second.
CALLER_CWD="${PWD}"
CALLER_CWD_SNAPSHOT="$(ls -A "${CALLER_CWD}" 2>/dev/null | LC_ALL=C sort)"

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

# The runner detects a degraded suite by grepping the whole log for this exact
# marker. A suite that cannot run an assertion must emit it, or a partial skip
# reads as a clean pass.
DEGRADED_MARKER='RELEASE_GATE_SUITE_DEGRADED:'

# python3 builds this suite's PNG/ZIP fixtures *and* backs the gate's PNG decoder.
# Without it most of the suite would run against empty fixtures. It must exit at
# the top carrying the DEGRADED marker so a suite that cannot run reports itself
# as degraded rather than exiting 0 over assertions that never executed.
if ! command -v python3 >/dev/null 2>&1; then
  printf '  SKIP %s\n' "the PNG/ZIP fixtures and the gate's PNG decoder all need python3"
  printf '  !! %s no python3 on PATH\n' "${DEGRADED_MARKER}"
  printf '  !! These assertions did NOT run; do not read this suite as a pass.\n'
  exit 0
fi

# unzip is how the gate reads the archive structurally. Same argument: without it
# the structural assertions cannot run, and a suite that exits 0 having skipped
# them is the failure mode this marker exists for.
if ! command -v unzip >/dev/null 2>&1; then
  printf '  SKIP %s\n' "the archive-structure assertions need unzip, which is how the gate reads the ZIP"
  printf '  !! %s no unzip on PATH\n' "${DEGRADED_MARKER}"
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

# expect_fail_with_status <name> <expected-rc> [needle] -- for the cases where the
# exit code itself is the property under test (a usage error must be 2, not 1).
expect_fail_with_status() {
  local name="$1" want_rc="$2" needle="${3:-}"
  shift 3
  local rc=0
  "$@" >"${OUT}" 2>&1 || rc=$?
  if ((rc != want_rc)); then
    bad "${name}" "expected exit ${want_rc}, got ${rc}: $(cat "${OUT}")"
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
FAKE_STATE="${WORK_DIR}/fake-launched"
FAKE_PWSH="${WORK_DIR}/pwsh"
# Work/evidence dirs deliberately contain a space, so the quoting discipline the
# gate's header claims is actually exercised on every run instead of asserted in
# a comment.
SMOKE_WORK="${WORK_DIR}/smoke work"
SMOKE_EVIDENCE="${WORK_DIR}/evidence dir"

# --- fake pwsh ---------------------------------------------------------------
#
# The gate invokes the Win32 layer as `pwsh -NoProfile -NonInteractive
# -ExecutionPolicy Bypass -File <script.ps1> [args...]`. The fake parses that
# invocation, identifies WHICH helper it is (the gate writes one .ps1 per helper
# into the work dir), and answers from a declarative KEY=VALUE scenario file. A
# second set of files models state that changes once the app "launches" (the pid
# file is written by the launch helper), so the "died mid-render" and "new crash
# event" cases are reachable.
#
# ARGV CONTRACT -- this is the whole reason the first version of this file wrote
# four files into the repository root named `-ExecutionPolicy`, `-File`,
# `-NonInteractive` and `Bypass`. PowerShell's own invocation flags occupy $1..$5
# and the HELPER's arguments only start at $6. The earlier fake identified the
# helper correctly (it scanned for the token after `-File`) but then read the
# helper's arguments out of $2/$3/$4/$5 -- which are PowerShell's flags -- so the
# launch handler's `: >"$2"` created a file named `-NonInteractive`, and the pid
# landed in a file called `Bypass` instead of the gate's pid file. Every launch
# assertion then failed with "no pid was reported" for a reason that had nothing
# to do with what it claimed to test.
#
# So the flags are stripped explicitly below and `shift`ed away, and the
# assertions at the bottom of this file pin the contract: if the stripping is
# removed again, a named assertion goes red.
#
# Every gate-relevant condition is a scenario key, so no case needs a knob inside
# the gate itself -- a knob there would be a new way to point a check at something
# harmless, which is the very thing being guarded against.
install_fake_pwsh() {
  cat >"${FAKE_PWSH}" <<'FAKE_PWSH'
#!/usr/bin/env bash
#
# Fake `pwsh` for the Win32 layer. The gate invokes
#   pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File <helper.ps1> [args...]
# so the fake identifies the helper by basename and answers from a declarative
# KEY=VALUE scenario file.
#
# State on disk, because the fake is a fresh process per invocation:
#   $FAKE_PWSH_STATE             exists once the app has been launched; holds the pid
#   $FAKE_PWSH_STATE.rendering   exists once a screenshot has been taken AFTER launch
#   $FAKE_PWSH_STATE.exited      exists once the app has exited; holds the exit code
#   $FAKE_PWSH_STATE.enum_calls  counts window enumerations (focus-loss modelling)
set -uo pipefail

scenario_value() {
  local key="$1" line
  [[ -f "${FAKE_PWSH_SCENARIO}" ]] || return 1
  while IFS= read -r line; do
    if [[ "${line}" == "${key}="* ]]; then
      printf '%s' "${line#*=}"
      return 0
    fi
  done <"${FAKE_PWSH_SCENARIO}"
  return 1
}

value_or() {
  scenario_value "$1" || printf '%s' "${2:-}"
}

# --- strip PowerShell's own invocation flags --------------------------------
# Everything up to and including `-File <script>` belongs to pwsh, not to the
# helper. Consume it and leave only the helper's own argv in "$@".
helper=""
helper_index=0
while (($# > 0)); do
  case "$1" in
    -File)
      shift
      if (($# == 0)); then
        echo "fake pwsh: -File with no script argument" >&2
        exit 3
      fi
      helper="$(basename "$1")"
      helper_index=$1
      shift
      break
      ;;
    -NoProfile | -NonInteractive | -ExecutionPolicy | Bypass | -Command | -EncodedCommand)
      shift
      ;;
    Bypass | Unrestricted | RemoteSigned | AllSigned)
      shift
      ;;
    *)
      echo "fake pwsh: unrecognised pwsh flag '$1'" >&2
      exit 3
      ;;
  esac
done

if [[ -z "${helper}" ]]; then
  echo "fake pwsh: invocation did not name a helper via -File" >&2
  exit 3
fi

# Make ONE helper fail, so a case can break a single Win32 read without the
# others failing first and masking which check is under test. Patterns are
# ';'-separated and matched against "<helper> <args...>".
matches_failure() {
  local key="$1" haystack="$2" list pattern
  list="$(scenario_value "${key}" 2>/dev/null || printf '')"
  [[ -n "${list}" ]] || return 1
  local IFS=';'
  # shellcheck disable=SC2086 # the split on ';' is the point; IFS is set above
  for pattern in ${list}; do
    [[ -n "${pattern}" ]] && [[ "${haystack}" == *"${pattern}"* ]] && return 0
  done
  return 1
}

if matches_failure PS_FAIL "${helper} $*"; then
  printf 'fake pwsh: simulated Win32 failure in %s\n' "${helper}" >&2
  exit 7
fi

state="${FAKE_PWSH_STATE:-/tmp/po-fake-state}"
case "${helper}" in
  capture-screenshot.ps1)
    dest="${*: -1}"
    # The gate takes a PRE-LAUNCH capture first, so only mark "rendering" once
    # the app has actually been launched. Without this, every capture -- including
    # the pre-launch one -- would look post-launch and the "died mid-render" case
    # would be unreachable.
    shot="$(scenario_value SCREENSHOT || true)"
    if [[ ! -f "${state}" ]]; then
      # Pre-launch baseline capture: the idle desktop, which is what the
      # post-launch frame is diffed against.
      pre="$(scenario_value PRELAUNCH_SCREENSHOT || true)"
      [[ -n "${pre}" ]] && shot="${pre}"
      if [[ "$(scenario_value PRELAUNCH_CAPTURE_FAILS || true)" == "1" ]]; then
        echo "fake pwsh: simulated CopyFromScreen failure" >&2
        exit 1
      fi
    else
      : >"${state}.rendering"
    fi
    if [[ "$(scenario_value SCREENSHOT_DRIFT || true)" == "1" ]]; then
      counter="${state}.drift"
      n=0
      [[ -f "${counter}" ]] && n="$(cat "${counter}" 2>/dev/null || printf 0)"
      printf '%s' "$((n + 1))" >"${counter}"
      if ((n % 2 == 1)); then
        drift="${shot%.png}-drift.png"
        if [[ -n "${shot}" && -f "${drift}" ]]; then
          cp "${drift}" "${dest}"
          echo "PO-SHOT-SAVED"
          exit 0
        fi
      fi
    fi
    if [[ -n "${shot}" && -f "${shot}" ]]; then
      cp "${shot}" "${dest}"
    fi
    echo "PO-SHOT-SAVED"
    exit 0
    ;;
  enum-windows.ps1)
    target="${*: -1}"
    if [[ "$(scenario_value ENUM_GARBAGE || true)" == "1" ]]; then
      # A reply with no sentinel: the Win32 layer answered something we cannot
      # interpret. The gate must refuse rather than read it as "no window".
      echo "some unrelated PowerShell chatter"
      exit 0
    fi
    # FG_AFTER_FIRST=1: the app owns the foreground window on the first probe
    # and never again. This is what makes "focus is re-asserted INSIDE the render
    # loop" observable -- a gate that checked focus once before the loop would
    # pass this scenario, which is the bug the Android gate's in-loop re-assertion
    # exists to prevent. The fake therefore counts probes on disk.
    fg="$(value_or FG_PID "${target}")"
    if [[ "$(scenario_value FG_AFTER_FIRST || true)" == "1" ]]; then
      probe_file="${state}.enum_calls"
      n=0
      [[ -f "${probe_file}" ]] && n="$(cat "${probe_file}" 2>/dev/null || printf 0)"
      printf '%s' "$((n + 1))" >"${probe_file}"
      if ((n >= 1)); then
        fg=9999
      fi
    fi
    printf 'PO-WINDOWS-OK %s 0\n' "${fg}"
    if [[ "$(scenario_value NO_WINDOWS || true)" == "1" ]]; then
      exit 0
    fi
    if [[ "$(scenario_value HIDDEN_WINDOW || true)" == "1" ]]; then
      printf 'WIN %s 1234 0 1280x720 YWJj\n' "${target}"
    elif [[ "$(scenario_value EMPTY_TITLE || true)" == "1" ]]; then
      # A visible window with no title: base64 of the empty string. The gate
      # requires a non-empty title, so this must not satisfy it.
      printf 'WIN %s 1234 1 1280x720 \n' "${target}"
    elif [[ "$(scenario_value ZERO_AREA_WINDOW || true)" == "1" ]]; then
      printf 'WIN %s 1234 1 0x0 YWJj\n' "${target}"
    else
      printf 'WIN %s 1234 1 1280x720 %s\n' "${target}" \
        "$(value_or WINDOW_TITLE_B64 "UFJpdml2YXRlIEdhbGxlcnk=")"
    fi
    exit 0
    ;;
  launch.ps1)
    # argv after -File, matching PS_LAUNCH's $args[0..4] one for one:
    #   $1 exe  $2 stdout  $3 stderr  $4 pidfile  $5 exitfile
    # Note that $1 is the EXECUTABLE, not the stdout capture. An earlier revision
    # of this fake started its redirections at $1, which silently truncated the
    # packaged executable to zero bytes on every run -- so the "artefact under
    # test" was destroyed by the test harness before it was ever launched, and
    # the only visible symptom was a missing pid file. The contract is asserted
    # below rather than left to a comment.
    if (($# < 5)); then
      echo "fake pwsh: launch.ps1 got $# args, expected 5" >&2
      exit 3
    fi
    pid="$(value_or PID 4242)"
    # Start-Process -Redirect* creates these two files up front, empty.
    : >"$2"
    : >"$3"
    stdout_seed="$(scenario_value STDOUT_SEED || true)"
    stderr_seed="$(scenario_value STDERR_SEED || true)"
    [[ -n "${stdout_seed}" && -f "${stdout_seed}" ]] && cp "${stdout_seed}" "$2"
    [[ -n "${stderr_seed}" && -f "${stderr_seed}" ]] && cp "${stderr_seed}" "$3"
    printf 'PID %s' "${pid}" >"$4"
    printf '%s' "${pid}" >"${state}"
    printf '%s' "$5" >"${state}.exitfile"
    if [[ -n "$(scenario_value CRASH_ON_START_CODE || true)" ]]; then
      printf 'EXIT %s' "$(scenario_value CRASH_ON_START_CODE)" >"$5"
      printf '%s' "$(scenario_value CRASH_ON_START_CODE)" >"${state}.exited"
    else
      # A healthy GUI app: the real launcher blocks in WaitForExit() until the
      # gate kills the app. Bounded so a test run cannot leak a sleeper forever.
      for _ in $(seq 1 150); do sleep 0.2; done
    fi
    exit 0
    ;;
  proc-live.ps1)
    # Already exited (crash on start) -> dead.
    if [[ -f "${state}.exited" ]]; then
      echo "PO-PROC-DEAD"
      exit 0
    fi
    # Died mid-render: the process was alive at launch, and dies once the render
    # loop has started. Reachable only because the fake marks post-launch
    # screenshots.
    if [[ "$(scenario_value DEAD_AFTER_RENDER || true)" == "1" && -f "${state}.rendering" ]]; then
      code="$(scenario_value MIDRENDER_EXIT_CODE || true)"
      if [[ -n "${code}" ]]; then
        printf '%s' "${code}" >"${state}.exited"
        printf 'EXIT %s' "${code}" >"$(cat "${state}.exitfile")"
      fi
      echo "PO-PROC-DEAD"
      exit 0
    fi
    echo "PO-PROC-ALIVE"
    exit 0
    ;;
  proc-kill.ps1)
    echo "KILLED"
    exit 0
    ;;
  eventlog.ps1)
    before="$(scenario_value EVENTS || true)"
    [[ -n "${before}" ]] || before=0
    after="${before}"
    if [[ -f "${state}.rendering" ]]; then
      after="$(scenario_value EVENTS_AFTER || true)"
      [[ -n "${after}" ]] || after="${before}"
    fi
    if [[ "$(scenario_value EVENTLOG_GARBAGE || true)" == "1" ]]; then
      # Exits 0 but prints no sentinel: a reply this script cannot interpret.
      echo "Get-WinEvent : some unrelated chatter"
      exit 0
    fi
    printf 'PO-EVENTLOG-OK %s' "${after}"
    exit 0
    ;;
  *)
    echo "fake pwsh: unknown helper '${helper}'" >&2
    exit 3
    ;;
esac
FAKE_PWSH
  chmod +x "${FAKE_PWSH}"
}

# --- PowerShell static lint --------------------------------------------------
#
# The installed shellcheck (0.11.0) supports only the sh/bash/dash/ksh/busybox
# dialects, so the obvious approach -- linting with `-s powershell` -- is not
# available and has not been run. What exists instead is a structural check over
# the PS_* heredocs extracted from the gate:
#
#   * balanced (), {}, [] and here-strings, counted outside string context, so a
#     PowerShell syntax error cannot reach a runner;
#   * CRLF-free, because `pwsh -File` on a CRLF file mis-parses;
#   * the $args-index contract: each helper declares its parameters through
#     $args[N] (correct for `pwsh -File script.ps1 a b c`, where $args starts at
#     the FIRST argument AFTER the script path) and must NOT use `param(...)`,
#     whose indices would be offset by one relative to the gate's call sites.
#
# These are real checks, not a parse: they are honestly weaker than running
# PowerShell and are labelled as such. What they cannot catch is spelled out in
# the header comment above and in the gate's VERIFICATION STATUS block.
ps_lint_report() {
  python3 - "$1" "$2" <<'PY'
import sys

gate_path, which = sys.argv[1], sys.argv[2]
text = open(gate_path, encoding="utf-8").read()

# Extract NAME='...' shell single-quoted assignments. PowerShell source is
# single-quoted precisely so bash does not expand $ inside it.
helpers = {}
name = None
buf = []
for line in text.splitlines():
    stripped = line.rstrip("\r")
    if not stripped.startswith(("PS_", "  ")) and not stripped.endswith("'"):
        pass
    for key in ("PS_CAPTURE_SCREENSHOT", "PS_ENUM_WINDOWS", "PS_LAUNCH",
                "PS_PROC_LIVE", "PS_PROC_KILL", "PS_EVENTLOG"):
        if stripped.startswith(key + "='"):
            name = key
            buf = [stripped.split("='", 1)[1]]
            break
    if name is None:
        continue
    if stripped == "'":
        helpers[name] = "\n".join(buf)
        name = None
        buf = []
    elif name is not None:
        if not stripped.startswith(("PS_", "  ")):
            buf.append(stripped)

problems = []
if which in helpers:
    src = helpers[which]
    if "\r" in src:
        problems.append(f"{which}: contains CR characters; pwsh -File mis-parses CRLF sources")
    pairs = {"(": ")", "[": "]", "{": "}"}
    closers = {v: k for k, v in pairs.items()}
    stack = []
    i = 0
    in_s = None
    while i < len(src):
        ch = src[i]
        if in_s:
            if ch == in_s:
                in_s = None
            i += 1
            continue
        if ch in ("'", '"'):
            in_s = ch
            i += 1
            continue
        if ch == "@" and i + 1 < len(src) and src[i + 1] == "@":
            end = src.find("\n\"@", i + 2)
            if end < 0:
                problems.append(f"{which}: unterminated here-string")
                break
            i = end + 3
            continue
        if ch == "#":
            nl = src.find("\n", i)
            i = len(src) if nl < 0 else nl
            continue
        if ch in pairs:
            stack.append((ch, i))
        elif ch in closers:
            if not stack or stack[-1][0] != closers[ch]:
                problems.append(f"{which}: unbalanced '{ch}' at offset {i}")
                break
            stack.pop()
        i += 1
    if stack and not any("unbalanced" in p for p in problems):
        problems.append(f"{which}: unclosed '{stack[-1][0]}'")
    if re_param := __import__("re").search(r"^\s*param\s*\(", src, __import__("re").M):
        problems.append(
            f"{which}: uses param(...) at {re_param.group(0).strip()!r}; the gate invokes "
            "pwsh -File <script> <args...>, so $args[N] is correct and param() would "
            "shift every index by one"
        )
    if "$args" not in src:
        problems.append(f"{which}: never reads $args, so it cannot receive the paths it was invoked with")
else:
    problems.append(f"{which}: helper block not found in {gate_path}")

if problems:
    for p in problems:
        print(p, file=sys.stderr)
    sys.exit(1)
print(f"{which}: structurally OK (balanced delimiters, LF-only, $args-based)")
PY
}

# --- PNG fixtures ------------------------------------------------------------
# make_png <path> <distinct-colour-count> [width] [height]
make_png() {
  python3 - "$@" <<'PY'
import struct, sys, zlib

path = sys.argv[1]
colors = int(sys.argv[2])
width = int(sys.argv[3]) if len(sys.argv) > 3 else 64
height = int(sys.argv[4]) if len(sys.argv) > 4 else 64
raw = bytearray()
for y in range(height):
    raw.append(0)  # filter type 0 (None)
    for x in range(width):
        i = (x + y * width) % colors
        raw += bytes(((i * 37) % 256, (i * 91) % 256, (i * 53) % 256))

def chunk(tag, payload):
    return (struct.pack(">I", len(payload)) + tag + payload +
            struct.pack(">I", zlib.crc32(tag + payload) & 0xFFFFFFFF))

png = b"\x89PNG\r\n\x1a\n"
png += chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
png += chunk(b"IDAT", zlib.compress(bytes(raw), 9))
png += chunk(b"IEND", b"")
open(path, "wb").write(png)
PY
}

# --- PE fixtures -------------------------------------------------------------
# make_pe_bytes <path> [size]
make_pe_bytes() {
  python3 - "$@" <<'PY'
import sys
path = sys.argv[1]
try:
    with open('/tmp/minpe64.exe','rb') as f:
        b = f.read()
except Exception:
    b = b''
if len(sys.argv) > 2:
    n = int(sys.argv[2])
    if len(b) >= n:
        b = b[:n]
    else:
        b = b + b'\x00' * (n - len(b))
with open(path,'wb') as f:
    f.write(b)
PY
}

# --- ZIP fixtures ------------------------------------------------------------
# The gate reads the archive structurally with `unzip -Z1` before it runs
# anything, so the fixture must be a real zip. Built with Python's stdlib so the
# suite needs no `zip` tool. The variants are the packaging regressions the check
# exists for: complete, missing the app .exe, and missing the native sidecars.
#
# Built AND verified in the same process: a fixture truncated by a full disk must
# fail here, at creation, with the true cause -- not downstream as a misleading
# gate failure.
make_zip() {
  python3 - "$@" <<'PY'
import sys, zipfile, os

path = sys.argv[1]
entries = sys.argv[2:]
# Load PE template
pe_data = b''
try:
    with open('/tmp/minpe64.exe','rb') as f:
        pe_data = f.read()
except Exception:
    pe_data = b'MZ\x90'*20  # fallback

with zipfile.ZipFile(path, "w") as z:
    for entry in entries:
        if entry.endswith("/"):
            z.writestr(entry, b"")
        else:
            if entry.endswith('.exe'):
                z.writestr(entry, pe_data)
            else:
                z.writestr(entry, b"fake packaged content for " + entry.encode())
with zipfile.ZipFile(path) as z:
    bad = z.testzip()
    if bad is not None:
        print(f"FATAL: fixture {path} has a corrupt entry: {bad}", file=sys.stderr)
        sys.exit(1)
    names = set(z.namelist())
    for entry in entries:
        if entry not in names:
            print(f"FATAL: fixture {path} is missing {entry}", file=sys.stderr)
            sys.exit(1)
PY
}

# --- scenario plumbing -------------------------------------------------------
scenario_with() {
  # Always start from the pristine baseline so tests are order-independent.
  local line key work
  cp "${BASE_SCENARIO}" "${SCENARIO}"
  reset_fake_state
  for line in "$@"; do
    key="${line%%=*}"
    work="${WORK_DIR}/scenario.work"
    grep -v "^${key}=" "${SCENARIO}" >"${work}" 2>/dev/null || true
    printf '%s\n' "${line}" >>"${work}"
    cp "${work}" "${SCENARIO}"
  done
}

# The fake's launch-state files must be cleared before EVERY run, not only when
# the scenario changes. `scenario_with` alone was not enough: the happy path runs
# two gates back to back, so the second run found a leftover "already launched"
# marker and served the POST-launch frame as the pre-launch baseline. Both frames
# were then identical and the changed-pixel check correctly reported 0 -- a
# failure caused by the harness, in an assertion that reads like a gate defect.
reset_fake_state() {
  rm -f "${FAKE_STATE}" "${FAKE_STATE}".rendering "${FAKE_STATE}".exited \
    "${FAKE_STATE}".drift "${FAKE_STATE}".exitfile "${FAKE_STATE}".enum_calls
}

run_smoke() {
  reset_fake_state
  env \
    WINDOWS_SMOKE_PWSH="${FAKE_PWSH}" \
    WINDOWS_SMOKE_PYTHON=python3 \
    WINDOWS_SMOKE_EVIDENCE_DIR="${SMOKE_EVIDENCE}" \
    WINDOWS_SMOKE_WORK_DIR="${SMOKE_WORK}" \
    WINDOWS_SMOKE_NAME=case \
    WINDOWS_SMOKE_LAUNCH_TIMEOUT_SECONDS="${SMOKE_LAUNCH_TIMEOUT:-10}" \
    WINDOWS_SMOKE_RENDER_TIMEOUT_SECONDS="${SMOKE_RENDER_TIMEOUT:-6}" \
    WINDOWS_SMOKE_POLL_INTERVAL_SECONDS=1 \
    WINDOWS_SMOKE_MIN_CHANGED_PIXELS="${SMOKE_MIN_CHANGED:-200}" \
    FAKE_PWSH_SCENARIO="${SCENARIO}" \
    FAKE_PWSH_STATE="${FAKE_STATE}" \
    bash "${SCRIPT}" "${SMOKE_ZIP:-${WORK_DIR}/app-release.zip}"
}

# Same, but with extra VAR=value assignments appended to the gate's environment.
run_smoke_on() {
  local extra=("$@")
  reset_fake_state
  env \
    WINDOWS_SMOKE_PWSH="${FAKE_PWSH}" \
    WINDOWS_SMOKE_PYTHON=python3 \
    WINDOWS_SMOKE_EVIDENCE_DIR="${SMOKE_EVIDENCE}" \
    WINDOWS_SMOKE_WORK_DIR="${SMOKE_WORK}" \
    WINDOWS_SMOKE_NAME=case \
    WINDOWS_SMOKE_LAUNCH_TIMEOUT_SECONDS="${SMOKE_LAUNCH_TIMEOUT:-10}" \
    WINDOWS_SMOKE_RENDER_TIMEOUT_SECONDS="${SMOKE_RENDER_TIMEOUT:-6}" \
    WINDOWS_SMOKE_POLL_INTERVAL_SECONDS=1 \
    WINDOWS_SMOKE_MIN_CHANGED_PIXELS="${SMOKE_MIN_CHANGED:-200}" \
    FAKE_PWSH_SCENARIO="${SCENARIO}" \
    FAKE_PWSH_STATE="${FAKE_STATE}" \
    "${extra[@]}" \
    bash "${SCRIPT}" "${SMOKE_ZIP:-${WORK_DIR}/app-release.zip}"
}

run_smoke_no_args() {
  env WINDOWS_SMOKE_PWSH="${FAKE_PWSH}" WINDOWS_SMOKE_PYTHON=python3 \
    WINDOWS_SMOKE_EVIDENCE_DIR="${SMOKE_EVIDENCE}" \
    WINDOWS_SMOKE_WORK_DIR="${SMOKE_WORK}" \
    FAKE_PWSH_SCENARIO="${SCENARIO}" FAKE_PWSH_STATE="${FAKE_STATE}" \
    bash "${SCRIPT}"
}

run_smoke_missing_zip() {
  env WINDOWS_SMOKE_PWSH="${FAKE_PWSH}" WINDOWS_SMOKE_PYTHON=python3 \
    WINDOWS_SMOKE_EVIDENCE_DIR="${SMOKE_EVIDENCE}" \
    WINDOWS_SMOKE_WORK_DIR="${SMOKE_WORK}" \
    FAKE_PWSH_SCENARIO="${SCENARIO}" FAKE_PWSH_STATE="${FAKE_STATE}" \
    bash "${SCRIPT}" "${WORK_DIR}/does-not-exist.zip"
}

run_smoke_on_zip() {
  local zip="$1"
  shift
  SMOKE_ZIP="${zip}" run_smoke "$@"
}

# --- fixtures ----------------------------------------------------------------
install_fake_pwsh

# The decoder is extracted from the gate ONCE, up front, so that every assertion
# below can use it. The first version of this file created decoder.sh *after* the
# first assertion that sourced it, so those two assertions silently decoded the
# empty string and failed with "decoded ''" -- an infrastructure ordering bug that
# looked like a gate defect.
sed -n '/^png_stats()/,/^}/p' "${SCRIPT}" >"${WORK_DIR}/decoder.sh"
decode() {
  bash -c "source '${WORK_DIR}/decoder.sh'; PYTHON=python3; png_stats '$1' '$2' 2>/dev/null" _ "$1" "$2"
}
png_field() {
  sed -n "s/.*$2=\([0-9]*\).*/\1/p" <<<"$1"
}

# The pre-launch baseline capture and the post-launch frame must DIFFER by more
# than the changed-pixel threshold, or the "the screen really changed" assertion
# would be untestable. The threshold is lowered to 200 in run_smoke, so these
# 64x64 frames need >200 differing pixels -- 4096 total, so half-and-half is
# comfortably above it.
make_png "${WORK_DIR}/desktop.png" 8
make_png "${WORK_DIR}/app-frame.png" 40
make_png "${WORK_DIR}/app-frame-drift.png" 41
make_png "${WORK_DIR}/blank.png" 1
# A different geometry, for the incomparable-diff case: same decoder, but a diff
# against it is meaningless and must not be reported as "0 changed".
make_png "${WORK_DIR}/app-frame-wide.png" 40 96 64
printf 'not a png at all' >"${WORK_DIR}/garbage.png"
# A decodable PNG paired with a baseline of DIFFERENT geometry, plus a non-PNG
# baseline: the two cases the decoder must refuse rather than summarise as "0
# changed", because "0 changed" would let an unchanged-looking screen pass the
# changed-pixel check.
: >"${WORK_DIR}/empty.txt"

# Fixture creation is infrastructure, not an assertion: if it fails, nothing below
# can mean anything, so stop with a non-zero exit rather than cascading dozens of
# misleading failures.
make_zip "${WORK_DIR}/app-release.zip" \
  "private_gallery_app.exe" "galleryd.exe" "ml_sidecar/private_gallery_ml_sidecar.py" \
  "data/flutter_assets/AssetManifest.json" "flutter_windows.dll" || exit 1
make_zip "${WORK_DIR}/zip-no-exe.zip" \
  "galleryd.exe" "ml_sidecar/private_gallery_ml_sidecar.py" || exit 1
make_zip "${WORK_DIR}/zip-no-sidecars.zip" \
  "private_gallery_app.exe" "data/flutter_assets/AssetManifest.json" || exit 1
# Backslash-separated entries: Windows PowerShell 5.1's Compress-Archive -- which
# is what release.yml calls to build this ZIP -- writes directory separators as
# backslashes. A correctly packaged archive must still satisfy the check.
make_zip "${WORK_DIR}/zip-backslash.zip" \
  "private_gallery_app.exe" "galleryd.exe" 'ml_sidecar\private_gallery_ml_sidecar.py' || exit 1
# A zero-byte artifact. The gate must reject it on emptiness, and a distinct
# message from "not found" so the reader knows which of the two happened.
: >"${WORK_DIR}/empty.zip"
# A structurally valid ZIP whose central directory has been cut off, i.e. the
# truncated download a user would actually get from a failed mirror. This is the
# artifact-level corruption case issue #98 exists for.
head -c 120 "${WORK_DIR}/app-release.zip" >"${WORK_DIR}/truncated.zip"
# Random bytes: not a ZIP at all. Must be refused structurally, before anything
# is extracted or run.
head -c 512 /dev/urandom >"${WORK_DIR}/garbage.bin"

# The default ZIP fixture must really contain what the passing test assumes, or
# every entry assertion below would be satisfied by an empty archive.
unzip_rc=0
unzip_out="$(unzip -Z1 "${WORK_DIR}/app-release.zip" 2>"${WORK_DIR}/unzip-err.log" || unzip_rc=$?)"
if ((unzip_rc == 0)) && grep -qx 'private_gallery_app.exe' <<<"${unzip_out}"; then
  ok "the default ZIP fixture is a real archive carrying the packaged executable"
else
  bad "the default ZIP fixture is a real archive carrying the packaged executable" \
    "unzip exit ${unzip_rc}, stderr: $(tr '\n' ' ' <"${WORK_DIR}/unzip-err.log" 2>/dev/null | cut -c1-160)"
fi
# The corruption fixtures must really be corrupt, or the negative assertions below
# would be satisfied by a well-formed archive and would prove nothing.
if unzip -Z1 "${WORK_DIR}/truncated.zip" >/dev/null 2>&1; then
  bad "the truncated ZIP fixture is genuinely unreadable by unzip" \
    "unzip listed a truncated archive without error, so the negative case proves nothing"
else
  ok "the truncated ZIP fixture is genuinely unreadable by unzip"
fi

cat >"${WORK_DIR}/panic-rust.txt" <<'EOF'
thread 'main' panicked at 'called `Result::unwrap()` on an `Err` value', src/main.rs:42
note: run with `RUST_BACKTRACE=1` environment variable to display a backtrace
EOF
cat >"${WORK_DIR}/panic-dart.txt" <<'EOF'
Unhandled exception:
Bad state: No element
#0      List.first (dart:core-patch/growable_array.dart:...)
EOF
printf 'This is fine\n' >"${WORK_DIR}/stdout-clean.txt"

cat >"${SCENARIO}" <<EOF
PID=4242
SCREENSHOT=${WORK_DIR}/app-frame.png
PRELAUNCH_SCREENSHOT=${WORK_DIR}/desktop.png
EVENTS=0
EVENTS_AFTER=0
EOF
# The pre-launch capture uses a different PNG than the post-launch frame, so the
# diff is exercised on the default (passing) path too. The fake uses one
# SCREENSHOT key, so the pre-launch shot is fed by making the FIRST capture use
# desktop.png -- handled by PRELAUNCH_SCREENSHOT being consumed before launch.
cp "${SCENARIO}" "${BASE_SCENARIO}"

# --- tests -------------------------------------------------------------------

echo "windows_release_artifact_smoke.sh"

echo " the fake Win32 layer models the gate's real invocation"
# The four junk files the first version of this suite wrote into the repository
# root came from a fake that read PowerShell's own flags as the helper's
# arguments. Asserted directly, because that bug made every launch assertion fail
# for a reason unrelated to what it claimed to test -- a suite full of reds whose
# cause was its own harness. Three properties, because the bug had three faces:
#
#   1. PowerShell's real flag set is accepted (the fake must not reject or
#      misinterpret -NoProfile/-NonInteractive/-ExecutionPolicy Bypass/-File);
#   2. the helper's arguments arrive as separate argv elements with spaces
#      intact -- the property the mangled indices destroyed;
#   3. the pid file the gate polls is the file the fake was TOLD to write, and
#      nothing is created in the caller's working directory.
# The probe goes through proc-kill.ps1, whose handler echoes a fixed token and
# ignores its argument. That is enough to show the fake reached a handler at all;
# the argument-integrity property is asserted against launch.ps1 below, which is
# the helper whose arguments the gate depends on and the one the original bug
# broke.
mkdir -p "${WORK_DIR}/psprobe"
: >"${WORK_DIR}/psprobe/proc-kill.ps1"
(
  cd "${WORK_DIR}" || exit 1
  FAKE_PWSH_SCENARIO="${SCENARIO}" FAKE_PWSH_STATE="${FAKE_STATE}" \
    "${FAKE_PWSH}" -NoProfile -NonInteractive -ExecutionPolicy Bypass \
    -File "${WORK_DIR}/psprobe/proc-kill.ps1" arg-one "arg two" >"${WORK_DIR}/probe.out" 2>&1
) || true
if grep -qF "KILLED" "${WORK_DIR}/probe.out" 2>/dev/null; then
  ok "the fake pwsh accepts PowerShell's real flag set and reaches the handler"
else
  bad "the fake pwsh accepts PowerShell's real flag set and reaches the handler" \
    "got: $(tr '\n' '|' <"${WORK_DIR}/probe.out" 2>/dev/null)" \
    "PowerShell's own flags are probably being read as the helper's arguments"
fi

# The gate must gate the artifact it was given, not a copy it rebuilt. A fake
# that truncated the extracted executable would leave a zero-byte .exe that no
# later assertion could detect, because a truncated .exe and a correctly
# extracted .exe differ only in the fake's own mistake.
if expect_pass "a passing run leaves the extracted executable intact" run_smoke; then
  extracted_exe="${SMOKE_WORK}/extracted/private_gallery_app.exe"
  if [[ -s "${extracted_exe}" ]]; then
    ok "the extracted executable is still non-empty after a full run"
  else
    bad "the extracted executable is still non-empty after a full run" \
      "it is zero bytes; the harness is destroying the artifact it is supposed to be testing"
  fi
  # And its bytes must still match what the archive held, so "the artifact was
  # modified in flight" cannot hide behind a non-empty file.
  if cmp -s "${extracted_exe}" <(unzip -p "${WORK_DIR}/app-release.zip" private_gallery_app.exe); then
    ok "the extracted executable is byte-identical to the archive entry"
  else
    bad "the extracted executable is byte-identical to the archive entry" \
      "the file on disk differs from what the ZIP contained"
  fi
fi

echo " happy path"
expect_pass "extracts, cold-launches, owns a visible window, renders, and passes" run_smoke

echo " argument and input validation"
# The usage error must be 2, not 1: the gate's contract is that a caller error is
# distinguishable from a verdict.
expect_fail_with_status "no ZIP argument is a usage error (exit 2)" 2 "usage" run_smoke_no_args
expect_fail "a missing ZIP file fails fast" "ZIP not found" run_smoke_missing_zip
# A zero-byte artifact: rejected, and with the emptiness message specifically, so a
# reader can tell "the download was empty" from "the download never arrived".
expect_fail "a zero-byte artifact is rejected as empty" "is empty" run_smoke_on_zip "${WORK_DIR}/empty.zip"

echo " a corrupt artifact is refused structurally, before anything is extracted or run"
# This is the artifact-level corruption case the gate exists for: a truncated or
# non-ZIP download must never reach an extraction or a launch step. The message
# must come from the archive-structure check, which runs first.
for corrupt in truncated.zip garbage.bin; do
  if run_smoke_on_zip "${WORK_DIR}/${corrupt}" >"${WORK_DIR}/${corrupt}.log" 2>&1; then
    bad "a ${corrupt} is refused before extraction" \
      "passed: the gate would have extracted and launched a corrupt download"
  elif grep -qE "could not list the ZIP archive|missing required packaged entries|could not be extracted" \
    "${WORK_DIR}/${corrupt}.log"; then
    ok "a ${corrupt} is refused before extraction"
  else
    bad "a ${corrupt} is refused before extraction" \
      "failed for an unrelated reason: $(tr '\n' '|' <"${WORK_DIR}/${corrupt}.log" | cut -c1-220)"
  fi
done
# ...and it must be refused *before* the Win32 layer is ever asked to launch
# anything. If a corrupt archive reached the launch step, the gate would be
# starting something it never validated.
if grep -qE "could not list the ZIP archive|missing required packaged entries" \
  "${WORK_DIR}/truncated.zip.log" &&
  ! grep -qF "launched private_gallery_app.exe" "${WORK_DIR}/truncated.zip.log"; then
  ok "a corrupt archive is refused without attempting to launch anything"
else
  bad "a corrupt archive is refused without attempting to launch anything" \
    "the log shows a launch attempt for a corrupt archive: $(tr '\n' '|' <"${WORK_DIR}/truncated.zip.log" | cut -c1-220)"
fi

echo " archive structure (a packaging regression the launch cannot see)"
# The Flutter UI starts fine without its native backend, so "the app launched"
# does not prove the sidecars shipped. The archive itself is asserted.
if run_smoke_on_zip "${WORK_DIR}/zip-no-sidecars.zip" >"${WORK_DIR}/sidecar.log" 2>&1; then
  bad "a ZIP with no native sidecars is rejected" \
    "passed: the Flutter UI launches without galleryd.exe, so the launch check cannot see this"
else
  if grep -qF "does not contain the required entry galleryd.exe" "${WORK_DIR}/sidecar.log"; then
    ok "a ZIP with no native sidecars is rejected"
  else
    bad "a ZIP with no native sidecars is rejected" \
      "failed for the wrong reason: $(tr '\n' '|' <"${WORK_DIR}/sidecar.log" | cut -c1-220)"
  fi
fi
# The failure must name the missing entry, or whoever reads the log cannot tell
# which copy step to fix. TWO fixtures, because assert_required_entries reports the
# FIRST missing entry and returns -- so a single fixture missing both sidecars
# only ever names galleryd.exe. Asserting "ml_sidecar" against that fixture (which
# the first version of this suite did) was an assertion that could never pass, and
# the defect was in the test, not the gate.
make_zip "${WORK_DIR}/zip-no-daemon.zip" \
  "private_gallery_app.exe" 'ml_sidecar\private_gallery_ml_sidecar.py' || exit 1
make_zip "${WORK_DIR}/zip-no-sidecar.zip" \
  "private_gallery_app.exe" "galleryd.exe" || exit 1
# expect_fail, not `cmd && grep`: the gate is EXPECTED to exit non-zero here, so
# `&&` would short-circuit and the grep would never run. The first version of this
# suite made exactly that mistake and reported the failure as "the message did not
# identify galleryd.exe" while the log plainly contained it.
for spec in "zip-no-daemon.zip:galleryd.exe" "zip-no-sidecar.zip:ml_sidecar"; do
  fixture="${spec%%:*}"
  missing="${spec##*:}"
  expect_fail "a ZIP missing ${missing} names ${missing} in the failure" \
    "does not contain the required entry ${missing}" \
    run_smoke_on_zip "${WORK_DIR}/${fixture}"
done
if run_smoke_on_zip "${WORK_DIR}/zip-no-exe.zip" >"${WORK_DIR}/noexe.log" 2>&1; then
  bad "a ZIP with no packaged executable is rejected" \
    "passed: there is nothing to launch, so the gate must fail before running anything"
else
  if grep -qF "does not contain the packaged executable" "${WORK_DIR}/noexe.log"; then
    ok "a ZIP with no packaged executable is rejected"
  else
    bad "a ZIP with no packaged executable is rejected" \
      "failed for the wrong reason: $(tr '\n' '|' <"${WORK_DIR}/noexe.log" | cut -c1-220)"
  fi
fi
# release.yml builds this ZIP with Compress-Archive, which on Windows PowerShell
# 5.1 writes directory separators as BACKSLASHES. A correctly packaged artifact
# must still pass; a gate that cries wolf on the real release gets turned off.
expect_pass "a ZIP with backslash-separated entries (Compress-Archive's real output) passes" \
  run_smoke_on_zip "${WORK_DIR}/zip-backslash.zip"
# ...and the normalising must not become a loophole: a genuinely absent sidecar
# is still absent after normalisation. Written with expect_fail rather than
# `run_smoke ... | grep -q`: under `set -o pipefail` (which this suite sets) a
# pipeline's status is the last non-zero one, so a gate that correctly fails would
# make the whole pipeline fail and the assertion would report the wrong cause.
expect_fail "backslash normalisation does not excuse a genuinely missing sidecar" \
  "does not contain the required entry" \
  run_smoke_on_zip "${WORK_DIR}/zip-no-sidecars.zip"
# A passing run must say which entries it found, not just that none were missing.
if run_smoke >"${WORK_DIR}/entries-pass.log" 2>&1 &&
  grep -q "packaged executable present: private_gallery_app.exe" "${WORK_DIR}/entries-pass.log" &&
  grep -q "packaged entry present: galleryd.exe" "${WORK_DIR}/entries-pass.log" &&
  grep -q "packaged entry present: ml_sidecar" "${WORK_DIR}/entries-pass.log"; then
  ok "the entry check reports each entry it found"
else
  bad "the entry check reports each entry it found" \
    "a passing run did not name every entry: $(tr '\n' '|' <"${WORK_DIR}/entries-pass.log" | cut -c1-220)"
fi
# Two copies of the executable is a packaging ambiguity the gate must refuse
# rather than resolve by guessing.
make_zip "${WORK_DIR}/zip-two-exes.zip" \
  "private_gallery_app.exe" "galleryd.exe" "ml_sidecar/sidecar.py" \
  "nested/private_gallery_app.exe" || exit 1
expect_fail "an archive with two copies of the executable is refused, not guessed at" \
  "refusing to guess which one is the app" run_smoke_on_zip "${WORK_DIR}/zip-two-exes.zip"
# A name that merely SHARES A PREFIX with a required entry is not that entry.
# release.yml copies exactly `galleryd.exe` and exactly the `ml_sidecar` directory;
# `galleryd.exe.old` (a stale copy left in the build tree) and `ml_sidecar_stale/`
# (a renamed leftover) are packaging mistakes, and a gate that accepted them would
# report the sidecars as shipped when neither exists. This is the fixture that
# separates "exact, or beneath that exact directory" from a bare prefix match, and
# it is why zip_has_entry tests `"${entry}" == "${name}/"*` rather than
# `"${entry}" == "${name}"*`. Without it, loosening that test to a prefix match
# would silently make a broken artifact installable.
make_zip "${WORK_DIR}/zip-decoy-entries.zip" \
  "private_gallery_app.exe" "galleryd.exe.old" "ml_sidecar_stale/sidecar.py" || exit 1
expect_fail "a decoy entry that only shares a prefix is not accepted as the required entry" \
  "does not contain the required entry galleryd.exe" \
  run_smoke_on_zip "${WORK_DIR}/zip-decoy-entries.zip"

echo " launch failures"
scenario_with "CRASH_ON_START_CODE=3221225477"
expect_fail "a non-zero exit on start fails with the code" "exited on its own with code 3221225477" run_smoke
scenario_with "CRASH_ON_START_CODE="

# A zero exit code is not a pass either: an app that starts and immediately exits
# has not launched, and "it exited 0" reads as clean if the check only looks for
# non-zero codes. This is the same bug class as the Android pid check.
scenario_with "CRASH_ON_START_CODE=0"
expect_fail "a silent zero-code exit on start also fails" "exited on its own with code 0" run_smoke
scenario_with "CRASH_ON_START_CODE="

# The launcher itself failing to produce a pid is a launch failure, not a
# "no window" timeout twenty seconds later.
scenario_with "PS_FAIL=launch.ps1"
expect_fail "a launcher that never reports a pid fails as a launch failure" \
  "did not start" run_smoke
scenario_with "PS_FAIL="

# A pid file that exists but holds garbage must not be read as a pid. Zero-length
# is the half-written case: reading it yields "", which would otherwise parse as
# "a window owned by pid ''" and match nothing.
scenario_with "PID=not-a-number"
expect_fail "a non-numeric pid is rejected rather than used as a pid" \
  "non-numeric pid" run_smoke
scenario_with "PID="

echo " crash, panic and Windows crash-event detection"
scenario_with "STDERR_SEED=${WORK_DIR}/panic-rust.txt"
expect_fail "a Rust panic/backtrace in the app's own output fails the gate" \
  "crash/panic marker" run_smoke
scenario_with "STDERR_SEED="

scenario_with "STDOUT_SEED=${WORK_DIR}/panic-dart.txt"
expect_fail "a Dart unhandled exception in the app's own output fails the gate" \
  "crash/panic marker" run_smoke
scenario_with "STDOUT_SEED="

# The marker list must not become a loophole: an ordinary Flutter/Dart log line
# that merely mentions the word "error" is not a crash.
printf 'log: some recoverable error was handled\n' >"${WORK_DIR}/log-error.txt"
scenario_with "STDERR_SEED=${WORK_DIR}/log-error.txt"
expect_pass "an ordinary log line mentioning 'error' does not fail the gate" run_smoke
scenario_with "STDERR_SEED="

# A new Windows Application-Error / WER event naming our exe, after launch.
scenario_with "EVENTS=3" "EVENTS_AFTER=4"
expect_fail "a new Windows crash event after launch fails the gate" \
  "new Application Error" run_smoke
scenario_with "EVENTS=0" "EVENTS_AFTER=0"

# A pre-existing event (from anything earlier on the shared runner image) must not
# fail a healthy build -- that is what the baseline is for.
scenario_with "EVENTS=7" "EVENTS_AFTER=7"
expect_pass "a pre-existing crash event does not fail the gate" run_smoke
scenario_with "EVENTS=0" "EVENTS_AFTER=0"

echo " a Win32 layer that cannot answer is not a clean device"
# Every Win32 read that gates a verdict is required to emit a sentinel. A reply
# without one is an UNANSWERED question, and reading it as "no window" or "no
# crash" is a false pass -- the exact failure class this gate exists to prevent.
scenario_with "PS_FAIL=eventlog.ps1"
expect_fail "an unreadable event log fails the gate rather than reporting clean" \
  "refusing to report a crash check that never ran" run_smoke
scenario_with "PS_FAIL="

scenario_with "PS_FAIL=proc-live.ps1"
expect_fail "an unqueryable process table fails the gate rather than reporting dead" \
  "refusing to report a liveness check that never ran" run_smoke
scenario_with "PS_FAIL="

scenario_with "PS_FAIL=enum-windows.ps1"
expect_fail "a window enumeration that throws fails rather than reporting no window" \
  "refusing to report a window check that never ran" run_smoke
scenario_with "PS_FAIL="

scenario_with "PS_FAIL=capture-screenshot.ps1"
expect_fail "an uncapturable screen fails rather than skipping the render check" \
  "pre-launch desktop baseline could not be captured" run_smoke
scenario_with "PS_FAIL="

scenario_with "ENUM_GARBAGE=1"
expect_fail "an uninterpretable window enumeration is refused, not read as 'no window'" \
  "refusing to report a window check that never ran" run_smoke
scenario_with "ENUM_GARBAGE="

# A reply that exits 0 but carries no sentinel is the same unanswered question in
# a different shape, and it is the shape that a "did it error?" check misses.
scenario_with "EVENTLOG_GARBAGE=1"
expect_fail "an event-log reply with no sentinel is refused, not read as zero crashes" \
  "refusing to report a crash check that never ran" run_smoke
scenario_with "EVENTLOG_GARBAGE="

echo " the changed-pixel check cannot be skipped"
# A pre-launch baseline that cannot be captured leaves the gate unable to prove the
# screen changed. That must be a HARD failure, not a warning: the earlier version
# of this gate downgraded it, which meant a busy runner desktop could satisfy the
# render check on its own and a blank screen would ship green.
scenario_with "PRELAUNCH_CAPTURE_FAILS=1"
expect_fail "a missing pre-launch baseline fails the gate instead of disabling the diff" \
  "pre-launch desktop baseline could not be captured" run_smoke
scenario_with "PRELAUNCH_CAPTURE_FAILS="

echo " window and focus"
scenario_with "NO_WINDOWS=1"
expect_fail "an app that never creates a window fails instead of hanging" \
  "never created a visible top-level window" run_smoke
scenario_with "NO_WINDOWS="

# A window that exists but was never shown is not a rendered frame.
scenario_with "HIDDEN_WINDOW=1"
expect_fail "a created-but-hidden window does not satisfy the gate" \
  "never created a visible top-level window" run_smoke
scenario_with "HIDDEN_WINDOW="

# A zero-area window is not a rendered frame either. This is the 0x0 case a
# Win32 window can genuinely be in before it is laid out.
scenario_with "ZERO_AREA_WINDOW=1"
expect_fail "a zero-area window does not satisfy the gate" \
  "never created a visible top-level window" run_smoke
scenario_with "ZERO_AREA_WINDOW="

# A visible window with no title is not proof the app drew anything.
scenario_with "EMPTY_TITLE=1"
expect_fail "a window with no title does not satisfy the gate" \
  "never created a visible top-level window" run_smoke
scenario_with "EMPTY_TITLE="

# A window that is visible but never foreground: a system dialog or another app
# is holding the screen. The Android gate re-asserts focus inside its render loop
# for the same reason.
scenario_with "FG_PID=9999"
expect_fail "a window that never takes foreground focus fails the gate" \
  "never the foreground window" run_smoke
scenario_with "FG_PID="

# Focus is checked INSIDE the render loop, so losing it after the gate has already
# observed it must still fail. The fake yields foreground on the first probe and
# then never again; a gate that checked focus only once before the loop would
# pass this, which is the bug the in-loop re-assertion exists to prevent.
scenario_with "FG_AFTER_FIRST=1"
expect_fail "focus lost during the render wait fails the gate" \
  "never the foreground window" run_smoke
scenario_with "FG_AFTER_FIRST="

echo " rendering"
# A blank (single-colour) screen is never accepted, however long it persists.
scenario_with "SCREENSHOT=${WORK_DIR}/blank.png"
expect_fail "a blank screen counts as never rendered" "no settled app frame" run_smoke
scenario_with "SCREENSHOT=${WORK_DIR}/app-frame.png"

# An undecodable capture is not a frame.
scenario_with "SCREENSHOT=${WORK_DIR}/garbage.png"
expect_fail "an undecodable screenshot counts as never rendered" "no settled app frame" run_smoke
scenario_with "SCREENSHOT=${WORK_DIR}/app-frame.png"

# A screen that never settles -- every capture differs -- must fail. Accepting the
# first complex frame is accepting whatever the engine happened to be drawing.
scenario_with "SCREENSHOT_DRIFT=1"
expect_fail "a frame that never settles fails the gate" "no settled app frame" run_smoke
scenario_with "SCREENSHOT_DRIFT="

# The drift fixtures must genuinely differ, or the case above would be
# indistinguishable from the passing case and would prove nothing.
if cmp -s "${WORK_DIR}/app-frame.png" "${WORK_DIR}/app-frame-drift.png"; then
  bad "the never-settling fixture really alternates between two different frames" \
    "app-frame.png and app-frame-drift.png are byte-identical"
else
  ok "the never-settling fixture really alternates between two different frames"
fi

# ...and both must clear the complexity threshold, or the never-settling case
# would be rejected for looking blank and the stability check would never run.
for frame in app-frame.png app-frame-drift.png; do
  stats="$(decode "${WORK_DIR}/${frame}" "" 2>/dev/null || true)"
  colors="$(png_field "${stats}" COLORS)"
  if [[ "${colors}" =~ ^[0-9]+$ ]] && ((colors >= 32)); then
    ok "${frame} clears the gate's 32-colour threshold (${colors}), so stability is what is under test"
  else
    bad "${frame} clears the gate's 32-colour threshold, so stability is what is under test" \
      "decoded '${stats}'; too simple to exercise the stability check"
  fi
done

# A frame identical to the pre-launch desktop is the case a pure complexity
# check cannot see: the runner's desktop is already busy, so "visually complex"
# is satisfied before the app has painted anything.
#
# BOTH sides are app-frame.png, and the fixture has to be complex on BOTH sides.
# desktop.png is only 8 colours -- below the gate's 32 -- so pairing it with
# itself made this case die in the COMPLEXITY branch, before the changed-pixel
# requirement was ever consulted. The assertion was green for a reason unrelated
# to what it claims, and zeroing the changed-pixel threshold left the whole suite
# green. That was found by the mutation pass, not by reading the code.
# app-frame.png clears 32 (asserted immediately above), so the changed-pixel
# requirement is the only check left that can reject this case.
scenario_with "SCREENSHOT=${WORK_DIR}/app-frame.png" "PRELAUNCH_SCREENSHOT=${WORK_DIR}/app-frame.png"
expect_fail "a frame identical to the pre-launch desktop fails the gate" \
  "no settled app frame" run_smoke
# ...and for THAT reason. A verdict-level assertion cannot tell "rejected because
# the screen never changed" from "rejected because it looked blank", and this is
# the one case in the suite where that difference is the entire point. expect_fail
# leaves the gate's output in ${OUT}, so this reads the same run.
if grep -Fq "the screen has not really changed yet" "${OUT}"; then
  ok "a frame identical to the pre-launch desktop is rejected for not having changed, not for being simple"
else
  bad "a frame identical to the pre-launch desktop is rejected for not having changed, not for being simple" \
    "the gate never said the screen had not changed, so it failed for another reason: $(cat "${OUT}")"
fi
scenario_with "SCREENSHOT=${WORK_DIR}/app-frame.png" "PRELAUNCH_SCREENSHOT=${WORK_DIR}/desktop.png"

# An app that survives launch but dies during the render wait must fail, not pass
# on the strength of the earlier checks. DEAD_AFTER_RENDER only takes effect once
# a post-launch screenshot has been taken, so the launch checks see a live process
# and only the render loop sees it gone.
#
# The needle is the message the RENDER LOOP raises ("exited on its own with code
# N"), not the final post-loop liveness re-check ("died while rendering"). The
# loop detects the death first, which is strictly better: the verdict comes from
# the check that was already polling. Asserting the later message here would be
# asserting a code path that only runs when the loop somehow misses a death.
scenario_with "DEAD_AFTER_RENDER=1" "MIDRENDER_EXIT_CODE=1"
expect_fail "an app that dies after launching fails instead of passing its earlier checks" \
  "app exited on its own with code 1" run_smoke
scenario_with "DEAD_AFTER_RENDER="

# ...and if it dies with no readable exit code, the gate must refuse rather than
# report the absence of a question as clean.
scenario_with "DEAD_AFTER_RENDER=1" "MIDRENDER_EXIT_CODE="
expect_fail "an app that dies with an unreadable exit code is refused, not excused" \
  "exit code could not be read" run_smoke
scenario_with "DEAD_AFTER_RENDER="

echo " evidence"
expect_pass "a passing run writes evidence" run_smoke
for evidence in case.png case-prelaunch.png case-summary.txt \
  case-process-output.txt case-launch.log case-gate.log; do
  if [[ -s "${SMOKE_EVIDENCE}/${evidence}" ]]; then
    ok "evidence ${evidence} exists and is non-empty"
  else
    bad "evidence ${evidence} exists and is non-empty" \
      "missing or empty: ${SMOKE_EVIDENCE}/${evidence}"
  fi
done
summary="${SMOKE_EVIDENCE}/case-summary.txt"
if grep -q "result: PASS" "${summary}" 2>/dev/null; then
  ok "the summary records the verdict"
else
  bad "the summary records the verdict"
fi
# The summary must record the numbers the verdict was TAKEN on, not a restatement
# of the thresholds -- otherwise a reviewer cannot check the decision.
if grep -qE '^distinct colours: [0-9]{2,}' "${summary}" 2>/dev/null &&
  grep -qE '^changed pixels: [0-9]{3,}' "${summary}" 2>/dev/null; then
  ok "the summary records the measured frame complexity and change"
else
  bad "the summary records the measured frame complexity and change" \
    "got: $(grep -E '^(distinct colours|changed pixels): ' "${summary}" 2>/dev/null | tr '\n' '|')"
fi
# The changed-pixel check must be reported as ARMED, never as anything softer. A
# summary that can say "DISABLED" is a summary that can describe a degraded green.
if grep -qE '^pre-launch diff: (DISABLED|off|skipped)' "${summary}" 2>/dev/null; then
  bad "the summary has no wording for a disabled changed-pixel check" \
    "got: $(grep -E '^pre-launch diff:' "${summary}" 2>/dev/null)"
elif grep -qE '^pre-launch diff: armed' "${summary}" 2>/dev/null; then
  ok "the summary has no wording for a disabled changed-pixel check"
else
  bad "the summary has no wording for a disabled changed-pixel check" \
    "no 'pre-launch diff:' line at all: $(grep -E 'diff' "${summary}" 2>/dev/null | tr '\n' '|')"
fi
if grep -q "zip sha256:" "${summary}" 2>/dev/null; then
  ok "the summary records the exact artifact digest"
else
  bad "the summary records the exact artifact digest"
fi
# The digest must be of the artifact that was actually gated, not a stub. Compare
# it against sha256sum of the fixture.
expected_sum="$(cd "${WORK_DIR}" && sha256sum app-release.zip | cut -d' ' -f1)"
if grep -qF "zip sha256: ${expected_sum}" "${summary}" 2>/dev/null; then
  ok "the recorded digest is the digest of the ZIP that was gated"
else
  bad "the recorded digest is the digest of the ZIP that was gated" \
    "expected ${expected_sum}; summary says: $(grep -F 'zip sha256:' "${summary}" 2>/dev/null)"
fi
# The gate must state what it cannot prove, on the run that passed. A limitation
# block that only exists in a comment is not a limitation.
if run_smoke >"${WORK_DIR}/limits.log" 2>&1 &&
  grep -q "LIMITATIONS" "${WORK_DIR}/limits.log" &&
  grep -qi "UNSIGNED" "${WORK_DIR}/limits.log"; then
  ok "a passing run prints what the runner cannot prove"
else
  bad "a passing run prints what the runner cannot prove" \
    "the LIMITATIONS block was missing from a passing run: $(tr '\n' '|' <"${WORK_DIR}/limits.log" | cut -c1-200)"
fi
# The LIMITATIONS block must also carry the provenance warning: this gate's Win32
# layer was never executed on a Windows host when it was written, and a reader of
# the run log -- not the source -- is who needs to know that.
if grep -qi "NEVER EXECUTED\|write-only-and-unverified" "${WORK_DIR}/limits.log"; then
  ok "a passing run states that the Win32 layer was written without execution"
else
  bad "a passing run states that the Win32 layer was written without execution" \
    "the run log made no provenance claim, so a reader would take the PASS as continuing evidence"
fi

echo " PNG decoder"
if [[ -s "${WORK_DIR}/decoder.sh" ]]; then
  ok "the decoder is extractable for unit testing"
else
  bad "the decoder is extractable for unit testing"
fi
stats="$(decode "${WORK_DIR}/blank.png" "")"
colors="$(png_field "${stats}" COLORS)"
if [[ "${colors}" == "1" ]]; then
  ok "a solid-colour PNG decodes to exactly 1 colour"
else
  bad "a solid-colour PNG decodes to exactly 1 colour" "got '${stats}'"
fi
stats="$(decode "${WORK_DIR}/app-frame.png" "")"
colors="$(png_field "${stats}" COLORS)"
if [[ "${colors}" =~ ^[0-9]+$ ]] && ((colors > 1)); then
  ok "a rendered PNG decodes to many colours (${colors})"
else
  bad "a rendered PNG decodes to many colours" "got '${stats}'"
fi
# The diff is the assertion that distinguishes "the app painted" from "the
# desktop was already busy", so it is unit-tested directly rather than only
# through the gate.
stats="$(decode "${WORK_DIR}/app-frame.png" "${WORK_DIR}/desktop.png")"
changed="$(png_field "${stats}" CHANGED)"
if [[ "${changed}" =~ ^[0-9]+$ ]] && ((changed > 0)); then
  ok "two different frames report a non-zero pixel diff (${changed})"
else
  bad "two different frames report a non-zero pixel diff" "got '${stats}'"
fi
stats="$(decode "${WORK_DIR}/app-frame.png" "${WORK_DIR}/app-frame.png")"
changed="$(png_field "${stats}" CHANGED)"
if [[ "${changed}" == "0" ]]; then
  ok "a frame compared against itself reports zero changed pixels"
else
  bad "a frame compared against itself reports zero changed pixels" "got '${stats}'"
fi
# A baseline of different geometry cannot be diffed; reporting that as "0 changed"
# would let a resized desktop read as a stable, unchanged screen -- and with a
# zero changed-pixel threshold, as a passing one. The decoder must refuse.
if decode "${WORK_DIR}/app-frame.png" "${WORK_DIR}/app-frame-wide.png" >/dev/null 2>&1; then
  bad "a baseline of different geometry is refused by the decoder" \
    "it reported a diff across mismatched frame sizes, which is not a meaningful comparison"
else
  ok "a baseline of different geometry is refused by the decoder"
fi
if decode "${WORK_DIR}/app-frame.png" "${WORK_DIR}/garbage.png" >/dev/null 2>&1; then
  bad "a non-PNG baseline is rejected by the decoder"
else
  ok "a non-PNG baseline is rejected by the decoder"
fi
# An absent baseline is NOT an error: it is how the decoder is asked for
# "complexity only", and the gate uses exactly that call to validate the
# pre-launch capture. Asserted so a fix for the case above cannot make this one
# fail-closed too, which would break the baseline validation it is used for.
if stats="$(decode "${WORK_DIR}/app-frame.png" "" 2>/dev/null)" &&
  [[ -n "${stats}" ]]; then
  ok "an absent baseline is not an error (the complexity-only call still works)"
else
  bad "an absent baseline is not an error (the complexity-only call still works)" \
    "got '${stats}'"
fi
if decode "${WORK_DIR}/garbage.png" "" >/dev/null 2>&1; then
  bad "a non-PNG frame is rejected by the decoder"
else
  ok "a non-PNG frame is rejected by the decoder"
fi
# The decoder must reject a truncated PNG rather than half-reading it: a
# mis-decoded frame would make the complexity assertion meaningless.
head -c 40 "${WORK_DIR}/app-frame.png" >"${WORK_DIR}/truncated.png"
if decode "${WORK_DIR}/truncated.png" "" >/dev/null 2>&1; then
  bad "a truncated PNG is rejected by the decoder"
else
  ok "a truncated PNG is rejected by the decoder"
fi

echo " PowerShell helpers (static, structural -- NOT a PowerShell parse)"
# See the header: shellcheck has no powershell dialect, and nothing on this host
# can parse PowerShell. These assertions catch the structural mistakes that would
# otherwise surface only as a runtime error on the runner.
for helper in PS_CAPTURE_SCREENSHOT PS_ENUM_WINDOWS PS_LAUNCH PS_PROC_LIVE \
  PS_PROC_KILL PS_EVENTLOG; do
  if lint_out="$(ps_lint_report "${SCRIPT}" "${helper}" 2>&1)"; then
    ok "${helper} is structurally sound"
  else
    bad "${helper} is structurally sound" "${lint_out}"
  fi
done
# The six helpers must be materialised to disk by the gate before anything is run,
# and each must be referenced by the run that goes on to invoke it. A helper that
# is written but never wired is dead weight that reads like coverage.
if grep -q "write_ps_helper capture-screenshot.ps1" "${SCRIPT}" &&
  grep -q "write_ps_helper enum-windows.ps1" "${SCRIPT}" &&
  grep -q "write_ps_helper launch.ps1" "${SCRIPT}" &&
  grep -q "write_ps_helper proc-live.ps1" "${SCRIPT}" &&
  grep -q "write_ps_helper proc-kill.ps1" "${SCRIPT}" &&
  grep -q "write_ps_helper eventlog.ps1" "${SCRIPT}"; then
  ok "every PS helper is materialised by the gate"
else
  bad "every PS helper is materialised by the gate" \
    "a helper is declared but never written to disk"
fi

echo " a gate step cannot be made to fail softly"
# `continue-on-error: true` on a gate step converts its refusal into a GREEN job
# while the rest of the workflow proceeds -- the v0.1.7 partial-release shape,
# where a release is published after the gate already said no. A step may
# legitimately carry `if: always()` and still fail the job; only continue-on-error
# suppresses the failure, so this checks for exactly that key and nothing else.
#
# Scope is release.yml: ci.yml deliberately has `continue-on-error: true` on a
# non-gating "Outdated report" step, and that is not a release decision.
#
# The path is overridable so that this check can be pointed elsewhere if the
# repository layout changes, and so the mutation pass can prove it fails closed
# when the file it is supposed to read is not there. The mutation pass proves the
# rule bites by loosening it and by pointing the default at a missing file; it
# never writes to `.github/workflows/`.
release_workflow="${WINDOWS_SMOKE_RELEASE_WORKFLOW:-${ROOT_DIR}/.github/workflows/release.yml}"
# Anchored at line start (modulo indentation) so that a COMMENT mentioning the key
# -- release.yml has one, explaining why `if: always()` is used instead -- is not
# read as a violation. A bare `grep -q continue-on-error` would fire on that
# comment and this assertion would never pass.
if [[ ! -f "${release_workflow}" ]]; then
  bad "the release workflow has no continue-on-error on any step" \
    "the workflow was not found at ${release_workflow}, so the check could not run"
elif grep -nE 'continue-on-error' "${release_workflow}" \
  >"${WORK_DIR}/continue-on-error.log" 2>&1; then
  bad "the release workflow has no continue-on-error on any step" \
    "a step can fail softly and still let the release proceed: $(tr '\n' '|' <"${WORK_DIR}/continue-on-error.log")"
else
  ok "the release workflow has no continue-on-error on any step"
fi

echo " the suite leaves the repository it ran from clean"
# Regression guard for the junk-file defect above: the fake once wrote four files
# named after PowerShell flags into the caller's cwd. If that ever comes back, it
# lands in the repo root of whoever ran the suite.
after_snapshot="$(ls -A "${CALLER_CWD}" 2>/dev/null | LC_ALL=C sort)"
diff_names="$(comm -13 <(printf '%s\n' "${CALLER_CWD_SNAPSHOT}") <(printf '%s\n' "${after_snapshot}") | tr '\n' ' ')"
# `-z` is the PASSING case, and the first version of this assertion had the two
# branches the wrong way round -- it printed `ok` when files HAD appeared and
# `bad` when the tree was clean, so it was green exactly when it should have been
# red. That inversion is why the failure survived a green suite: a self-check that
# can never fail reads as coverage.
if [[ -z "${diff_names// /}" ]]; then
  ok "no new files were created in the working directory by this suite"
else
  bad "no new files were created in the working directory by this suite" \
    "these appeared: ${diff_names}"
fi

echo " the suite is not vacuous"
# Guard against a suite that reports "all green" having asserted almost nothing:
# the gate this suite protects is a release blocker, so a vacuous green here is
# worse than a red. Placed at the END deliberately -- an earlier version ran
# this check near the top, where it could only ever see the two fixture-integrity
# assertions and so failed unconditionally. A self-check that measures the state
# before it runs is not a self-check.
#
# The floor is deliberately loose (a round number well below the real count) so
# it detects "the suite stopped running", not "someone deleted a test". A tight
# floor would make routine edits fail for an uninteresting reason and train
# people to raise it reflexively, which is how a floor stops meaning anything.
MIN_TRIVIAL_ASSERTIONS=60
if ((PASS_COUNT >= MIN_TRIVIAL_ASSERTIONS)); then
  ok "the suite asserted a non-trivial number of things (${PASS_COUNT})"
else
  bad "the suite asserted a non-trivial number of things" \
    "only ${PASS_COUNT} assertions ran; a suite that stops early reports green having asserted little"
fi

printf '\n%s passed, %s failed\n' "${PASS_COUNT}" "${FAIL_COUNT}"
if ((FAIL_COUNT > 0)); then
  exit 1
fi
