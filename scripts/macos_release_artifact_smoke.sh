#!/usr/bin/env bash
#
# Artifact-level release gate for the macOS .dmg: prove the exact file we are
# about to publish can actually be mounted, cold-launched, and survives long
# enough to render a real frame, on a real macOS runner.
#
# Why this exists: issue #98, the macOS half. The `macos` job in
# .github/workflows/release.yml builds `flutter build macos`, copies the Rust
# daemon and the Python sidecar into the bundle, and packs the result into
# `photo-organizer-macos-<ref>.dmg`, which is then published. Every check in CI
# up to that point validated the *code*. None validated the *binary*. The
# Android sibling (`android_release_artifact_smoke.sh`, issue #97) is the
# worked example: CI shipped an APK that no phone could install. The same class
# of bug is available on macOS -- a DMG whose bundle is missing its daemon, is
# built for the wrong architecture, is quarantined, or launches and then shows a
# blank window -- and the release body already says "unsigned build; no
# notarization performed", so nobody is looking at this artifact.
#
# This script is a committed, locally testable script rather than an inline
# `run:` block, for the same reason the Android gate is: shell that only exists
# in a workflow cannot be tested, and a gate that cannot be tested is a comment.
#
# Design notes (each of these is a deliberate decision, not an accident):
#
#   * It operates on the published bytes. The input is the `.dmg` itself, not a
#     rebuilt `.app`: it is mounted read-only with `hdiutil` and the app is
#     launched *from the mounted volume*, so the thing that renders is the thing
#     a user downloads. Launching from a read-only DMG is deliberately the
#     harsher of the two real-world paths (drag-to-Applications copies the
#     bundle to a writable volume first), so a failure here is a real packaging
#     defect rather than an artefact of the harness. Drag-to-Applications is NOT
#     exercised; see the limitations block.
#
#   * DMG shape is checked structurally, before anything is mounted. A UDZO
#     image ends in a 512-byte trailer whose first four bytes are the literal
#     `koly`; requiring it is what stops an arbitrary file (a truncated upload,
#     a zip, a Git LFS pointer) from being "mounted" and passing. Every way this
#     check can fail to run -- no `hdiutil`, an unlistable image, a mount point
#     that stays empty -- is a hard failure, not a warning, because nothing
#     downstream re-asserts that we really launched the shipped artifact.
#
#   * Architecture is checked from the bundle, not assumed from the runner. The
#     runner's `uname -m` and the Mach-O architectures of both the app
#     executable and the bundled Rust daemon are compared. A `macos-latest`
#     runner that cannot execute the artifact we just built is a real and
#     unfixable-by-here condition, and the honest answer is a non-zero exit that
#     says so -- not a green run and not a skip.
#
#   * Gatekeeper is handled deliberately rather than optimistically. This project
#     ships an unsigned, unnotarized build (stated in the release body), so
#     `spctl --assess` is *expected* to reject it and that expectation is
#     recorded as evidence and as a `::warning::`, not treated as a failure --
#     failing on it would block every release forever over a property the project
#     publishes on purpose. What IS fatal is a published bundle that carries
#     `com.apple.quarantine`: quarantine is set by the browser at download time,
#     so a quarantined upload means the OS will put a Gatekeeper dialog in front
#     of every user, and the launch would then be gated on someone clicking
#     "Open". The gate refuses that outright rather than quietly stripping the
#     attribute, because stripping it is precisely the step that hides the
#     refusal. (The working copy is sanitised *after* that assertion, so a stray
#     attribute from the runner's temp directory cannot manufacture a failure.)
#
#   * "Launched" is not the same as "rendered", and on macOS it is not even the
#     same as "has a window". The gate therefore requires, at the moment of
#     capture: a live process, a window the window server reports, a frame with
#     at least MIN_DISTINCT_COLORS distinct colours, and two consecutive
#     captures that are byte-identical. It prefers a *window-scoped* capture
#     (`screencapture -l <windowid>`) over a full-screen one, because a
#     full-screen capture of a macOS desktop is visually complex even when the
#     app has painted nothing -- the menu bar, the wallpaper and the Dock are
#     enough to clear any colour threshold. The window assertion is what stops
#     that from being a pass, not the colour count.
#
#   * The display harness is proven BEFORE the app is launched. If
#     `screencapture` cannot produce a non-trivial frame of an idle desktop --
#     no attached display, no WindowServer session, or Screen Recording (TCC)
#     not granted to the automation user -- then this runner cannot prove
#     anything about rendering, and the gate fails immediately with that as the
#     stated reason. It does not fall back to "trust me, it probably launched".
#     This ordering matters: it separates "the runner cannot see" from "the app
#     did not draw", which are otherwise the same red build.
#
#   * Crash detection reads the OS's own DiagnosticReports, diffed against a
#     pre-launch marker file. This is the macOS analogue of Android's dedicated
#     `logcat -b crash` buffer: a fresh runner crashes unrelated system
#     processes during boot, so "any .ips file exists" is meaningless, but
#     "a .ips report for *this* bundle was written after we launched" is precise.
#     Both the file name and the report body must name our executable, so a
#     same-named process belonging to something else cannot fail the release.
#     The dir must be enumerable, and at least one of the two standard report
#     directories must exist: a reporting path that is not there has not been
#     shown to work, and "found nothing" is not the same as "looked".
#
#   * LIMITATION, stated rather than papered over, and repeated in the summary:
#     the pixels are not proven to come from the app's own UI. macOS shows a
#     Launch Services/Launchpad splash for a cold `open` of a bundle, and a
#     splash is inside a real window, is complex and is perfectly stable, so all
#     three render conditions are satisfied by it. Distinguishing the two needs a
#     Flutter-owned surface identified from the window server, or the semantics
#     tree, which requires an accessibility service unavailable in CI. This is
#     the same known false pass the Android gate records, and the fix is the
#     same in kind. It is recorded rather than guessed at, because a heuristic
#     that is wrong in the *lenient* direction reintroduces exactly the false
#     pass this gate exists to prevent.
#
# Usage: macos_release_artifact_smoke.sh <path-to-dmg-or-app-bundle>
#
# Tunables (all have safe defaults; override via env in tests):
#   MACOS_SMOKE_BUNDLE_ID                 expected bundle id (default: read from Info.plist)
#   MACOS_SMOKE_LAUNCH_TIMEOUT_SECONDS    process-alive budget after `open`
#   MACOS_SMOKE_RENDER_TIMEOUT_SECONDS    first-real-frame budget
#   MACOS_SMOKE_POLL_INTERVAL_SECONDS     poll period for the waits
#   MACOS_SMOKE_MIN_DISTINCT_COLORS       frame complexity threshold
#   MACOS_SMOKE_EVIDENCE_DIR              where evidence files are written
#   MACOS_SMOKE_NAME                      evidence file prefix (matrix-safe)
#   MACOS_SMOKE_REQUIRED_BUNDLE_FILES     files that must exist in Contents/MacOS
#   MACOS_SMOKE_MIN_WINDOW_POINTS         minimum window width/height in points
#   MACOS_SMOKE_DIAG_REPORTS_DIRS         ";"-separated crash-report directories
#   MACOS_SMOKE_LOG_LOOKBACK              unified-log lookback window
#   MACOS_SMOKE_*_BIN                     the macOS tool to use for each operation.
#                                         Present so the suite can substitute a
#                                         fake device; these change *which* binary
#                                         runs, never *whether* a check runs.

set -euo pipefail

LAUNCH_TIMEOUT_SECONDS="${MACOS_SMOKE_LAUNCH_TIMEOUT_SECONDS:-90}"
RENDER_TIMEOUT_SECONDS="${MACOS_SMOKE_RENDER_TIMEOUT_SECONDS:-120}"
POLL_INTERVAL_SECONDS="${MACOS_SMOKE_POLL_INTERVAL_SECONDS:-3}"
MIN_DISTINCT_COLORS="${MACOS_SMOKE_MIN_DISTINCT_COLORS:-32}"
EVIDENCE_DIR="${MACOS_SMOKE_EVIDENCE_DIR:-.}"
SMOKE_NAME="${MACOS_SMOKE_NAME:-macos-smoke}"
MIN_WINDOW_POINTS="${MACOS_SMOKE_MIN_WINDOW_POINTS:-200}"
LOG_LOOKBACK="${MACOS_SMOKE_LOG_LOOKBACK:-10m}"

# The macOS tools this gate drives. Every one of them is overridable, and every
# one of them is a real dependency whose absence is a hard failure -- the same
# fail-closed posture the Android gate takes for `unzip`, and for the same
# reason: on this platform nothing downstream re-asserts any of these.
HDITOOL_BIN="${MACOS_SMOKE_HDITOOL_BIN:-hdiutil}"
OPEN_BIN="${MACOS_SMOKE_OPEN_BIN:-open}"
LSAPPINFO_BIN="${MACOS_SMOKE_LSAPPINFO_BIN:-lsappinfo}"
SCREENSHOT_BIN="${MACOS_SMOKE_SCREENSHOT_BIN:-screencapture}"
XATTR_BIN="${MACOS_SMOKE_XATTR_BIN:-xattr}"
LIPO_BIN="${MACOS_SMOKE_LIPO_BIN:-lipo}"
SPCTL_BIN="${MACOS_SMOKE_SPCTL_BIN:-spctl}"
LOG_BIN="${MACOS_SMOKE_LOG_BIN:-log}"
FIND_BIN="${MACOS_SMOKE_FIND_BIN:-find}"
PLIST_BUDDY_BIN="${MACOS_SMOKE_PLIST_BUDDY_BIN:-/usr/libexec/PlistBuddy}"

# Files that must be present in Contents/MacOS alongside the app executable.
#
# `galleryd` is the Rust daemon: release.yml copies it into the bundle, and the
# app cannot organise anything without it. A bundle that lost it is exactly the
# #97 bug class -- installs, launches, renders, and is useless -- and no amount
# of rendering proves it is there, so it is asserted structurally, before the
# app is ever touched. Read as a space-separated string and split deliberately:
# quoting the default inside `${:-}` would produce one entry literally named
# "galleryd ml_sidecar". This is the one place an unquoted expansion is the
# intended behaviour.
read -r -a REQUIRED_BUNDLE_FILES <<<"${MACOS_SMOKE_REQUIRED_BUNDLE_FILES:-galleryd}"
if ((${#REQUIRED_BUNDLE_FILES[@]} == 0)); then
  echo "ERROR: MACOS_SMOKE_REQUIRED_BUNDLE_FILES is set but empty; refusing to check for no bundled files at all" >&2
  exit 2
fi

# Crash reports are written per user and per system.
#
# Both are consulted, and at least one must exist. A runner on which neither
# exists has not been shown to have a working crash-reporting path, and
# "found nothing in a directory that was never there" is the exact shape of the
# #97 false pass -- so it is refused rather than reported as clean. ";"-separated
# so paths containing spaces survive, split on IFS rather than an unquoted
# expansion for the same reason the Android fake `adb` splits its patterns.
DIAG_REPORTS_DIRS_RAW="${MACOS_SMOKE_DIAG_REPORTS_DIRS:-${HOME:-/tmp}/Library/Logs/DiagnosticReports;/Library/Logs/DiagnosticReports}"

MOUNT_DIR=""
MOUNT_ROOT=""
MOUNT_PATH=""
APP_PATH=""
APP_EXECUTABLE=""
APP_BUNDLE_ID=""
APP_PID=""
WINDOW_ID=""
VISIBLE=""
HIDDEN=""
WINDOW_BOUNDS=""

SCREENSHOT_PATH=""
PREFLIGHT_SCREENSHOT_PATH=""
CRASH_REPORTS_PATH=""
UNIFIED_LOG_PATH=""
LSAPPINFO_PATH=""
SPCTL_PATH=""
SUMMARY_PATH=""
OPEN_PATH=""

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

# `head -n 1` is avoided throughout: closing a pipe early can SIGPIPE the writer,
# which `set -o pipefail` would report as a failure. Bash string surgery is used
# instead so no pipeline depends on a reader closing early.
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

# One path policy for evidence. User-downloadable sidecars record bare
# filenames, because they must verify outside the runner. The run-internal
# summary records workspace-relative paths when they are inside the workspace
# and absolute otherwise: absolute runner paths differ on every machine and make
# evidence incomparable across runs. Paths are never secrets, so this is about
# comparability, not redaction.
evidence_display_path() {
  local path="$1" workspace="${GITHUB_WORKSPACE:-}"
  if [[ -n "${workspace}" && "${path}" == "${workspace}/"* ]]; then
    printf '%s\n' "${path#"${workspace}/"}"
  else
    printf '%s\n' "${path}"
  fi
}

# Every limitation of this gate, printed to the log and copied into the
# evidence. Printed unconditionally rather than only on failure, because a
# reader of a green run needs the same list as a reader of a red one -- the
# point of a drop-gate is that what it proved is legible, and "it passed" does
# not say what was left unproven.
print_limitations() {
  printf '%s\n' "LIMITATIONS (what this gate does NOT prove):" >&2
  printf '%s\n' \
    "  * The rendered pixels are not proven to come from the app's own UI. A macOS" \
    "    launch splash lives inside a real window, is visually complex and is" \
    "    perfectly stable, so it satisfies every render condition here. Separating" \
    "    them needs a Flutter-owned surface from the window server, or the" \
    "    semantics tree, which needs an accessibility service unavailable in CI." \
    "  * No real user login session. The runner is an automation account; TCC" \
    "    (Screen Recording, Accessibility) grants, FileVault state, and per-user" \
    "    keychain availability are not those of a person at a desk." \
    "  * Drag-to-Applications is not exercised: the bundle is launched from the" \
    "    read-only mounted DMG, which is the harsher of the two real paths." \
    "  * Notarization and stapling are out of scope; the build is unsigned by" \
    "    design and spctl rejection is recorded, not failed." \
    "  * No Apple Silicon is proven unless uname -m says arm64. The gate compares" \
    "    the runner's architecture against the bundle's and fails on a mismatch;" \
    "    it does not upgrade an x86_64 run into evidence about Apple Silicon. An" \
    "    x86_64 bundle on an arm64 host is exercised through Rosetta, which is" \
    "    not the same claim as native." \
    "  * No real photo library, no GPU/Metal path, no multi-space or display" \
    "    scaling behaviour, and nothing about a first-run user's real media." \
    "  * Crash detection is scoped to reports written for this bundle. A hang" \
    "    that writes no .ips report is not a crash this gate can see." >&2
}

# --- PNG decoding ------------------------------------------------------------

# Prints the number of distinct colours in a PNG (early-exits above the
# caller's threshold). Decodes only what `screencapture` produces: 8-bit,
# non-interlaced, greyscale / RGB / greyscale+alpha / RGBA. Implemented in
# Python's stdlib so the gate needs no image tooling on the runner.
#
# This is deliberately a second copy rather than a shared helper: the Android
# gate owns the other one, and a shared file that either platform's change breaks
# would turn a working macOS gate into a red build for an unrelated reason. The
# mutation suite pins this copy independently.
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

# --- artifact shape ----------------------------------------------------------

# A UDZO disk image ends in a 512-byte trailer beginning with the literal
# `koly`. Checked before `hdiutil` is trusted, so a truncated upload, a zip, or
# a Git LFS pointer cannot be "mounted" and quietly pass.
assert_dmg_image() {
  local dmg="$1" size trailer
  size="$(wc -c <"${dmg}")"
  if ((size < 1024)); then
    fail "${dmg} is ${size} bytes; a macOS disk image is far larger, so this is a truncated or wrong file"
  fi
  # `tail -c 512` then read the first four bytes with bash's `read -n 4`, so no
  # pipeline in this script depends on a reader closing early (which SIGPIPs the
  # writer, and `set -o pipefail` would report that as a failure).
  trailer="$(tail -c 512 "${dmg}" | { IFS= read -r -n 4 first || true; printf '%s' "${first:-}"; })"
  if [[ "${trailer}" != "koly" ]]; then
    fail "${dmg} has no 'koly' disk-image trailer, so it is not the .dmg this gate can gate; if the release ever publishes a .zip or a bare .app, teach this script that format explicitly rather than letting it accept anything"
  fi
  log "dmg trailer verified: ${size} bytes, koly signature present"
}

# Locates the single application bundle at the root of the mounted image.
#
# Exactly one is required. Picking the "first" of several would make which
# bundle got gated depend on `ls` ordering, which is not a property anyone
# reviewed; and a DMG whose root holds two app bundles is a packaging bug worth
# being told about.
#
# `find`'s exit status is checked, and a listing that could not be read is
# reported as *that* rather than as "no app bundle". Both directions refuse --
# an unreadable root is not evidence that the image is empty, and conflating the
# two is the #97 false-pass shape. The distinction matters to whoever reads a red
# build: "the image is empty" is a packaging bug, "the image could not be read"
# is a runner or image-corruption problem, and they have different owners.
locate_app_bundle() {
  local root="$1" candidates=() candidate listing rc=0
  listing="$("${FIND_BIN}" "${root}" -mindepth 1 -maxdepth 1 -type d -name '*.app' 2>/dev/null)" || rc=$?
  if ((rc != 0)); then
    printf '::error::could not list the mounted image at %s (find exit %s), so whether it holds an app bundle is unknown. This gate will not report "no bundle" from a directory it never read.\n' \
      "${root}" "${rc}" >&2
    return 1
  fi
  while IFS= read -r candidate; do
    [[ -n "${candidate}" ]] || continue
    candidates+=("${candidate}")
  done <<<"${listing}"
  if ((${#candidates[@]} == 0)); then
    printf '::error::the mounted image contains no .app bundle at its root: [%s]\n' \
      "$("${FIND_BIN}" "${root}" -mindepth 1 -maxdepth 1 2>/dev/null | tr '\n' ' ')" >&2
    return 1
  fi
  if ((${#candidates[@]} > 1)); then
    printf '::error::the mounted image contains %s app bundles at its root (%s); this gate refuses to guess which one a user would open\n' \
      "${#candidates[@]}" "$(printf '%s ' "${candidates[@]}")" >&2
    return 1
  fi
  printf '%s' "${candidates[0]}"
}

# Reads a top-level string key out of Info.plist.
#
# `/usr/libexec/PlistBuddy` is a real parser, so this cannot be satisfied by a
# comment or a key that only looks right. Non-zero exit propagates, so a
# missing key is an unanswered question rather than an empty string that reads
# as "fine".
plist_value() {
  local plist="$1" key="$2"
  "${PLIST_BUDDY_BIN}" -c "Print :${key}" "${plist}" 2>/dev/null | tr -d '\r'
}

assert_bundle_layout() {
  local app="$1" plist executable
  plist="${app}/Contents/Info.plist"
  if [[ ! -f "${plist}" ]]; then
    fail "${app} has no Contents/Info.plist; that is not an application bundle"
  fi
  executable="$(trim "$(plist_value "${plist}" CFBundleExecutable)")"
  if [[ -z "${executable}" ]]; then
    fail "${app}/Contents/Info.plist has no CFBundleExecutable, so the bundle does not say what to launch"
  fi
  if [[ ! -f "${app}/Contents/MacOS/${executable}" ]]; then
    fail "${app} declares CFBundleExecutable=${executable} but ${app}/Contents/MacOS/${executable} does not exist"
  fi
  if [[ ! -s "${app}/Contents/MacOS/${executable}" ]]; then
    fail "${app}/Contents/MacOS/${executable} is empty; a zero-byte main executable launches to nothing and would be indistinguishable from a render failure"
  fi
  APP_EXECUTABLE="${executable}"
  APP_BUNDLE_ID="$(trim "$(plist_value "${plist}" CFBundleIdentifier)")"
  if [[ -z "${APP_BUNDLE_ID}" ]]; then
    fail "${app}/Contents/Info.plist has no CFBundleIdentifier, so the launch cannot be tracked in the window server"
  fi
  log "bundle: $(basename "${app}") (id ${APP_BUNDLE_ID}, executable ${APP_EXECUTABLE})"

  local required
  for required in "${REQUIRED_BUNDLE_FILES[@]}"; do
    if [[ ! -e "${app}/Contents/MacOS/${required}" ]]; then
      printf '::error::%s ships without Contents/MacOS/%s. The app installs, cold-launches and renders without it, so no amount of launch evidence catches a dropped sidecar -- which is the #97 bug class verbatim.\n' \
        "${app}" "${required}" >&2
      return 1
    fi
    if [[ ! -x "${app}/Contents/MacOS/${required}" ]]; then
      printf '::error::%s ships Contents/MacOS/%s but it is not executable; a dropped chmod +x is invisible to a launch test that only looks at the app process\n' \
        "${app}" "${required}" >&2
      return 1
    fi
    log "bundled sidecar present and executable: ${required}"
  done
}

# Normalises the spellings a machine may report for the same architecture.
# `uname -m` and `lipo -archs` agree on macOS, but a developer running this
# suite on Linux gets `x86_64`/`amd64` and `arm64`/`aarch64`, and a comparison
# that is only correct on one of those hosts is a check that is silently off.
normalize_arch() {
  case "$1" in
    aarch64 | arm64e) printf 'arm64' ;;
    amd64 | x86_64 | x64) printf 'x86_64' ;;
    i386 | i686) printf 'i686' ;;
    *) printf '%s' "$1" ;;
  esac
}

# Asserts the runner can actually execute the binaries we are about to launch.
#
# Read from the Mach-O headers, so a fat header advertising both slices counts
# for both and a thin header counts only for its own. This is the macOS analogue
# of the Android ABI check, and it exists for the same reason: the gate can only
# ever prove the slice the runner is. A mismatch here is unfixable from inside
# this script -- Rosetta translates x86_64 on Apple Silicon, but no mechanism
# runs an arm64 slice on an Intel host -- so the honest answer is a non-zero exit
# that names both architectures, not a warning and not a skip.
assert_architecture_matches_runner() {
  local app="$1" runner raw candidate
  runner="$(normalize_arch "$(uname -m)")"
  log "runner architecture: ${runner}"
  # The app executable plus every declared sidecar. The daemon is included
  # because an arm64 app with an x86_64-only galleryd launches and renders and
  # then fails at the first thing the daemon does -- the same "the binary is
  # wrong" class as the Android ABI check, one layer down.
  local binaries=("${APP_EXECUTABLE}" "${REQUIRED_BUNDLE_FILES[@]}")
  local binary
  for binary in "${binaries[@]}"; do
    if ! raw="$("${LIPO_BIN}" -archs "${app}/Contents/MacOS/${binary}" 2>&1)"; then
      printf '::error::could not read the Mach-O architectures of %s, so it cannot be shown to be runnable here: %s\n' \
        "${binary}" "$(trim "${raw}")" >&2
      return 1
    fi
    local matched=0
    # shellcheck disable=SC2086 # `lipo -archs` is a space-separated list; the split is the point
    for candidate in ${raw}; do
      if [[ "$(normalize_arch "${candidate}")" == "${runner}" ]]; then
        matched=1
        break
      fi
    done
    if ((matched == 0)); then
      printf '::error::%s is built for [%s] but this runner is %s, so it cannot be executed here at all. This is a real limitation of the runner/artifact pair, not a defect the gate can work around: nothing downstream re-launches this binary.\n' \
        "${binary}" "$(trim "${raw}")" "${runner}" >&2
      return 1
    fi
    log "architecture ok: ${binary} carries [$(trim "${raw}")] (runner is ${runner})"
  done
}

# Quarantine and Gatekeeper posture.
#
# `xattr -p` exits non-zero when the attribute is absent, which is the healthy
# case, so its status is captured rather than propagated. A quarantined upload
# is fatal: quarantine is what makes a double-clicked download raise a Gatekeeper
# dialog, and stripping it to make the gate go green would hide the very refusal
# this is here to surface.
assert_published_bundle_not_quarantined() {
  local app="$1" raw rc=0
  raw="$("${XATTR_BIN}" -p com.apple.quarantine "${app}" 2>/dev/null)" || rc=$?
  if ((rc == 0)) && ! is_blank "${raw}"; then
    printf '::error::the published bundle carries com.apple.quarantine:\n%s\nThe OS will raise a Gatekeeper dialog for every user who double-clicks it. The gate refuses to strip the attribute, because stripping it is exactly the step that hides this refusal.\n' \
      "${raw}" >&2
    return 1
  fi
  log "published bundle is not quarantined"

  # The working copy is sanitised *after* the assertion above, and only so a
  # stray attribute inherited from the runner's own temp directory cannot
  # manufacture a launch failure. Logged, because a silent xattr -cr is
  # indistinguishable from tampering.
  if "${XATTR_BIN}" -cr "${app}" >/dev/null 2>&1; then
    log "cleared extended attributes on the working copy so the launch tests the bundle, not the runner's temp directory"
  fi
}

# `spctl --assess` is expected to reject this build: the project publishes an
# unsigned, unnotarized macOS artifact and says so in the release body. That is
# a recorded property, not a regression, so a rejection is evidence plus a
# warning. Failing here instead would block every release forever over a
# deliberate, documented choice -- and the thing the gate exists to catch, a
# Gatekeeper refusal that actually stops the app from launching, is caught by the
# launch itself.
record_gatekeeper_assessment() {
  local app="$1" output rc=0
  output="$("${SPCTL_BIN}" --assess --type execute --verbose=4 "${app}" 2>&1)" || rc=$?
  {
    printf 'exit status: %s\n' "${rc}"
    printf '%s\n' "${output}"
  } >"${SPCTL_PATH}"
  if ((rc == 0)); then
    log "Gatekeeper assessment: accepted"
  else
    printf '::warning::spctl rejected the bundle, which is expected for this unsigned, unnotarized build (documented in the release notes). Recorded as evidence; the launch below is what must succeed.\n' >&2
    log "Gatekeeper assessment: rejected (unsigned, unnotarized -- expected for this project); see ${SPCTL_PATH}"
  fi
}

# --- the display harness -----------------------------------------------------

# Proves this runner can produce a non-trivial frame BEFORE the app is launched.
#
# A macOS desktop is not a blank screen: menu bar, wallpaper and Dock are
# already complex, so "the capture worked" has to mean "the capture produced a
# decodable PNG with real content". If it cannot, this runner cannot prove
# anything about rendering -- no attached display, no WindowServer session, or
# Screen Recording (TCC) not granted to the automation user -- and the gate says
# so immediately instead of reporting a mysterious render timeout twenty
# minutes later.
preflight_display_harness() {
  local dest="$1" colors
  if ! "${SCREENSHOT_BIN}" -x -o "${dest}" >/dev/null 2>&1 || [[ ! -s "${dest}" ]]; then
    fail "this runner cannot capture the screen (${SCREENSHOT_BIN} produced no file). That usually means no attached display or no WindowServer session for the automation user. This gate will not report a launch or render verdict it cannot evidence, so it stops here."
  fi
  if ! colors="$(png_distinct_colors "${dest}" "${MIN_DISTINCT_COLORS}" 2>&1)"; then
    fail "the pre-launch screen capture is not a decodable PNG: ${colors}. The capture harness is broken, so a render verdict from it would be meaningless."
  fi
  if [[ ! "${colors}" =~ ^[0-9]+$ ]] || ((colors < MIN_DISTINCT_COLORS)); then
    fail "the idle desktop only produced ${colors} distinct colours (threshold ${MIN_DISTINCT_COLORS}), so screen capture is producing a blank or solid frame on this runner. This is a display/permission problem, not an app problem, and it is reported as a failure rather than skipped: nothing here can evidence a rendered frame."
  fi
  log "display harness verified: an idle desktop captures as a decodable PNG with ${colors}+ distinct colours"
}

# --- the window server -------------------------------------------------------

# Reads one key out of `lsappinfo info`.
#
# `lsappinfo` is used rather than `CGWindowListCopyWindowInfo` or AppleScript
# deliberately: it is a Launch Services query, so it needs no TCC grant (no
# Screen Recording, no Accessibility), which is what makes it usable in CI at
# all. A small set of key spellings is accepted because the tool's output shape
# has varied across macOS releases, and a check that breaks on a key rename is a
# check that gets deleted. Every accepted spelling is an affirmative answer; an
# unrecognised shape yields an empty value, which the callers treat as "not
# established" and refuse.
#
# The match is anchored to the start of the trimmed line, so `pid` cannot be
# satisfied by some other key that merely ends in "pid" (an unanchored substring
# match here would be satisfied by a `Upid:` or a `BundleIdentifier:` line and
# would report a pid that is not the app's).
lsappinfo_field() {
  local asn="$1" key="$2" line
  while IFS= read -r line; do
    line="$(trim "${line}")"
    if [[ "${line}" == "${key}:"* ]]; then
      trim "${line#"${key}:"}"
      return 0
    fi
  done <<<"$(lsappinfo_output "${asn}")"
  return 1
}

lsappinfo_output() {
  local asn="$1"
  "${LSAPPINFO_BIN}" info "${asn}" 2>/dev/null
}

# The raw reply to "which application serial number owns this bundle id", with
# whitespace squeezed out.
#
# `find bundleid=<id>` is the documented spelling. The `findLSApplication` verb
# that used to be here is not: on the macOS 26.6.2 runner it answers
# `Unrecognized command: findLSApplication` on *stdout*, so `2>/dev/null` cannot
# suppress it and the caller read the error text as a serial number. That is how
# release run 37184543519 aborted at the "already registered with the window
# server" check with nothing running and nothing launched.
#
# Sets two globals rather than printing the reply.
#
# This cannot be a command substitution. `raw="$(lsappinfo_asn_raw)"` runs the
# function in a subshell, so an assignment to the status inside it dies with the
# subshell and the caller sees the variable unset -- which under a `${VAR:-1}`
# default reads as "the tool failed". Measured, not assumed: the first version of
# this fix did exactly that and turned the entire gate red, reporting an
# unanswerable window server on runs where lsappinfo answered perfectly well.
#
# The status is captured rather than discarded because `|| true` collapses two
# different facts into one empty reply:
#   * "the app is not running" -- exit 0, nothing on stdout
#   * "the window server would not answer" -- non-zero, nothing on stdout, which a
#     sandbox, TCC, or a missing window-server connection all produce
# Reading the second as the first makes the cold-launch check pass precisely when
# it was not performed at all. The reply is still what the parsing cares about;
# only the pre-launch caller acts on the status.
LSAPPINFO_RC=0
LSAPPINFO_RAW=''
lsappinfo_query() {
  local out rc=0
  out="$("${LSAPPINFO_BIN}" find "bundleid=${APP_BUNDLE_ID}" 2>/dev/null)" || rc=$?
  LSAPPINFO_RC="${rc}"
  LSAPPINFO_RAW="$(printf '%s' "${out}" | tr -d '[:space:]')"
}

# The reply as a well-formed ASN, or nothing.
#
# "Nothing" is a real answer -- the app is not running -- and `refresh_window_state`
# treats it as "no window yet", which is correct for an app that is still launching.
# An unparseable reply is filtered out here rather than being passed along as an ASN,
# so the two callers cannot end up disagreeing about what the tool actually said.
#
# That holds for reply *content*, not for the exit status: an unanswerable window
# server and an empty reply both arrive as "". `LSAPPINFO_RC` is what keeps them
# apart, and only the pre-launch caller reads it.
lsappinfo_asn() {
  lsappinfo_query
  if [[ "${LSAPPINFO_RAW}" =~ ^ASN:0x[0-9a-fA-F]+:0x[0-9a-fA-F]+:$ ]]; then
    printf '%s\n' "${LSAPPINFO_RAW}"
  fi
}

# Refreshes the cached window-server state for the app.
#
# Two states are accepted as "has a window", and the difference is recorded
# rather than hidden:
#   * a window id -- the strongest signal, and the only one that permits a
#     window-scoped screenshot;
#   * Visible=1 with Hidden absent or 0 -- the window server knows the process
#     has UI, but the tool did not hand us a window id, so the capture falls
#     back to full-screen.
# Anything else is "no window", which is a failure. Critically this is *not*
# satisfied by a live process: an app can be running with no window at all
# (background helper, a Flutter engine that never created a view), and a
# full-screen capture of the desktop behind it would sail through a
# complexity-and-stability check.
refresh_window_state() {
  local asn info
  asn="$(lsappinfo_asn)"
  if [[ -z "${asn}" ]]; then
    WINDOW_ID=""
    VISIBLE=""
    HIDDEN=""
    WINDOW_BOUNDS=""
    APP_PID=""
    return 1
  fi
  info="$(lsappinfo_output "${asn}")"
  printf '%s\n' "${info}" >>"${LSAPPINFO_PATH}"
  APP_PID="$(trim "$(lsappinfo_field "${asn}" 'pid' 2>/dev/null || true)")"
  WINDOW_ID=""
  local candidate
  for candidate in FrontWindow MainWindow WindowID windowID; do
    WINDOW_ID="$(trim "$(lsappinfo_field "${asn}" "${candidate}" 2>/dev/null || true)")"
    if [[ -n "${WINDOW_ID}" && "${WINDOW_ID}" != "0x00000000" && "${WINDOW_ID}" != "0" && "${WINDOW_ID}" != "0x0" ]]; then
      break
    fi
    WINDOW_ID=""
  done
  VISIBLE="$(trim "$(lsappinfo_field "${asn}" 'Visible' 2>/dev/null || true)")"
  HIDDEN="$(trim "$(lsappinfo_field "${asn}" 'Hidden' 2>/dev/null || true)")"
  WINDOW_BOUNDS="$(trim "$(lsappinfo_field "${asn}" 'Bounds' 2>/dev/null || true)")"
  return 0
}

app_is_registered() {
  refresh_window_state
}

# A window exists, is on screen, and is not a degenerate helper window.
#
# Two rejections, both deliberate:
#
#   * Hidden=1, checked BEFORE the window id is consulted. `lsappinfo` can
#     report a window id for an app whose windows are hidden, and accepting that
#     would hand the render check a full-screen capture of whatever is behind
#     the app -- a desktop is complex and stable, so the frame would settle and
#     the gate would pass on an app that painted nothing. That path was
#     reachable, and the suite caught it.
#
#   * The size floor, because a 1x1 or 16x16 window is what a crashing Flutter
#     engine or a stray NSPanel can produce, and a window-scoped capture of one
#     is trivially uniform. The floor is enforced only when a window id was
#     reported; a missing bounds value is not itself a gate, because refusing to
#     run on an unverified parsing assumption would make the gate permanently red
#     for a reason unrelated to the artifact. An unparseable bounds string yields
#     extent 0, which the floor then rejects -- a window we cannot measure is not
#     a window we will claim is large.
window_is_present() {
  refresh_window_state || return 1
  if [[ "${HIDDEN}" == "1" ]]; then
    log "no window: the window server reports Hidden=1 for this bundle, so a capture would show whatever is behind it"
    return 1
  fi
  if [[ -n "${WINDOW_ID}" ]]; then
    local width=0 height=0
    read -r width height <<<"$(window_extent)"
    if ((width >= MIN_WINDOW_POINTS && height >= MIN_WINDOW_POINTS)); then
      return 0
    fi
    log "window ${WINDOW_ID} is ${width}x${height} points, below the ${MIN_WINDOW_POINTS}x${MIN_WINDOW_POINTS} floor"
    return 1
  fi
  if [[ "${VISIBLE}" == "1" && ( -z "${HIDDEN}" || "${HIDDEN}" == "0" ) ]]; then
    return 0
  fi
  log "no window: window id empty, Visible='${VISIBLE}', Hidden='${HIDDEN}'"
  return 1
}

# Extracts width and height from `lsappinfo`'s `{{x, y}, {w, h}}` bounds.
#
# Deliberately tolerant: the coordinates are in points, may be floats, and are
# printed in a CoreGraphics-style nested-brace form. If the shape is not
# recognised the gate substitutes 0, which the size floor then rejects -- a
# window we cannot measure is not a window we will claim is large.
window_extent() {
  local bounds="${WINDOW_BOUNDS}"
  if [[ ! "${bounds}" =~ \{[^{}]*\},[[:space:]]*\{[[:space:]]*([0-9.]+)[[:space:]]*,[[:space:]]*([0-9.]+) ]]; then
    printf '0 0'
    return 0
  fi
  printf '%s %s' "${BASH_REMATCH[1]%%.*}" "${BASH_REMATCH[2]%%.*}"
}

# --- launching ---------------------------------------------------------------

# Asserts nothing is already running under this bundle id.
#
# The gate is about a *cold* launch. If a copy is already up, `open` would
# activate it and every subsequent observation would describe a warm process,
# which is the exact thing the Android gate's `am start -W ... LaunchState: COLD`
# is there to guarantee.
# Refuse to continue unless the window server positively says nothing is running.
#
# Three answers are possible and only two of them are usable. Before this was
# shape-checked, any non-empty reply counted as "already running", and because
# `lsappinfo` reports some errors on stdout, a rejected query was reported as a
# phantom instance -- a red gate for an app that was never started.
#
# There is deliberately no `pkill` before the launch. Terminating a stray
# instance would make this check pass without ever proving the launch is cold,
# which is the entire reason it exists (the Android gate pins the same property
# with `am start -W ... LaunchState: COLD`). A red gate naming the real cause is
# the correct outcome here.
assert_nothing_already_running() {
  local raw
  lsappinfo_query
  raw="${LSAPPINFO_RAW}"

  if [[ "${raw}" =~ ^ASN:0x[0-9a-fA-F]+:0x[0-9a-fA-F]+:$ ]]; then
    fail "${APP_BUNDLE_ID} is already registered with the window server (application serial number ${raw}); this gate requires a cold launch, so something is already running and 'open' would only activate it. Kill it and re-run."
  fi

  # An empty reply is the only ambiguous case, and the exit status is what resolves
  # it: "nothing is running" and "the window server would not answer" both print
  # nothing, so taking the empty string as proof of absence makes this check pass
  # exactly when it was never performed. The cold launch is then unproven and the
  # gate reports success it did not earn.
  #
  # Checked last, after the two branches above, because a tool that answered with
  # unusable *text* has given us something to work with and should be reported as
  # the parse failure it is, quoting its own reply. Only a tool that said nothing at
  # all has left the question open.
  if [[ -z "${raw}" ]]; then
    if ((LSAPPINFO_RC != 0)); then
      fail "could not ask the window server whether ${APP_BUNDLE_ID} is running (lsappinfo find exited ${LSAPPINFO_RC} with no usable reply). This gate requires a positively cold launch, and 'no reply' is not proof that nothing is running -- a sandbox, TCC, or a missing window-server connection produces exactly this. Re-run on a session with a working window server; do not work around it by killing processes, which would void the cold-launch proof."
    fi
    log "no existing instance of ${APP_BUNDLE_ID} is registered"
    return 0
  fi
  # Not an ASN. That is a question the gate could not get answered, not a
  # statement about what is running, and the difference matters: reporting it as
  # "already running" sends the operator to kill a process that may not exist.
  # Quoting the reply verbatim is what makes the failure diagnosable.
  fail "cannot tell whether ${APP_BUNDLE_ID} is already running: lsappinfo answered with something that is not an application serial number: '${raw}'. Refusing to continue, because a cold launch cannot be proven while the window server will not answer. This is a fault in the gate's environment, not a claim that the app is running."
}

cold_launch() {
  local output rc=0
  output="$("${OPEN_BIN}" -n "${APP_PATH}" 2>&1)" || rc=$?
  # `open`'s output goes to its own evidence file, not into the summary. The
  # summary is a key: value record that the suite parses; appending raw tool
  # output to it put a bare absolute path in the middle of that record, which
  # broke the "no absolute runner path leaks into the summary" invariant and
  # made the summary unparseable as evidence.
  {
    printf 'command: open -n %s\n' "$(evidence_display_path "${APP_PATH}")"
    printf 'exit status: %s\n' "${rc}"
    printf '%s\n' "${output}"
  } >"${OPEN_PATH}"
  if ((rc != 0)); then
    printf '%s\n' "open refused to launch the bundle (exit ${rc}):" >&2
    printf '%s\n' "${output}" >&2
    fail "the packaged app could not be launched; on macOS this is where an OS-level refusal (Gatekeeper, a damaged bundle, an unregistered architecture) shows up"
  fi
  log "cold launch requested: open -n ${APP_PATH}"
}

# --- the render check --------------------------------------------------------

# Writes one frame to `dest`, preferring a capture of the app's own window.
#
# Window-scoped first, full-screen as the fallback, and the fallback is
# announced: a silent downgrade from "this is the app's window" to "this is
# whatever is on the desktop" is exactly the kind of quiet that turns a gate
# into a comment. The full-screen path is still safe, because window_is_present
# gates it -- but the evidence should say which frame it is.
#
# The scope is returned in CAPTURE_SCOPE, not on stdout.
#
# This is deliberate and it was a real bug: the scope used to be the function's
# stdout, captured by `scope="$(capture_frame ...)"`, which runs the function in a
# subshell. `CAPTURE_FALLBACK_REASON` was assigned in that same subshell, so the
# parent never saw it and the "falling back to a full-screen capture" line could
# never print. The downgrade was real; the announcement was dead code, and the
# test meant to catch it passed only because it matched a window-id substring
# that appears in a different log line too. Setting both variables in the
# caller's own shell is what makes the announcement reachable.
CAPTURE_SCOPE=""
CAPTURE_FALLBACK_REASON=""
capture_frame() {
  local dest="$1"
  CAPTURE_SCOPE=""
  CAPTURE_FALLBACK_REASON=""
  if [[ -n "${WINDOW_ID}" ]]; then
    if "${SCREENSHOT_BIN}" -x -o -l "${WINDOW_ID}" "${dest}" >/dev/null 2>&1 && [[ -s "${dest}" ]]; then
      CAPTURE_SCOPE="window"
      return 0
    fi
    CAPTURE_FALLBACK_REASON="the window-scoped capture of window ${WINDOW_ID} produced no image"
  fi
  if "${SCREENSHOT_BIN}" -x -o "${dest}" >/dev/null 2>&1 && [[ -s "${dest}" ]]; then
    CAPTURE_SCOPE="screen"
    return 0
  fi
  return 1
}

# Wait for a settled, app-owned frame.
#
# What this proves, precisely:
#   1. the window server still reports a window for this bundle *at the moment of
#      capture* -- a panel or alert can appear and a background window can be
#      hidden while we wait;
#   2. the frame is visually complex (>= MIN_DISTINCT_COLORS), which rules out a
#      solid blank, a window-scoped capture of an unpainted surface, and an
#      undecodable capture;
#   3. the frame is *stable* -- two consecutive captures agree -- which rules
#      out a screen caught mid-transition while the Flutter engine is still
#      starting.
#
# What it does NOT prove, and must not be claimed: that the pixels came from the
# app's own UI rather than a macOS launch splash. See the header and the printed
# LIMITATIONS block.
#
# The check is deliberately biased against false PASSES: it can only block the
# release, never let a broken artifact through. Requiring stability is what makes
# it safe to bias that way.
await_settled_app_frame() {
  local deadline=$((SECONDS + RENDER_TIMEOUT_SECONDS)) colors=-1
  local previous="" current="" stable_captures=0
  local last_window_error="" scope=""

  while ((SECONDS < deadline)); do
    # Re-assert the window inside the loop. Checking it only before this loop
    # would let a window that appeared and then hid satisfy the gate.
    if ! window_is_present; then
      last_window_error="window id='${WINDOW_ID}' Visible='${VISIBLE}' Hidden='${HIDDEN}' bounds='${WINDOW_BOUNDS}'"
      log "no app window while waiting for a frame; window server says: ${last_window_error}"
      previous=""
      stable_captures=0
      sleep "${POLL_INTERVAL_SECONDS}"
      continue
    fi

    if capture_frame "${SCREENSHOT_PATH}"; then
      scope="${CAPTURE_SCOPE}"
      if [[ -n "${CAPTURE_FALLBACK_REASON}" ]]; then
        log "${CAPTURE_FALLBACK_REASON}; falling back to a full-screen capture (the window assertion still gates this frame)"
      fi
      if colors="$(png_distinct_colors "${SCREENSHOT_PATH}" "${MIN_DISTINCT_COLORS}" 2>/dev/null)"; then
        if [[ "${colors}" =~ ^[0-9]+$ ]] && ((colors >= MIN_DISTINCT_COLORS)); then
          # sha256_of, not a bare sha256sum: on a host without GNU coreutils a
          # bare call yields an empty digest every iteration, so
          # `stable_captures` never advances and the gate burns its whole budget
          # reporting a misleading "no settled frame" verdict about a good frame.
          current="$(sha256_of "${SCREENSHOT_PATH}")"
          if [[ -n "${current}" && "${current}" == "${previous}" ]]; then
            stable_captures=$((stable_captures + 1))
          else
            stable_captures=0
          fi
          if ((stable_captures >= 1)); then
            log "settled app frame (${scope} capture): ${colors}+ distinct colours, identical across two consecutive captures"
            return 0
          fi
          previous="${current}"
        else
          log "frame is not yet visually complex (${colors} distinct colours); retrying"
          previous=""
          stable_captures=0
        fi
      else
        log "screenshot could not be decoded yet; retrying"
        previous=""
        stable_captures=0
      fi
    else
      log "screenshot capture failed; retrying"
      previous=""
      stable_captures=0
    fi
    sleep "${POLL_INTERVAL_SECONDS}"
  done

  if [[ -n "${last_window_error}" ]]; then
    fail "the app's window went away while waiting for a settled frame (within ${RENDER_TIMEOUT_SECONDS}s); window server says: ${last_window_error}"
  fi
  return 1
}

# --- crash detection ---------------------------------------------------------

# Proves the crash-reporting path exists at all before the launch.
#
# Named for what it does rather than for a "baseline" it does not take: the
# per-file timestamp baseline is a separate marker file created after this
# passes. At least one of the standard report directories must exist, because a
# runner on which none does has not been shown to have a working reporting path,
# and "found nothing in a directory that was never there" is the exact shape of
# the #97 false pass.
assert_crash_reporting_available() {
  local dir
  local IFS=';'
  # shellcheck disable=SC2086 # ';' is the separator; the split is the point
  for dir in ${DIAG_REPORTS_DIRS_RAW}; do
    [[ -n "${dir}" ]] || continue
    if [[ -d "${dir}" ]]; then
      log "crash reports will be read from ${dir}"
      return 0
    fi
  done
  printf '::error::no crash-report directory exists (searched: %s). Nothing downstream re-checks for crashes, so "found nothing" here would be the absence of a question rather than a clean result.\n' \
    "${DIAG_REPORTS_DIRS_RAW//;/, }" >&2
  return 1
}

# Prints every crash report for our executable written since the baseline
# marker. Returns non-zero if a directory that exists could not be read, which
# is the "unanswered question" case: `find` exits non-zero on a permission
# error, and swallowing that would report a crash check that never ran as a
# clean one.
#
# Both the file name and the report body must name the executable. The name
# filter alone would fail the release on an unrelated process that happens to
# share a name; the body filter alone would depend on the .ips field layout.
# Requiring both is the only reading that is precise in the safe direction.
find_new_crash_reports() {
  local marker="$1" found="" dir listing rc
  local IFS=';'
  # shellcheck disable=SC2086 # ';' is the separator; the split is the point
  for dir in ${DIAG_REPORTS_DIRS_RAW}; do
    [[ -n "${dir}" ]] || continue
    if [[ ! -d "${dir}" ]]; then
      continue
    fi
    rc=0
    # `ls`-shaped output parsed with bash rather than `ls -1 | while read`, so
    # the loop runs in this shell and the found-list is visible to the caller.
    listing="$("${FIND_BIN}" "${dir}" -type f -name "${APP_EXECUTABLE}*" -newer "${marker}" 2>/dev/null)" || rc=$?
    if ((rc != 0)); then
      printf 'could not list crash reports in %s (find exit %s)\n' "${dir}" "${rc}" >&2
      return 1
    fi
    local report
    while IFS= read -r report; do
      [[ -n "${report}" ]] || continue
      if grep -qF "${APP_EXECUTABLE}" "${report}" 2>/dev/null; then
        found+="${report}"$'\n'
      fi
    done <<<"${listing}"
  done
  printf '%s' "${found}"
}

assert_no_crash_reports() {
  local marker="$1" reports rc=0
  reports="$(find_new_crash_reports "${marker}")" || rc=$?
  if ((rc != 0)); then
    fail "could not read the crash-report directories (exit ${rc}); refusing to report a crash check that never ran"
  fi
  printf '%s' "${reports}" >"${CRASH_REPORTS_PATH}"
  if ! is_blank "${reports}"; then
    printf 'macOS wrote a crash report for %s during the launch:\n%s\n' "${APP_EXECUTABLE}" "${reports}" >&2
    fail "a crash report was written for ${APP_EXECUTABLE} after launch"
  fi
  log "crash reports clean (no crash report for ${APP_EXECUTABLE} written after launch)"
}

# Best-effort unified log for the evidence bundle. Never a gate: a log that
# cannot be read is not evidence of anything, but it is also not a reason to
# fail a release whose install/launch/render verdict is already established. The
# failure is annotated rather than swallowed.
collect_logs() {
  local executable="${APP_EXECUTABLE}"
  if "${LOG_BIN}" show --style compact --last "${LOG_LOOKBACK}" \
    --predicate "process == \"${executable}\"" >"${UNIFIED_LOG_PATH}" 2>/dev/null; then
    log "unified log collected for ${executable} (last ${LOG_LOOKBACK})"
  else
    printf '::warning::could not read the unified log for %s; the evidence bundle has no app log, but this did not affect the verdict\n' \
      "${executable}" >&2
    printf 'unified log unavailable for %s\n' "${executable}" >"${UNIFIED_LOG_PATH}"
  fi
}

# --- lifecycle ---------------------------------------------------------------

cleanup() {
  # Detaching the image first means the app cannot outlive its own volume.
  if [[ -n "${MOUNT_DIR}" && -d "${MOUNT_DIR}" ]]; then
    "${HDITOOL_BIN}" detach "${MOUNT_DIR}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${MOUNT_ROOT}" && -d "${MOUNT_ROOT}" ]]; then
    rm -rf "${MOUNT_ROOT}"
  fi
  if [[ -n "${APP_EXECUTABLE}" ]]; then
    pkill -x "${APP_EXECUTABLE}" >/dev/null 2>&1 || true
  fi
  return 0
}

# The digest of the published artifact. A directory has none, and printing an
# empty field in release evidence is a claim a reader cannot check, so the
# un-hashable case is spelled out rather than left blank.
artifact_digest() {
  local artifact="$1"
  if [[ -d "${artifact}" ]]; then
    printf 'n/a (an extracted bundle is a directory; the hash of a DMG is the one that matters)'
    return 0
  fi
  sha256_of "${artifact}"
}

main() {
  local artifact="${1:-}"
  if [[ -z "${artifact}" ]]; then
    echo "usage: $(basename "$0") <path-to-dmg-or-app-bundle>" >&2
    exit 2
  fi
  if [[ ! -e "${artifact}" ]]; then
    fail "artifact not found: ${artifact}"
  fi
  print_limitations

  require_tool python3
  require_tool "${HDITOOL_BIN}"
  require_tool "${OPEN_BIN}"
  require_tool "${LSAPPINFO_BIN}"
  require_tool "${SCREENSHOT_BIN}"
  require_tool "${XATTR_BIN}"
  require_tool "${LIPO_BIN}"
  require_tool "${SPCTL_BIN}"
  require_tool "${FIND_BIN}"
  require_tool "${PLIST_BUDDY_BIN}"

  mkdir -p "${EVIDENCE_DIR}"
  SCREENSHOT_PATH="${EVIDENCE_DIR}/${SMOKE_NAME}.png"
  PREFLIGHT_SCREENSHOT_PATH="${EVIDENCE_DIR}/${SMOKE_NAME}-preflight.png"
  CRASH_REPORTS_PATH="${EVIDENCE_DIR}/${SMOKE_NAME}-crash-reports.txt"
  UNIFIED_LOG_PATH="${EVIDENCE_DIR}/${SMOKE_NAME}-log.txt"
  LSAPPINFO_PATH="${EVIDENCE_DIR}/${SMOKE_NAME}-lsappinfo.txt"
  SPCTL_PATH="${EVIDENCE_DIR}/${SMOKE_NAME}-spctl.txt"
  MOUNT_PATH="${EVIDENCE_DIR}/${SMOKE_NAME}-mount.txt"
  SUMMARY_PATH="${EVIDENCE_DIR}/${SMOKE_NAME}-summary.txt"
  OPEN_PATH="${EVIDENCE_DIR}/${SMOKE_NAME}-open.txt"
  : >"${SUMMARY_PATH}"
  : >"${LSAPPINFO_PATH}"
  trap cleanup EXIT

  # Everything above this line is cheap and structural; everything below needs a
  # mounted volume, so the artifact's own shape is settled first.
  if [[ -d "${artifact}" ]]; then
    if [[ "${artifact}" != *.app ]]; then
      fail "${artifact} is a directory but is not a .app bundle; this gate takes the published .dmg, or the extracted .app, and refuses anything else"
    fi
    APP_PATH="${artifact}"
    log "gating an extracted .app bundle directly: ${APP_PATH}"
  else
    if [[ ! -s "${artifact}" ]]; then
      fail "artifact is empty: ${artifact}"
    fi
    assert_dmg_image "${artifact}"
    # MACOS_SMOKE_MOUNT_DIR places the mount point deliberately. It exists so
    # the test suite can keep a whole run inside one directory tree, which is
    # what makes the workspace-relative evidence-path assertions observable: a
    # `mktemp` mount under TMPDIR sits outside GITHUB_WORKSPACE on any runner,
    # so every recorded path would be absolute and the comparability property
    # under test could not be seen at all. Defaults to a private temp directory,
    # which is what a real run wants.
    if [[ -n "${MACOS_SMOKE_MOUNT_DIR:-}" ]]; then
      MOUNT_ROOT="$(mktemp -d "${MACOS_SMOKE_MOUNT_DIR}/macos-smoke-mount.XXXXXX")"
    else
      MOUNT_ROOT="$(mktemp -d)"
    fi
    MOUNT_DIR="${MOUNT_ROOT}/mnt"
    mkdir -p "${MOUNT_DIR}"
    # -nobrowse keeps the image out of the Finder sidebar, -noautoopen stops
    # mount from opening a window that would take focus from the app later, and
    # -noverify skips a checksum we have no reason to doubt. Read-only: the
    # published bytes are not ours to modify.
    if ! "${HDITOOL_BIN}" attach -readonly -nobrowse -noautoopen -noverify \
      -mountpoint "${MOUNT_DIR}" "${artifact}" >"${MOUNT_PATH}" 2>&1; then
      cat "${MOUNT_PATH}" >&2
      fail "the .dmg could not be mounted; an unreadable or corrupted image is a release-blocking packaging failure"
    fi
    log "mounted $(basename "${artifact}") read-only at ${MOUNT_DIR}"
    APP_PATH="$(locate_app_bundle "${MOUNT_DIR}")" ||
      fail "the mounted image does not contain exactly one application bundle at its root"
  fi

  assert_bundle_layout "${APP_PATH}" || fail "the published bundle is missing files it must ship"
  assert_architecture_matches_runner "${APP_PATH}" ||
    fail "the published bundle cannot be executed on this runner"
  assert_published_bundle_not_quarantined "${APP_PATH}" ||
    fail "the published bundle carries a Gatekeeper quarantine attribute"
  record_gatekeeper_assessment "${APP_PATH}"

  # The display harness is proven before the app exists, so a harness problem is
  # never reported as a render problem.
  preflight_display_harness "${PREFLIGHT_SCREENSHOT_PATH}"
  assert_crash_reporting_available ||
    fail "no crash-report directory is available, so a crash check could not run"

  local marker="${EVIDENCE_DIR}/${SMOKE_NAME}-crash-baseline"
  : >"${marker}"

  {
    printf 'artifact: %s\n' "$(evidence_display_path "${artifact}")"
    printf 'artifact sha256: %s\n' "$(artifact_digest "${artifact}")"
    printf 'app bundle: %s\n' "$(basename "${APP_PATH}")"
    printf 'bundle id: %s\n' "${APP_BUNDLE_ID}"
    printf 'executable: %s\n' "${APP_EXECUTABLE}"
    printf 'runner arch: %s\n' "$(normalize_arch "$(uname -m)")"
    printf 'macOS: %s\n' "$(sw_vers -productVersion 2>/dev/null || printf 'unknown')"
  } >"${SUMMARY_PATH}"

  assert_nothing_already_running
  cold_launch

  wait_until "${APP_BUNDLE_ID} to register with the window server" \
    "${LAUNCH_TIMEOUT_SECONDS}" app_is_registered ||
    fail "${APP_BUNDLE_ID} never appeared in the window server after launch (crash on start, or an OS-level refusal)"

  wait_until "${APP_BUNDLE_ID} window" "${LAUNCH_TIMEOUT_SECONDS}" window_is_present ||
    fail "${APP_BUNDLE_ID} is running but never presented a window; window server says: id='${WINDOW_ID}' Visible='${VISIBLE}' Hidden='${HIDDEN}' bounds='${WINDOW_BOUNDS}'"
  log "window present: id='${WINDOW_ID}' Visible='${VISIBLE}' Hidden='${HIDDEN}' bounds='${WINDOW_BOUNDS}' pid='${APP_PID}'"

  if ! await_settled_app_frame; then
    collect_logs
    fail "no settled app frame within ${RENDER_TIMEOUT_SECONDS}s (a blank, splash-only or never-settling window is a failure)"
  fi

  # Re-checked after the render wait: a process that died while painting is
  # invisible to the checks that ran before it.
  window_is_present || fail "${APP_BUNDLE_ID} lost its window while rendering"
  assert_no_crash_reports "${marker}"
  collect_logs

  {
    printf 'result: PASS\n'
    printf 'final window id: %s\n' "${WINDOW_ID}"
    printf 'final bounds: %s\n' "${WINDOW_BOUNDS}"
    printf 'final pid: %s\n' "${APP_PID}"
    printf 'screenshot: %s\n' "$(evidence_display_path "${SCREENSHOT_PATH}")"
    printf 'preflight screenshot: %s\n' "$(evidence_display_path "${PREFLIGHT_SCREENSHOT_PATH}")"
    printf 'gatekeeper: see %s\n' "$(evidence_display_path "${SPCTL_PATH}")"
  } >>"${SUMMARY_PATH}"

  log "PASS: the published .dmg mounted, and the bundled app cold-launched and rendered on this macOS runner"
  log "evidence: ${SUMMARY_PATH}, ${SCREENSHOT_PATH}, ${PREFLIGHT_SCREENSHOT_PATH}, ${CRASH_REPORTS_PATH}, ${UNIFIED_LOG_PATH}, ${LSAPPINFO_PATH}, ${SPCTL_PATH}, ${OPEN_PATH}"
}

main "$@"
