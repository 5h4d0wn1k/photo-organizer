#!/usr/bin/env bash
#
# Artifact-level release gate for the Windows ZIP: prove the exact file we are
# about to publish can be extracted, cold-launched as a real interactive process,
# produces a genuine top-level window, and survives long enough to change the
# screen and render a stable, visually-complex frame -- on a real Windows desktop
# session, not a service context.
#
# This is the Windows half of issue #98 (sibling of #97, which is Android-only).
# Every check here that exists on the Android gate exists for the same reason:
# all of our unit/integration tests validate the *code*; this validates the
# *binary a user will download and run*.
#
# VERIFICATION STATUS -- read this before trusting anything below.
#
#   What has actually been executed, by the author of this file:
#
#     * The bash control flow, the archive-structure check, the ZIP extraction,
#       the PNG decoder, the changed-pixel diff, every failure-closed branch,
#       and the exit-code propagation are exercised on every CI run of
#       scripts/tests/windows_release_artifact_smoke_test.sh, which substitutes
#       a fake `pwsh` for the Win32 layer. See that file for the fixtures.
#
#     * The SIX PowerShell helper programs below (PS_CAPTURE_SCREENSHOT,
#       PS_ENUM_WINDOWS, PS_LAUNCH, PS_PROC_LIVE, PS_PROC_KILL, PS_EVENTLOG)
#       have NEVER BEEN EXECUTED. They were written on a Linux host that has no
#       PowerShell, no Win32 `user32.dll`/`gdiplus` and no interactive desktop.
#       They are structurally reviewed and statically linted by the test suite
#       (balanced delimiters, CRLF-freedom, `$args`-index contract), which is a
#       real check -- but it is NOT a parse by PowerShell and NOT a run.
#
#     * Consequently NOTHING that requires a real Windows session has ever been
#       observed to work: extracting to a Windows path, Start-Process on a real
#       PE binary, EnumWindows finding the app's HWND, CopyFromScreen returning
#       a real desktop bitmap, and Get-WinEvent answering. The first CI run on
#       windows-latest is the first real execution, and it should be treated as a
#       shakedown, not as confirmation.
#
#   Everything the gate ASSERTS is written fail-closed for that reason: a Win32
#   read that cannot be answered is a hard failure, never "clean". So a
#   first-run failure is expected to be a real defect report, not a harness
#   artefact -- but do not assume the opposite either. Nothing in this file
#   claims a Windows guarantee that has been observed, and no comment here may
#   be read as one.
#
# Design notes (each is a deliberate decision, not an accident):
#
#   * Shell choice. windows-latest's DEFAULT shell is PowerShell. This gate is
#     bash, run under Git-for-Windows bash (the `shell: bash` runner, i.e.
#     C:\Program Files\Git\bin\bash.exe). Reason: the sibling Android gate is
#     bash, so every one of its hard-won lessons (fail-closed when a "clean"
#     read is really an unanswered read; a committed, testable script rather than
#     an inline blob; deliberate timeout budgets) transfers verbatim, and a
#     Windows gate written in a different language than the gates it must match
#     would be a second, unshared standard. The workflow documents this and
#     invokes this script with `shell: bash`. All Win32-specific work (window
#     enumeration, screen capture, the event log) is done by tiny, explicit
#     PowerShell helper programs written to disk and invoked via `pwsh
#     -NoProfile -NonInteractive -File`; `pwsh` is the same interpreter the rest
#     of this repo's Windows workflow uses, and -NonInteractive/-NoProfile stop
#     a stray prompt or profile from hanging the gate. See pwsh_helper() for the
#     invocation and for the argument-quoting discipline it encodes.
#
#   * The artifact under test is the ZIP, and the ZIP is checked structurally
#     *before* it is run. This archive is not an APK, so there is no install step;
#     the analogue is: does the archive contain the shipped .exe (and the
#     sidecars the release workflow copies in)? A packaging regression that drops
#     the daemon is invisible to "the app launched", because the Flutter UI can
#     start without its native backend. So the required entries are asserted from
#     the archive, fail-closed, exactly like the Android native-ABI check.
#
#   * Crash detection is a *pre/post baseline* on the Windows Application event
#     log (Application Error 1000 / .NET Runtime 1026 / WER 1001) *and* a scan of
#     the launched process's own stdout/stderr for panic/backtrace/unhandled
#     markers. The event log is read as a baseline count so a pre-existing entry
#     (from anything earlier on the shared runner) cannot fail the build, while
#     any NEW entry naming our executable does. A read that fails is a failure,
#     not a clean result -- the same rule the Android gate learned the hard way.
#
#   * "Launched" is not "rendered" and "process exists" is not "window shown".
#     This gate requires all of: a live process, at least one *visible*
#     top-level window owned by that process, and a settled frame that is
#     visually complex (>= MIN_DISTINCT_COLORS distinct colours) AND byte-stable
#     across two consecutive captures. A blank frame, a splash, a black screen,
#     or a screen that never stops animating all fail.
#
#   * LIMITATION, stated rather than papered over. This runner is a GitHub-hosted
#     `windows-latest` VM. It is interactive-session-capable, but it is still a
#     virtual machine: it is not a user's physical desktop, it has no GPU/real
#     display, and it cannot prove anything about SmartScreen/AV/Defender
#     reputation, code signing (this ZIP is unsigned), multi-monitor DPI, or a
#     real user's hardware. It also cannot prove a user can *install* the ZIP the
#     way a human would (there is no installer; it is a portable zip). What it
#     does prove is that the exact published bytes extract, start as a GUI
#     process, create and own a real window, and paint a real frame on a real
#     Windows. See LIMITATIONS text printed on every pass.
#
# Usage: windows_release_artifact_smoke.sh <path-to-zip>
#
# Tunables (safe defaults; override via env in tests):
#   WINDOWS_SMOKE_NAME                     evidence file prefix (matrix-safe)
#   WINDOWS_SMOKE_EVIDENCE_DIR             where evidence files are written
#   WINDOWS_SMOKE_WORK_DIR                 scratch dir (extracted tree, temp files)
#   WINDOWS_SMOKE_PWSH                     PowerShell executable (default: pwsh)
#   WINDOWS_SMOKE_PYTHON                   python interpreter (default: python3)
#   WINDOWS_SMOKE_EXE_NAME                 expected packaged .exe basename
#   WINDOWS_SMOKE_LAUNCH_TIMEOUT_SECONDS   process+window budget after start
#   WINDOWS_SMOKE_RENDER_TIMEOUT_SECONDS   settled-frame budget
#   WINDOWS_SMOKE_MIN_DISTINCT_COLORS      screenshot complexity threshold
#   WINDOWS_SMOKE_MIN_CHANGED_PIXELS       pixels that must differ vs pre-launch
#   WINDOWS_SMOKE_EXPECT_MACHINE           PE machine type the .exe must declare
#   WINDOWS_SMOKE_EXPECT_PE_MAGIC          PE optional-header magic it must declare
#   WINDOWS_SMOKE_POLL_INTERVAL_SECONDS    poll period
#   WINDOWS_SMOKE_REQUIRED_ENTRIES         ';' list of entries the zip must hold

set -euo pipefail

NAME="${WINDOWS_SMOKE_NAME:-windows-smoke}"
EVIDENCE_DIR="${WINDOWS_SMOKE_EVIDENCE_DIR:-.}"
WORK_DIR="${WINDOWS_SMOKE_WORK_DIR:-}"
PWSH="${WINDOWS_SMOKE_PWSH:-pwsh}"
PYTHON="${WINDOWS_SMOKE_PYTHON:-python3}"
EXE_NAME="${WINDOWS_SMOKE_EXE_NAME:-private_gallery_app.exe}"
LAUNCH_TIMEOUT_SECONDS="${WINDOWS_SMOKE_LAUNCH_TIMEOUT_SECONDS:-90}"
RENDER_TIMEOUT_SECONDS="${WINDOWS_SMOKE_RENDER_TIMEOUT_SECONDS:-90}"
MIN_DISTINCT_COLORS="${WINDOWS_SMOKE_MIN_DISTINCT_COLORS:-32}"
# The screen must demonstrably CHANGE because we launched the app. Without this,
# a runner whose desktop is already busy (wallpaper, taskbar, a stray dialog)
# would satisfy a pure "visually complex" check without the app having painted
# anything at all. 20000 px is ~1% of a 1920x1080 desktop: far below any real
# window's footprint, far above compression/anti-alias noise.
MIN_CHANGED_PIXELS="${WINDOWS_SMOKE_MIN_CHANGED_PIXELS:-20000}"
# What the packaged .exe must be. release.yml builds `flutter build windows`,
# which is x64, so the shipped image must be AMD64/PE32+. Overridable so the test
# suite can drive the refusals without needing a real PE of each shape; the
# defaults are the values the release actually produces, and the suite asserts
# the gate is using its defaults, not the ones a test injected.
EXPECT_MACHINE="${WINDOWS_SMOKE_EXPECT_MACHINE:-0x8664}"
EXPECT_PE_MAGIC="${WINDOWS_SMOKE_EXPECT_PE_MAGIC:-0x20b}"
POLL_INTERVAL_SECONDS="${WINDOWS_SMOKE_POLL_INTERVAL_SECONDS:-2}"

# Sidecars the release workflow copies into the bundle (see release.yml
# "Package Windows ZIP"). A packaging regression that drops the native daemon
# still lets the Flutter UI launch, so this is checked from the archive, not
# inferred from "the app started". Read as a ';' list and split deliberately so
# the whole default arrives as one string.
REQUIRED_ENTRIES="${WINDOWS_SMOKE_REQUIRED_ENTRIES:-galleryd.exe;ml_sidecar}"

# Every write into the gate's own log goes through this, which tees to stdout AND
# to $LOG_PATH. The workflow uploads $LOG_PATH as the run log; a reviewer must
# never have to reconstruct the log from the Actions UI to see why a gate failed.
LOG_PATH=""
RUN_PID=""
# 1 while a usable pre-launch desktop capture exists, so the "the screen really
# changed" half of the render assertion is armed. Set in main once the baseline
# has actually been captured (and proven decodable).
#
# It is not a disclosure flag and must not become one. An earlier version treated
# an uncapturable baseline as a warning, left this at 0, and reached a PASS with
# the changed-pixel requirement quietly dropped -- disclosing it in the summary
# and in LIMITATIONS, which is exactly why disclosing it was the wrong design:
# the release is still published, and a reader of the release notes never sees
# this log. So the flag is now an invariant instead: reaching the render loop or
# the end of main with it unset is a hard `fail`, and the only summary wording is
# the unconditional `pre-launch diff: armed`. There is deliberately no DISABLED
# fallback to be reached.
DIFF_ENABLED=0

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

# contains <needle> <haystack>. ${2:-} rather than ${2} on purpose: a caller that
# forgets the haystack must fail CLOSED (a sentinel that "was not found", so the
# gate goes red) instead of aborting the run on an unbound-variable error and
# taking the rest of the assertions with it.
contains() {
  local needle="${1:-}" haystack="${2:-}"
  [[ -n "${needle}" ]] && [[ "${haystack}" == *"${needle}"* ]]
}

log() {
  printf '[%s] %s\n' "${NAME}" "$*"
}

fail() {
  printf '[%s] ERROR: %s\n' "${NAME}" "$*" >&2
  exit 1
}

require_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    fail "missing required tool: $1"
  fi
}

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

wait_until() {
  local description="$1" timeout_seconds="$2"
  shift 2
  local deadline=$((SECONDS + timeout_seconds)) rc=0 unanswered=0
  # Three-valued predicates (0 yes / 1 no / 2 could-not-ask) MUST NOT be flattened
  # here. A plain `if "$@"` discards the distinction between "the app has no
  # window yet" and "the window enumeration could not be answered at all", and
  # the timeout then reports the second as the first.
  #
  # That is not a cosmetic difference. An unqueryable Win32 layer is the exact
  # condition under which a gate that flattens the tri-state reports a confident,
  # specific and WRONG reason -- "the app never created a visible top-level
  # window" -- for a Win32 bridge that is simply broken. The run still fails, so
  # this is a diagnosis failure rather than a false pass, but it points a reviewer
  # at the application instead of at the thing that is actually broken. Preserved
  # here so the caller can say which of the two happened.
  while ((SECONDS < deadline)); do
    rc=0
    if "$@"; then
      return 0
    else
      rc=$?
    fi
    if ((rc == 2)); then
      unanswered=1
    fi
    sleep "${POLL_INTERVAL_SECONDS}"
  done
  log "timed out after ${timeout_seconds}s waiting for ${description}"
  ((unanswered == 1)) && return 2
  return 1
}

# Predicate for wait_until: has the detached launcher written the app's pid yet?
# -s (not -e) on purpose -- a zero-length pid file is a half-written file, and
# reading it would yield an empty pid that later parses as "non-numeric".
pid_file_reported() {
  [[ -s "${RUN_PID_FILE}" ]]
}

# One path policy for evidence: run-internal paths are recorded relative to the
# workspace when they live inside it, absolute otherwise, so evidence is
# comparable across runners instead of embedding /home/runner/... prefixes.
evidence_display_path() {
  local path="$1" workspace="${GITHUB_WORKSPACE:-}"
  if [[ -n "${workspace}" && "${path}" == "${workspace}/"* ]]; then
    printf '%s\n' "${path#"${workspace}/"}"
  else
    printf '%s\n' "${path}"
  fi
}

# --- PowerShell bridge --------------------------------------------------------
#
# Every Win32 operation this gate needs is done by a small, explicit PowerShell
# program written to $WORK_DIR and executed with:
#
#   pwsh -NoProfile -NonInteractive -File <script> [args...]
#
# Why -File and not an inline -Command / -EncodedCommand string: an inline
# command is a quoting minefield (PowerShell's own single-quote escaping, the
# runner's shell, and one more layer of MSYS argument rewriting), and any
# mistake there fails as a *syntax* error that is easy to misread as "the feature
# is unavailable". A real .ps1 file is linted by the shell itself, and a syntax
# error is reported as a syntax error. -NonInteractive guarantees a prompt can
# never block the gate; -NoProfile stops runner profile scripts from injecting
# aliases or progress bars that corrupt parsed output.
#
# MSYS / Git-Bash argument mangling: Git Bash rewrites POSIX-looking arguments
# into Windows paths before handing them to a native (non-MSYS) program. That
# rewriting is why `Program Files` quoting breaks in so many Windows CI scripts.
# We do not fight it: every path this gate passes to PowerShell is first run
# through win_path(), which emits an already-forward-slashed form, and the two
# argv-passing helpers never quote a path themselves -- PowerShell receives each
# path as ONE argv element, and `pwsh -File` reconstructs `$args` correctly.
#
# A space in the path is not hypothetical here: the test suite points
# WINDOWS_SMOKE_WORK_DIR and WINDOWS_SMOKE_EVIDENCE_DIR at directories whose
# names contain a space, so the quoting discipline above is exercised on every
# CI run rather than asserted in a comment. (NEVER VERIFIED ON WINDOWS: that the
# same holds under real MSYS path conversion, which no Linux test can reach. The
# tests substitute a fake `pwsh` that performs no conversion.)

win_path() {
  # Normalise a bash path to the forward-slash Windows form PowerShell expects,
  # without ever losing a space. cygpath -u/-m live in Git Bash; on a non-Windows
  # test host they are absent and the path is passed through unchanged (the tests
  # substitute a fake `pwsh`, so no conversion is needed there).
  local value="${1:-}"
  value="${value//\\//}"
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -m "${value}" 2>/dev/null || printf '%s' "${value}"
  else
    printf '%s' "${value}"
  fi
}

PS_HELPER_DIR=""

# Write a PowerShell helper program to disk. The heredoc is quoted ('PS') so the
# shell does not expand $ inside the PowerShell source.
write_ps_helper() {
  local filename="$1"
  local path="${PS_HELPER_DIR}/${filename}"
  cat >"${path}"
  printf '%s' "${path}"
}

# Invoke a PowerShell helper: run_ps_helper <file.ps1> [args...].
# All arguments are translated with win_path so spaces survive as single argv
# elements. stdout+stderr are merged; the caller inspects the merged text and,
# critically, the exit status. A non-zero status is NEVER swallowed -- callers
# that treat a read as a gate must distinguish "queried, found clean" from
# "could not ask at all".
run_ps_helper() {
  local script="$1"
  shift
  local args=() arg translated
  for arg in "$@"; do
    translated="$(win_path "${arg}")"
    args+=("${translated}")
  done
  set +e
  "${PWSH}" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "${script}" "${args[@]}" 2>&1
  local rc=$?
  set -e
  return "${rc}"
}

# --- Win32: screen capture ----------------------------------------------------
# .NET's Graphics.CopyFromScreen is the standard supported way to grab the
# desktop on Windows without a third-party tool. It reads the *virtual screen*
# (all monitors) from the current interactive session, so this only works if the
# runner's agent is running in an interactive session with a visible desktop --
# which GitHub-hosted windows-latest runners do. It would fail (or return a black
# frame) under a service/session-0 context; that is why the rendered-frame check
# below is a hard assertion and not a warning.
PS_CAPTURE_SCREENSHOT='
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$out = $args[0]
$bounds = [System.Windows.Forms.SystemInformation]::VirtualScreen
$bmp = New-Object System.Drawing.Bitmap $bounds.Width, $bounds.Height
$gfx = [System.Drawing.Graphics]::FromImage($bmp)
try { $gfx.CopyFromScreen($bounds.X, $bounds.Y, 0, 0, $bmp.Size) }
finally { $gfx.Dispose() }
$bmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
Write-Output "PO-SHOT-SAVED"
'

# --- Win32: window enumeration -----------------------------------------------
# EnumerateWindows + GetWindowThreadProcessId + IsWindowVisible, one line per
# visible top-level window, plus the foreground window. This is the Windows
# analogue of the Android gate's `dumpsys window | mCurrentFocus` check: it proves
# the app owns a real, visible, on-screen top-level window (title + geometry),
# not merely that a process exists. Output lines:
#   FG <pid> <hwnd>
#   WIN <pid> <hwnd> <visible 0|1> <w>x<h> <title-b64>
# The title is base64 because it can contain newlines and non-ASCII.
PS_ENUM_WINDOWS='
$ErrorActionPreference = "Stop"
$target = [int]$args[0]
Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public class PoWin {
  public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr l);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
}
"@
$fg = [PoWin]::GetForegroundWindow()
$fgPid = 0
[void][PoWin]::GetWindowThreadProcessId($fg, [ref]$fgPid)
# Sentinel first: a reply without it did not run, and "could not ask" must never
# be read downstream as "no window exists" or "nothing is in the foreground".
Write-Output ("PO-WINDOWS-OK {0} {1}" -f $fgPid, $fg.ToInt64())
$found = New-Object System.Collections.ArrayList
$cb = [PoWin+EnumWindowsProc]{
  param($h, $l)
  $p = 0
  [void][PoWin]::GetWindowThreadProcessId($h, [ref]$p)
  if ($p -eq $target) {
    $sb = New-Object System.Text.StringBuilder 512
    [void][PoWin]::GetWindowTextW($h, $sb, 512)
    $r = New-Object PoWin+RECT
    [void][PoWin]::GetWindowRect($h, [ref]$r)
    $vis = if ([PoWin]::IsWindowVisible($h) -and -not [PoWin]::IsIconic($h)) { 1 } else { 0 }
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($sb.ToString()))
    $w = $r.Right - $r.Left
    $hgt = $r.Bottom - $r.Top
    [void]$found.Add(("WIN {0} {1} {2} {3}x{4} {5}" -f $p, $h.ToInt64(), $vis, $w, $hgt, $b64))
  }
  return $true
}
[void][PoWin]::EnumWindows($cb, [IntPtr]::Zero)
foreach ($line in $found) { Write-Output $line }
'

# --- Win32: process launch / exit code ---------------------------------------
# Start-Process -PassThru gives a Process object with a real ExitCode once the
# process has exited -- something tasklist/Get-Process cannot report after the
# fact. The helper starts the exe, writes "<pid>" to $pidfile, waits, then writes
# "<exitcode>" to $exitfile. The gate polls those files. Redirecting stdout/stderr
# to files is what lets us scan the app's own output for panics later.
PS_LAUNCH='
$ErrorActionPreference = "Stop"
$exe = $args[0]; $stdout = $args[1]; $stderr = $args[2]; $pidfile = $args[3]; $exitfile = $args[4]
$proc = Start-Process -FilePath $exe -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
Set-Content -LiteralPath $pidfile -Value ("PID " + $proc.Id) -NoNewline
$proc.WaitForExit()
Set-Content -LiteralPath $exitfile -Value ("EXIT " + $proc.ExitCode) -NoNewline
'

# --- Win32: process liveness --------------------------------------------------
# Get-Process -Id is the supported way to ask "is this pid still running?". Used
# to distinguish a live app from one that died mid-render.
PS_PROC_LIVE='
$ErrorActionPreference = "Stop"
$id = [int]$args[0]
$p = Get-Process -Id $id -ErrorAction SilentlyContinue
if ($null -eq $p) { Write-Output "PO-PROC-DEAD" } else { Write-Output "PO-PROC-ALIVE" }
'

# --- Win32: process terminate -------------------------------------------------
# Stop-Process -Force is the supported kill. Used to tear the app down at the end
# of a pass (a release-gate runner must not leak a GUI process) and never to
# decide a verdict -- the verdict is taken while the app is still running.
PS_PROC_KILL='
$ErrorActionPreference = "Stop"
$id = [int]$args[0]
Stop-Process -Id $id -Force -ErrorAction SilentlyContinue
Write-Output "KILLED"
'

# --- Win32: Application event log --------------------------------------------
# Count Application-log events in the crash family (1000 Application Error,
# 1001 Windows Error Reporting, 1026 .NET Runtime) that name our executable.
# Read as a pre/post baseline so pre-existing entries on the shared runner image
# cannot fail a healthy build, while a NEW entry naming our exe always does. A
# read that fails is a hard failure (see assert_no_new_crash_events), never a
# silent "clean".
#
# The `-ErrorAction` split below is load-bearing and was the first thing that
# would have broken this on a real runner. `Get-WinEvent` raises a terminating
# "No events were found that match the specified selection criteria" error when a
# filter matches nothing -- which is the *normal, healthy* state of a freshly
# provisioned image. Under `$ErrorActionPreference = "Stop"` plus
# `-ErrorAction Stop` that throw exits non-zero, the gate reads it as "could not
# ask", and every healthy build goes red. So the query is allowed to come back
# empty, and only a query that genuinely could not be performed is reported as a
# failure. This is the same "an empty answer is an answer" rule the Android
# exit-info gate had to learn, arriving from the other direction.
#
# NEVER EXECUTED: written on a Linux host with no PowerShell and no event log.
# The distinction it relies on -- "no matching events" versus "could not query" --
# is asserted structurally by the test suite, not observed.
PS_EVENTLOG='
$ErrorActionPreference = "Stop"
$exe = $args[0]
$ids = @(1000, 1001, 1026)
$n = -1
try {
  $events = @(Get-WinEvent -FilterHashtable @{ LogName = "Application"; Id = $ids } -ErrorAction SilentlyContinue)
  $n = 0
  foreach ($e in $events) {
    if ($e.Message -and $e.Message -like ("*" + $exe + "*")) { $n++ }
  }
} catch {
  Write-Output ("PO-EVENTLOG-FAILED " + $_.Exception.Message)
  exit 1
}
Write-Output ("PO-EVENTLOG-OK " + $n)
'

# --- PNG complexity / diff ---------------------------------------------------
# Implemented in Python's stdlib so the runner needs no image tooling and the
# logic is unit-testable off-Windows (the test suite sources this function
# directly and feeds it synthetic PNGs). Decodes the PNGs this gate produces:
# 8-bit, non-interlaced, greyscale / RGB / greyscale+alpha / RGBA. Anything else
# is refused rather than guessed at, because a mis-decoded frame would make the
# complexity assertion meaningless.
#
# Two facts are computed in one decode pass:
#   * distinct colour count  -> rejects a blank / solid / black screen;
#   * changed pixels vs a baseline capture -> proves the screen actually CHANGED
#     after launch, and (with the byte-identical stability check in the render
#     loop) rejects a screen that never settles.
#
# Print "COLORS=<n> CHANGED=<n>" for a frame. CHANGED is the number of pixels
# that differ from <baseline> (0 when no baseline is given, or when the two
# captures have different geometry -- an incomparable diff must not be reported
# as "unchanged" evidence of stability).
png_stats() {
  local file="$1" baseline="${2:-}" threshold="${3:-0}"
  "${PYTHON}" - "${file}" "${baseline}" "${threshold}" <<'PY'
import struct, sys, zlib

path, baseline, threshold = sys.argv[1], sys.argv[2], int(sys.argv[3])

class BadPng(Exception):
    pass

def decode(path):
    with open(path, "rb") as h:
        data = h.read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise BadPng("not a PNG file")
    off = 8
    w = ht = depth = ctype = None
    idat = bytearray()
    while off + 8 <= len(data):
        (ln,) = struct.unpack(">I", data[off:off+4])
        tag = data[off+4:off+8]
        payload = data[off+8:off+8+ln]
        off += 12 + ln
        if tag == b"IHDR":
            w, ht, depth, ctype, _c, _f, il = struct.unpack(">IIBBBBB", payload)
            if il != 0:
                raise BadPng("interlaced PNG is not supported")
        elif tag == b"IDAT":
            idat += payload
        elif tag == b"IEND":
            break
    channels = {0: 1, 2: 3, 4: 2, 6: 4}.get(ctype)
    if w is None or channels is None:
        raise BadPng("unsupported PNG header (color_type=%s)" % ctype)
    if depth != 8:
        raise BadPng("unsupported PNG bit depth %s; expected 8" % depth)
    raw = zlib.decompress(bytes(idat))
    stride = w * channels
    if len(raw) < (stride + 1) * ht:
        raise BadPng("truncated PNG image data")
    rows = []
    prev = bytearray(stride)
    pos = 0
    for _ in range(ht):
        ft = raw[pos]; pos += 1
        line = bytearray(raw[pos:pos+stride]); pos += stride
        if ft == 1:
            for i in range(channels, stride):
                line[i] = (line[i] + line[i-channels]) & 0xFF
        elif ft == 2:
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 0xFF
        elif ft == 3:
            for i in range(stride):
                left = line[i-channels] if i >= channels else 0
                line[i] = (line[i] + ((left + prev[i]) >> 1)) & 0xFF
        elif ft == 4:
            for i in range(stride):
                left = line[i-channels] if i >= channels else 0
                up = prev[i]
                ul = prev[i-channels] if i >= channels else 0
                p = left + up - ul
                da, db, dc = abs(p-left), abs(p-up), abs(p-ul)
                if da <= db and da <= dc: pr = left
                elif db <= dc: pr = up
                else: pr = ul
                line[i] = (line[i] + pr) & 0xFF
        elif ft != 0:
            raise BadPng("unsupported PNG filter type %d" % ft)
        rows.append(bytes(line))
        prev = line
    return w, ht, channels, rows

try:
    w, ht, channels, rows = decode(path)
except (BadPng, OSError, zlib.error) as exc:
    sys.exit("cannot decode %s: %s" % (path, exc))

seen = set()
for line in rows:
    for s in range(0, len(line), channels):
        seen.add(line[s:s+channels])
colors = len(seen)

changed = 0
if baseline and baseline.strip():
    # A baseline that EXISTS but cannot be decoded is a hard error, not "0
    # changed". Reporting CHANGED=0 for an undecodable baseline would hand the
    # render loop a diff number and let it go red for the wrong reason, or --
    # worse, with MIN_CHANGED_PIXELS=0 would let a blank screen look "stable".
    # Only a genuinely absent/empty baseline means "no baseline to compare".
    try:
        bw, bht, bch, brows = decode(baseline)
    except (BadPng, OSError, zlib.error) as exc:
        sys.exit("cannot decode baseline %s: %s" % (baseline, exc))
    if (bw, bht) != (w, ht):
        # A baseline of different geometry cannot be diffed, and reporting that as
        # CHANGED=0 is a false pass, not a conservative default: with
        # MIN_CHANGED_PIXELS=0 an incomparable comparison satisfies the
        # changed-pixel requirement, and with any other threshold it sends the
        # render loop red for a reason that has nothing to do with the app. Either
        # way the number is a lie. Refuse, loudly, and let the caller decide.
        # (This is reachable in practice: CopyFromScreen can return a different
        # size if the display resolution changes or a monitor is attached between
        # the baseline and the frame.)
        sys.exit("cannot diff %s: geometry %dx%d differs from the baseline's %dx%d"
                 % (path, w, ht, bw, bht))
    for a, b in zip(rows, brows):
        if a != b:
            for s in range(0, len(a), channels):
                if a[s:s+channels] != b[s:s+channels]:
                    changed += 1

print("COLORS=%d CHANGED=%d" % (colors, changed))
PY
}

# --- archive structure (before the app is ever run) --------------------------
# The Windows analogue of the Android "native ABIs present in the APK" check.
# An APK with no native libs still installs on the emulator; a Windows zip with
# no galleryd.exe/ml_sidecar still launches the Flutter UI. Neither is caught by
# observing that "the app started", so the archive itself is asserted. Every way
# this check can fail to run is a hard failure, not a warning -- a skipped check
# here would be a green release that ships a ZIP whose backend is missing.
list_zip_entries() {
  local zip="$1" out
  out="$(unzip -Z1 "${zip}" 2>&1)" || {
    printf '::error::could not list the ZIP archive, so its packaged contents cannot be verified: %s\n' "$(trim "${out}")" >&2
    return 1
  }
  printf '%s\n' "${out}"
}

# Does the archive contain <name>, either as a file ("<name>") or as a directory
# prefix ("<name>/...")?
#
# Entry names are normalised to forward slashes FIRST. This is not cosmetic:
# Windows PowerShell 5.1's Compress-Archive -- which is what release.yml calls to
# build this ZIP -- writes directory separators as BACKSLASHES, so a legitimately
# packaged ml_sidecar directory appears as "ml_sidecar\\private_gallery_ml_
# sidecar.py". Matching the un-normalised name would fail a correctly built
# artifact, and a gate that cries wolf on the real release is a gate that gets
# turned off.
zip_has_entry() {
  local entries="$1" name="$2" normalised entry
  # sed BRE: `\\` matches ONE literal backslash. The source line below is
  # single-quoted, so it reaches sed exactly as written -- `'s|\\|/|g'`. This
  # previously used four backslashes, which in a BRE means "two consecutive
  # literal backslashes", a sequence that never occurs in a ZIP entry name, so
  # the substitution matched nothing and the backslash-separated archives
  # produced by PowerShell 5.1's Compress-Archive were rejected as missing
  # their ml_sidecar entry. Verified empirically against a ZIP built the way
  # release.yml builds it; see the fixture `zip-backslash.zip` in the test suite,
  # which fails without this fix and passes with it.
  normalised="$(sed 's|\\|/|g' <<<"${entries}")"
  while IFS= read -r entry; do
    [[ -n "${entry}" ]] || continue
    # Exact match, or an entry BENEATH that exact name as a directory. This was a
    # bare prefix match (`"${name}"*`) until the test suite's
    # `zip-decoy-entries.zip` fixture caught it: a prefix match accepts
    # `galleryd.exe.old` for `galleryd.exe` and `ml_sidecar_stale/sidecar.py` for
    # `ml_sidecar`, so an archive that shipped neither real sidecar was reported
    # as having shipped both. That is a false pass of exactly the kind this
    # function exists to prevent.
    if [[ "${entry}" == "${name}" || "${entry}" == "${name}/"* ]]; then
      return 0
    fi
  done <<<"${normalised}"
  return 1
}

# Would extracting this archive write anything outside the directory we name?
#
# `unzip` is not trusted to prevent it. Info-ZIP's handling of an entry named
# `../x` has varied across versions and builds, and this gate calls `unzip -o`
# with no path-restricting option, on the assumption that the archive is our own.
# That assumption is what makes this worth asserting rather than skipping: the
# archive is an artifact downloaded by a workflow, and "the packaging step would
# never do that" is not a check.
#
# It also matters for the gate's own verdict, not only the runner's. The app
# executable is located by `find "${EXTRACT_DIR}"`, and the summary hashes that
# path. An escaping entry can put a second copy of the executable somewhere the
# gate does not look, so the bytes that get launched and the bytes that get
# reported need not be the same -- a false pass wearing the costume of a real one.
#
# Fail-closed, and checked before the extraction rather than after, because the
# point is to not perform the extraction at all. Entry names are normalised to
# forward slashes first: release.yml builds this ZIP with PowerShell 5.1's
# Compress-Archive, which writes '\\', so `..\\..\\x` must be caught as
# surely as `../../x`.
assert_no_path_traversal() {
  local zip="$1" entries entry normalised bad=""
  entries="$(list_zip_entries "${zip}")" || return 1
  while IFS= read -r entry; do
    [[ -n "${entry}" ]] || continue
    normalised="$(sed 's|\\|/|g' <<<"${entry}")"
    # An absolute path. A leading '/' covers POSIX; a leading '/' also covers a
    # Windows UNC path once '\\\\' has become '//'; a drive letter covers
    # `C:/...` and `C:\\...`.
    if [[ "${normalised}" =~ ^/ || "${normalised}" =~ ^[A-Za-z]: ]]; then
      bad="${bad}  absolute path:       ${entry}"$'\n'
      continue
    fi
    # A `..` segment anywhere. Wrapped in slashes so a trailing `..` and a `..`
    # that is a whole segment are both caught, and so a legitimate name that
    # merely *contains* dots (`ml_sidecar..bak/x`) is not.
    if [[ "/${normalised}/" == *"/../"* ]]; then
      bad="${bad}  parent traversal:   ${entry}"$'\n'
      continue
    fi
  done <<<"${entries}"
  if [[ -n "${bad}" ]]; then
    printf '::error::the ZIP contains entries that would write outside the extraction directory:\n' >&2
    printf '%s' "${bad}" >&2
    printf 'Refusing to extract it. An archive that cannot be shown safe to extract is not extracted.\n' >&2
    return 1
  fi
  return 0
}

# Is this really a 64-bit Windows executable?
#
# Read out of the bytes rather than asked of the OS, deliberately. The value of
# the check is the sentence: a packaging regression that ships the wrong
# architecture, or a file that is not a PE image at all, should fail as "this is
# not a 64-bit Windows PE executable" instead of as whatever Start-Process
# eventually says about it. It also gives the gate something real to assert
# before it reaches the part that needs an interactive desktop at all, so a
# wrong-arch artifact is reported the same way on a headless runner as on a real
# one.
#
# Every way this can fail to decide is a hard failure: too short to hold the
# headers, no `MZ`, an `e_lfanew` that points outside the file, no `PE\\0\\0`
# signature, an unexpected machine type, or an optional-header magic that is not
# PE32+. None of them may be reported as "clean".
assert_pe_executable() {
  local exe="$1"
  if ! "${PYTHON}" - "${exe}" "${EXPECT_MACHINE}" "${EXPECT_PE_MAGIC}" <<'PYTHON'
import struct
import sys

path, want_machine, want_magic = sys.argv[1], int(sys.argv[2], 0), int(sys.argv[3], 0)
MACHINE = {0x8664: "x86-64 (AMD64)", 0x014C: "x86 (i386)", 0xAA64: "ARM64", 0x01C4: "ARMv7"}
PE_MAGIC = {0x20B: "PE32+ (64-bit)", 0x10B: "PE32 (32-bit)", 0x107: "ROM"}


def bail(reason, detail=""):
    print(f"::error::the packaged executable is not a {want_magic_name} Windows executable: {reason}{detail}",
          file=sys.stderr)
    sys.exit(1)


want_magic_name = PE_MAGIC.get(want_magic, f"0x{want_magic:x}")
try:
    with open(path, "rb") as handle:
        blob = handle.read()
except OSError as exc:
    bail(f"it could not be read ({exc})")

if len(blob) < 0x40:
    bail(f"it is {len(blob)} bytes, too short to hold a DOS header")
if blob[:2] != b"MZ":
    bail(f"it does not begin with the MZ signature (found {blob[:2]!r})")
(e_lfanew,) = struct.unpack_from("<I", blob, 0x3C)
if e_lfanew + 24 > len(blob):
    bail(f"its DOS header points to a PE header at offset {e_lfanew}, past the end of a {len(blob)}-byte file")
if blob[e_lfanew:e_lfanew + 4] != b"PE\x00\x00":
    bail(f"there is no PE signature at the offset its DOS header names (found {blob[e_lfanew:e_lfanew + 4]!r})")
(machine,) = struct.unpack_from("<H", blob, e_lfanew + 4)
(magic,) = struct.unpack_from("<H", blob, e_lfanew + 24)
# Report both together: "wrong architecture" and "not a 64-bit image" are
# different defects and a reader fixing the packaging needs to know which.
seen_machine = MACHINE.get(machine, f"0x{machine:04x}")
seen_magic = PE_MAGIC.get(magic, f"0x{magic:04x}")
if machine != want_machine:
    bail(f"its machine type is {seen_machine}, not {MACHINE.get(want_machine, hex(want_machine))}",
         f" (release.yml builds x64, so this is a packaging regression)")
if magic != want_magic:
    bail(f"its optional header is {seen_magic}, not {want_magic_name}",
         f" (the machine type is correct, so the image itself is inconsistent)")
print(f"PE header: machine={seen_machine} image={seen_magic} pe_offset={e_lfanew}")
PYTHON
  then
    return 1
  fi
  return 0
}

assert_required_entries() {
  local zip="$1" entries abi
  if ! command -v unzip >/dev/null 2>&1; then
    printf '::error::unzip is not available, so the packaged entries cannot be verified.\n' >&2
    return 1
  fi
  entries="$(list_zip_entries "${zip}")" || return 1
  if is_blank "${entries}"; then
    printf '::error::the ZIP listed zero entries; it is empty or unreadable.\n' >&2
    return 1
  fi
  # The app executable itself. Without it there is nothing to launch.
  # Fixed-string matching: EXE_NAME contains a '.', which in a regex would also
  # match "gallerydXexe" and let a mispackaged archive pass the check.
  if ! zip_has_entry "${entries}" "${EXE_NAME}"; then
    printf '::error::the ZIP does not contain the packaged executable %s. It cannot be launched.\n' "${EXE_NAME}" >&2
    return 1
  fi
  log "packaged executable present: ${EXE_NAME}"
  # Sidecars, ';' separated.
  local IFS=';'
  # shellcheck disable=SC2086 # the split on ';' is the point; IFS is set above
  for abi in ${REQUIRED_ENTRIES}; do
    [[ -n "${abi}" ]] || continue
    if zip_has_entry "${entries}" "${abi}"; then
      log "packaged entry present: ${abi}"
    else
      printf '::error::the ZIP does not contain the required entry %s. The release workflow copies the native daemon and ml_sidecar into the bundle; a packaging regression that drops them produces a ZIP whose Flutter UI can start but which cannot do any real work, and "the app launched" would not catch it.\n' "${abi}" >&2
      return 1
    fi
  done
}

# --- window helpers ----------------------------------------------------------
# Parse the PS_ENUM_WINDOWS output. Every Win32 read in this gate is required to
# emit a sentinel line first; a reply without it did not run, and "I could not
# ask" must never be read as "there is no window" or "nothing is in the
# foreground". That distinction is the whole reason these return 2 rather than a
# plain false. Same rule the Android exit-info gate learned the hard way.
#
# A window the app owns must be VISIBLE (IsWindowVisible=1 and not minimised),
# have a non-empty title, and have non-zero area. A 0x0 or minimised window is
# not a rendered frame, so accepting one would let a window that was created and
# immediately hidden satisfy the gate.
#
# Return codes: 0 = yes, 1 = no (a well-formed answer), 2 = could not ask.
app_has_visible_window() {
  local pid="$1" out line kind wpid hwnd vis geometry w h title header=0
  out="$(run_ps_helper "${PS_WINDOWS_SCRIPT}" "${pid}")" || return 2
  while IFS= read -r line; do
    case "${line}" in
      "PO-WINDOWS-OK "*)
        header=1
        ;;
      WIN\ *)
        # WIN <pid> <hwnd> <visible 0|1> <w>x<h> <title-b64>
        # kind and hwnd are read to advance the cursor to the fields used below.
        # shellcheck disable=SC2034 # positional fields, not all are used
        read -r kind wpid hwnd vis geometry title <<<"${line}"
        [[ "${wpid}" == "${pid}" ]] || continue
        [[ "${vis}" == "1" ]] || continue
        w="${geometry%%x*}"
        h="${geometry##*x}"
        [[ "${w}" =~ ^[0-9]+$ && "${h}" =~ ^[0-9]+$ ]] || continue
        ((w > 0 && h > 0)) || continue
        [[ -n "${title}" && "${title}" != "-" ]] || continue
        return 0
        ;;
    esac
  done <<<"${out}"
  # A reply with no sentinel is an unanswered question, not "no window".
  ((header == 1)) || return 2
  return 1
}

# Is a window the app owns the FOREGROUND window? The Android gate re-asserts
# focus inside the render loop; a window can exist while a dialog or another
# window holds focus, and that must fail here too.
#
# The foreground check is the OS's own verdict: PS_ENUM_WINDOWS puts the pid of
# the foreground window on the sentinel line. "We have a visible window" is not
# the same as "our window has focus" -- a modal dialog owned by the same process,
# or another app that raised itself, both leave a visible window behind.
app_window_is_foreground() {
  local pid="$1" out line kind wpid hwnd vis geometry title
  local header=0 fgpid="" sentinel_kind sentinel_pid sentinel_hwnd
  out="$(run_ps_helper "${PS_WINDOWS_SCRIPT}" "${pid}")" || return 2
  while IFS= read -r line; do
    case "${line}" in
      "PO-WINDOWS-OK "*)
        # Only the pid is needed; kind and hwnd are read to advance the cursor.
        # shellcheck disable=SC2034 # positional fields, not all are used
        read -r sentinel_kind sentinel_pid sentinel_hwnd <<<"${line}"
        header=1
        fgpid="${sentinel_pid}"
        ;;
      WIN\ *)
        # Same here: the WIN line is parsed in full so the title lands in $title,
        # but this function only needs the sentinel to have been seen.
        # shellcheck disable=SC2034 # positional fields, not all are used
        read -r kind wpid hwnd vis geometry title <<<"${line}"
        ;;
    esac
  done <<<"${out}"
  ((header == 1)) || return 2
  if [[ -z "${fgpid}" || ! "${fgpid}" =~ ^[0-9]+$ ]]; then
    return 2
  fi
  [[ "${fgpid}" == "${pid}" ]]
}

# --- process helpers ---------------------------------------------------------
# A cold launch: no arguments, a fresh process, stdout/stderr captured to disk
# for the crash scan. The artifact is the packaged executable extracted from the
# exact ZIP under test, never a locally rebuilt copy.
#
# The launcher MUST be detached. PS_LAUNCH ends in $proc.WaitForExit(), so a
# synchronous call would block for as long as the app runs -- which for a healthy
# GUI app is until the gate kills it. The gate therefore starts the launcher in
# the background and polls for the pid file, which the launcher writes the moment
# Start-Process has actually created the process. That ordering is what makes
# "it started" observable independently of "it is still running".
LAUNCHER_JOB_PID=""

launch_process() {
  local exe="$1"
  rm -f "${RUN_PID_FILE}" "${RUN_EXIT_FILE}"
  # The launcher's own stdout/stderr goes to LAUNCH_LOG, which is uploaded as
  # evidence. It is written here rather than left to the redirection alone
  # because a healthy Start-Process produces NO output at all, so an
  # evidence file that is empty on success cannot be distinguished from one that
  # was never written -- and "we have evidence" then rests on the presence of a
  # zero-byte file. Recording the exact invocation means the file is non-empty on
  # every run, so its emptiness becomes a real signal rather than an ambiguity.
  {
    printf 'launcher: %s\n' "${PWSH}"
    printf 'launcher script: %s\n' "$(win_path "${PS_LAUNCH_SCRIPT}")"
    printf 'launcher exe: %s\n' "$(win_path "${exe}")"
    printf 'launcher stdout: %s\n' "$(win_path "${STDOUT_PATH}")"
    printf 'launcher stderr: %s\n' "$(win_path "${STDERR_PATH}")"
    printf 'launcher pid file: %s\n' "$(win_path "${RUN_PID_FILE}")"
    printf 'launcher exit file: %s\n' "$(win_path "${RUN_EXIT_FILE}")"
  } >"${LAUNCH_LOG}"
  # Backgrounded, APPENDING to its own log. MSYS_NO_PATHCONV stops Git Bash from
  # re-mangling the already-cygpath'd argv, so a path containing a space (this
  # gate extracts under a directory that deliberately contains one) arrives as a
  # single argument.
  #
  # `>>` not `>`: the header above has already written this file, and `>` here
  # would truncate it back to zero bytes on a healthy launch -- which is exactly
  # the state the header exists to rule out. `>>` is opened by the subshell when
  # it starts, so it cannot clobber bytes written afterwards.
  MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' "${PWSH}" -NoProfile -NonInteractive \
    -ExecutionPolicy Bypass -File "$(win_path "${PS_LAUNCH_SCRIPT}")" \
    "$(win_path "${exe}")" "$(win_path "${STDOUT_PATH}")" "$(win_path "${STDERR_PATH}")" \
    "$(win_path "${RUN_PID_FILE}")" "$(win_path "${RUN_EXIT_FILE}")" \
    >>"${LAUNCH_LOG}" 2>&1 &
  LAUNCHER_JOB_PID="$!"

  # A named predicate, not a "test expression" string: wait_until invokes "$@"
  # as a COMMAND, and `[[` is a bash KEYWORD -- a `[[` handed in through "$@"
  # is looked up as an executable, so every poll would fail with ENOENT and the
  # wait would always time out.
  if ! wait_until "the packaged executable to report a pid" "${LAUNCH_TIMEOUT_SECONDS}" \
    pid_file_reported; then
    printf '%s\n' "launcher output:" >&2
    cat "${LAUNCH_LOG}" >&2 || true
    fail "the packaged executable did not start within ${LAUNCH_TIMEOUT_SECONDS}s (no pid was reported)"
  fi
  log "launched $(basename "${exe}") (cold, no arguments)"
}

# Stop the detached launcher so the runner is not left holding a PowerShell that
# is still blocked in WaitForExit. Cleanup only; never a verdict input.
stop_launcher() {
  if [[ -n "${LAUNCHER_JOB_PID}" ]]; then
    kill "${LAUNCHER_JOB_PID}" 2>/dev/null || true
    wait "${LAUNCHER_JOB_PID}" 2>/dev/null || true
    LAUNCHER_JOB_PID=""
  fi
}

process_is_alive() {
  # 0 = alive, 1 = definitely dead, 2 = could not ask. A `Get-Process` failure is
  # NOT "dead" and NOT "alive": it is an unanswered question, and the caller must
  # refuse to report a liveness check that never ran. Matching on a bare "ALIVE"
  # substring would also match a PowerShell error string mentioning it.
  local pid="$1" out
  out="$(run_ps_helper "${PS_PROC_LIVE_SCRIPT}" "${pid}")" || return 2
  if contains "PO-PROC-ALIVE" "${out}"; then
    return 0
  fi
  if contains "PO-PROC-DEAD" "${out}"; then
    return 1
  fi
  return 2
}

read_exit_code() {
  # Prints the recorded exit code, or fails if the app is still running (no code
  # exists yet) or the file is unreadable. A missing exit file is NOT zero.
  local value
  [[ -s "${RUN_EXIT_FILE}" ]] || return 1
  value="$(trim "$(cat "${RUN_EXIT_FILE}")")"
  value="${value#EXIT }"
  [[ "${value}" =~ ^-?[0-9]+$ ]] || return 1
  printf '%s' "${value}"
}

kill_process() {
  local pid="$1"
  run_ps_helper "${PS_PROC_KILL_SCRIPT}" "${pid}" >/dev/null 2>&1 || true
}

# --- rendered frame -----------------------------------------------------------
# Wait for a settled, app-owned, visually-complex frame.
#
# What this proves, precisely:
#   1. the process is still alive at the moment of capture (a mid-render crash
#      cannot satisfy this);
#   2. it owns at least one *visible* top-level window with a non-empty title --
#      the Windows analogue of "the app holds window focus";
#   3. that window is the FOREGROUND window at capture time, so a dialog or a
#      second window cannot pass on its behalf;
#   4. the frame is visually complex (>= MIN_DISTINCT_COLORS), which rejects a
#      blank / solid / black screen and an undecodable capture;
#   5. the frame is byte-stable across two consecutive captures, which rejects a
#      screen still animating (splash, progress, repaint storm) -- a launch
#      frame caught mid-transition is not a rendered frame;
#   6. the frame differs from the pre-launch desktop by at least
#      MIN_CHANGED_PIXELS, so "the desktop was already busy" cannot satisfy the
#      gate on its own -- something on screen actually changed because we
#      launched the app.
#
# All six are re-evaluated inside the loop, not once before it: a window that
# loses foreground focus mid-wait (a system dialog, a Defender notification) must
# fail, not be forgiven because it was focused a moment earlier.
await_settled_app_frame() {
  local deadline=$((SECONDS + RENDER_TIMEOUT_SECONDS))
  local rc=0 stats="" frame_colors=-1 frame_changed=-1
  local previous="" current="" stable=0
  local focus_lost=0
  # Published to the summary in main, so the evidence records the numbers the
  # verdict was actually taken on rather than a restatement of the thresholds.
  FRAME_COLORS=""
  FRAME_CHANGED=""

  while ((SECONDS < deadline)); do
    # Defensive invariant, checked inside the loop rather than once before it.
    # The original loop carried `|| ((DIFF_ENABLED == 0))` here, which is a
    # silent-pass branch: if any future edit ever set the flag to 0 on a degraded
    # runner, the changed-pixel requirement would quietly stop being part of the
    # verdict and a blank screen would pass. There is no path that should reach
    # this loop unarmed, so it is a hard failure rather than a tolerance.
    if ((DIFF_ENABLED != 1)); then
      fail "internal invariant violated: reached the render loop with the changed-pixel check disarmed"
    fi

    rc=0
    process_is_alive "${RUN_PID}" || rc=$?
    if ((rc == 2)); then
      rc=1
    fi
    if ((rc != 0)); then
      local exit_code
      if exit_code="$(read_exit_code)"; then
        printf '%s\n' "process output (stdout):" >&2
        cat "${STDOUT_PATH}" >&2 || true
        printf '%s\n' "process output (stderr):" >&2
        cat "${STDERR_PATH}" >&2 || true
        fail "the app exited on its own with code ${exit_code} before rendering a stable frame"
      fi
      fail "the app is no longer running and its exit code could not be read; refusing to report a liveness check that never completed"
    fi

    rc=0
    app_has_visible_window "${RUN_PID}" || rc=$?
    if ((rc == 2)); then
      fail "could not enumerate top-level windows; refusing to report a window check that never ran"
    fi
    if ((rc != 0)); then
      log "no visible top-level window yet (the process is alive but has not shown one)"
      previous=""; stable=0
      sleep "${POLL_INTERVAL_SECONDS}"
      continue
    fi

    rc=0
    app_window_is_foreground "${RUN_PID}" || rc=$?
    if ((rc == 2)); then
      fail "could not read the foreground window; refusing to report a focus check that never ran"
    fi
    if ((rc != 0)); then
      log "a window exists but is not the foreground window yet"
      focus_lost=1
      previous=""; stable=0
      sleep "${POLL_INTERVAL_SECONDS}"
      continue
    fi
    focus_lost=0

    if capture_screenshot "${SCREENSHOT_PATH}"; then
      if stats="$(png_stats "${SCREENSHOT_PATH}" "${PRELAUNCH_PATH}" 2>/dev/null)"; then
        frame_colors="$(awk -F'[= ]' '{print $2}' <<<"${stats}")"
        frame_changed="$(awk -F'[= ]' '{print $4}' <<<"${stats}")"
        if [[ "${frame_colors}" =~ ^[0-9]+$ ]] && ((frame_colors >= MIN_DISTINCT_COLORS)); then
          # sha256_of, not a bare sha256sum: on a host without GNU coreutils an
          # empty digest every iteration would make `stable` never advance and the
          # gate would burn its budget reporting a misleading "no settled frame"
          # verdict about a perfectly good frame.
          current="$(sha256_of "${SCREENSHOT_PATH}")"
          if [[ -n "${current}" && "${current}" == "${previous}" ]]; then
            stable=$((stable + 1))
          else
            stable=0
          fi
          # DIFF_ENABLED is asserted == 1 at the top of every iteration, so the
          # changed-pixel requirement is unconditional here by construction.
          if ((stable >= 1)) && [[ "${frame_changed}" =~ ^[0-9]+$ ]] &&
            ((frame_changed >= MIN_CHANGED_PIXELS)); then
            FRAME_COLORS="${frame_colors}"
            FRAME_CHANGED="${frame_changed}"
            log "settled app frame: ${frame_colors}+ distinct colours, byte-identical across two captures, ${frame_changed} pixels changed vs the pre-launch desktop"
            return 0
          fi
          if ((stable >= 1)) && [[ "${frame_changed}" =~ ^[0-9]+$ ]]; then
            log "frame is stable but only ${frame_changed} pixels differ from the pre-launch desktop (< ${MIN_CHANGED_PIXELS}); the screen has not really changed yet"
          fi
          previous="${current}"
        else
          log "frame is not yet visually complex (${frame_colors} distinct colours); retrying"
          previous=""; stable=0
        fi
      else
        log "screenshot could not be decoded yet; retrying"
        previous=""; stable=0
      fi
    fi
    sleep "${POLL_INTERVAL_SECONDS}"
  done

  if ((focus_lost != 0)); then
    fail "a window was never the foreground window within ${RENDER_TIMEOUT_SECONDS}s; a system dialog or another app is holding the screen"
  fi
  return 1
}

capture_screenshot() {
  local destination="$1" out rc=0
  mkdir -p "$(dirname "${destination}")"
  out="$(run_ps_helper "${PS_SCREENSHOT_SCRIPT}" "${destination}")" || rc=$?
  # A screen capture that fails is not fatal on its own (it may succeed on a later
  # poll), but a capture that claims success and wrote no file is a contradiction
  # we must not read as a frame.
  if ((rc != 0)) || ! contains "PO-SHOT-SAVED" "${out}"; then
    return 1
  fi
  [[ -s "${destination}" ]] || return 1
  return 0
}

# --- crash / panic detection -------------------------------------------------
# Scan the launched process's own output for panic/abort markers. A GUI app
# normally writes nothing here, so an empty file is the clean case -- but a file
# that could not be read is NOT clean, so both files must exist first.
assert_no_panic_output() {
  local out combined
  local marker
  if [[ ! -e "${STDOUT_PATH}" ]]; then
    fail "the launcher's stdout capture is missing; refusing to report a crash-output check that never ran"
  fi
  if [[ ! -e "${STDERR_PATH}" ]]; then
    fail "the launcher's stderr capture is missing; refusing to report a crash-output check that never ran"
  fi
  combined="$(cat "${STDOUT_PATH}" "${STDERR_PATH}" 2>/dev/null || true)"
  printf '%s\n' "${combined}" >"${PROCESS_OUTPUT_PATH}"
  for marker in \
    "panicked at" \
    "RUST_BACKTRACE" \
    "Unhandled exception" \
    "UnhandledException" \
    "ACCESS_VIOLATION" \
    "Exception code:" \
    "STATUS_STACK_BUFFER_OVERRUN" \
    "Fatal error" \
    "Unhandled Exception"; do
    if contains "${marker}" "${combined}"; then
      printf '%s\n' "${combined}" >&2
      fail "the app reported a crash/panic marker in its own output: ${marker}"
    fi
  done
  log "no panic/backtrace marker in the app's stdout/stderr"
}

# --- Windows crash events (baseline diff) ------------------------------------
# Read the count of crash-family Application events naming our exe. Pre-launch
# this is a baseline; post-launch it must not have grown. A read that fails is a
# hard failure: an unanswered question is not a clean device.
read_crash_event_count() {
  local out line="" candidate
  if ! out="$(run_ps_helper "${PS_EVENTLOG_SCRIPT}" "${EXE_NAME}")"; then
    return 2
  fi
  # A helper that reports its OWN failure on stdout and exits non-zero is already
  # caught above. This loop is the other direction: a reply that carries neither
  # sentinel is a reply this script cannot interpret, and counting it as "0
  # crashes" would be reading an unanswered question as a clean result.
  while IFS= read -r candidate; do
    if [[ "${candidate}" == "PO-EVENTLOG-OK "* ]]; then
      line="${candidate}"
      break
    fi
  done <<<"${out}"
  if [[ -z "${line}" ]]; then
    return 2
  fi
  line="${line#PO-EVENTLOG-OK }"
  line="$(trim "${line}")"
  [[ "${line}" =~ ^[0-9]+$ ]] || return 2
  printf '%s' "${line}"
}

assert_no_new_crash_events() {
  local baseline="$1" after rc=0
  after="$(read_crash_event_count)" || rc=$?
  if ((rc != 0)); then
    fail "could not read the Windows Application event log; refusing to report a crash check that never ran"
  fi
  printf 'post-launch crash events naming %s: %s (baseline %s)\n' "${EXE_NAME}" "${after}" "${baseline}" >>"${SUMMARY_PATH}"
  if ((after > baseline)); then
    fail "Windows recorded a new Application Error / .NET Runtime / WER event for ${EXE_NAME} (${baseline} before launch, ${after} after)"
  fi
  log "Windows crash-event log clean (${after} events naming ${EXE_NAME}, same as pre-launch baseline)"
}

print_limitations() {
  # Defensive: DIFF_ENABLED is only cleared by a hard `fail` above, so reaching
  # the end of main with it still 0 means the fail-closed path was bypassed.
  # Asserted here rather than assumed, because this block is the last thing a
  # reader of the run log sees and it must never describe a degraded run as a
  # clean one.
  if ((DIFF_ENABLED != 1)); then
    fail "internal invariant violated: the changed-pixel check was not armed on a run that reached the end"
  fi
  cat <<'LIMIT'
LIMITATIONS (what this gate does NOT prove on a GitHub-hosted windows-latest runner):
  * This is a virtual machine, not a user's physical desktop. It proves the exact
    published bytes extract, start, create a real visible foreground window, and
    paint a real frame. It proves nothing about real hardware, multiple monitors,
    DPI scaling, or a user's GPU/driver stack.
  * The ZIP is UNSIGNED. This gate does not perform or verify Authenticode
    signing, and it does not exercise SmartScreen, Defender/AV reputation, or the
    "Windows protected your PC" interstitial, which only appear on
    shell/Explorer-launched unsigned binaries.
  * There is no installer. This is a portable ZIP; a human "installing" it means
    extracting it. Extraction here is done by the gate, not by a user's shell,
    so a user's unzip-tool/AV/zone-of-death interactions are not covered.
  * It cannot prove a human can USE the app: no library is imported, no daemon
    handshake is verified end to end. It proves the process starts, owns a window,
    renders, and does not crash within the gate's budget.
  * Session context: this relies on the runner agent running in an INTERACTIVE
    desktop session (screen capture requires it). A service/session-0 context
    fails the pre-launch baseline capture, which is a hard failure -- it cannot
    silently degrade into a weaker check.
  * PROVENANCE OF THIS GATE, not of the artifact: the Win32 layer is six
    PowerShell helpers that were written on a Linux host. Until this script has
    run to a PASS on windows-latest, treat every assertion below as
    write-only-and-unverified. A PASS recorded here is the first evidence, not
    a continuation of one.
LIMIT
  cat <<'LIMIT'
  A PASS means the checks above ran and passed. It is not a claim about anything
  this list says the runner cannot see.
LIMIT
}

# --- main --------------------------------------------------------------------
main() {
  local zip="${1:-}" extracted_pid=""
  if [[ -z "${zip}" ]]; then
    echo "usage: $(basename "$0") <path-to-zip>" >&2
    exit 2
  fi
  [[ -f "${zip}" ]] || fail "ZIP not found: ${zip}"
  [[ -s "${zip}" ]] || fail "ZIP is empty: ${zip}"

  # The PS helpers and the extracted tree are scratch. Default WORK_DIR to a
  # unique temp dir so parallel matrix legs never collide; tests override it.
  if [[ -z "${WORK_DIR}" ]]; then
    WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/po-windows-smoke.XXXXXX")"
  else
    mkdir -p "${WORK_DIR}"
  fi
  PS_HELPER_DIR="${WORK_DIR}/pshelpers"
  mkdir -p "${PS_HELPER_DIR}"

  mkdir -p "${EVIDENCE_DIR}"
  SCREENSHOT_PATH="${EVIDENCE_DIR}/${NAME}.png"
  PRELAUNCH_PATH="${EVIDENCE_DIR}/${NAME}-prelaunch.png"
  STDOUT_PATH="${EVIDENCE_DIR}/${NAME}-stdout.txt"
  STDERR_PATH="${EVIDENCE_DIR}/${NAME}-stderr.txt"
  PROCESS_OUTPUT_PATH="${EVIDENCE_DIR}/${NAME}-process-output.txt"
  LAUNCH_LOG="${EVIDENCE_DIR}/${NAME}-launch.log"
  RUN_PID_FILE="${WORK_DIR}/run.pid"
  RUN_EXIT_FILE="${WORK_DIR}/run.exit"
  EXTRACT_DIR="${WORK_DIR}/extracted"
  SUMMARY_PATH="${EVIDENCE_DIR}/${NAME}-summary.txt"
  : >"${SUMMARY_PATH}"

  require_tool "${PYTHON}"
  require_tool unzip

  # Materialise the PowerShell helpers.
  PS_SCREENSHOT_SCRIPT="$(write_ps_helper capture-screenshot.ps1 <<<"${PS_CAPTURE_SCREENSHOT}")"
  PS_WINDOWS_SCRIPT="$(write_ps_helper enum-windows.ps1 <<<"${PS_ENUM_WINDOWS}")"
  PS_LAUNCH_SCRIPT="$(write_ps_helper launch.ps1 <<<"${PS_LAUNCH}")"
  PS_PROC_LIVE_SCRIPT="$(write_ps_helper proc-live.ps1 <<<"${PS_PROC_LIVE}")"
  PS_PROC_KILL_SCRIPT="$(write_ps_helper proc-kill.ps1 <<<"${PS_PROC_KILL}")"
  PS_EVENTLOG_SCRIPT="$(write_ps_helper eventlog.ps1 <<<"${PS_EVENTLOG}")"

  # Structural check on the archive BEFORE anything runs. A packaging regression
  # is reported as "missing sidecar", not as a mysterious launch failure later.
  assert_required_entries "${zip}" ||
    fail "the release artifact is missing required packaged entries (see the errors above)"

  # Before the extraction, not after: the point of asserting an archive is safe
  # is to not extract one that is not.
  assert_no_path_traversal "${zip}" ||
    fail "the release artifact contains entries that would escape the extraction directory (see the errors above)"

  # Extract the exact bytes we just listed.
  rm -rf "${EXTRACT_DIR}"
  mkdir -p "${EXTRACT_DIR}"
  log "extracting $(basename "${zip}") to ${EXTRACT_DIR}"
  # unzip is preferred over Expand-Archive so the tree is identical to what a user
  # gets on double-click, and so a corrupt archive fails here with unzip's own
  # error rather than inside a launch check.
  if ! unzip -q -o "${zip}" -d "${EXTRACT_DIR}" 2>"${WORK_DIR}/unzip-extract.log"; then
    printf '%s\n' "unzip failed to extract the archive:" >&2
    cat "${WORK_DIR}/unzip-extract.log" >&2 || true
    fail "the release archive could not be extracted"
  fi

  # Locate the packaged executable inside the extracted tree. A release ZIP
  # normally has it at the top level, but never assume: search for the basename
  # and require exactly one match, so an ambiguous archive is a failure.
  # Deliberately NOT `find ... | head`: closing the pipe early can SIGPIPE find,
  # which `set -o pipefail` reports as a failure, so a perfectly good archive
  # would look like a broken one. Collect every match, then decide explicitly.
  local exe_path="" match count=0
  while IFS= read -r match; do
    [[ -n "${match}" ]] || continue
    exe_path="${match}"
    count=$((count + 1))
  done < <(find "${EXTRACT_DIR}" -type f -iname "${EXE_NAME}" 2>/dev/null || true)
  if ((count == 0)); then
    printf '%s\n' "extracted tree:" >&2
    find "${EXTRACT_DIR}" -maxdepth 3 2>/dev/null | sed 's/^/  /' >&2 || true
    fail "the packaged executable ${EXE_NAME} was not found in the extracted archive"
  fi
  if ((count > 1)); then
    find "${EXTRACT_DIR}" -type f -iname "${EXE_NAME}" 2>/dev/null | sed 's/^/  /' >&2 || true
    fail "the archive contains ${count} copies of ${EXE_NAME}; refusing to guess which one is the app"
  fi
  # The bytes, not the filename. This is the check that turns "the ZIP contains
  # something called private_gallery_app.exe" into "the ZIP contains a 64-bit
  # Windows PE executable".
  assert_pe_executable "${exe_path}" ||
    fail "the packaged executable is not the expected Windows PE image (see the errors above)"

  # Give the tree a realistic working directory and log the exact path (which may
  # contain spaces) we are about to launch, so a log reader can reproduce it.
  log "packaged executable: ${exe_path}"

  {
    printf 'zip: %s\n' "$(evidence_display_path "${zip}")"
    printf 'zip sha256: %s\n' "$(sha256_of "${zip}")"
    printf 'executable: %s\n' "$(evidence_display_path "${exe_path}")"
    printf 'executable sha256: %s\n' "$(sha256_of "${exe_path}")"
    printf 'python: %s\n' "${PYTHON}"
  } >"${SUMMARY_PATH}"

  # --- pre-launch desktop baseline (for the "did the screen change" diff) ----
  #
  # This baseline is REQUIRED, not best-effort. An earlier version of this file
  # treated an uncapturable pre-launch desktop as a warning, set DIFF_ENABLED=0
  # and carried on to a PASS with a strictly weaker render assertion, printing a
  # note in LIMITATIONS. That is precisely the degraded green this gate exists to
  # prevent, and it fails in the lenient direction, which is the only unacceptable
  # direction:
  #
  #   * nothing downstream re-asserts the changed-pixel check, so a blank or
  #     never-painted screen would ship green;
  #   * "we printed a disclaimer" is not a mitigation -- the release is still
  #     published, and a reader of the release notes does not see this log.
  #
  # So a baseline that cannot be captured, or that cannot be decoded, is a hard
  # failure. If a future Windows runner genuinely cannot provide a desktop
  # capture, the correct response is to fix the runner or to remove this gate and
  # say so in the issue -- not to ship a weaker one. (This mirrors the Android
  # gate's rule that the native-ABI check may never degrade to a warning.)
  log "capturing the pre-launch desktop for the change diff"
  if ! capture_screenshot "${PRELAUNCH_PATH}"; then
    printf '::error::could not capture the pre-launch desktop.\n' >&2
    printf '::error::Without a baseline the gate cannot prove the screen changed because the app was launched, so a busy runner desktop would satisfy the render check on its own. The gate fails closed rather than shipping a weaker assertion.\n' >&2
    fail "the pre-launch desktop baseline could not be captured, so the changed-pixel check cannot run"
  fi
  if ! png_stats "${PRELAUNCH_PATH}" "" >/dev/null 2>&1; then
    printf '::error::the pre-launch desktop capture is not a decodable PNG.\n' >&2
    printf '::error::An unreadable baseline cannot be diffed, and reporting that as "0 changed" would let any frame look like an unchanged screen. The gate fails closed rather than disabling the check.\n' >&2
    fail "the pre-launch desktop baseline is not a decodable PNG, so the changed-pixel check cannot run"
  fi
  # Armed only from the same evidence the diff itself will use. Arming it on "the
  # file exists" would let an undecodable baseline make the render loop
  # unsatisfiable, and disarming it silently would let a blank screen pass.
  DIFF_ENABLED=1
  log "pre-launch baseline is usable; the changed-pixel check is armed (>= ${MIN_CHANGED_PIXELS} px must differ)"

  # Pre-launch Windows crash-event baseline.
  local baseline rc=0
  baseline="$(read_crash_event_count)" || rc=$?
  if ((rc != 0)); then
    fail "could not read the Windows Application event log before launch; refusing to report a crash check that never ran"
  fi
  printf 'pre-launch crash events naming %s: %s\n' "${EXE_NAME}" "${baseline}" >>"${SUMMARY_PATH}"
  log "Windows crash-event baseline: ${baseline} event(s) naming ${EXE_NAME}"

  # --- launch (cold) ---------------------------------------------------------
  launch_process "${exe_path}"
  extracted_pid="$(trim "$(cat "${RUN_PID_FILE}")")"
  extracted_pid="${extracted_pid#PID }"
  RUN_PID="${extracted_pid}"
  if [[ ! "${RUN_PID}" =~ ^[0-9]+$ ]]; then
    fail "launcher reported a non-numeric pid (${RUN_PID})"
  fi
  log "app pid: ${RUN_PID}"

  # --- wait for a window -----------------------------------------------------
  # Tri-state on purpose. wait_until returns 2 when the predicate reported
  # "could not ask", and that must be reported as a broken Win32 bridge rather
  # than as an application that never drew a window. Without this the run failed
  # with a confident and completely wrong reason whenever the window enumeration
  # itself was unavailable.
  win_rc=0
  wait_until "the app to own a visible window" "${LAUNCH_TIMEOUT_SECONDS}" \
    app_has_visible_window "${RUN_PID}" || win_rc=$?
  if ((win_rc == 2)); then
    fail "could not enumerate top-level windows while waiting for one; refusing to report a window check that never ran"
  fi
  if ((win_rc != 0)); then
    fail "the app never created a visible top-level window within ${LAUNCH_TIMEOUT_SECONDS}s"
  fi
  log "app owns a visible top-level window"

  # --- wait for a settled, app-owned, complex frame --------------------------
  if ! await_settled_app_frame; then
    collect_logs
    fail "no settled app frame within ${RENDER_TIMEOUT_SECONDS}s (a blank, never-changing or never-settling screen is a failure)"
  fi

  # --- final liveness + crash assertions -------------------------------------
  rc=0
  process_is_alive "${RUN_PID}" || rc=$?
  if ((rc == 2)); then
    fail "could not query the process table at end of run; refusing to report a liveness check that never ran"
  fi
  if ((rc != 0)); then
    local final_exit
    if final_exit="$(read_exit_code)"; then
      collect_logs
      fail "the app died while rendering (exit code ${final_exit})"
    fi
    fail "the app is no longer running and its exit code could not be read"
  fi

  assert_no_panic_output
  assert_no_new_crash_events "${baseline}"

  # Tear the GUI process down so the runner does not leak it, then record. This
  # happens AFTER the verdict; it is cleanup, never a decision input.
  kill_process "${RUN_PID}"
  collect_logs

  {
    printf 'result: PASS\n'
    printf 'final pid: %s\n' "${RUN_PID}"
    printf 'screenshot: %s\n' "$(evidence_display_path "${SCREENSHOT_PATH}")"
    printf 'pre-launch screenshot: %s\n' "$(evidence_display_path "${PRELAUNCH_PATH}")"
    printf 'distinct colours: %s\n' "${FRAME_COLORS:-unknown}"
    printf 'changed pixels: %s\n' "${FRAME_CHANGED:-unknown}"
    printf 'min distinct colours: %s\n' "${MIN_DISTINCT_COLORS}"
    printf 'min changed pixels: %s\n' "${MIN_CHANGED_PIXELS}"
    # Unconditional, because the only way to reach this point with the check off
    # is a bypassed fail-closed branch -- and print_limitations, which runs after
    # this block, aborts on exactly that. There is deliberately no "DISABLED"
    # wording to fall back to: a degraded green is the outcome this gate must not
    # be able to produce.
    printf 'pre-launch diff: armed\n'
  } >>"${SUMMARY_PATH}"

  log "PASS: the release artifact extracted, cold-launched, owned a visible foreground window, and rendered a stable complex frame on Windows"
  log "evidence: ${SUMMARY_PATH}, ${SCREENSHOT_PATH}, ${PRELAUNCH_PATH}, ${PROCESS_OUTPUT_PATH}, ${LAUNCH_LOG}"
  print_limitations
  log "printed LIMITATIONS above describe what this runner CANNOT prove; do not read a PASS as more than that"
}

# Full stdout+stderr of the gate, for the workflow to upload as run evidence.
collect_logs() {
  # Nothing to drain beyond the per-process files we already wrote; this is a
  # hook so a future step (e.g. dumping the event log) has one obvious place.
  :
}

# Emit the whole run to both stdout and $LOG_PATH, then exit with main's status.
run_and_tee() {
  local rc=0
  # main is invoked as the LEFT element of a pipeline. Bash runs each pipeline
  # element in a subshell that does NOT inherit the caller's `set -e` unless
  # `inherit_errexit` (shopt) is on, which it is not by default -- so main must not
  # depend on the caller's errexit. It does not: main's own last statement is
  # either a `fail` (explicit `exit 1`) or a successful command, and every check
  # inside it is an explicit `if`/`||` that handles its own failure. The verdict
  # is therefore carried out of the pipeline explicitly via PIPESTATUS[0].
  #
  # PIPESTATUS is read on the line immediately after the pipeline and before
  # anything else runs, because ANY intervening command (even a `local`) resets
  # it to the status of that command rather than of the pipeline.
  main "$@" 2>&1 | tee "${LOG_PATH}"
  rc="${PIPESTATUS[0]}"
  return "${rc}"
}

# Create the evidence directory before the first log line can be emitted, then
# pin the log path in the same forward-slash form PowerShell would see. The
# workflow uploads exactly this file as the run's log evidence.
main_setup() {
  mkdir -p "${EVIDENCE_DIR}"
}
main_setup
LOG_PATH="${EVIDENCE_DIR}/${NAME}-gate.log"
run_and_tee "$@"
exit "$?"
