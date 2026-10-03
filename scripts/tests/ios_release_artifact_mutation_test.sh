#!/usr/bin/env bash
#
# Mutation pass for the assertions in
# scripts/tests/ios_release_artifact_smoke_test.sh, which test
# scripts/ios_release_artifact_smoke.sh.
#
# A green suite is worth very little on its own here. Almost every assertion in
# the suite is satisfied by the gate printing a particular string, and a check
# that has been reduced to "the gate says the magic words" reads exactly like a
# check. So each mutation below breaks ONE line of the gate and requires a
# SPECIFIC named assertion to go red.
#
# "The suite exited non-zero" is not a result. A specific assertion going red is.
# Four guards exist because each of the following failure modes was reachable:
#
#   * `preflight` rejects a mutation that leaves the gate unparseable. Such a
#     mutation measures nothing and reads as a legitimate red.
#   * `apply` requires the anchor to occur exactly once and then reads the file
#     back to confirm the replacement landed. Writing a file is not evidence that
#     the file says what was intended.
#   * `needle_matches` requires the NAMED assertion to have gone red. A red suite
#     with some other assertion red is a false pass wearing a failure's clothes.
#     A mutation that is recorded as biting because the suite happened to be red
#     is worthless, so an assertion that is red for an unrelated reason is
#     reported as NOT BITING rather than counted.
#   * `grep -c` rather than `grep -q` in `needle_matches`, deliberately: `grep -q`
#     exits on its first match, SIGPIPEs the upstream `grep -v`, and under
#     `set -o pipefail` that turns a successful match into a non-zero pipeline
#     depending on whether the writer finished first. It is a race.
#
# A mutation that fails to apply is reported as a FAILURE of this harness, never
# as a pass. An unapplied mutation is the easiest way to manufacture a green
# mutation report.
#
# Everything runs on Linux. The gate's simulator-driving code cannot execute
# here, so it is exercised through the same injectable seam the suite uses: a
# fake `xcrun` and a fake backend probe, wired in by environment variable. That
# means a mutation here is a mutation of real gate source, and a red assertion is
# a real consequence of the mutation -- but it is NOT evidence about a real
# simulator. See the "Honest gaps" section of the report.
set -uo pipefail

SOURCE_ROOT="${PO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# --- sharding ---------------------------------------------------------------
#
# A full pass runs the whole suite once per mutation, which is minutes each; the
# complete set is hours. `MUTATION_SHARDS=N MUTATION_SHARD=i` runs only the
# mutations where `index % N == i`, so the set can be split across parallel CI
# jobs. Default: one shard containing everything.
SHARDS="${MUTATION_SHARDS:-1}"
SHARD="${MUTATION_SHARD:-0}"
if [[ ! "${SHARDS}" =~ ^[1-9][0-9]*$ ]]; then
  printf 'FATAL: MUTATION_SHARDS must be a positive integer; got %q\n' "${SHARDS}" >&2
  exit 2
fi
if [[ ! "${SHARD}" =~ ^[0-9]+$ ]] || ((SHARD >= SHARDS)); then
  printf 'FATAL: MUTATION_SHARD must be 0..%s; got %q\n' "$((SHARDS - 1))" "${SHARD}" >&2
  exit 2
fi

WORK="$(mktemp -d)"
cleanup() {
  rm -rf "${WORK}"
}
trap cleanup EXIT

# The whole `scripts/` tree is COPIED and mutated in place.
#
# Two reasons, both load-bearing. First, the suite derives its own root from its
# location (`dirname "${BASH_SOURCE[0]}"/../..`), not from an environment
# variable, so a mutated checker next to an unmutated tree would not be the pair
# under test. Second, mutating a copy means a shard can run for hours without
# ever leaving the developer's worktree dirty -- and shards can run concurrently,
# which they cannot if they all rewrite one file.
mkdir -p "${WORK}/tree"
cp -R "${SOURCE_ROOT}/scripts" "${WORK}/tree/scripts"

ROOT_DIR="${WORK}/tree"
SUITE="${ROOT_DIR}/scripts/tests/ios_release_artifact_smoke_test.sh"
GATE="${ROOT_DIR}/scripts/ios_release_artifact_smoke.sh"

for required in "${SUITE}" "${GATE}"; do
  if [[ ! -f "${required}" ]]; then
    printf 'FATAL: %s does not exist\n' "${required}" >&2
    exit 2
  fi
done

cp "${GATE}" "${WORK}/gate.orig"

restore() {
  cp "${WORK}/gate.orig" "${GATE}"
}

# apply <file> <old> <new>
# Requires the anchor to occur EXACTLY once. A zero-occurrence anchor is a
# harness bug (exit 3); a multi-occurrence anchor is a harness bug too (exit 4),
# because the replacement would land somewhere unintended and the red assertion
# would prove nothing about the intended line.
apply() {
  python3 - "$1" "$2" "$3" <<'PYTHON'
import sys

path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, encoding="utf-8") as handle:
    text = handle.read()
count = text.count(old)
if count == 0:
    print(f"ANCHOR NOT FOUND: {old[:100]!r}", file=sys.stderr)
    sys.exit(3)
if count > 1:
    print(f"ANCHOR IS NOT UNIQUE ({count} occurrences): {old[:100]!r}", file=sys.stderr)
    sys.exit(4)
with open(path, "w", encoding="utf-8") as handle:
    handle.write(text.replace(old, new, 1))
# Read the file back. Writing a file is not evidence that the file contains the
# intended text.
with open(path, encoding="utf-8") as handle:
    after = handle.read()
if new and new not in after:
    print("MUTATION DID NOT LAND: replacement text absent", file=sys.stderr)
    sys.exit(5)
if old and old in after and old not in new:
    print("MUTATION DID NOT LAND: original text still present", file=sys.stderr)
    sys.exit(6)
print(text[: text.index(old)].count("\n") + 1)
PYTHON
}

# preflight <file> -- refuse a mutation that leaves the gate unparseable.
preflight() {
  local out
  if ! out="$(bash -n "$1" 2>&1)"; then
    printf 'the gate no longer parses: %s\n' "${out}" >&2
    return 1
  fi
  return 0
}

# needle_matches <log-file> <assertion-text>
#
# Counts the lines reporting the named assertion as FAIL. `grep -c` rather than
# `grep -q`: see the header.
needle_matches() {
  grep -c "^  FAIL ${2}\$" "$1" 2>/dev/null || true
}

TOTAL=0
BIT=0
NOT_BIT=0
SUITE_RED_BUT_WRONG=0
SUITE_STILL_GREEN=0
DECLARED_FAILURES=()

note() {
  printf '%s\n' "$1"
}

# run_mutation <id> <description> <anchor> <replacement> <assertion-text>
#
# 1. apply the mutation and record the line it landed on
# 2. refuse it if the gate no longer parses
# 3. run the whole suite with the mutated gate
# 4. require the NAMED assertion to be red
MUTATION_INDEX=0

run_mutation() {
  local id="$1" description="$2" anchor="$3" replacement="$4" assertion="$5"
  local line rc matches idx

  # Counted BEFORE the shard test, so the assignment is identical regardless of
  # which shard is running: a mutation keeps its index, and therefore its shard,
  # no matter how the set is split.
  idx="${MUTATION_INDEX}"
  MUTATION_INDEX=$((MUTATION_INDEX + 1))
  if ((idx % SHARDS != SHARD)); then
    return 0
  fi

  TOTAL=$((TOTAL + 1))
  note ""
  note "=== ${id}: ${description}"
  note "    assertion required to go red: ${assertion}"

  restore
  if ! line="$(apply "${GATE}" "${anchor}" "${replacement}" 2>&1)"; then
    note "    RESULT: NOT BITING -- the mutation did not apply"
    note "      ${line}"
    NOT_BIT=$((NOT_BIT + 1))
    DECLARED_FAILURES+=("${id}: mutation did not apply (${line})")
    return
  fi
  note "    mutation landed at ${GATE}:${line}"
  if ! preflight "${GATE}"; then
    note "    RESULT: NOT BITING -- the mutation left the gate unparseable"
    NOT_BIT=$((NOT_BIT + 1))
    DECLARED_FAILURES+=("${id}: mutation left the gate unparseable")
    return
  fi

  (
    cd "${ROOT_DIR}" || exit 3
    export TMPDIR="${WORK}/tmp"
    mkdir -p "${TMPDIR}"
    bash "${SUITE}"
  ) >"${WORK}/suite.log" 2>&1
  rc=$?

  matches="$(needle_matches "${WORK}/suite.log" "${assertion}")"
  if [[ "${matches}" -lt 1 ]]; then
    if ((rc == 0)); then
      note "    RESULT: NOT BITING -- the suite stayed green (exit 0)"
      SUITE_STILL_GREEN=$((SUITE_STILL_GREEN + 1))
      DECLARED_FAILURES+=("${id}: suite stayed green; '${assertion}' never bit")
    else
      note "    RESULT: NOT BITING -- the suite went red but NOT on that assertion"
      note "      assertions that did go red:"
      grep '^  FAIL ' "${WORK}/suite.log" | head -20 | sed 's/^/        /'
      SUITE_RED_BUT_WRONG=$((SUITE_RED_BUT_WRONG + 1))
      DECLARED_FAILURES+=("${id}: suite red, but '${assertion}' was not among the failures")
    fi
    return
  fi

  note "    RESULT: BITING -- '${assertion}' reported FAIL ${matches} time(s), suite exit ${rc}"
  BIT=$((BIT + 1))
  restore
}

# --- control: the unmutated suite must be green -----------------------------
note "=== control: unmutated gate"
restore
(
  cd "${ROOT_DIR}" || exit 3
  export TMPDIR="${WORK}/tmp-control"
  mkdir -p "${TMPDIR}"
  bash "${SUITE}"
) >"${WORK}/control.log" 2>&1
control_rc=$?
note "    suite exit ${control_rc}"
if ((control_rc != 0)); then
  note "    the unmutated suite is RED, so no mutation result below can be trusted"
  grep '^  FAIL ' "${WORK}/control.log" | head -20 | sed 's/^/      /'
  printf '\nCONTROL FAILED: the suite must be green before mutations mean anything.\n'
  exit 1
fi
tail -2 "${WORK}/control.log" | sed 's/^/    /'

# --- mutations --------------------------------------------------------------
#
# Group (a): "is it really the released artifact" -- the structural checks.
run_mutation "A1" \
  'drop the CFBundleIdentifier match, so ANY bundle id is accepted' \
  'if [[ "${bundle_id}" != "${BUNDLE_ID}" ]]; then' \
  'if false; then' \
  'a bundle declaring a different bundle id is rejected'

run_mutation "A2" \
  'drop the app-executable existence check' \
  '[[ -f "${exec_path}" ]] || fail "the bundle'"'"'s CFBundleExecutable is missing: ${exec_path}"' \
  'true || fail "the bundle'"'"'s CFBundleExecutable is missing: ${exec_path}"' \
  'a bundle with a plist but no executable is rejected'

run_mutation "A3" \
  'drop the native-daemon existence check, so a bundle shipping no daemon passes' \
  '[[ -f "${native_path}" ]] ||' \
  'true ||' \
  'a bundle missing its native daemon is rejected'

run_mutation "A4" \
  'accept a device-slice binary: require ANY slice to be a simulator slice' \
  'while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    slices+=("${line}")
    [[ "${line}" == *":${EXPECTED_PLATFORM}" ]] || unexpected+=("${line}")
  done <<<"${platforms}"' \
  'while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    slices+=("${line}")
  done <<<"${platforms}"
  if grep -qxF "${EXPECTED_PLATFORM}" <<<"${platforms}"; then
    unexpected=()
  else
    unexpected=("${slices[@]}")
  fi' \
  'a universal bundle mixing simulator and device slices is rejected'

run_mutation "A5" \
  'make an unreadable Mach-O platform UNREADABLE-but-passing' \
  'fail "${what}: could not read the Mach-O platform of ${path}"' \
  'log "${what}: platform unreadable, continuing anyway"' \
  'a truncated app executable is rejected'

run_mutation "A6" \
  'accept a bundle whose Info.plist is not a property list' \
  'bundle_id="$(plist_value "${plist}" CFBundleIdentifier)" ||
    fail "cannot read CFBundleIdentifier from ${plist}"' \
  'bundle_id="$(plist_value "${plist}" CFBundleIdentifier 2>/dev/null || printf "x")"
  [[ -n "${bundle_id}" ]] || fail "cannot read CFBundleIdentifier from ${plist}"' \
  'an unreadable Info.plist is rejected'

# Group (b): simulator availability / boot. "Which simulator is booted" is part of
# what must be verified, because release.yml has no simulator destination at all.
run_mutation "B1" \
  'pick the OLDEST runtime instead of the newest, so ordering is inverted' \
  'newest = max(version_key(c[0]) for c in matching)' \
  'newest = min(version_key(c[0]) for c in matching)' \
  'the selector orders real hyphenated runtime ids (18-2 beats 18-0 beats 17-5)'

run_mutation "B2" \
  'stop refusing when no usable simulator could be selected, and continue with none' \
  'fail "no usable iOS simulator could be selected"' \
  'true' \
  'an unparseable device list is refused rather than read as empty'

run_mutation "B3" \
  'treat a simulator that never reaches Booted as booted' \
  'wait_until "${SIM_NAME} to finish booting" "${BOOT_TIMEOUT_SECONDS}" is_sim_booted ||
    fail "the simulator never reached state Booted within ${BOOT_TIMEOUT_SECONDS}s"' \
  'true || fail "the simulator never reached state Booted within ${BOOT_TIMEOUT_SECONDS}s"' \
  'a simulator that never boots fails on the deadline instead of hanging'

run_mutation "B4" \
  'drop the independent bootstatus confirmation' \
  'if ! run_with_deadline "${BOOT_TIMEOUT_SECONDS}" "${XCRUN}" simctl bootstatus "${SIM_UDID}"; then
    fail "simctl bootstatus did not complete for ${SIM_NAME} within ${BOOT_TIMEOUT_SECONDS}s"
  fi' \
  'true' \
  'a wedged simctl bootstatus times out instead of hanging the job'

run_mutation "B5" \
  'consider non-iOS runtimes, so a newer watchOS runtime can be selected' \
  '  if ".SimRuntime.iOS-" not in runtime_id:' \
  '  if False:' \
  'the selector considers only iOS runtimes (a newer watchOS runtime is ignored)'

# Group (c): crash detection.
run_mutation "C1" \
  'stop failing on a crash report attributed to the app' \
  'if ((attributed > 0)); then' \
  'if false; then' \
  'a crash report for the app fails the gate'

run_mutation "C2" \
  'treat an unparseable crash report as clean instead of unattributable' \
  'unparsed=$((unparsed + 1))' \
  'unparsed=0' \
  'an unparseable crash report is treated as a crash, not as clean'

run_mutation "C3" \
  'skip the crash check when the crash-report directory is missing' \
  '  if [[ ! -d "${CRASH_DIR}" ]]; then
    return 1
  fi' \
  '  if [[ ! -d "${CRASH_DIR}" ]]; then
    return 0
  fi' \
  'a missing crash-report directory fails instead of skipping the crash check'

run_mutation "C4" \
  'attribute a crash report to neither the app nor the runner' \
  'if [[ "${proc}" == "${EXECUTABLE_NAME}" || "${bundle}" == "${BUNDLE_ID}" ]]; then
      attributed=$((attributed + 1))
    else
      unrelated=$((unrelated + 1))
    fi' \
  'unrelated=$((unrelated + 1))' \
  'a crash report is attributed by bundle id even under another process name'

# Group (d): frame stability and complexity.
run_mutation "D1" \
  'accept the FIRST captured frame, dropping the two-identical-captures rule' \
  '          current="$(sha256_of "${SCREENSHOT_PATH}")"
          if [[ -n "${current}" && "${current}" == "${previous}" ]]; then
            stable=$((stable + 1))
          else
            stable=0
          fi' \
  '          current="$(sha256_of "${SCREENSHOT_PATH}")"
          stable=1' \
  'a screen that never settles counts as never rendered'

run_mutation "D2" \
  'drop the minimum-distinct-colours complexity floor' \
  '((colors >= MIN_DISTINCT_COLORS))' \
  '((colors >= 0))' \
  'a blank screen counts as never rendered'

run_mutation "D3" \
  'drop the render deadline, so a never-rendering app is waited on forever' \
  'if ! await_settled_frame; then
    collect_logs
    fail "no settled app frame within ${RENDER_TIMEOUT_SECONDS}s (a blank, LaunchScreen-only or never-settling screen is a failure)"
  fi' \
  'await_settled_frame || true' \
  'an undecodable screenshot counts as never rendered'

run_mutation "D4" \
  'accept a colour threshold that cannot fail' \
  '((MIN_DISTINCT_COLORS < 2))' \
  'false' \
  'a colour threshold below 2 is refused, not defaulted'

# Group (e): fail-closed degradation paths.
run_mutation "E1" \
  'skip the gate when xcrun is missing instead of failing' \
  'require_tool "${XCRUN}"' \
  'command -v "${XCRUN}" >/dev/null 2>&1 || true' \
  'a missing xcrun fails instead of skipping the gate'

# Anchored with surrounding context on purpose: the --no-verify retry contains a
# byte-identical `if ((rc == 0)) && app_is_registered` line, so a bare one-line
# anchor is ambiguous and would land in whichever half happened to come first.
run_mutation "E2" \
  'trust simctl exit status alone for the install (drop the registration check)' \
  '  if ((rc == 0)) && app_is_registered; then
    log "installed $(basename "${app}")"
    return 0
  fi' \
  '  if ((rc == 0)); then
    log "installed $(basename "${app}")"
    return 0
  fi' \
  'an install that exits 0 without registering the app is rejected'

run_mutation "E3" \
  'accept a launch that reported no pid' \
  '  if [[ ! "${pid}" =~ ^[0-9]+$ ]] || ((pid <= 0)); then' \
  '  if false; then' \
  'a launch that reports no pid is not believed'

run_mutation "E4" \
  'accept a warm launch as a cold launch' \
  'fail "${BUNDLE_ID} is already running on ${SIM_NAME} before launch; this must be a cold launch"' \
  'log "${BUNDLE_ID} is already running on ${SIM_NAME} before launch; continuing"' \
  'an app that is already running is not a cold launch'

run_mutation "E5" \
  'do not re-check liveness after the frame, so a late crash passes' \
  'is_app_running || fail "${BUNDLE_ID} died while rendering"' \
  'true' \
  'an app that dies after painting a frame still fails'

run_mutation "E6" \
  'accept an empty device-name filter as "any device"' \
  'SIM_DEVICE_PREFIX="${IOS_SMOKE_SIM_DEVICE-iPhone}"' \
  'SIM_DEVICE_PREFIX="${IOS_SMOKE_SIM_DEVICE:-iPhone}"' \
  'an empty device-name filter is refused rather than matching everything'

# Group (f): the backend finding. This is the headline check; if it can be
# removed and the suite stays green, the suite does not test the finding.
run_mutation "F1" \
  'stop failing when no backend probe can answer' \
  '    BACKEND_REASON="the artifact cannot be shown to reach a backend: IOS_SMOKE_BACKEND_PROBE is unset, so no probe could answer. This app'"'"'s only backend is the daemon at ${NATIVE_BINARY}, iOS forbids an app from spawning it, and local_daemon_launcher.dart:24-32 returns attempted:false on every non-desktop platform. Install+launch+render passed; usefulness did not."
    return 1' \
  '    BACKEND_REASON=""
    return 0' \
  'an artifact with no demonstrable backend fails the gate'

run_mutation "F2" \
  'believe a probe that exits 0 and prints nothing' \
  'if [[ -z "${out//[[:space:]]/}" ]]; then' \
  'if false; then' \
  'a backend probe that exits 0 with no output fails the gate'

run_mutation "F3" \
  'believe a backend probe that exits non-zero' \
  'if ! out="$(run_with_deadline "${BACKEND_TIMEOUT_SECONDS}" "${probe}" 2>&1)"; then' \
  'if out="$(run_with_deadline "${BACKEND_TIMEOUT_SECONDS}" "${probe}" 2>&1)"; then' \
  'a backend probe that reports unreachable fails the gate'

run_mutation "F4" \
  'record PASS before the backend question is asked' \
  '  backend_rc=0
  assert_backend_is_reachable || backend_rc=$?' \
  '  backend_rc=0
  record_summary PASS "${app}"
  assert_backend_is_reachable || backend_rc=$?' \
  'the summary verdict is RENDER-ONLY, never PASS, when the backend is unproven'

run_mutation "F5" \
  'accept a backend probe that is not executable' \
  '  if [[ ! -x "${probe}" ]]; then
    BACKEND_REASON="the backend probe is not executable' \
  '  if false; then
    BACKEND_REASON="the backend probe is not executable' \
  'a backend probe that is not executable fails the gate'

# Group (g): the exit status itself, and the evidence verdict.
#
# G2 is the shell equivalent of `continue-on-error: true` in a workflow step. A
# reviewer flagged that key as the v0.1.7 partial-release shape: it turns a
# gate's refusal into a green job while the rest of the workflow carries on. In a
# shell script the same defect is `|| true` on the invocation, so it is mutated
# here rather than merely being absent from the wiring snippet.
run_mutation "G1" \
  'write the verdict twice, so the summary can be read both ways' \
  '  if ((backend_rc != 0)); then
    record_summary "RENDER-ONLY (backend unproven)" "${app}"
    fail "${BACKEND_REASON}"
  fi' \
  '  if ((backend_rc != 0)); then
    record_summary "RENDER-ONLY (backend unproven)" "${app}"
  fi
  record_summary PASS "${app}"
  if ((backend_rc != 0)); then
    fail "${BACKEND_REASON}"
  fi' \
  'the summary states its verdict exactly once'

run_mutation "G2" \
  'report the refusal but exit 0 -- the shell equivalent of continue-on-error' \
  '  printf '"'"'[%s] ERROR: %s\n'"'"' "${SMOKE_NAME}" "$*" >&2
  exit 1' \
  '  printf '"'"'[%s] ERROR: %s\n'"'"' "${SMOKE_NAME}" "$*" >&2
  exit 0' \
  'an artifact with no demonstrable backend fails the gate'

run_mutation "G3" \
  'make the missing-backend verdict PASS, the exact overstatement being prevented' \
  'record_summary "RENDER-ONLY (backend unproven)" "${app}"' \
  'record_summary PASS "${app}"' \
  'the summary verdict is RENDER-ONLY, never PASS, when the backend is unproven'

# --- summary ---------------------------------------------------------------
restore
note ""
note "================================================================"
if ((SHARDS > 1)); then
  note "shard ${SHARD} of ${SHARDS} (mutations with index % ${SHARDS} == ${SHARD})"
  note "this is a PARTIAL run: the other shards are separate jobs, and this"
  note "result says nothing about the mutations they own."
fi
note "mutations run in this shard: ${TOTAL}"
note "  biting:                              ${BIT}"
note "  NOT biting (suite stayed green):     ${SUITE_STILL_GREEN}"
note "  NOT biting (wrong assertion red):    ${SUITE_RED_BUT_WRONG}"
note "  NOT biting (mutation did not apply): ${NOT_BIT}"
note "================================================================"

if ((${#DECLARED_FAILURES[@]} > 0)); then
  note ""
  note "NON-BITING MUTATIONS (each is a failure of this harness, not a pass):"
  for failure in "${DECLARED_FAILURES[@]}"; do
    note "  - ${failure}"
  done
  printf '\nRESULT: FAILED -- %d of %d mutations did not bite.\n' \
    "${#DECLARED_FAILURES[@]}" "${TOTAL}"
  exit 1
fi

printf '\nRESULT: all %d mutations bit on their named assertion.\n' "${TOTAL}"
