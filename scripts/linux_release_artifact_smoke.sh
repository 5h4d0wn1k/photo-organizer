#!/usr/bin/env bash
#
# Artifact-level release gate for the Linux release artifacts: prove the exact
# files we are about to publish can be installed, cold-launched, made to render
# a real frame on a real X server, and proven not to have crashed.
#
# Why this exists: issue #98. CI ran the unit and integration suites, built a
# Linux AppImage and a .deb, and shipped them without anything ever executing
# them. Every check that ran validated the *code*; none validated the *binary*.
# This script closes that gap, and is the Linux counterpart of
# scripts/android_release_artifact_smoke.sh (issue #97).
#
# Design notes (each of these is a deliberate decision, not an accident):
#
#   * It is a committed script, not an inline `run:` block. The gate's logic is
#     the deliverable, so it has to be reviewable, testable, and runnable on a
#     developer machine. All CI-specific work is confined to passing the artifact
#     directory and the evidence directory.
#
#   * The script owns its X server. It re-executes itself under `xvfb-run`, so
#     there is no separate "start the display" step to forget and no dependency on
#     an interactive DISPLAY. `Xvfb` and `xauth` are hard requirements: Debian's
#     `xvfb-run` exits 127 with a cryptic message when xauth is missing, and a
#     gate that dies for a missing helper instead of naming it trains people to
#     ignore red builds. Screen geometry is 1280x800x24 (the geometry the Flutter
#     Xvfb harness uses) and `-nolisten tcp` keeps a stray TCP listener off a
#     shared runner.
#
#   * Two artifacts, two legs, both required. The release publishes an AppImage
#     AND a .deb, so the gate proves both. Requiring both is deliberate: if the
#     Linux build silently stopped producing one of them, a gate that skipped the
#     missing one would report a pass it never earned.
#
#   * "Install" for the .deb is a faithful *data-layout* extraction performed by
#     `dpkg-deb -x` (the same tool dpkg itself uses to unpack `data.tar.*`), with
#     `bsdtar` as a fallback extractor. It is NOT `dpkg -i`. That is a stated
#     limitation, not a shortcut: `dpkg -i` needs root, mutates the runner, and
#     would add a second, untestable code path. The package's control file
#     declares no maintainer scripts, so extraction loses nothing but dpkg's
#     metadata database. Absolute install paths inside the package
#     (`/usr/bin/photo-organizer`, `Exec=/opt/photo-organizer/AppRun`) are still
#     asserted, mapped onto the extraction root, so a package that would not
#     install into a working layout is still rejected.
#
#   * "Cold launch" is defined rather than assumed. Each leg gets a fresh process
#     group (via `setsid --wait`, which also hands back the child's real exit
#     status), a private `HOME`/`XDG_*` tree so no dconf/gsettings state from the
#     runner can shape the first frame, a private `TMPDIR` so the AppImage's
#     extraction cannot collide with anything else, and a private
#     `PRIVATE_GALLERY_RUNTIME_ROOT` so the app's and daemon's own logs are
#     captured as evidence instead of being lost.
#
#   * "Launched" is not "rendered", and neither is "rendered once". The gate
#     requires all of: a top-level window covering at least
#     LINUX_SMOKE_MIN_WINDOW_PERCENT of the root; `Map State: IsViewable` from an
#     authoritative `xwininfo -id` query; a window rectangle containing at least
#     LINUX_SMOKE_MIN_COLOURS distinct colours (a blank frame, a solid background,
#     or a failed-to-composite frame all fail this); and `compare -metric AE`
#     between two captures taken LINUX_SMOKE_SETTLE_SECONDS apart differing by at
#     most LINUX_SMOKE_MAX_UNSETTLED_PIXELS. The AE threshold rather than
#     byte-identity is deliberate: a caret blink should not fail a release, but a
#     screen still animating or mid-transition should.
#
#   * The metrics are self-checked at runtime. A colour threshold is only evidence
#     if `%k` still counts colours, and a pixel-diff bound is only evidence if AE
#     still diffs pixels. On a broken or stubbed ImageMagick both can exit 0 and
#     print nothing, turning the two strongest assertions into silent passes. The
#     gate therefore renders known images (solid, two-colour) and self-compares,
#     and fails closed if the answers are not exactly 1, 2, 0 and non-zero.
#
#   * Crash detection is process-level plus log-level, and the two are treated
#     differently on purpose. A process that dies on its own, before the frame is
#     proven or after it is proven, fails the gate -- including death by signal,
#     which is how a Rust `galleryd` segfault or a Flutter engine crash presents.
#     In the logs, native crash signatures (SIGSEGV/SIGABRT, sanitizers, "terminate
#     called", stack smashing) fail the gate, and a Rust `panicked at` in
#     `galleryd.log` fails the gate. A Dart "Unhandled exception" is recorded as a
#     WARNING and does not fail: this app talks to D-Bus and the Secret Service,
#     which do not exist on a headless runner, so treating an
#     environment-driven Dart error as an artifact defect would be a false
#     failure. The asymmetry is deliberate and stated, not an oversight.
#
#   * The exec bit is not assumed. Artifact upload/download does not preserve it,
#     and `chmod +x` on the published file would mutate a checksum-verified
#     artifact. The gate chmods a private copy and records both modes.
#
#   * LIMITATION, stated rather than papered over: `assets/linux/photo-organizer.desktop`
#     declares `Exec=photo-organizer`, a bare name, while the AppImage ships a FLAT
#     AppDir in which no file called `photo-organizer` exists (the .deb works
#     because packaging rewrites `Exec` to the absolute
#     `/opt/photo-organizer/AppRun`). So for the AppImage the gate asserts the
#     payload layout and the real launch, and RECORDS the desktop entry's
#     unresolved `Exec` as a warning instead of asserting it resolves. Fixing the
#     packaging is out of scope for this issue; a gate that asserted the broken
#     thing could never go green, and one that deleted the assertion would be a
#     false pass. The .deb leg does assert absolute-`Exec` resolution, which is
#     the half that is supposed to work.
#
#   * LIMITATION: `--appimage-extract` is used to inspect the AppImage payload,
#     which needs a working FUSE. A runner without `libfuse2` therefore fails on
#     `appimage_payload_extract` rather than degrading quietly. The launch itself
#     uses `APPIMAGE_EXTRACT_AND_RUN=1` and needs no FUSE at all, so payload
#     inspection and launch fail for separate, separately diagnosable reasons.
#
#   * LIMITATION: the evidence proves a real X client drew a stable, visually
#     complex frame in a real window of the real artifact. It cannot prove the
#     frame came from the app's own UI rather than from a theme-provided
#     placeholder -- the same false pass the Android gate documents for the API
#     31+ system splash. This app does not map a window until Flutter's
#     first-frame callback (`app/linux/runner/my_application.cc`), so a mapped
#     window is strong but not conclusive evidence of a painted first frame.
#
#   * Every assertion carries a stable `assertion=<tag>` name. The structural test
#     suite mutates the gate one assertion at a time and requires that exact tag to
#     go red, which is what keeps "the gate is wired up" from being an
#     unfalsifiable claim.
#
# Exit status: 0 = every leg passed. 1 = a named assertion failed. 2 = usage error
# (bad arguments or a non-integer tunable).

set -euo pipefail

# ---------------------------------------------------------------------------
# Tunables
# ---------------------------------------------------------------------------
#
# Overridable so the structural test suite can exercise failure paths without a
# real 120-second launch, and so a genuinely different display can say so in one
# place instead of by editing an assertion. Every one of these is an assertion
# threshold: the defaults are strict and there is no switch that turns an assertion
# off.
#
# 20% of a 1280x800 root is 204800 px^2 against a 1280x720 window at 921600 px^2,
# so a correctly mapped app clears it by 4.5x while the 10x10 GTK helper windows
# the toolkit creates clear it by nothing.
: "${LINUX_SMOKE_MIN_WINDOW_PERCENT:=20}"
# 32 distinct colours. The real app renders 1139 in the window rectangle; an
# unfilled window or a failed GL context renders 1.
: "${LINUX_SMOKE_MIN_COLOURS:=32}"
# 64 differing pixels between two captures 3s apart: ~0.006% of the frame.
: "${LINUX_SMOKE_MAX_UNSETTLED_PIXELS:=64}"
: "${LINUX_SMOKE_SETTLE_SECONDS:=3}"
: "${LINUX_SMOKE_POLL_SECONDS:=2}"
: "${LINUX_SMOKE_SETTLE_ATTEMPTS:=3}"
# 120s. The app maps its window about 5s after exec locally; CI runners are
# slower, and this gate must not be the flaky thing in the release.
: "${LINUX_SMOKE_LAUNCH_TIMEOUT:=120}"
# The token a probed window's WM_CLASS (or its name) must carry to be accepted as
# the app's when PID ancestry could not settle it. Empty DISABLES the fallback,
# which is the right setting for a machine where no such token can be trusted --
# with it empty, an unattributable window is a hard failure and there is no second
# way in. The default is the shipped binary's name, which is also the basename
# GTK puts in WM_CLASS for a Flutter Linux app.
: "${LINUX_SMOKE_EXPECT_WINDOW_MATCH:=photo-organizer}"
# How far up the PPID chain the attribution walk is willing to go. Not an
# assertion threshold; a bound so a pathological /proc cannot hang the gate on its
# own diagnosis. A healthy `setsid --wait` chain is two or three links.
: "${LINUX_SMOKE_ANCESTRY_LIMIT:=16}"
# 60s of retrying the colour probe, so a slow first paint is not a failure but a
# permanently blank window still is.
: "${LINUX_SMOKE_RENDER_TIMEOUT:=60}"
: "${LINUX_SMOKE_NAME:=gate}"
: "${LINUX_SMOKE_EVIDENCE_DIR:=}"
: "${LINUX_SMOKE_KEEP_SCRATCH:=0}"
# How long cleanup waits between SIGTERM and SIGKILL, and between the group kill
# and the pkill sweep. Not an assertion threshold -- nothing is proven or
# disproven by it -- just the grace an X client and a Rust daemon get to exit
# cleanly so the runner is left tidy.
: "${LINUX_SMOKE_TEARDOWN_GRACE_SECONDS:=1}"

# Software GL is mandatory, not an optimisation: under a bare Xvfb there is no
# GPU and no DRM node, so the default GL path produces no window at all, and a
# gate that depends on which driver a runner happens to have is not a gate.
# Exported for the launch only, and overridable so a real-GPU runner can prove the
# accelerated path instead.
: "${LINUX_SMOKE_LIBGL_ALWAYS_SOFTWARE:=1}"
: "${LINUX_SMOKE_GDK_BACKEND:=x11}"
: "${LINUX_SMOKE_GDK_GL:=gles}"

XVFB_SERVER_ARGS='-screen 0 1280x800x24 -nolisten tcp'

# Signatures that mean "this process died badly" in any language's log. Kept to
# things a healthy headless run cannot produce.
NATIVE_CRASH_RE='Segmentation fault|core dumped|\bAborted\b|SIGSEGV|SIGABRT|SIGBUS|SIGILL|SIGFPE|AddressSanitizer|LeakSanitizer|MemorySanitizer|ThreadSanitizer|UndefinedBehaviorSanitizer|stack smashing|double free|free\(\): |malloc\(\): |terminate called|assertion .* failed'
# A Rust panic is an unambiguous daemon defect, so it is promoted to a failure in
# the daemon's own log. It is not in the list above because the same text could
# appear in a Flutter-side log where the environment is not clean.
RUST_PANIC_RE='panicked at|thread .* panicked at|RUST_BACKTRACE'
# Environment-induced Dart errors: recorded, never fatal (see header).
DART_SOFT_RE='Unhandled exception|Unhandled Exception|EXCEPTION CAUGHT'

usage() {
  cat <<'EOF'
Usage: linux_release_artifact_smoke.sh <artifact-dir>

Proves the Linux release artifacts in <artifact-dir> install, cold-launch and
render a real frame under Xvfb, and that neither leg crashes.

The directory must contain exactly one *.AppImage and exactly one *_amd64.deb
(the names produced by the `linux` job in release.yml).

Environment:
  LINUX_SMOKE_EVIDENCE_DIR            where evidence is written (default: ./linux-smoke-evidence)
  LINUX_SMOKE_NAME                    evidence/log label (default: gate)
  LINUX_SMOKE_MIN_WINDOW_PERCENT      min top-level window area as % of root (default 20)
  LINUX_SMOKE_MIN_COLOURS             min distinct colours in the window rect (default 32)
  LINUX_SMOKE_MAX_UNSETTLED_PIXELS    max differing pixels between settles (default 64)
  LINUX_SMOKE_SETTLE_SECONDS          seconds between the two settle captures (default 3)
  LINUX_SMOKE_SETTLE_ATTEMPTS         settle comparisons before failing (default 3)
  LINUX_SMOKE_POLL_SECONDS            poll interval while waiting (default 2)
  LINUX_SMOKE_LAUNCH_TIMEOUT          seconds to wait for a viewable window (default 120)
  LINUX_SMOKE_RENDER_TIMEOUT          seconds to wait for a complex frame (default 60)
  LINUX_SMOKE_LIBGL_ALWAYS_SOFTWARE / _GDK_BACKEND / _GDK_GL   launch GL config
  LINUX_SMOKE_KEEP_SCRATCH=1          keep the scratch tree (always kept on failure)
EOF
}

# ---------------------------------------------------------------------------
# Logging / assertions
# ---------------------------------------------------------------------------
#
# `fail` takes a stable assertion tag first. The tag is what the structural test
# suite greps for after mutating a single assertion, so a tag that changes -- or a
# failure reporting a different one -- is itself a test failure.

EVIDENCE_DIR=""
SUMMARY_FILE=""
SCRATCH=""
APP_PID=""
LAST_ASSERTION="none"
RESULT="fail"
WAIT_STATUS=0
ROOT_W=0
ROOT_H=0
# Set by probe_window / verify_window_mapped.
PROBE_ID=""
PROBE_W=0
PROBE_H=0
PROBE_X=0
PROBE_Y=0
CROP_GEOM=""
# Which leg is being run, and what to call it in an assertion message. Set by
# run_leg, read by verify_window_mapped when it reports an unattributable window,
# which is the one failure whose text has to be readable on its own.
probe_leg=""
leg_label=""

log() {
  printf '[%s] %s\n' "${SMOKE_NAME}" "$*"
}

warn() {
  printf '[%s] WARN: %s\n' "${SMOKE_NAME}" "$*" >&2
}

record() {
  printf '%s=%s\n' "$1" "${2-}" >>"${SUMMARY_FILE}"
}

fail() {
  local tag="$1"
  shift
  LAST_ASSERTION="${tag}"
  RESULT="fail"
  printf '[%s] FAIL assertion=%s: %s\n' "${SMOKE_NAME}" "${tag}" "$*" >&2
  record "assertion" "${tag}"
  record "result" "fail"
  exit 1
}

# An integer-validated tunable. A typo in a threshold must not silently become 0
# (which makes the assertion free) or empty (which makes the comparison a syntax
# error).
require_uint() {
  local name="$1" value="$2"
  if [[ ! "${value}" =~ ^[0-9]+$ ]]; then
    printf 'ERROR: %s=%s is not a non-negative integer\n' "${name}" "${value}" >&2
    exit 2
  fi
}

require_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    fail required_tool "missing required tool: $1"
  fi
}

# ---------------------------------------------------------------------------
# Arguments and thresholds
# ---------------------------------------------------------------------------
#
# Checked BEFORE the X server is started, and that ordering is deliberate.
# Asking the gate for its usage, passing it the wrong number of arguments, or
# handing it a threshold that is not a number are all questions a person or a
# wrapper script asks when something is already wrong; answering them must not
# depend on an X server existing, must not spin one up, and must not write
# evidence. This block used to sit after the `xvfb-run` re-exec, so `--help` on
# a machine without `xvfb`/`xauth` died with `xvfb_tooling` and exit 1 -- an
# unanswerable question dressed up as an answer.
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi
if [[ $# -ne 1 ]]; then
  usage >&2
  exit 2
fi
ARTIFACT_DIR="$1"
if [[ ! -d "${ARTIFACT_DIR}" ]]; then
  printf 'ERROR: artifact directory does not exist: %s\n' "${ARTIFACT_DIR}" >&2
  exit 2
fi
ARTIFACT_DIR="$(cd "${ARTIFACT_DIR}" && pwd)"

for pair in \
  "LINUX_SMOKE_MIN_WINDOW_PERCENT:${LINUX_SMOKE_MIN_WINDOW_PERCENT}" \
  "LINUX_SMOKE_MIN_COLOURS:${LINUX_SMOKE_MIN_COLOURS}" \
  "LINUX_SMOKE_MAX_UNSETTLED_PIXELS:${LINUX_SMOKE_MAX_UNSETTLED_PIXELS}" \
  "LINUX_SMOKE_SETTLE_SECONDS:${LINUX_SMOKE_SETTLE_SECONDS}" \
  "LINUX_SMOKE_SETTLE_ATTEMPTS:${LINUX_SMOKE_SETTLE_ATTEMPTS}" \
  "LINUX_SMOKE_POLL_SECONDS:${LINUX_SMOKE_POLL_SECONDS}" \
  "LINUX_SMOKE_LAUNCH_TIMEOUT:${LINUX_SMOKE_LAUNCH_TIMEOUT}" \
  "LINUX_SMOKE_RENDER_TIMEOUT:${LINUX_SMOKE_RENDER_TIMEOUT}" \
  "LINUX_SMOKE_TEARDOWN_GRACE_SECONDS:${LINUX_SMOKE_TEARDOWN_GRACE_SECONDS}"; do
  require_uint "${pair%%:*}" "${pair#*:}"
done

# ---------------------------------------------------------------------------
# Xvfb ownership
# ---------------------------------------------------------------------------
#
# Re-exec under xvfb-run exactly once; the guard variable is what makes the
# re-exec terminate instead of two runs ping-ponging forever.

if [[ "${LINUX_SMOKE_UNDER_XVFB:-0}" != "1" ]]; then
  for t in xvfb-run Xvfb xauth; do
    if ! command -v "${t}" >/dev/null 2>&1; then
      printf '[%s] FAIL assertion=xvfb_tooling: missing required tool: %s\n' \
        "${LINUX_SMOKE_NAME}" "${t}" >&2
      printf 'The Linux artifact gate needs a real X server. On Debian/Ubuntu:\n' >&2
      printf '  sudo apt-get install -y xvfb xauth\n' >&2
      exit 1
    fi
  done
  # `env` carries the guard across the exec; xvfb-run does not set it. The X
  # server's own stderr is forwarded so a dying Xvfb is visible in the CI log
  # instead of surfacing only as "no window appeared".
  exec xvfb-run --auto-servernum --server-args="${XVFB_SERVER_ARGS}" -e /dev/stderr \
    env LINUX_SMOKE_UNDER_XVFB=1 "${0}" "$@"
fi

# ---------------------------------------------------------------------------
# Evidence
# ---------------------------------------------------------------------------
SMOKE_NAME="${LINUX_SMOKE_NAME}"
if [[ -z "${LINUX_SMOKE_EVIDENCE_DIR}" ]]; then
  EVIDENCE_DIR="$(pwd)/linux-smoke-evidence"
else
  EVIDENCE_DIR="${LINUX_SMOKE_EVIDENCE_DIR}"
fi
mkdir -p "${EVIDENCE_DIR}"
EVIDENCE_DIR="$(cd "${EVIDENCE_DIR}" && pwd)"

if [[ -z "${DISPLAY:-}" ]]; then
  fail x11_display "DISPLAY is unset inside the gate; the xvfb-run re-exec did not happen"
fi

# The summary is the FIRST thing written, so the evidence directory is never
# empty. The release workflow uploads it with `if-no-files-found: error`, and
# evidence that is missing because the gate died before its first write would be
# indistinguishable from a gate that found nothing wrong.
SUMMARY_FILE="${EVIDENCE_DIR}/linux-smoke-${SMOKE_NAME}-summary.txt"
: >"${SUMMARY_FILE}"
record "gate" "linux_release_artifact_smoke"
record "name" "${SMOKE_NAME}"
record "started_utc" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
record "artifact_dir" "${ARTIFACT_DIR}"
record "display" "${DISPLAY}"
record "xvfb_server_args" "${XVFB_SERVER_ARGS}"
record "gl_config" "LIBGL_ALWAYS_SOFTWARE=${LINUX_SMOKE_LIBGL_ALWAYS_SOFTWARE} GDK_BACKEND=${LINUX_SMOKE_GDK_BACKEND} GDK_GL=${LINUX_SMOKE_GDK_GL}"
record "thresholds" "min_window_percent=${LINUX_SMOKE_MIN_WINDOW_PERCENT} min_colours=${LINUX_SMOKE_MIN_COLOURS} max_unsettled_px=${LINUX_SMOKE_MAX_UNSETTLED_PIXELS}"
record "result" "in-progress"

# From here a failure must still leave a truthful summary, including which
# assertion failed.
on_exit() {
  local status=$?
  if [[ -n "${SUMMARY_FILE}" && "${RESULT}" != "pass" ]]; then
    record "assertion" "${LAST_ASSERTION}"
    record "result" "fail"
    record "exit_status" "${status}"
  fi
  if [[ -n "${SCRATCH}" ]]; then
    if [[ "${RESULT}" == "pass" && "${LINUX_SMOKE_KEEP_SCRATCH}" != "1" ]]; then
      rm -rf "${SCRATCH}" 2>/dev/null || true
    else
      record "scratch_kept" "${SCRATCH}"
    fi
  fi
}
trap on_exit EXIT
# A cancelled CI job must not orphan an X client on the runner.
trap 'if [[ -n "${APP_PID}" ]] && kill -0 "${APP_PID}" 2>/dev/null; then kill_tree "${APP_PID}"; fi' INT TERM

# ---------------------------------------------------------------------------
# Tooling
# ---------------------------------------------------------------------------
#
# ImageMagick 7 ships `magick` plus optional compat symlinks. Resolve both shapes
# rather than hardcoding IM6 names, so the gate works on a runner whose package
# dropped the symlinks.
if command -v import >/dev/null 2>&1 && command -v convert >/dev/null 2>&1 \
  && command -v compare >/dev/null 2>&1; then
  IMPORT_CMD=(import)
  CONVERT_CMD=(convert)
  COMPARE_CMD=(compare)
elif command -v magick >/dev/null 2>&1; then
  IMPORT_CMD=(magick import)
  CONVERT_CMD=(magick convert)
  COMPARE_CMD=(magick compare)
else
  fail imagemagick_tooling \
    "need ImageMagick's import/convert/compare (or IM7's magick); install the imagemagick package"
fi

for t in xwininfo setsid find grep sed awk cat date mktemp od stat \
  sha256sum readlink wc sort tr cut basename dirname sleep env chmod cp \
  mkdir rm; do
  require_tool "${t}"
done

IMAGEMAGICK_LOG="${EVIDENCE_DIR}/linux-smoke-${SMOKE_NAME}-imagemagick.log"
record "imagemagick" "${IMPORT_CMD[*]}"
record "xwininfo" "$(xwininfo -version 2>&1 | tr '\n' ' ' | cut -c1-100)"

# ---------------------------------------------------------------------------
# Metric self-check
# ---------------------------------------------------------------------------
#
# `compare -metric AE` has two on-disk answer shapes and the gate must read both.
# IM6 prints a bare integer (`1024`). IM7 prints the count followed by the
# normalised ratio in parentheses -- `1024 (0.001)` -- and switches to C
# scientific notation once the count reaches 1e6: a full 1280x800 root that
# changes completely prints `1.024e+06 (1)`. BOTH shapes were reproduced against
# ImageMagick 7.1.2 while writing this, and both occur on a plain 1280x800 Xvfb
# screen, so a parser that only accepted `^[0-9]+$` did not miss an edge case --
# it read EVERY IM7 answer, including a perfectly stable one (`0 (0)`), as "the
# metric is broken". The parse therefore lives in one place and is used by the
# self-check and the settle probe alike.
normalise_ae() {
  local raw="$1" count
  raw="$(printf '%s' "${raw}" | tr -d '[:space:]')"
  # Drop IM7's trailing `(normalised)` half, if present.
  count="${raw%%(*}"
  if [[ "${count}" =~ ^[0-9]+$ ]]; then
    printf '%s' "${count}"
    return 0
  fi
  # `1.024e+06` -> `1024000`. AE counts are whole pixels, so there is nothing to
  # round; LC_ALL=C keeps the decimal point a point.
  if [[ "${count}" =~ ^[0-9]+(\.[0-9]+)?[eE][+-]?[0-9]+$ ]]; then
    LC_ALL=C awk -v x="${count}" 'BEGIN { printf "%.0f", x }'
    return 0
  fi
  return 1
}

# A threshold is only evidence if the tool behind it still works: a stubbed
# `convert`/`compare` exits 0 and prints nothing, which would turn the two
# strongest assertions into no-ops. Prove %k counts colours and AE counts
# differing pixels, on images whose answers are known exactly.
metric_selfcheck() {
  local dir="$1"
  local k_solid k_two self_ae cross_ae
  local solid="${dir}/solid.png" two="${dir}/two-hue.png"

  if ! "${CONVERT_CMD[@]}" -size 8x8 'xc:#ff0000' "png:${solid}" 2>>"${IMAGEMAGICK_LOG}"; then
    fail metric_selfcheck_colours "could not render the solid self-check image"
  fi
  # Two 4px halves side by side: exactly two colours, no antialiasing, so the
  # expected count is unambiguous.
  if ! "${CONVERT_CMD[@]}" -size 4x8 'xc:#ff0000' -size 4x8 'xc:#0000ff' \
    +append "png:${two}" 2>>"${IMAGEMAGICK_LOG}"; then
    fail metric_selfcheck_colours "could not render the two-colour self-check image"
  fi

  k_solid="$("${CONVERT_CMD[@]}" "${solid}" -format '%k' info: 2>>"${IMAGEMAGICK_LOG}" || true)"
  k_two="$("${CONVERT_CMD[@]}" "${two}" -format '%k' info: 2>>"${IMAGEMAGICK_LOG}" || true)"
  # The self-check answers are exact, so this comparison must be exact too: a
  # loose one would let a broken metric tool through the very check meant to
  # catch it.
  if [[ "${k_solid}" != "1" || "${k_two}" != "2" ]]; then
    fail metric_selfcheck_colours \
      "ImageMagick colour-count self-check failed (solid='${k_solid}' expected 1, two-hue='${k_two}' expected 2); the colour assertion would be meaningless"
  fi

  # `compare` prints the metric on stderr and exits 1 when the images differ, so
  # the status is discarded on purpose and only the printed number is trusted --
  # but only after a self-compare has proved the number is a real count, and only
  # after `normalise_ae` has reduced IM7's `0 (0)` / `1.024e+06 (1)` shapes to a
  # plain integer.
  self_ae="$("${COMPARE_CMD[@]}" -metric AE "${solid}" "${solid}" null: 2>&1 || true)"
  self_ae="$(normalise_ae "${self_ae}")" || self_ae=""
  if [[ ! "${self_ae}" =~ ^[0-9]+$ ]]; then
    fail metric_selfcheck_settle \
      "ImageMagick AE self-check returned a non-numeric result ('${self_ae}'); the stability assertion would be meaningless"
  fi
  # AE against a genuinely different image, so a tool that always prints 0 is
  # caught rather than trusted.
  cross_ae="$("${COMPARE_CMD[@]}" -metric AE "${solid}" "${two}" null: 2>&1 || true)"
  cross_ae="$(normalise_ae "${cross_ae}")" || cross_ae=""
  if [[ ! "${cross_ae}" =~ ^[0-9]+$ ]] || ((cross_ae <= 0)); then
    fail metric_selfcheck_settle \
      "ImageMagick AE self-check did not detect differing pixels between two different images (got '${cross_ae}'); the stability assertion would be meaningless"
  fi

  record "metric_selfcheck" "ok k_solid=${k_solid} k_two_hue=${k_two} self_ae=${self_ae} cross_ae=${cross_ae}"
  rm -f "${solid}" "${two}"
}

# ---------------------------------------------------------------------------
# X probes
# ---------------------------------------------------------------------------
#
# Root geometry, read once. Every area comparison is relative to these two
# numbers, so "20% of the screen" cannot be fudged by a probe that reports
# nothing.
root_geometry() {
  local out dims
  if ! out="$(xwininfo -root 2>&1)"; then
    fail root_geometry "xwininfo -root failed: ${out}"
  fi
  dims="$(printf '%s\n' "${out}" \
    | awk '/^[[:space:]]+Width:/ {w=$2} /^[[:space:]]+Height:/ {h=$2} END {if (w=="" || h=="") exit 1; print w" "h}')" || true
  if [[ -z "${dims}" ]]; then
    fail root_geometry "could not read the root width/height from xwininfo -root"
  fi
  # Deliberate word split of the two numbers printed above.
  # shellcheck disable=SC2086
  set -- ${dims}
  ROOT_W="$1"
  ROOT_H="$2"
  record "root_geometry" "${ROOT_W}x${ROOT_H}"
}

# The window probe.
#
# `xwininfo -root -tree` lists the root's direct children (top-level windows) at
# one indent level and their descendants deeper, so the minimum indent over all
# parsed window lines IS the top-level level. That is what makes this immune to a
# stray GTK helper window being mistaken for the app -- and to the toolkit's 10x10
# offscreen helpers, which are top-level too and are excluded by area. Among the
# top-level windows the largest by area is the app; ties break on the lower window
# id so the choice is deterministic across runs.
#
# Return codes are load-bearing:
#   0  a candidate was found (it still needs the authoritative IsViewable check)
#   1  the tree parsed and simply has no big-enough top-level window yet
#   2  xwininfo itself is broken -- a hard failure, never "not yet", because a
#      broken probe would otherwise be indistinguishable from a slow launch and
#      would turn the whole gate into a timeout
#   3  top-level windows exist but none is big enough, which is a different
#      diagnosis from "nothing has appeared yet" and is reported as such
probe_window() {
  local out line indent id rest
  local -a c_id c_w c_h c_x c_y c_i
  local n=0 base=-1 i best=-1 left right area best_area min_area toplevels=0

  if ! out="$(xwininfo -root -tree 2>&1)"; then
    printf 'xwininfo -root -tree failed: %s\n' "${out}" >&2
    return 2
  fi

  while IFS= read -r line; do
    [[ "${line}" =~ ^([[:space:]]+)(0x[0-9a-fA-F]+)[[:space:]] ]] || continue
    indent=${#BASH_REMATCH[1]}
    id="${BASH_REMATCH[2]}"
    rest="${line#*"${id}"}"
    # The geometry is the LAST geometry-shaped token pair on the line, so the
    # match is anchored at end-of-line. A window title containing "800x600+0+0"
    # therefore cannot be mistaken for the geometry: only the real trailing
    # fields satisfy the anchor. The structural suite exercises exactly that
    # ("Video 800x600+0+0") and requires the probe to read the REAL geometry.
    #
    # The signs are `[-+]?` rather than `-?`, and that is load-bearing rather
    # than defensive. xwininfo prints the relative geometry as
    # "WxH+X+Y" but the absolute one as "+X+Y" -- always with a literal leading
    # `+` on each field -- so an on-screen window at +0+0 reads as "1280x720+0+0
    # +0+0" and an offscreen GTK helper at (-100,-100) reads as "10x10+-100+-100
    # +-100+-100". With `-?` the absolute pair could never match, so NO line ever
    # parsed, probe_window always answered "nothing has appeared yet", and every
    # run ended at launch_timeout. A gate that cannot pass is not a gate, so the
    # pattern is fixed rather than the threshold beside it.
    #
    # Only the two trailing forms are accepted: relative+absolute, or relative
    # alone for xwininfo builds that print one geometry. Anything else on the
    # line is skipped instead of guessed at.
    if [[ "${rest}" =~ ([0-9]+)x([0-9]+)([-+][0-9]+)([-+][0-9]+)[[:space:]]+([-+][0-9]+)([-+][0-9]+)[[:space:]]*$ ]]; then
      :
    elif [[ "${rest}" =~ ([0-9]+)x([0-9]+)([-+][0-9]+)([-+][0-9]+)[[:space:]]*$ ]]; then
      :
    else
      continue
    fi
    c_id[n]="${id}"
    c_w[n]="${BASH_REMATCH[1]}"
    c_h[n]="${BASH_REMATCH[2]}"
    # The sign is part of the matched text, so it has to come off before the
    # value is used as a number. `+0` is not a valid C integer literal and bash
    # arithmetic rejects it with "value too great for base", and even when it
    # survives, the geometry is re-serialised into `CROP_GEOM` and into the
    # evidence line -- which is how `1280x720++0++0` ended up in the log and a
    # crop geometry ImageMagick cannot parse. Only a leading `+` is stripped;
    # a leading `-` is part of a negative coordinate and must survive.
    c_x[n]="${BASH_REMATCH[3]#\+}"; c_x[n]="${c_x[n]%-}"
    c_y[n]="${BASH_REMATCH[4]#\+}"; c_y[n]="${c_y[n]%-}"
    c_i[n]="${indent}"
    if ((base < 0 || indent < base)); then
      base=${indent}
    fi
    n=$((n + 1))
  done <<<"${out}"

  min_area=$((ROOT_W * ROOT_H * LINUX_SMOKE_MIN_WINDOW_PERCENT / 100))
  best_area=0
  for ((i = 0; i < n; i++)); do
    ((c_i[i] == base)) || continue
    toplevels=$((toplevels + 1))
    area=$((c_w[i] * c_h[i]))
    ((area >= min_area)) || continue
    if ((best < 0 || area > best_area)); then
      best=${i}
      best_area=${area}
    elif ((area == best_area)); then
      left=$((16#${c_id[i]#0x}))
      right=$((16#${c_id[best]#0x}))
      if ((left < right)); then
        best=${i}
      fi
    fi
  done

  if ((best < 0)); then
    if ((toplevels > 0)); then
      return 3
    fi
    return 1
  fi

  PROBE_ID="${c_id[best]}"
  PROBE_W="${c_w[best]}"
  PROBE_H="${c_h[best]}"
  PROBE_X="${c_x[best]}"
  PROBE_Y="${c_y[best]}"
  return 0
}

# ---------------------------------------------------------------------------
# Process ancestry, for window attribution
# ---------------------------------------------------------------------------
#
# `xwininfo -id` names the PID of the client that mapped the window. Whether that
# process is the launched leg is a question about the process table, and /proc
# answers it directly. It is the strongest attribution available without a window
# manager: a name or a WM_CLASS is a string the app chose, so a stale or
# coincidental match is possible, while a PPID chain is not a claim anyone makes.
#
# Depth is bounded, and the bound is not arbitrary. `setsid --wait` puts the launch
# in its own session and the app is its child, so a healthy chain is two or three
# links; a dozen is generous for a wrapper chain, and a bound matters because an
# unbounded walk on a machine with a deep or looping /proc would hang the gate on
# its own diagnosis. Reaching PID 1 first is the normal ending and is not an
# error -- it just means the answer was no.
#
# Both helpers read /proc and nothing else. `ps` is not used: its output format is
# not a contract, its behaviour under a PID race is not defined, and this is a
# verdict path, so the answer has to come from the kernel's own files or not at all.
LINUX_SMOKE_ANCESTRY_LIMIT="${LINUX_SMOKE_ANCESTRY_LIMIT:-16}"

# ancestor_chain <pid> -- "pid pp pp pp ... 1", for the evidence record. Never
# fails: an unreadable /proc entry ends the walk, because the answer to "is this
# our window" is allowed to be "no" and is not allowed to be "the gate crashed".
ancestor_chain() {
  local pid="$1" out="" i=0 cur="$1" ppid
  while [[ "${cur}" =~ ^[0-9]+$ ]] && ((cur > 1)) && ((i < LINUX_SMOKE_ANCESTRY_LIMIT)); do
    out+="${cur} "
    if [[ ! -r "/proc/${cur}/stat" ]]; then
      break
    fi
    # /proc/PID/stat is "pid (comm) state ppid ...". comm is parenthesised and may
    # itself contain spaces and parentheses, so the fields after it are found from
    # the LAST ')' rather than by cutting on whitespace -- `photo organizer`
    # would otherwise shift every field by one.
    ppid="$(sed -e 's/^.*) //' -e 's/^[^ ]* //' "/proc/${cur}/stat" 2>/dev/null || true)"
    [[ "${ppid}" =~ ^[0-9]+$ ]] || break
    cur="${ppid}"
    i=$((i + 1))
  done
  printf '%s' "${out% }"
}

# is_ancestor_or_self <pid> <ancestor> -- is <pid> the process <ancestor>, or a
# descendant of it? Walks up from <pid> and compares, so the answer does not
# depend on the walk having been the same length on both sides.
is_ancestor_or_self() {
  local pid="$1" ancestor="$2" cur="$1" i=0 ppid
  [[ "${pid}" =~ ^[0-9]+$ && "${ancestor}" =~ ^[0-9]+$ ]] || return 1
  while ((i < LINUX_SMOKE_ANCESTRY_LIMIT)); do
    [[ "${cur}" == "${ancestor}" ]] && return 0
    ((cur > 1)) || return 1
    if [[ ! -r "/proc/${cur}/stat" ]]; then
      return 1
    fi
    ppid="$(sed -e 's/^.*) //' -e 's/^[^ ]* //' "/proc/${cur}/stat" 2>/dev/null || true)"
    [[ "${ppid}" =~ ^[0-9]+$ ]] || return 1
    cur="${ppid}"
    i=$((i + 1))
  done
  return 1
}

# The authoritative follow-up. The tree output prints geometry for unmapped
# windows too, so "the window exists" is not "the window is on screen".
# `xwininfo -id` is the query that answers that, and it re-reads the geometry from
# the window itself rather than trusting a tree line.
#
# It is also where the window is ATTRIBUTED, which is a different question and the
# one the whole gate turns on. Everything downstream -- the area floor, IsViewable,
# the colour floor, the settle bound, the teardown-crash check -- is satisfied by
# *a* window. `probe_window` picks the largest top-level one, and on a bare Xvfb
# with no window manager the only top-levels ought to be the app's. "Ought to be"
# is not a proof, and the gate honours a caller-set LINUX_SMOKE_UNDER_XVFB=1 with
# an ambient DISPLAY, so on a developer's real desktop it adopts the largest
# window on their screen. The two legs also run sequentially on one X server, so
# a surviving leg-1 window can satisfy leg 2's probe.
#
# Measured as a false pass: a foreign top-level 1279x799 -- larger than the app's
# 1280x720 -- added to the suite's own `good_tree` fixture was selected instead of
# the app, and the gate then completed its entire render proof against it. 124 of
# 125 assertions stayed green. The one red assertion noticed the *geometry*, not
# the *attribution*, which is the whole point: the render evidence would have been
# of somebody else's window.
#
# So the window must be the app's. Two independent ways, because either alone has
# a way to be wrong on a real runner:
#
#   * PID ancestry, the strong one. `xwininfo -id` reports the PID of the X client
#     that mapped the window; /proc says whether that process is the launched leg
#     or descends from it. This is a fact about the process table, not about a
#     string anyone chose.
#   * The window's own identity -- WM_CLASS, or its name -- matching an expected
#     token. Weaker, because a title is chosen by the app and a stale match is
#     possible, but it survives a window created by a process that is not a
#     descendant (a portal helper, a re-exec that lost its parent) and it is what
#     the Android gate uses, which requires the package name on the focused-window
#     line.
#
# Either is enough, and the evidence records WHICH one carried the attribution, so
# a reader is never left guessing whether the strong property held.
verify_window_mapped() {
  local id="$1" out state w h x y pid class
  if ! out="$(xwininfo -id "${id}" 2>&1)"; then
    fail window_geometry_unreadable "xwininfo -id ${id} failed: ${out}"
  fi
  state="$(printf '%s\n' "${out}" | awk '/Map State:/ {print $3; exit}')"
  if [[ "${state}" != "IsViewable" ]]; then
    fail window_not_visible \
      "window ${id} exists but its Map State is '${state:-unknown}', not IsViewable"
  fi

  # --- attribution, before anything is measured off this window ---
  pid="$(printf '%s\n' "${out}" | awk '/^[[:space:]]*PID:/ {print $2; exit}')"
  class="$(printf '%s\n' "${out}" | sed -n 's/^[[:space:]]*WM_CLASS(STRING) = "\(.*\)", "\(.*\)"$/\1 \2/p' | head -1)"
  local how="" chain="" ancestor=0
  if [[ -n "${pid}" && "${pid}" =~ ^[0-9]+$ ]] && ((pid > 1)); then
    chain="$(ancestor_chain "${pid}")"
    if [[ -n "${APP_PID}" ]] && is_ancestor_or_self "${pid}" "${APP_PID}"; then
      how="pid-ancestry"
      ancestor=1
    fi
  fi
  if ((ancestor == 0)) && [[ -n "${LINUX_SMOKE_EXPECT_WINDOW_MATCH}" ]]; then
    if [[ " ${class} " == *" ${LINUX_SMOKE_EXPECT_WINDOW_MATCH} "* ]] \
       || grep -qF -- "${LINUX_SMOKE_EXPECT_WINDOW_MATCH}" <<<"${class}"; then
      how="window-identity"
    fi
  fi
  record "$(probe_leg)_window_pid" "${pid:-<none>}"
  record "$(probe_leg)_window_wm_class" "${class:-<none>}"
  record "$(probe_leg)_window_attributed_by" "${how:-none}"
  if [[ -z "${how}" ]]; then
    record "$(probe_leg)_window_ancestry" "${chain:-<unreadable>}"
    fail window_not_attributed \
      "window ${id} is the largest top-level on ${DISPLAY:-<unset>} but nothing ties it to ${leg_label:-the app}: its PID is '${pid:-<none>}' (ancestry: ${chain:-<unreadable>}) and its WM_CLASS is '${class:-<none>}' against an expected '${LINUX_SMOKE_EXPECT_WINDOW_MATCH:-<none>}'. Rendering it would prove that some window rendered, not that the app did."
  fi
  log "window ${id} attributed to the app by ${how} (pid ${pid:-none}, class ${class:-none})"

  w="$(printf '%s\n' "${out}" | awk '/^[[:space:]]+Width:/ {print $2; exit}')"
  h="$(printf '%s\n' "${out}" | awk '/^[[:space:]]+Height:/ {print $2; exit}')"
  if [[ -z "${w}" || -z "${h}" ]]; then
    fail window_geometry_unreadable "could not read Width/Height for window ${id}"
  fi
  if printf '%s\n' "${out}" | grep -q 'Absolute upper-left X:'; then
    x="$(printf '%s\n' "${out}" | awk '/Absolute upper-left X:/ {print $NF; exit}')"
    y="$(printf '%s\n' "${out}" | awk '/Absolute upper-left Y:/ {print $NF; exit}')"
  else
    x="$(printf '%s\n' "${out}" | awk '/Upper-left corner:/ {print $(NF-1); exit}')"
    y="$(printf '%s\n' "${out}" | awk '/Upper-left corner:/ {print $NF; exit}')"
  fi
  if [[ -z "${x}" || -z "${y}" ]]; then
    fail window_geometry_unreadable "could not read the position of window ${id}"
  fi
  # Nothing read out of a tool's stdout reaches arithmetic or the crop geometry
  # without passing an integer check first. `xwininfo` prints these fields with
  # `%ld`, so they are plain digits, but a signed reading is accepted here on
  # purpose (an explicit `+0` is harmless) and any other text is a hard failure
  # rather than a value that later gets used as a number. It was not hypothetical:
  # a `+0` reaching `compute_crop_geom` produced a crop geometry of
  # `1280x720++0++0`, which is not a geometry ImageMagick can parse, and the
  # evidence summary recorded the garbage verbatim.
  for pair in "Width:${w}" "Height:${h}" "X:${x}" "Y:${y}"; do
    if [[ ! "${pair#*:}" =~ ^-?[0-9]+$ ]]; then
      fail window_geometry_unreadable \
        "window ${id} reported ${pair%%:*}='${pair#*:}', which is not an integer"
    fi
  done
  x="${x#+}"
  y="${y#+}"
  PROBE_W="${w}"
  PROBE_H="${h}"
  PROBE_X="${x}"
  PROBE_Y="${y}"
}

# The visible part of the window, clamped to the root. A window that is mostly
# offscreen is not evidence that a user could see anything, so the clamped
# rectangle has to clear the same area floor as the window itself.
compute_crop_geom() {  local x="$1" y="$2" w="$3" h="$4"
  local x0="${x}" y0="${y}" x1=$((x + w)) y1=$((y + h)) visible
  if ((x0 < 0)); then x0=0; fi
  if ((y0 < 0)); then y0=0; fi
  if ((x1 > ROOT_W)); then x1=${ROOT_W}; fi
  if ((y1 > ROOT_H)); then y1=${ROOT_H}; fi
  if ((x1 <= x0 || y1 <= y0)); then
    fail window_offscreen \
      "the window at ${x},${y} sized ${w}x${h} lies entirely outside the ${ROOT_W}x${ROOT_H} root"
  fi
  visible=$(((x1 - x0) * (y1 - y0)))
  if ((visible < ROOT_W * ROOT_H * LINUX_SMOKE_MIN_WINDOW_PERCENT / 100)); then
    fail window_offscreen \
      "only ${visible}px of the window is on screen ($((x1 - x0))x$((y1 - y0)) of ${w}x${h}); below the ${LINUX_SMOKE_MIN_WINDOW_PERCENT}% floor"
  fi
  CROP_GEOM="$((x1 - x0))x$((y1 - y0))+${x0}+${y0}"
}

# ---------------------------------------------------------------------------
# Render proof
# ---------------------------------------------------------------------------
capture_root() {
  local out_png="$1"
  if ! "${IMPORT_CMD[@]}" -display "${DISPLAY}" -window root "png:${out_png}" 2>>"${IMAGEMAGICK_LOG}"; then
    return 1
  fi
  [[ -s "${out_png}" ]]
}

count_colours() {
  local png="$1" geom="$2" n
  n="$("${CONVERT_CMD[@]}" "${png}" -crop "${geom}" +repage -format '%k' info: 2>>"${IMAGEMAGICK_LOG}" || true)"
  n="$(printf '%s' "${n}" | tr -d '[:space:]')"
  # The colour count must be a plain integer: an empty or non-numeric answer means
  # the metric is not answering, which is a failure and not "0 colours".
  if [[ ! "${n}" =~ ^[0-9]+$ ]]; then
    return 1
  fi
  printf '%s' "${n}"
}

pixel_diff() {
  local a="$1" b="$2" raw
  # `compare` exits 1 when the images differ, which is the normal expected case
  # here, so only the printed number is used.
  raw="$("${COMPARE_CMD[@]}" -metric AE "${a}" "${b}" null: 2>&1 || true)"
  # Same rule as the colour count: a non-numeric AE means the diff is unknown, and
  # an unknown diff must never be read as "0 differing pixels". `normalise_ae`
  # understands both the IM6 and the IM7 answer shapes; its failure status is what
  # the caller turns into render_unsettled.
  normalise_ae "${raw}"
}

# Waits until the window rectangle is visually complex, then proves it stops
# changing. It retries rather than sleeping a fixed amount, because "slow first
# paint" and "no first paint at all" look identical at any fixed instant.
prove_render() {
  local leg="$1" pid="$2"
  local render_deadline=$((SECONDS + LINUX_SMOKE_RENDER_TIMEOUT))
  local root_png="${EVIDENCE_DIR}/linux-smoke-${SMOKE_NAME}-${leg}-root.png"
  local win_png="${EVIDENCE_DIR}/linux-smoke-${SMOKE_NAME}-${leg}-window.png"
  local prev_png="${EVIDENCE_DIR}/linux-smoke-${SMOKE_NAME}-${leg}-settle-previous.png"
  local cur_png="${EVIDENCE_DIR}/linux-smoke-${SMOKE_NAME}-${leg}-settle-current.png"
  local colours="" attempt diff=0

  while :; do
    if ! kill -0 "${pid}" 2>/dev/null; then
      collect_wait_status "${pid}"
      fail app_exited_during_launch \
        "${leg}: the app exited (status $(classify_status "${WAIT_STATUS}")) before it drew a usable frame"
    fi
    if capture_root "${root_png}"; then
      if colours="$(count_colours "${root_png}" "${CROP_GEOM}")"; then
        if ((colours >= LINUX_SMOKE_MIN_COLOURS)); then
          break
        fi
      else
        fail render_colour_probe_failed \
          "${leg}: could not count distinct colours in ${CROP_GEOM} (convert produced no numeric answer)"
      fi
    else
      fail render_capture_failed "${leg}: 'import -window root' failed to produce a PNG"
    fi
    if ((SECONDS >= render_deadline)); then
      fail render_not_complex \
        "${leg}: the window never showed more than ${colours:-0} distinct colours in ${CROP_GEOM} within ${LINUX_SMOKE_RENDER_TIMEOUT}s (floor: ${LINUX_SMOKE_MIN_COLOURS}); a blank or failed-to-composite frame"
    fi
    log "${leg}: the window is mapped but flat (${colours:-0} colours) - waiting for the first real frame"
    sleep "${LINUX_SMOKE_POLL_SECONDS}"
  done

  # The window's own rectangle as its own artifact: this is the
  # "visually-complex frame" the drop-gate asks for.
  if ! "${CONVERT_CMD[@]}" "${root_png}" -crop "${CROP_GEOM}" +repage "${win_png}" 2>>"${IMAGEMAGICK_LOG}" \
    || [[ ! -s "${win_png}" ]]; then
    fail render_capture_failed "${leg}: could not crop the window rectangle out of the root capture"
  fi
  # Both settle captures must be full-root captures so `compare` sees identical
  # geometry; comparing the cropped window against a full root would make AE
  # report a size mismatch instead of a pixel count.
  cp -f "${root_png}" "${prev_png}"

  for ((attempt = 1; attempt <= LINUX_SMOKE_SETTLE_ATTEMPTS; attempt++)); do
    sleep "${LINUX_SMOKE_SETTLE_SECONDS}"
    if ! capture_root "${cur_png}"; then
      fail render_capture_failed "${leg}: the second root capture failed"
    fi
    if ! diff="$(pixel_diff "${prev_png}" "${cur_png}")"; then
      fail render_unsettled \
        "${leg}: 'compare -metric AE' did not return a pixel count; the stability assertion cannot be trusted"
    fi
    record "${leg}_settle_diff_px_attempt_${attempt}" "${diff}"
    if ((diff <= LINUX_SMOKE_MAX_UNSETTLED_PIXELS)); then
      record "${leg}_colours" "${colours}"
      record "${leg}_settle_diff_px" "${diff}"
      log "${leg}: rendered ${colours} distinct colours in ${CROP_GEOM}, stable within ${diff}px across ${LINUX_SMOKE_SETTLE_SECONDS}s"
      rm -f "${prev_png}"
      return 0
    fi
    log "${leg}: still changing (${diff}px differ, bound ${LINUX_SMOKE_MAX_UNSETTLED_PIXELS}) - attempt ${attempt}/${LINUX_SMOKE_SETTLE_ATTEMPTS}"
    cp -f "${cur_png}" "${prev_png}"
  done

  fail render_unsettled \
    "${leg}: the window never settled within ${LINUX_SMOKE_SETTLE_ATTEMPTS} attempts (last diff ${diff}px, bound ${LINUX_SMOKE_MAX_UNSETTLED_PIXELS}); a screen stuck animating or mid-transition"
}

# ---------------------------------------------------------------------------
# Process control
# ---------------------------------------------------------------------------
#
# Sets WAIT_STATUS rather than printing it. `wait` only reports on the current
# shell's own children, so a command substitution -- which runs in a subshell --
# could never see the app's status and would return 127 for every crash,
# turning "the app segfaulted" into "the app exited with 127".
collect_wait_status() {
  local pid="$1"
  WAIT_STATUS=0
  # Every call site believes the process is already gone -- that is why they are
  # all guarded by `! kill -0` or preceded by kill_tree. `wait` on a process
  # that is still running blocks FOREVER, so if the invariant is ever broken the
  # gate would hang in CI instead of failing: a hang is a green release that
  # nobody notices, because the job eventually gets cancelled by a human. Take
  # the tree down first and report the status that was forced.
  if kill -0 "${pid}" 2>/dev/null; then
    kill -KILL "-${pid}" 2>/dev/null || kill -KILL "${pid}" 2>/dev/null || true
  fi
  wait "${pid}" 2>/dev/null || WAIT_STATUS=$?
}

classify_status() {
  local st="$1"
  if ((st == 0)); then
    printf 'exit:0'
  elif ((st > 128)); then
    printf 'signal:%d' "$((st - 128))"
  else
    printf 'exit:%d' "${st}"
  fi
}

# Kills the whole launch tree. The process-group kill is the precise path; the
# pgrep fallback exists because `galleryd` is a child of the app and, on some
# launch shapes, lands in a group of its own. The scratch path is unique per run
# and never appears in this script's own argv, so matching on it cannot select the
# gate itself.
kill_tree() {
  local pid="${1:-${APP_PID}}"
  if [[ -z "${pid}" ]]; then
    return 0
  fi
  if kill -0 "${pid}" 2>/dev/null; then
    kill -TERM "-${pid}" 2>/dev/null || kill -TERM "${pid}" 2>/dev/null || true
  fi
  sleep "${LINUX_SMOKE_TEARDOWN_GRACE_SECONDS}"
  if [[ -n "${SCRATCH}" ]] && command -v pkill >/dev/null 2>&1; then
    local esc
    esc="$(printf '%s' "${SCRATCH}" | sed 's/[][\\.*^$+(){}|]/\\&/g')"
    pkill -TERM -f "${esc}" 2>/dev/null || true
  fi
  sleep "${LINUX_SMOKE_TEARDOWN_GRACE_SECONDS}"
  if kill -0 "${pid}" 2>/dev/null; then
    kill -KILL "-${pid}" 2>/dev/null || kill -KILL "${pid}" 2>/dev/null || true
  fi
  if [[ -n "${SCRATCH}" ]] && command -v pkill >/dev/null 2>&1; then
    local esc
    esc="$(printf '%s' "${SCRATCH}" | sed 's/[][\\.*^$+(){}|]/\\&/g')"
    pkill -KILL -f "${esc}" 2>/dev/null || true
  fi
  return 0
}

# Crash-marker scan. `fatal` selects the handling: the daemon's log is held to the
# Rust-panic standard as well, because a panic there is a defect with no plausible
# environmental cause. The app's Dart errors are reported, never fatal.
scan_for_crashes() {
  local leg="$1" file="$2" label="$3" re="$4" fatal="$5" hits count
  if [[ ! -f "${file}" ]]; then
    return 0
  fi
  hits="$(grep -Ein "${re}" "${file}" || true)"
  if [[ -z "${hits}" ]]; then
    return 0
  fi
  {
    printf '### %s / %s (%s)\n' "${leg}" "${label}" "${fatal}"
    printf '%s\n' "${hits}"
  } >>"${EVIDENCE_DIR}/linux-smoke-${SMOKE_NAME}-crashes.txt"
  count="$(printf '%s\n' "${hits}" | wc -l | tr -d '[:space:]')"
  if [[ "${fatal}" == "fatal" ]]; then
    fail crash_signature \
      "${leg}: ${count} native crash signature(s) in ${label} (see linux-smoke-${SMOKE_NAME}-crashes.txt)"
  fi
  warn "${leg}: ${count} soft error line(s) in ${label} (${DART_SOFT_RE}) - recorded, not fatal"
}

# Copies the leg's logs out of the runtime dir and scans them. The launch log
# (the app's stdout/stderr) is scanned too: it is where the Flutter engine's own
# messages go, and it is the only log that exists if the app never got far enough
# to open its own.
collect_logs() {
  local leg="$1" runtime="$2"
  local launch_log="${EVIDENCE_DIR}/linux-smoke-${SMOKE_NAME}-${leg}-launch.log"
  local app_log="${EVIDENCE_DIR}/linux-smoke-${SMOKE_NAME}-${leg}-app.log"
  local daemon_log="${EVIDENCE_DIR}/linux-smoke-${SMOKE_NAME}-${leg}-galleryd.log"
  if [[ -f "${runtime}/private-gallery-app.log" ]]; then
    cp -f "${runtime}/private-gallery-app.log" "${app_log}"
  fi
  if [[ -f "${runtime}/galleryd.log" ]]; then
    cp -f "${runtime}/galleryd.log" "${daemon_log}"
  fi
  record "${leg}_launch_log_bytes" "$(file_bytes "${launch_log}")"
  record "${leg}_app_log_bytes" "$(file_bytes "${app_log}")"
  record "${leg}_daemon_log_bytes" "$(file_bytes "${daemon_log}")"
  scan_for_crashes "${leg}" "${launch_log}" "the launch log" "${NATIVE_CRASH_RE}" fatal
  scan_for_crashes "${leg}" "${app_log}" "the app's own log" "${NATIVE_CRASH_RE}" fatal
  scan_for_crashes "${leg}" "${daemon_log}" "galleryd.log" "${NATIVE_CRASH_RE}|${RUST_PANIC_RE}" fatal
  scan_for_crashes "${leg}" "${launch_log}" "the launch log" "${DART_SOFT_RE}" soft
  scan_for_crashes "${leg}" "${app_log}" "the app's own log" "${DART_SOFT_RE}" soft
}

file_bytes() {
  if [[ -f "$1" ]]; then
    wc -c <"$1" | tr -d '[:space:]'
  else
    printf '0'
  fi
}

# ---------------------------------------------------------------------------
# The shared leg pipeline
# ---------------------------------------------------------------------------
#
# One implementation, two callers. The AppImage leg and the .deb leg differ only in
# how the artifact is proven installable and in what path is launched; everything
# after that -- launch, window, render, stability, crash -- is identical, which is
# the only way both legs can honestly be called gated.
#
# Usage: run_leg <leg-name> <launch-command...>
run_leg() {
  local leg="$1"
  shift

  # Read back by verify_window_mapped: the evidence keys and the assertion text
  # both need to name the leg, and this is the only place that knows it.
  leg_label="the ${leg} leg"

  local leg_dir="${SCRATCH}/${leg}"
  local home="${leg_dir}/home"
  local runtime="${leg_dir}/runtime"
  local tmp="${leg_dir}/tmp"
  mkdir -p "${home}" "${runtime}" "${tmp}"
  chmod 700 "${runtime}"
  record "${leg}_scratch" "${leg_dir}"

  log "=== leg ${leg}: cold launch ==="
  local out="${EVIDENCE_DIR}/linux-smoke-${SMOKE_NAME}-${leg}-launch.log"
  : >"${out}"

  # `setsid --wait` gives the launch its own session (so cleanup can take down the
  # whole tree) and, crucially, hands back the child's real exit status --
  # including 128+N for a fatal signal, which is the crash signal this gate cares
  # most about.
  env -i \
    PATH="${PATH}" \
    LANG=C.UTF-8 \
    DISPLAY="${DISPLAY}" \
    HOME="${home}" \
    TMPDIR="${tmp}" \
    XDG_RUNTIME_DIR="${runtime}" \
    XDG_CONFIG_HOME="${home}/.config" \
    XDG_DATA_HOME="${home}/.local/share" \
    XDG_CACHE_HOME="${home}/.cache" \
    XDG_STATE_HOME="${home}/.state" \
    LIBGL_ALWAYS_SOFTWARE="${LINUX_SMOKE_LIBGL_ALWAYS_SOFTWARE}" \
    GDK_BACKEND="${LINUX_SMOKE_GDK_BACKEND}" \
    GDK_GL="${LINUX_SMOKE_GDK_GL}" \
    APPIMAGE_EXTRACT_AND_RUN=1 \
    PRIVATE_GALLERY_RUNTIME_ROOT="${runtime}" \
    setsid --wait "$@" >>"${out}" 2>&1 &
  APP_PID=$!
  record "${leg}_app_pid" "${APP_PID}"

  # --- window ---
  local window_deadline=$((SECONDS + LINUX_SMOKE_LAUNCH_TIMEOUT)) rc=0 saw_small=0
  while :; do
    if ! kill -0 "${APP_PID}" 2>/dev/null; then
      collect_wait_status "${APP_PID}"
      collect_logs "${leg}" "${runtime}"
      fail app_exited_during_launch \
        "${leg}: the app exited (status $(classify_status "${WAIT_STATUS}")) before a usable window appeared; see linux-smoke-${SMOKE_NAME}-${leg}-launch.log"
    fi
    if probe_window; then
      break
    else
      rc=$?
    fi
    if ((rc == 2)); then
      fail window_probe_failed "${leg}: the X window probe itself failed; see stderr above"
    fi
    if ((rc == 3)); then
      saw_small=1
    fi
    if ((SECONDS >= window_deadline)); then
      collect_logs "${leg}" "${runtime}"
      if ((saw_small == 1)); then
        fail window_area_too_small \
          "${leg}: top-level windows appeared but none covered >=${LINUX_SMOKE_MIN_WINDOW_PERCENT}% of the ${ROOT_W}x${ROOT_H} root within ${LINUX_SMOKE_LAUNCH_TIMEOUT}s; the app is up but is not presenting a real window"
      fi
      fail launch_timeout \
        "${leg}: no top-level window at all appeared within ${LINUX_SMOKE_LAUNCH_TIMEOUT}s; see linux-smoke-${SMOKE_NAME}-${leg}-launch.log"
    fi
    sleep "${LINUX_SMOKE_POLL_SECONDS}"
  done

  log "${leg}: found a top-level window ${PROBE_ID} at ${PROBE_W}x${PROBE_H}+${PROBE_X}+${PROBE_Y}"
  record "${leg}_window_id" "${PROBE_ID}"

  verify_window_mapped "${PROBE_ID}"
  record "${leg}_window_geometry" "${PROBE_W}x${PROBE_H}+${PROBE_X}+${PROBE_Y}"
  record "${leg}_map_state" "IsViewable"
  compute_crop_geom "${PROBE_X}" "${PROBE_Y}" "${PROBE_W}" "${PROBE_H}"
  record "${leg}_crop_geometry" "${CROP_GEOM}"

  # --- render, stability, crash ---
  prove_render "${leg}" "${APP_PID}"

  # An app that draws a frame and then dies two seconds later still ships a bad
  # artifact, so survival is asserted explicitly rather than assumed from the
  # render passing.
  if ! kill -0 "${APP_PID}" 2>/dev/null; then
    collect_wait_status "${APP_PID}"
    collect_logs "${leg}" "${runtime}"
    fail app_exited_after_first_frame \
      "${leg}: the app drew a frame and then exited (status $(classify_status "${WAIT_STATUS}"))"
  fi

  kill_tree "${APP_PID}"
  collect_wait_status "${APP_PID}"
  record "${leg}_exit_status" "${WAIT_STATUS}"
  record "${leg}_exit_class" "$(classify_status "${WAIT_STATUS}")"

  # A deliberate SIGTERM shows up as 128+15 (or 128+9 if it needed SIGKILL).
  # Anything else -- a segfault, an abort, a plain non-zero exit -- means the app
  # was already on its way out when we asked it to stop, which is a crash no
  # matter how convenient the timing.
  if [[ "${WAIT_STATUS}" != "143" && "${WAIT_STATUS}" != "137" && "${WAIT_STATUS}" != "0" ]]; then
    collect_logs "${leg}" "${runtime}"
    fail app_crashed_at_teardown \
      "${leg}: the app terminated with $(classify_status "${WAIT_STATUS}") instead of stopping on request"
  fi

  collect_logs "${leg}" "${runtime}"
  APP_PID=""
  log "=== leg ${leg}: PASS ==="
}

# ---------------------------------------------------------------------------
# Artifact discovery
# ---------------------------------------------------------------------------
#
# Exactly one of each. Zero is a build failure that must not be mistaken for a
# gate with nothing to do; two is an ambiguity the gate must not resolve by
# guessing which one is the real artifact.
declare -a APPIMAGES=() DEBS=()
while IFS= read -r -d '' f; do
  APPIMAGES+=("${f}")
done < <(find "${ARTIFACT_DIR}" -maxdepth 1 -type f -name '*.AppImage' -print0 | sort -z)
while IFS= read -r -d '' f; do
  DEBS+=("${f}")
done < <(find "${ARTIFACT_DIR}" -maxdepth 1 -type f -name '*_amd64.deb' -print0 | sort -z)

if ((${#APPIMAGES[@]} == 0)); then
  fail artifact_discovery "no *.AppImage in ${ARTIFACT_DIR}; the Linux release must publish one"
fi
if ((${#APPIMAGES[@]} > 1)); then
  fail artifact_discovery "found ${#APPIMAGES[@]} *.AppImage files in ${ARTIFACT_DIR} (${APPIMAGES[*]}); exactly one is required"
fi
if ((${#DEBS[@]} == 0)); then
  fail artifact_discovery "no *_amd64.deb in ${ARTIFACT_DIR}; the Linux release must publish one"
fi
if ((${#DEBS[@]} > 1)); then
  fail artifact_discovery "found ${#DEBS[@]} *_amd64.deb files in ${ARTIFACT_DIR} (${DEBS[*]}); exactly one is required"
fi
APPIMAGE="${APPIMAGES[0]}"
DEB="${DEBS[0]}"
record "appimage" "${APPIMAGE}"
record "appimage_sha256" "$(sha256sum "${APPIMAGE}" | cut -d' ' -f1)"
record "deb" "${DEB}"
record "deb_sha256" "$(sha256sum "${DEB}" | cut -d' ' -f1)"

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/linux-smoke-scratch.XXXXXXXX")"
record "scratch" "${SCRATCH}"
mkdir -p "${SCRATCH}/metric-selfcheck"
metric_selfcheck "${SCRATCH}/metric-selfcheck"
root_geometry

# ---------------------------------------------------------------------------
# Leg 1: the AppImage
# ---------------------------------------------------------------------------
#
# Structural facts first -- cheap, and a far better error message than a 120s
# timeout -- then the real launch of the real file.
appimage_mode_published="$(stat -c '%a' "${APPIMAGE}")"
appimage_size="$(stat -c '%s' "${APPIMAGE}")"
record "appimage_mode_published" "${appimage_mode_published}"
record "appimage_size_bytes" "${appimage_size}"
if ((appimage_size < 1048576)); then
  fail appimage_size "the AppImage is ${appimage_size} bytes; a real one is tens of megabytes"
fi

# chmod a private copy: artifact upload/download does not preserve the exec bit,
# and mutating the published file would invalidate its checksum.
APPIMAGE_RUN="${SCRATCH}/appimage/photo-organizer.AppImage"
mkdir -p "${SCRATCH}/appimage"
cp -f "${APPIMAGE}" "${APPIMAGE_RUN}"
chmod 0755 "${APPIMAGE_RUN}"
record "appimage_mode_gated" "$(stat -c '%a' "${APPIMAGE_RUN}")"
if [[ ! -x "${APPIMAGE_RUN}" ]]; then
  fail appimage_executable_bit "the private AppImage copy is not executable after chmod 0755"
fi

# Payload inspection. `--appimage-extract` is the runtime's own supported
# interface and needs FUSE; a runner without libfuse2 fails here with a named
# assertion rather than quietly skipping the structural checks.
APPIMAGE_EXTRACT_DIR="${SCRATCH}/appimage-extract"
mkdir -p "${APPIMAGE_EXTRACT_DIR}"
if ! (cd "${APPIMAGE_EXTRACT_DIR}" && "${APPIMAGE_RUN}" --appimage-extract) \
  >>"${EVIDENCE_DIR}/linux-smoke-${SMOKE_NAME}-appimage-extract.log" 2>&1; then
  fail appimage_payload_extract \
    "'--appimage-extract' failed, so the AppImage payload cannot be inspected. On Debian/Ubuntu this usually means libfuse2 is missing; the launch itself does not need FUSE because it uses APPIMAGE_EXTRACT_AND_RUN=1"
fi
PAYLOAD="${APPIMAGE_EXTRACT_DIR}/squashfs-root"
if [[ ! -d "${PAYLOAD}" ]]; then
  fail appimage_payload_extract "the AppImage extracted but produced no squashfs-root directory"
fi

# The flat AppDir layout, exactly as the `linux` job in release.yml assembles it.
for required_rel in \
  "AppRun" \
  "private_gallery_app" \
  "galleryd" \
  "ml_sidecar/private_gallery_ml_sidecar.py" \
  "photo-organizer.desktop"; do
  if [[ ! -f "${PAYLOAD}/${required_rel}" ]]; then
    fail appimage_layout_missing "the AppImage payload is missing ${required_rel}"
  fi
done
for required_rel in "AppRun" "private_gallery_app" "galleryd"; do
  if [[ ! -x "${PAYLOAD}/${required_rel}" ]]; then
    fail appimage_not_executable "${required_rel} is not executable inside the AppImage"
  fi
done
# The engine binary has to be a real ELF object. A packaging change that shipped a
# truncated file, a text-mode-converted binary, or an LFS pointer named
# `private_gallery_app` would pass every existence and permission check and then
# fail at exec, 120 seconds into the leg.
require_elf() {
  local file="$1" tag="$2"
  local hdr magic class data machine
  hdr="$(od -An -tx1 -N20 "${file}" 2>/dev/null | tr -d ' \n' || true)"
  # byte 0-3 is the magic, one hex pair per byte and no separators.
  magic="${hdr:0:8}"
  class="${hdr:8:2}"
  data="${hdr:10:2}"
  # Bytes 18-19 are e_machine, in the file's own byte order. Bytes 16-17 are
  # e_type (2 = ET_EXEC, 3 = ET_DYN) and come FIRST in the header, so reading
  # 16-17 as the machine gets 0x0300 on an ordinary PIE binary -- which is the
  # first version of this check, and it rejected the real artifact.
  machine="${hdr:36:4}"
  if [[ "${magic}" != "7f454c46" ]]; then
    fail "${tag}" "${file} is not an ELF object (leading bytes '${magic:-none}', expected 7f454c46 = \\x7fELF)"
  fi
  # The magic alone proves nothing about architecture: `7f454c46` is the first
  # four bytes of EVERY ELF object, 32-bit ARM and RISC-V included, and a gate
  # that stopped here would report a pass on an artifact it cannot execute. EI_CLASS
  # is byte 4 and EI_DATA is byte 5; both are read so the e_machine comparison
  # below is a stated byte order rather than a blind one.
  if [[ "${class}" != "02" || "${data}" != "01" ]]; then
    fail "${tag}" \
      "${file} is not a little-endian 64-bit ELF (EI_CLASS=0x${class:-none}, EI_DATA=0x${data:-none}, expected 0x02/0x01)"
  fi
  # EM_X86_64 == 62 == 0x3e, little-endian, hence the `3e00` on disk. This is the
  # architecture assertion the release gate owes: the runner launches it, so the
  # bytes have to be the ones this runner can launch.
  if [[ "${machine}" != "3e00" ]]; then
    fail "${tag}" \
      "${file} is not x86-64 (e_machine=0x${machine:-none}, expected 0x3e00 = EM_X86_64); this gate launches the artifact on x86-64"
  fi
}
require_elf "${PAYLOAD}/private_gallery_app" appimage_payload_not_elf
require_elf "${PAYLOAD}/galleryd" appimage_payload_not_elf
record "appimage_payload" "${PAYLOAD}"
log "appimage: payload layout verified (AppRun, ELF private_gallery_app, galleryd, ml_sidecar, desktop entry)"

# Desktop entry: recorded, not asserted, because the shipped AppImage declares a
# bare `Exec=photo-organizer` that the flat AppDir does not contain. Asserting it
# would be asserting a bug; deleting the check would hide it. See the header.
appimage_desktop_exec="$(awk -F= '/^Exec=/ {print $2; exit}' "${PAYLOAD}/photo-organizer.desktop" || true)"
record "appimage_desktop_exec" "${appimage_desktop_exec:-<none>}"
if [[ -z "${appimage_desktop_exec}" ]]; then
  warn "appimage: photo-organizer.desktop has no Exec= line"
elif [[ "${appimage_desktop_exec}" != /* ]]; then
  if [[ -x "${PAYLOAD}/${appimage_desktop_exec}" || -x "${PAYLOAD}/usr/bin/${appimage_desktop_exec}" ]]; then
    log "appimage: the desktop entry Exec=${appimage_desktop_exec} resolves inside the AppDir"
    record "appimage_desktop_exec_resolves" "yes"
  else
    warn "appimage: KNOWN PACKAGING DEFECT - the desktop entry's Exec=${appimage_desktop_exec} is a bare name and no such executable exists in the flat AppDir, so a desktop launch would fail. Recorded, not failed: this is an assets/linux packaging bug, out of scope for issue #98"
    record "appimage_desktop_exec_resolves" "no"
  fi
else
  if [[ -x "${PAYLOAD}${appimage_desktop_exec}" ]]; then
    log "appimage: the desktop entry Exec=${appimage_desktop_exec} resolves inside the AppDir"
    record "appimage_desktop_exec_resolves" "yes"
  else
    fail appimage_desktop_exec_unresolvable \
      "the AppImage's desktop entry points at ${appimage_desktop_exec}, which is not in the payload"
  fi
fi

run_leg appimage "${APPIMAGE_RUN}"

# ---------------------------------------------------------------------------
# Leg 2: the .deb
# ---------------------------------------------------------------------------
#
# "Install" here is a faithful data-layout extraction (dpkg-deb -x, bsdtar
# fallback) plus the absolute-path checks that decide whether dpkg would produce a
# working installation. See the header for why this is not `dpkg -i`.
DEB_ROOT="${SCRATCH}/deb/root"
mkdir -p "${DEB_ROOT}"
if command -v dpkg-deb >/dev/null 2>&1; then
  record "deb_extractor" "dpkg-deb"
  if ! dpkg-deb -x "${DEB}" "${DEB_ROOT}" \
    >>"${EVIDENCE_DIR}/linux-smoke-${SMOKE_NAME}-deb-extract.log" 2>&1; then
    fail deb_extract_failed "dpkg-deb -x could not unpack ${DEB}"
  fi
elif command -v bsdtar >/dev/null 2>&1; then
  record "deb_extractor" "bsdtar"
  if ! bsdtar -xf "${DEB}" -C "${DEB_ROOT}" \
    >>"${EVIDENCE_DIR}/linux-smoke-${SMOKE_NAME}-deb-extract.log" 2>&1; then
    fail deb_extract_failed "bsdtar could not unpack ${DEB}"
  fi
else
  fail deb_extract_failed \
    "no way to unpack a .deb on this runner: install dpkg (dpkg-deb) or libarchive-tools (bsdtar)"
fi
if [[ ! -d "${DEB_ROOT}/opt/photo-organizer" ]]; then
  fail deb_layout_missing "the .deb does not lay down /opt/photo-organizer"
fi

for required_rel in \
  "opt/photo-organizer/AppRun" \
  "opt/photo-organizer/private_gallery_app" \
  "opt/photo-organizer/galleryd" \
  "opt/photo-organizer/ml_sidecar/private_gallery_ml_sidecar.py" \
  "usr/share/applications/photo-organizer.desktop" \
  "usr/share/icons/hicolor/512x512/apps/photo-organizer.png"; do
  if [[ ! -f "${DEB_ROOT}/${required_rel}" ]]; then
    fail deb_layout_missing "the .deb is missing ${required_rel}"
  fi
done
# Same reason as the AppImage leg: the engine binary must be a real ELF object,
# because a truncated or text-mode-converted file satisfies every existence and
# permission check and then fails at exec.
require_elf "${DEB_ROOT}/opt/photo-organizer/private_gallery_app" deb_binary_not_elf
require_elf "${DEB_ROOT}/opt/photo-organizer/galleryd" deb_binary_not_elf
for required_rel in \
  "opt/photo-organizer/AppRun" \
  "opt/photo-organizer/private_gallery_app" \
  "opt/photo-organizer/galleryd"; do
  if [[ ! -x "${DEB_ROOT}/${required_rel}" ]]; then
    fail deb_not_executable "${required_rel} is not executable in the .deb"
  fi
done

# /usr/bin/photo-organizer is the symlink a desktop user actually clicks. It has
# to exist, be a symlink, and point at the AppRun: a dangling symlink installs
# perfectly under dpkg and then fails at launch.
DEB_LAUNCHER="${DEB_ROOT}/usr/bin/photo-organizer"
if [[ ! -L "${DEB_LAUNCHER}" ]]; then
  fail deb_symlink_missing "/usr/bin/photo-organizer is not a symlink in the .deb"
fi
deb_link_target="$(readlink "${DEB_LAUNCHER}")"
record "deb_usr_bin_symlink" "${deb_link_target}"
if [[ "${deb_link_target}" != /* ]]; then
  fail deb_symlink_invalid \
    "/usr/bin/photo-organizer points at the relative path '${deb_link_target}'; it would not resolve after installation"
fi
if [[ ! -e "${DEB_ROOT}${deb_link_target}" ]]; then
  fail deb_symlink_invalid \
    "/usr/bin/photo-organizer points at ${deb_link_target}, which the package does not contain"
fi
if [[ "${deb_link_target}" != "/opt/photo-organizer/AppRun" ]]; then
  fail deb_symlink_invalid \
    "/usr/bin/photo-organizer points at ${deb_link_target}, not /opt/photo-organizer/AppRun"
fi

# The desktop entry the package installs uses an ABSOLUTE Exec, so -- unlike the
# AppImage's -- it must resolve, mapped from the real install path onto the
# extraction root.
deb_desktop="${DEB_ROOT}/usr/share/applications/photo-organizer.desktop"
deb_exec="$(awk -F= '/^Exec=/ {print $2; exit}' "${deb_desktop}" || true)"
record "deb_desktop_exec" "${deb_exec:-<none>}"
if [[ -z "${deb_exec}" ]]; then
  fail deb_desktop_entry_missing "the installed desktop entry has no Exec= line"
fi
if [[ "${deb_exec}" != /* ]]; then
  fail deb_exec_unresolvable \
    "the installed desktop entry uses the bare name '${deb_exec}'; a desktop launch resolves it against PATH, where this package installs nothing"
fi
if [[ ! -x "${DEB_ROOT}${deb_exec}" ]]; then
  fail deb_exec_unresolvable \
    "the installed desktop entry runs ${deb_exec}, which is not an executable file in the package"
fi
# The icon the entry names has to exist, or the launcher shows a broken image.
deb_icon_name="$(awk -F= '/^Icon=/ {print $2; exit}' "${deb_desktop}" || true)"
record "deb_desktop_icon" "${deb_icon_name:-<none>}"
if [[ -n "${deb_icon_name}" ]] \
  && [[ ! -f "${DEB_ROOT}/usr/share/icons/hicolor/512x512/apps/${deb_icon_name}.png" ]]; then
  fail deb_icon_missing \
    "the installed desktop entry names Icon=${deb_icon_name}, which the package does not install at the 512x512 hicolor path"
fi

# Package metadata: `dpkg -i` rejects a package with a broken control file, and
# these field values are what the published filename promises.
deb_control_field() {
  local field="$1" out member archive
  if command -v dpkg-deb >/dev/null 2>&1; then
    out="$(dpkg-deb -f "${DEB}" "${field}" 2>/dev/null)" || return 1
    printf '%s' "${out}"
    return 0
  fi
  member="$(bsdtar -tf "${DEB}" 2>/dev/null | grep -E -m1 '^control\.tar\.')" || return 1
  if [[ -z "${member}" ]]; then
    return 1
  fi
  archive="${SCRATCH}/deb/control/${member}"
  mkdir -p "${SCRATCH}/deb/control"
  bsdtar -xf "${DEB}" -C "${SCRATCH}/deb/control" "${member}" 2>/dev/null || return 1
  out="$(bsdtar -xOf "${archive}" ./control 2>/dev/null)" \
    || out="$(bsdtar -xOf "${archive}" control 2>/dev/null)" \
    || return 1
  # No `head -1`: the control file has exactly one of each field, and a duplicate
  # would then leave a newline in the value and fail the checks below.
  printf '%s\n' "${out}" | sed -n "s/^${field}:[[:space:]]*//p"
}

deb_pkg="$(deb_control_field Package || true)"
deb_ver="$(deb_control_field Version || true)"
deb_arch="$(deb_control_field Architecture || true)"
record "deb_control_package" "${deb_pkg:-<missing>}"
record "deb_control_version" "${deb_ver:-<missing>}"
record "deb_control_architecture" "${deb_arch:-<missing>}"
if [[ -z "${deb_pkg}" || -z "${deb_ver}" || -z "${deb_arch}" ]]; then
  fail deb_control_missing \
    "the .deb's control file is missing Package/Version/Architecture (Package='${deb_pkg}' Version='${deb_ver}' Architecture='${deb_arch}')"
fi
if [[ "${deb_pkg}" != "photo-organizer" ]]; then
  fail deb_control_invalid "the .deb declares Package: ${deb_pkg}, expected photo-organizer"
fi
if [[ "${deb_arch}" != "amd64" ]]; then
  fail deb_control_invalid "the .deb declares Architecture: ${deb_arch}, expected amd64"
fi
if [[ ! "${deb_ver}" =~ ^[0-9][0-9A-Za-z.+~:-]*$ ]]; then
  fail deb_control_invalid "the .deb declares an unusable Version: '${deb_ver}'"
fi
log "deb: layout, /usr/bin symlink, desktop entry, icon and control metadata verified"

run_leg deb "${DEB_ROOT}/opt/photo-organizer/AppRun"

# ---------------------------------------------------------------------------
# Result
# ---------------------------------------------------------------------------
RESULT="pass"
record "result" "pass"
record "finished_utc" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
log "PASS: both Linux legs installed, cold-launched, rendered a stable frame and showed no crash"
log "evidence: ${EVIDENCE_DIR}"
exit 0
