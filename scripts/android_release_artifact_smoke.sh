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
#     a blank frame. The gate therefore decodes the screenshot and requires a
#     frame that is visually complex AND byte-identical across two consecutive
#     captures, which rejects a blank screen, a screen mid-transition, and a
#     screen that never settles.
#
#   * LIMITATION, stated rather than papered over: on API 31+ the system splash
#     screen is drawn *inside the app's own window*, so it is focused, and a
#     launcher icon on a background is far above the colour threshold. A splash is
#     also perfectly stable, so the two-consecutive-capture check does not
#     exclude it either. This gate therefore cannot prove the pixels came from
#     the app's own UI rather than from the launch theme. Excluding it needs a
#     Flutter-owned surface identified via `dumpsys SurfaceFlinger --list`, or
#     the semantics tree via `uiautomator`, which needs an accessibility service
#     and is therefore unavailable in CI. A colour threshold loose enough to
#     catch the splash would be wrong in the lenient direction, which is the same
#     false pass the gate exists to prevent, so the limitation is recorded
#     instead of guessed at.
#
#   * The smoke matrix runs x86_64 system images only, because there is no free
#     hosted arm64 emulator. The emulator can therefore only ever prove the
#     x86_64 slice of the APK. Native ABIs are checked structurally from the
#     archive before the device is touched, because an APK carrying only the
#     emulator's ABI installs perfectly on the runner and fails on every real
#     phone.
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

# Native ABIs the release APK must carry, so it installs on real hardware.
#
# arm64-v8a is every current phone; armeabi-v7a is the 32-bit ABI Android still
# requires a build to support down to API 24 (minSdk here), and it is the one most
# likely to be dropped by an over-eager cross-compile change, because 64-bit-only
# builds are the norm. x86_64 is in the list only because the smoke matrix runs
# x86_64 images -- it is not a shipping target, and its presence here is not
# evidence that it works.
#
# Overridable so the structural test can exercise the failure path without
# building a real multi-ABI APK, and so a platform that genuinely drops an ABI can
# say so in one place instead of by deleting the assertion.
#
# Read as a space-separated string and split deliberately, so the whole default
# arrives as a single argument (quoting the default inside the `:-` would make it
# one ABI literally named "arm64-v8a armeabi-v7a"). The split is on whitespace via
# an unquoted expansion, which is the one place in this script where that is the
# intended behaviour.
read -r -a REQUIRED_ABIS <<<"${ANDROID_SMOKE_REQUIRED_ABIS:-arm64-v8a armeabi-v7a}"
if ((${#REQUIRED_ABIS[@]} == 0)); then
  echo "ERROR: ANDROID_SMOKE_REQUIRED_ABIS is set but empty; refusing to check no ABIs at all" >&2
  exit 2
fi

# The per-ABI library whose presence proves the ABI slice was really packaged.
#
# This used to be a claim about the Rust daemon: "the daemon ships native code,
# so an APK with no lib/ entries means the cross-compile produced nothing". That
# rationale is false. What is actually true of the `cargo ndk` step, measured
# rather than assumed:
#
#   * `native_core/Cargo.toml` declares no `crate-type`, so `galleryd` builds as
#     a bin and `native_core` as an rlib. Neither is a cdylib, and `cargo ndk`
#     copies only artifacts whose `crate_types` contain `cdylib` (cargo-ndk's
#     `artifact_is_cdylib`), so it drops both and no daemon is packaged. Nothing
#     in app/lib or app/android calls `loadLibrary`, `DynamicLibrary` or
#     `System.loadLibrary`, so nothing looks for one either. That is #140.
#   * The step is NOT a no-op. `iroh` and `iroh-relay` both declare
#     `crate-type = ["lib", "cdylib"]`, so cargo emits `libiroh.so` and
#     `libiroh_relay.so` for each target ABI and cargo-ndk copies them into
#     jniLibs. They are also what keeps the step from failing: cargo-ndk exits
#     non-zero with "No usable artifacts produced by cargo" when a target has no
#     cdylib at all, so if iroh ever dropped its cdylib the release build would
#     break loudly instead of quietly packaging nothing.
#
# `libflutter.so` is the witness on purpose, not because the Rust `.so`s are
# absent:
#   * it proves the property this gate exists for -- the APK carries a native ABI
#     slice for every required ABI, which is what INSTALL_FAILED_NO_MATCHING_ABIS
#     turns on;
#   * a dependency's `.so` (e.g. `libiroh.so`) would be governed by an upstream
#     crate's `crate-type`, so the release gate would fail for a reason outside
#     this repo's packaging;
#   * once #140 decides between a thin paired client and an on-device cdylib
#     daemon, the correct Rust witness changes, and that is a product decision
#     this gate must not pre-empt.
#
# `libflutter.so` is the engine, and every Flutter Android build packages it once
# per target ABI in debug and release alike, so it is a truthful witness for "this
# APK carries an arm slice". Nothing here may assert a library the APK does not
# contain.
#
# Evidence, and its limits. Measured on this host:
#
#   * `cargo metadata --manifest-path native_core/Cargo.toml` lists this package's
#     targets as `native_core` at `crate_types: ["lib"]` and `galleryd` at
#     `["bin"]` -- neither declares `crate-type`. (`crate_types` is per *target*,
#     under `.targets[]`; a dependency package has no top-level `crate_types` key,
#     so reading one is how a count of the graph goes wrong. Counting `[[lib]]`
#     sections in the registry manifests gives exactly four: `iroh`,
#     `iroh-relay`, `wasm-streams` and `ws_stream_wasm`. `rusqlite` also spells
#     `crate-type = ["cdylib"]`, but on an `[[example]]` rather than its lib
#     target, so cargo does not build it. The two wasm crates sit behind
#     `cfg(target_arch = "wasm32")` /
#     `cfg(all(target_family = "wasm", target_os = "unknown"))`, so cargo never
#     builds them for an Android target -- which leaves `iroh` and `iroh-relay`
#     as the two that are built.)
#   * A throwaway crate outside this repo, depending on `iroh = "=0.98.2"` with
#     its own `[[bin]]` and `src/lib.rs`, built with
#     `cargo build --message-format=json`: `galleryd_probe` came back at
#     `["bin"]` and `cdylib_probe` at `["lib"]`, neither with any `.so`.
#     `iroh` and `iroh_relay` came back at `["lib","cdylib"]` each, and cargo's
#     `filenames` for them listed an `.rlib` *and* a `.so` that exists on disk
#     as a real ELF shared object. 28 `.so` files were written in total: those
#     two, plus 26 `proc-macro` crates, which are a different `crate_type` and
#     host-only, so cargo-ndk's filter skips them.
#   * cargo-ndk 4.1.2 collects every `compiler-artifact` message (no package
#     filter), keeps the ones whose `target.crate_types` contains `CDyLib`
#     (`artifact_is_cdylib`), and copies the `.so` to
#     `<output>/<arch>/<file_name()>` verbatim. So the Rust `.so`s land in
#     `app/android/app/src/main/jniLibs/<arch>/` -- and their names keep cargo's
#     metadata hash (`libiroh-<hash>.so`), which is itself a reason no gate can
#     assert one by a stable name.
#
# What was NOT verified: this host has no NDK, no Flutter toolchain and no
# signing material, so the cross-compiled Android artifacts were never produced
# and no real signed APK was ever unzipped. `libiroh.so` being packaged is
# therefore established from cargo's own artifact emission plus cargo-ndk's copy
# code, NOT from inspecting an archive. The fixture tests below prove the *check*
# discriminates; they say nothing about what a real APK ships. cargo-ndk is
# installed unpinned (`cargo install cargo-ndk --locked`), so the copy logic
# quoted above was read from 4.1.2, the version cached locally, and could differ
# on a future release build.
#
# Asserted by name rather than as "the lib/<abi>/ directory exists": a directory
# holding one stray file is not a shipped native library, and a prefix match on
# the directory accepts one.
REQUIRED_NATIVE_LIB="libflutter.so"

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

# Runs a command on the device and prints its stdout.
#
# The exit status is propagated, deliberately. This used to end in `|| true`, which
# made a dead adb server indistinguishable from a device that had nothing to
# report: `dumpsys` returned empty, the adverse-exit count came out as 0, and the
# crash buffer came back empty. Both of those are the two gates that must never
# fail open, and both reported "clean" without ever having been asked. Every caller
# that is a gate now distinguishes "the device said there is nothing wrong" from
# "the question could not be delivered". Callers that genuinely do not care
# opt out explicitly at the call site.
adb_shell() {
  "${ADB}" shell "$@" 2>/dev/null
}

# `dumpsys activity exit-info` only exists on API 30+. On an older system image the
# service does not exist, so the check has to be skipped -- but the *decision* must
# come from a dedicated capability probe, never from text found inside the dump.
#
# This used to substring-match the whole dump for `not found` / `Unknown command` /
# `Can't find service` / `No service`. That is unsound, and dangerously so: an
# `ApplicationExitInfo` record carries a free-text `description=` field holding the
# crash or ANR message verbatim, and this app's daemon resolves paths and opens its
# index, so strings like "...: /data/gallery.db not found" are ordinary. One such
# adverse record therefore reported "exit-info unavailable on this API level",
# disabled the crash check and returned clean -- a crash shipping green, which is
# the exact failure class this gate exists to prevent. It was reachable with a
# real ANR and a real native SIGSEGV; the regression test names both.
#
# So the probe is now: read the API level, and treat the feature as absent only
# when the platform genuinely predates it. The error-shape strings are still
# recognised, but only against a reply that is not a plausible dumpsys output --
# see exit_info_looks_like_dumpsys, which is what stops a crash description from
# being read as a complaint from the service.

# Does this dump contain at least one ApplicationExitInfo record?
exit_info_has_records() {
  local dump="$1"
  contains "ApplicationExitInfo" "${dump}" || contains "reason=" "${dump}"
}

# Does this look like a genuine `dumpsys activity exit-info` reply, rather than an
# error from the service or a read that returned nothing?
#
# A freshly installed app that is still running has never been recorded as having
# exited, so the real, healthy reply on API 30+ is the dumpsys section header with
# zero `ApplicationExitInfo` blocks under it. Requiring a record here would fail
# every honest first run, so the header counts as a real reply. What must never
# count is a dump that merely contains an error string somewhere inside a record.
#
# The header is matched at the start of a line, case-insensitively, because its
# spelling is not stable across API levels. On 2026-10-04 the release run failed on
# API 30 and API 35 with a real, healthy reply that this function rejected:
#
#   ACTIVITY MANAGER PROCESS EXIT INFO (dumpsys activity exit-info)
#   Last Timestamp of Persistence Into Persistent Storage: 1970-01-01 00:00:00.000
#
# It knew only the older `ACTIVITY MANAGER LRU PROCESSES` and
# `Historical Process Exit`, so the gate reported "ApplicationExitInfo returned
# output that is not a dumpsys exit-info reply" after the app had installed,
# launched, rendered a stable 33-colour frame and left a clean crash buffer. The
# unit fixture used the header the gate already knew, so the suite and the gate
# agreed with each other and both disagreed with the device -- the standard
# consequence of writing a fixture from the implementation instead of from a real
# capture. The fixture is now the capture, verbatim, and the legacy spellings are
# kept as their own cases so this cannot become "only accept the new header".
#
# Still fail-closed: matching is anchored to the start of a line, so a complaint
# quoted *inside* a record cannot satisfy it, and `exit_info_unsupported` still
# rejects a dump carrying "Unknown command"/"Can't find service"/"No service".
exit_info_has_section_header() {
  local dump="$1" line lowered
  while IFS= read -r line; do
    lowered="$(trim "${line}")"
    lowered="${lowered,,}"
    case "${lowered}" in
      "activity manager process exit info"* | \
        "activity manager lru processes"* | \
        "historical process exit"*)
        return 0
        ;;
    esac
  done <<<"${dump}"
  return 1
}

exit_info_looks_like_dumpsys() {
  local dump="$1"
  exit_info_has_records "${dump}" || exit_info_has_section_header "${dump}"
}

# Does the service itself complain? Only meaningful for a reply that is not already
# a plausible dumpsys output.
exit_info_unsupported() {
  local dump="$1"
  exit_info_looks_like_dumpsys "${dump}" && return 1
  contains "Unknown command" "${dump}" ||
    contains "Can't find service" "${dump}" ||
    contains "No service" "${dump}"
}

# Is `dumpsys activity exit-info` available on this device at all?
#
# This is a positive, dedicated probe. It must not fall back to a default that
# enables or disables the check: an unreadable API level means we do not know
# whether the feature exists, and guessing is how a check silently switches off.
exit_info_supported() {
  local level
  level="$(adb_shell getprop ro.build.version.sdk)" || return 2
  level="$(trim "${level}")"
  if [[ ! "${level}" =~ ^[0-9]+$ ]]; then
    return 2
  fi
  ((level >= 30))
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

# Is a logcat *crash buffer* free of actual crashes?
#
# Not the same question as "is it blank". `adb logcat -b crash -d` can print a
# buffer header ("--------- beginning of crash") even when the buffer holds no
# entries, and whether it does varies between platform versions. A header is not
# a crash: treating it as one would fail every release, which is exactly the kind
# of false positive that trains people to ignore a red build. Real content --
# a Java "FATAL EXCEPTION" or a native tombstone -- is still a failure, including
# a SIGSEGV in the Rust galleryd daemon, which never appears as a Java exception.
crash_buffer_is_clean() {
  local line
  while IFS= read -r line; do
    line="$(trim "${line}")"
    [[ -z "${line}" ]] && continue
    [[ "${line}" == *"beginning of "* ]] && continue
    return 1
  done <<<"${1:-}"
  return 0
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
  # A failed `dumpsys` is not an unfocused window, it is an unanswered question.
  # Returning non-zero here makes the focus check fail closed, which is the
  # direction that errs; the launch gate reports the timeout and the real cause
  # stays visible in the adb output.
  dump="$(adb_shell dumpsys window)" || return 1
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

# Writes the run summary that is uploaded as release evidence. This is
# informational rather than a gate, so an unreadable property does not fail the
# run -- but a silently empty field in published evidence is exactly the kind of
# claim a reader cannot check, so each one is annotated when it cannot be read.
# One policy for paths in evidence. User-downloaded sidecars (the checksum)
# record bare filenames, because they must verify outside the runner. The
# run-internal summary records paths relative to the workspace root when they
# lie inside it, and absolute otherwise: absolute runner paths (e.g.
# /home/runner/work/...) differ on every machine and make evidence
# incomparable across runs, while relative paths stay stable. Paths are never
# secrets, so this is about comparability, not redaction.
evidence_display_path() {
  local path="$1" workspace="${GITHUB_WORKSPACE:-}"
  if [[ -n "${workspace}" && "${path}" == "${workspace}/"* ]]; then
    printf '%s\n' "${path#"${workspace}/"}"
  else
    printf '%s\n' "${path}"
  fi
}

record_installed_version() {
  local apk="$1" dump version_name version_code abi api release
  dump="$(adb_shell dumpsys package "${PACKAGE}")" || dump=""
  version_name="$(first_line "$(printf '%s' "${dump}" | sed -n 's/.*versionName=\([^ ]*\).*/\1/p')")"
  version_code="$(first_line "$(printf '%s' "${dump}" | sed -n 's/.*versionCode=\([^ ]*\).*/\1/p')")"
  abi="$(device_property ro.product.cpu.abi || printf 'unknown')"
  api="$(device_property ro.build.version.sdk || printf 'unknown')"
  release="$(device_property ro.build.version.release || printf 'unknown')"
  {
    printf 'package: %s\n' "${PACKAGE}"
    printf 'apk: %s\n' "$(evidence_display_path "${apk}")"
    printf 'apk sha256: %s\n' "$(sha256_of "${apk}")"
    printf 'device: API %s (Android %s), abi %s\n' "${api}" "${release}" "${abi}"
    printf 'installed versionName: %s\n' "${version_name:-unknown}"
    printf 'installed versionCode: %s\n' "${version_code:-unknown}"
  } >"${SUMMARY_PATH}"
  cat "${SUMMARY_PATH}"
}

# Reads a `getprop` value, printing "unknown" and annotating if adb could not
# answer. Used only for evidence, never for a gate decision.
device_property() {
  local value
  value="$(adb_shell getprop "$1")" || value=""
  value="$(trim "${value}")"
  if [[ -z "${value}" ]]; then
    printf '::warning::could not read device property %s; recorded as unknown in the evidence\n' "$1" >&2
    printf 'unknown'
    return 0
  fi
  printf '%s' "${value}"
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

# Prints the number of adverse ApplicationExitInfo entries recorded *before* the
# launch, or the literal string "unavailable" when the device could not be asked.
# The two are not interchangeable: an unavailable baseline must not be read as
# zero, or the post-launch comparison silently degrades into "no adverse exits"
# for a device that never answered in the first place.
capture_crash_baseline() {
  local dump rc=0
  dump="$(adb_shell dumpsys activity exit-info "${PACKAGE}")" || rc=$?
  printf '%s' "${dump}" >"${EXIT_INFO_PATH}"
  if ((rc != 0)); then
    return 1
  fi
  if is_blank "${dump}" || exit_info_unsupported "${dump}"; then
    printf '%s' "unavailable"
    return 0
  fi
  adverse_exit_reason_count "${dump}"
}

adverse_exit_reason_count() {
  local dump="$1" line count=0 reason candidate
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
  local baseline="$1" dump after rc=0
  dump="$(adb_shell dumpsys activity exit-info "${PACKAGE}")" || rc=$?
  printf '%s\n' "${dump}" >"${EXIT_INFO_PATH}"
  if ((rc != 0)); then
    # The dump could not be read. Counting adverse exits in an empty string yields
    # zero, and zero would read as "clean" -- so refuse instead. A crash check that
    # could not run is not a passing crash check.
    fail "could not read ApplicationExitInfo (adb exit ${rc}); refusing to report a crash check that never ran"
  fi
  if is_blank "${dump}"; then
    # A blank read on a device that has exit-info is not a clean device. `adb_shell`
    # drops stderr, so a failure the device reported on stderr while still exiting 0
    # is indistinguishable here from a device that answered nothing. Neither is
    # evidence of no crash, and this branch is the only one that used to degrade
    # with no annotation at all. Refuse instead, unless the platform genuinely
    # predates the feature -- which is a positive fact we can establish, not infer.
    local support_rc=0
    exit_info_supported || support_rc=$?
    if ((support_rc == 1)); then
      printf '::warning::API level is below 30, so ApplicationExitInfo does not exist; relying on the crash buffer alone\n' >&2
      log "exit-info unavailable on this API level; relying on the crash buffer"
      return 0
    fi
    if ((support_rc == 2)); then
      fail "could not read the device API level, so it cannot be established whether ApplicationExitInfo exists; refusing to report a crash check that never ran"
    fi
    fail "ApplicationExitInfo returned nothing on a device whose API level supports it; this is a failed read, not a clean result"
  fi
  if exit_info_unsupported "${dump}"; then
    # Reached only for a dump with no records in it, so the complaint really is
    # about the service. Still confirmed against the platform rather than trusted.
    local unsupported_rc=0
    exit_info_supported || unsupported_rc=$?
    if ((unsupported_rc == 1)); then
      printf '::warning::API level is below 30, so ApplicationExitInfo does not exist; relying on the crash buffer alone\n' >&2
      log "exit-info unavailable on this API level; relying on the crash buffer"
      return 0
    fi
    if ((unsupported_rc == 2)); then
      fail "could not read the device API level, so it cannot be established whether ApplicationExitInfo exists; refusing to report a crash check that never ran"
    fi
    fail "dumpsys activity exit-info reported no records and no service on an API level that supports it; refusing to report a crash check that never ran"
  fi
  if ! exit_info_looks_like_dumpsys "${dump}"; then
    # Non-blank, not a service complaint, and not recognisable as dumpsys output.
    # There is no reading of this that is safe to call clean, so refuse rather than
    # counting zero adverse entries in something that was never a dump.
    printf '%s\n' "${dump}" >&2
    fail "ApplicationExitInfo returned output that is not a dumpsys exit-info reply; refusing to report a crash check that never ran"
  fi
  after="$(adverse_exit_reason_count "${dump}")"
  if [[ "${baseline}" == "unavailable" ]]; then
    # No usable pre-launch baseline, so the comparison cannot be made and the
    # stronger of the two readings applies: zero adverse entries, outright. This is
    # strictly harder to satisfy than "no worse than before", never easier.
    if ((after > 0)); then
      printf '%s\n' "${dump}" >&2
      fail "adverse ApplicationExitInfo entries: ${after} recorded, with no pre-launch baseline to attribute them to"
    fi
    log "exit-info clean (${after} adverse entries, no baseline available so zero is required)"
    return 0
  fi
  if ((after > baseline)); then
    printf '%s\n' "Android recorded an abnormal exit of ${PACKAGE} (crash, native crash, ANR, or init failure):" >&2
    printf '%s\n' "${dump}" >&2
    fail "adverse ApplicationExitInfo entries: ${baseline} before launch, ${after} after"
  fi
  log "exit-info clean (${after} adverse entries, same as pre-launch baseline)"
}

assert_crash_buffer_clean() {
  local crash rc=0
  crash="$("${ADB}" logcat -b crash -d 2>/dev/null)" || rc=$?
  printf '%s\n' "${crash}" >"${CRASH_BUFFER_PATH}"
  if ((rc != 0)); then
    # Same reasoning as above, and this is the primary crash gate: `logcat -b crash`
    # works on every API level the matrix covers, so a non-zero exit means the
    # buffer could not be read, not that the feature is missing. Reporting "clean"
    # here would be reporting the absence of a question.
    fail "could not read the Android crash buffer (adb exit ${rc}); refusing to report a crash check that never ran"
  fi
  if ! crash_buffer_is_clean "${crash}"; then
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

# Wait for a settled, app-owned frame.
#
# What this actually proves, precisely -- the distinction matters because the
# previous version of this check claimed more than it could deliver.
#
# It requires THREE independent things:
#   1. the app's window still holds focus *at the moment of capture*, not merely
#      at some earlier point (a permission dialog can steal focus mid-wait);
#   2. the frame is visually complex (>= MIN_DISTINCT_COLOURS), which rules out a
#      solid-colour blank screen and an undecodable capture;
#   3. the frame is *stable* -- two consecutive captures agree -- which rules out
#      a screen caught mid-transition while the engine is still starting.
#
# What it does NOT prove, and must not be claimed: that the pixels came from the
# app's own UI rather than from the system splash screen. On API 31+ the splash
# is drawn *inside* the app's own window by the SplashScreen API, so it satisfies
# all three conditions above while the app has rendered nothing of its own. A
# splash screen is also a stable image, so condition 3 does not exclude it.
#
# Distinguishing the two needs a signal that only app content produces -- a
# Flutter-owned surface from `dumpsys SurfaceFlinger --list`, or the semantics
# tree, which needs an accessibility service and so is unavailable here. Tracked
# as a follow-up rather than guessed at, because a heuristic colour or layout
# threshold that is wrong in the *lenient* direction reintroduces exactly the
# false pass this gate exists to prevent. See docs/public-production-release-runbook.md.
#
# The check is deliberately biased against false PASSES rather than against false
# failures: it can only make the release block, never let a broken artifact ship.
# Requiring stability is what makes it safe to bias that way.
await_settled_app_frame() {
  local deadline=$((SECONDS + RENDER_TIMEOUT_SECONDS)) colors=-1
  local previous="" current="" stable_captures=0
  local last_focus_error=""

  while ((SECONDS < deadline)); do
    # Re-assert focus inside the loop. Checking it only before this loop let a
    # dialog that appeared afterwards satisfy the gate.
    if ! is_app_focused; then
      last_focus_error="$(focused_window)"
      log "lost window focus while waiting for a frame; focused window is now: ${last_focus_error}"
      previous=""
      stable_captures=0
      sleep "${POLL_INTERVAL_SECONDS}"
      continue
    fi

    if capture_screenshot "${SCREENSHOT_PATH}"; then
      if colors="$(png_distinct_colors "${SCREENSHOT_PATH}" "${MIN_DISTINCT_COLORS}" 2>/dev/null)"; then
        if [[ "${colors}" =~ ^[0-9]+$ ]] && ((colors >= MIN_DISTINCT_COLORS)); then
          # sha256_of, not a bare sha256sum: on a host without GNU coreutils a bare
          # call yields an empty digest every iteration, so `stable_captures` never
          # advances and the gate burns its whole budget reporting a misleading
          # "no settled app frame" verdict about a perfectly good frame.
          current="$(sha256_of "${SCREENSHOT_PATH}")"
          if [[ -n "${current}" && "${current}" == "${previous}" ]]; then
            stable_captures=$((stable_captures + 1))
          else
            stable_captures=0
          fi
          if ((stable_captures >= 1)); then
            log "settled app frame: ${colors}+ distinct colours, identical across two consecutive captures"
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
    fi
    sleep "${POLL_INTERVAL_SECONDS}"
  done

  if [[ -n "${last_focus_error}" ]]; then
    fail "lost window focus while waiting for a settled frame; focused window was: ${last_focus_error}"
  fi
  return 1
}

assert_native_abis_present() {
  local apk="$1" abi
  # The smoke matrix runs on x86_64 emulator images only -- there is no free
  # hosted arm64 emulator -- so the emulator can only ever prove the x86_64 slice
  # of the APK. An APK carrying only x86_64 libraries installs perfectly on that
  # image and fails on every real phone, which is the exact class of bug this gate
  # exists to catch. The native half therefore has to be checked structurally,
  # from the archive itself, or it is not checked at all.
  #
  # The APK is a zip. `unzip -Z1` lists the archive without extracting it, so this
  # costs nothing on a device-free runner.
  #
  # Every way this check can fail to run is a hard failure, not a warning. That is
  # the deliberate difference from a degraded test suite: here the check is the
  # *only* thing standing between the release and an APK that installs on the CI
  # emulator and fails on every real phone, and nothing downstream re-asserts it --
  # an APK with no native libraries at all installs on the x86_64 image with no ABI
  # mismatch, launches and renders, so a skipped check is a green release. An
  # absent tool, an unreadable archive, or an APK with no lib/ entries are all
  # states in which "cannot prove the arm slices are present" is the honest answer,
  # and the honest answer is not a pass.
  if ! command -v unzip >/dev/null 2>&1; then
    printf '::error::unzip is not available, so the APK native ABIs cannot be verified. The emulator matrix only runs x86_64 images, so this check is the only thing covering the real device ABIs.\n' >&2
    return 1
  fi
  local entries
  if ! entries="$(unzip -Z1 "${apk}" 2>&1)"; then
    printf '::error::could not list the APK archive, so its native ABIs cannot be verified: %s\n' "$(trim "${entries}")" >&2
    return 1
  fi
  # Flutter packages native libraries per ABI, so an APK with no lib/ entries at
  # all means the native packaging produced nothing -- a regression that a
  # Java-only build would pass silently and that the emulator cannot detect.
  # There is no opt-in: if a future build genuinely has no native code, the
  # REQUIRED_ABIS list is the thing to change, not this verdict.
  if ! grep -q '^lib/' <<<"${entries}"; then
    printf '::error::the APK contains no lib/ entries at all. Flutter Android builds package native libraries per ABI (e.g. libflutter.so); no lib/ entries mean the APK is missing the engine slices, a packaging regression the x86_64 emulator cannot detect because it would only expose a mismatch for the wrong ABI set.\n' >&2
    return 1
  fi
  for abi in "${REQUIRED_ABIS[@]}"; do
    # -F and -x, not a regex. `${REQUIRED_NATIVE_LIB}` contains a literal dot, and
    # a plain `grep -q "^lib/<abi>/libflutter.so$"` treats that dot as "any
    # character" -- so `lib/<abi>/libflutterXso` satisfied it. That is an
    # assertion satisfied for the wrong reason: the archive would be reported as
    # carrying the Flutter engine while carrying a different file. -x requires the
    # whole line and -F makes the pattern literal, so only the exact entry passes.
    local lib_entry="lib/${abi}/${REQUIRED_NATIVE_LIB}"
    if grep -qFx "${lib_entry}" <<<"${entries}"; then
      log "native library present: lib/${abi}/${REQUIRED_NATIVE_LIB}"
    else
      printf '::error::the APK contains no lib/%s/%s. The emulator matrix only runs x86_64 images, so this cannot be caught by installing it: on a real arm device the install would fail with INSTALL_FAILED_NO_MATCHING_ABIS if the required ABI slice is missing. This checks the Flutter engine artifact shipped with the app, not a custom daemon.\n' "${abi}" "${REQUIRED_NATIVE_LIB}" >&2
      fail "the APK is missing ${REQUIRED_NATIVE_LIB} for ${abi}"
    fi
  done
}

main() {
  local apk="${1:-}" baseline
  if [[ -z "${apk}" ]]; then
    echo "usage: $(basename "$0") <path-to-apk>" >&2
    exit 2
  fi
  [[ -f "${apk}" ]] || fail "APK not found: ${apk}"
  [[ -s "${apk}" ]] || fail "APK is empty: ${apk}"

  # Before the device is touched, so a packaging regression is reported as
  # "wrong ABIs" rather than as a mysterious install failure twenty minutes
  # after the emulator boots.
  assert_native_abis_present "${apk}"

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

  if ! baseline="$(capture_crash_baseline)"; then
    # The pre-launch read failed. Recording it as "unavailable" keeps the gate
    # running with the stronger requirement (zero adverse entries outright) rather
    # than dropping the check. Emitted as a workflow annotation rather than through
    # `log`, which prefixes the smoke name and would stop GitHub from parsing it.
    printf '::warning::could not read ApplicationExitInfo before launch; requiring zero adverse entries after launch instead of a comparison\n'
    printf 'pre-launch ApplicationExitInfo: unavailable (adb failed)\n' >>"${SUMMARY_PATH}"
    baseline="unavailable"
  fi
  clear_log_buffers
  cold_launch

  wait_until "${PACKAGE} process" "${LAUNCH_TIMEOUT_SECONDS}" is_app_running ||
    fail "${PACKAGE} is not running after launch (crash on start)"
  log "process alive: pid $(app_pid)"

  wait_until "${PACKAGE} window focus" "${LAUNCH_TIMEOUT_SECONDS}" is_app_focused ||
    fail "${PACKAGE} never took window focus; focused window was: $(focused_window)"
  log "window focused: $(focused_window)"

  if ! await_settled_app_frame; then
    collect_logs
    fail "no settled app frame within ${RENDER_TIMEOUT_SECONDS}s (a blank, launch-theme-only or never-settling screen is a failure)"
  fi

  is_app_running || fail "${PACKAGE} died while rendering"
  assert_crash_buffer_clean
  assert_no_adverse_exits "${baseline}"
  collect_logs

  {
    printf 'result: PASS\n'
    printf 'focused window: %s\n' "$(focused_window)"
    printf 'final pid: %s\n' "$(app_pid)"
    printf 'screenshot: %s\n' "$(evidence_display_path "${SCREENSHOT_PATH}")"
  } >>"${SUMMARY_PATH}"

  log "PASS: the release artifact installed, cold-launched and rendered on Android $(device_property ro.build.version.release) (API $(device_property ro.build.version.sdk))"
  log "evidence: ${SUMMARY_PATH}, ${SCREENSHOT_PATH}, ${CRASH_BUFFER_PATH}, ${EXIT_INFO_PATH}, ${LOGCAT_PATH}"
}

main "$@"
