#!/usr/bin/env bash
#
# Mutation pass for scripts/tests/windows_release_artifact_smoke_test.sh, and
# through it for scripts/windows_release_artifact_smoke.sh.
#
# A green suite proves the assertions were EVALUATED. It does not prove they would
# have CAUGHT anything. Nearly every assertion in the suite under test is either a
# substring match against gate output or a check over a fixture this harness could
# have replaced, so the failure mode is specific and common: a check that is
# misspelled, or pointed at the wrong text, or whose two branches are the wrong way
# round, and therefore passes unconditionally. That reads exactly like coverage.
#
# So each mutation breaks the PROTECTED code and requires a NAMED assertion to go
# red. "The suite exited non-zero" is not a result; a specific assertion going red
# is. Four guards, each added because the failure it prevents actually occurred
# while writing the files this harness protects:
#
#   * `apply` requires the anchor to occur exactly once and then reads the file back
#     to confirm the replacement landed. A mutation that silently does not apply
#     leaves the suite green, which the harness would otherwise report as "the
#     assertion does not bite" -- a false accusation, and the kind that gets a real
#     mutation deleted from this list to make the harness pass.
#   * `preflight` / `preflight_embedded_python` reject a mutation that leaves the
#     file broken. A red suite produced by a syntax error proves nothing: every
#     assertion goes red, so any needle "matches" and the mutation looks like it
#     bit. `bash -n` cannot see the gate's embedded PNG decoder, so that heredoc is
#     extracted and compiled separately.
#   * `needle_matches` requires the named assertion's own text in the red output. A
#     suite that goes red for an unrelated reason satisfies "exited non-zero" while
#     measuring nothing.
#
# `grep -c` rather than `grep -q` in needle_matches, deliberately: `grep -q` exits
# on its first match, SIGPIPEs the upstream `grep -v`, and under `set -o pipefail`
# that turns a successful match into a non-zero pipeline depending on whether the
# writer finished first. It is a race, and it made the sibling harness
# (release_atomic_publish_mutation_test.sh) report non-biting mutations whose
# assertions had in fact gone red.
#
# WHY EVERY NEEDLE IS AN ASSERTION NAME, not a gate message. The first version of
# this harness used the gate's own error text as the needle, and it under-reported:
# when a mutation turns a gate FAIL into a gate PASS, the suite's `expect_fail`
# prints "expected a non-zero exit, got success: <gate output>", which does NOT
# contain the gate's message. The assertion had gone red; the needle did not match;
# the mutation was wrongly reported as non-biting. An assertion NAME is printed in
# the FAIL line on every failing path, so it is the only needle that works for both
# "the gate now passes" and "the gate still fails, differently".
#
# SCOPE LIMIT, stated up front: this harness mutates the BASH logic of the gate and
# the suite. The six PowerShell helpers in the gate have NEVER been executed on a
# Windows host (see the gate's VERIFICATION STATUS block), so no mutation here can
# prove anything about them beyond what the suite's static structural lint checks.
# A mutation that breaks a PS_* heredoc is caught only as far as that lint goes,
# which is not a PowerShell parse.
set -uo pipefail

# Per-case wait budgets, tightened for this harness only. The suite honours these as
# SMOKE_LAUNCH_TIMEOUT / SMOKE_RENDER_TIMEOUT and uses 10s/6s by default; most
# negative cases here are precisely the ones that burn a full timeout waiting for
# something that never happens, so this is where nearly all the wall-clock is.
#
# This cannot turn a non-biting mutation into a biting one, which is the only
# concern that would matter: every mutation is judged by `needle_matches`, which
# demands the specific assertion's own text in the red output. A run that merely
# timed out everywhere produces a red suite full of the wrong assertions, which
# `needle_matches` rejects and which is reported as "went red but not on
# '<needle>'". A budget that is too short therefore fails LOUDLY and cannot
# masquerade as a pass. It could only mask a pass, and that is the safe direction.
export SMOKE_LAUNCH_TIMEOUT=5
export SMOKE_RENDER_TIMEOUT=4

# --- sharding ---------------------------------------------------------------
#
# A full pass re-runs the whole suite once per mutation, and this suite takes
# minutes, so the whole set is long enough to exceed the required check's
# timeout. `MUTATION_SHARDS=N MUTATION_SHARD=i` runs only the mutations where
# `index % N == i`, so the set can be split across concurrent shards. Every
# shard 0..N-1 is always run, so the union is the full mutation set: nothing is
# skipped to make the pass fast. Default: one shard (everything).
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

SOURCE_ROOT="${PO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

WORK="$(mktemp -d)"
# EXIT alone is not enough. bash does not run an EXIT trap for an untrapped
# SIGTERM, so a `timeout`, a `kill` from a CI step that ran long, or a Ctrl-C would
# leave the private tree behind. This trap was found by exactly that: a 90-second
# timeout on a diagnostic driver landed between the two edits of a compound
# mutation and left MIN_TRIVIAL_ASSERTIONS at the mutated value.
#
# It only has to delete the private tree: nothing the run mutates lives outside it
# (see below), so there is no worktree snapshot to restore.
trap 'rm -rf "${WORK}"' EXIT INT TERM HUP

# The whole relevant tree is COPIED and mutated in place: `scripts/` because the
# gate and suite live there, and `.github/` because the suite's soft-fail guard
# reads `.github/workflows/release.yml` from its own root.
#
# A shard re-runs the suite once per mutation and keeps the gate mutated for the
# whole run. Two shards sharing one file would each be testing the other's edit,
# and each would restore a different snapshot at the end -- exactly the cross-talk
# the concurrent fan-out in run_release_gate_tests.sh must not have. Copying gives
# every shard a private tree, which is what makes that fan-out safe, and it means
# a killed shard can never leave the developer's worktree mutated.
#
# Only two files are ever mutated, both of them files this work produced: the gate
# and its suite. Nothing under `.github/workflows/` is touched, even in the copy --
# a mid-run kill there would leave a mutated workflow behind, and other agents are
# editing those files in parallel. The suite's workflow guard is therefore proven
# to bite by mutating the GUARD (its rule, and the file it resolves to), not by
# planting a violation in the workflow it reads.
mkdir -p "${WORK}/tree"
cp -R "${SOURCE_ROOT}/scripts" "${WORK}/tree/scripts"
cp -R "${SOURCE_ROOT}/.github" "${WORK}/tree/.github"

ROOT_DIR="${WORK}/tree"
SUITE="${ROOT_DIR}/scripts/tests/windows_release_artifact_smoke_test.sh"
GATE="${ROOT_DIR}/scripts/windows_release_artifact_smoke.sh"

for required in "${SUITE}" "${GATE}" "${ROOT_DIR}/.github/workflows/release.yml"; do
  if [[ ! -f "${required}" ]]; then
    printf 'FATAL: %s does not exist\n' "${required}" >&2
    exit 2
  fi
done

cp "${GATE}" "${WORK}/gate.orig"
cp "${SUITE}" "${WORK}/suite.orig"

restore() {
  cp "${WORK}/gate.orig" "${GATE}"
  cp "${WORK}/suite.orig" "${SUITE}"
}

# apply <file> <old> <new> -- replace exactly one occurrence, then read the file back
# and confirm it now says what was intended. Writing a file is not evidence that the
# file contains the intended text.
apply() {
  python3 - "$1" "$2" "$3" <<'PYTHON'
import sys

path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, encoding="utf-8") as handle:
    text = handle.read()
count = text.count(old)
if count != 1:
    print(
        f"ANCHOR IS NOT UNIQUE ({count} occurrences): {old[:90]!r}", file=sys.stderr
    )
    sys.exit(4 if count else 3)
with open(path, "w", encoding="utf-8") as handle:
    handle.write(text.replace(old, new, 1))
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

# preflight <file> -- reject a mutation that leaves the file unparseable as shell.
preflight() {
  local out
  if ! out="$(bash -n "$1" 2>&1)"; then
    printf 'the shell script no longer parses: %s\n' "${out}" >&2
    return 1
  fi
  return 0
}

# The gate embeds its PNG decoder as a Python heredoc. A mutation that breaks that
# Python does not make the gate's bash unparseable, so `bash -n` would wave it
# through and the suite would go red everywhere -- which looks like a biting mutation
# but is really just a broken file. This is the only check here that reaches past the
# gate's bash surface, and it is what makes the frame-stability and geometry
# mutations trustworthy.
preflight_embedded_python() {
  local out
  out="$(python3 - "${GATE}" <<'PYTHON' 2>&1
import re
import sys

text = open(sys.argv[1], encoding="utf-8").read()
blocks = re.findall(r"png_stats\(\)\s*\{.*?<<'PY'\n(.*?)\nPY\n\}", text, re.S)
if not blocks:
    print("could not locate the png_stats heredoc in the gate")
    sys.exit(1)
for index, block in enumerate(blocks):
    try:
        compile(block, f"<png_stats #{index}>", "exec")
    except SyntaxError as exc:
        print(f"embedded Python #{index} no longer compiles: {exc}")
        sys.exit(1)
PYTHON
)" || {
    printf '%s\n' "${out}" >&2
    return 1
  }
  return 0
}

# Everything the suite said except its passing verdicts. A FAIL line is a symptom; the
# assertion's own detail line is the cause, and it is the more precise evidence.
needle_matches() {
  grep -vE '^[[:space:]]*ok ' <<<"$1" | grep -cF -- "$2" >/dev/null
}

# mutate <name> <old> <new> <needle> [target]
#
# `target` defaults to the gate. Mutating the *suite* is legitimate and needed: some
# assertions are load-bearing for the suite's own correctness rather than for catching
# a gate defect, and the only way to show those is to break them and watch a correct
# gate start failing.
mutate() {
  local name="$1" old="$2" new="$3" needle="$4"
  local target="${5:-${GATE}}"
  local index=${MUTATION_INDEX}
  MUTATION_INDEX=$((MUTATION_INDEX + 1))
  # Count the declaration BEFORE the shard skip, so the floor measures what the file
  # declares rather than what this shard happened to run.
  DECLARED_MUTATIONS=$((DECLARED_MUTATIONS + 1))
  # Shard selection: this mutation belongs to exactly one shard. The index is
  # captured before the skip, so a mutation keeps its index -- and its shard --
  # on every run. The driver always spawns every shard 0..N-1, so the union of
  # the shards is the full mutation set.
  if (( index % SHARDS != SHARD )); then
    return
  fi
  MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
  restore
  local line
  if ! line="$(apply "${target}" "${old}" "${new}" 2>&1)"; then
    mismatches+=("${name}: COULD NOT APPLY the mutation (${line})")
    restore
    return
  fi
  if ! preflight "${target}"; then
    mismatches+=("${name}: INVALID MUTATION -- it breaks the file under test, so a red suite would prove nothing")
    restore
    return
  fi
  if ! preflight_embedded_python; then
    mismatches+=("${name}: INVALID MUTATION -- it breaks the gate's embedded Python, so a red suite would prove nothing")
    restore
    return
  fi
  local out rc
  out="$(bash "${SUITE}" 2>&1)"
  rc=$?
  if [[ ${rc} -eq 0 ]]; then
    mismatches+=("${name}: SUITE STILL PASSED (the assertion does not bite)")
    mismatches+=("        line ${line}; the suite reported all-green against the mutated code")
  elif ! needle_matches "${out}" "${needle}"; then
    mismatches+=("${name}: went red but not on '${needle}'")
    mismatches+=("        line ${line}; saw: $(grep -E '^[[:space:]]*FAIL ' <<<"${out}" | head -3 | tr '\n' ' ')")
  else
    MUTATIONS_BITING=$((MUTATIONS_BITING + 1))
    printf '  bites  %s\n         line %s; needle %s\n' "${name}" "${line}" "${needle}"
  fi
  restore
}

# The exit-code guard is dead code on a green run, so it can only be shown to be
# load-bearing by forcing a failure at the same time. That is why this is a compound
# mutation rather than a `mutate` call, and why it is the one case where the desired
# evidence is a ZERO exit status:
#
#   1. CONTROL: force a failure (the non-vacuity floor raised out of reach -- itself
#      a real assertion in the suite), guard intact. The suite must exit non-zero.
#      Without this step, step 2 would prove nothing: a suite that is green for some
#      other reason also exits 0.
#   2. MUTATION: same forced failure, guard neutralised. The suite must print the
#      same failure and exit 0. That combination -- failures visible, exit status
#      green -- is precisely the v0.1.7 shape this repository was burned by, and it
#      is what CI reads as success.
mutate_exit_code_guard() {
  local name="the suite reports failures but still exits 0"
  local index=${MUTATION_INDEX}
  MUTATION_INDEX=$((MUTATION_INDEX + 1))
  # Count the declaration BEFORE the shard skip, exactly as mutate() does.
  DECLARED_MUTATIONS=$((DECLARED_MUTATIONS + 1))
  if (( index % SHARDS != SHARD )); then
    return
  fi
  MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
  local induced='the suite asserted a non-trivial number of things'
  local floor_old='MIN_TRIVIAL_ASSERTIONS=60'
  local floor_new='MIN_TRIVIAL_ASSERTIONS=100000'
  local guard_old='if ((FAIL_COUNT > 0)); then
  exit 1
fi'
  local guard_new='if ((FAIL_COUNT > 0)); then
  true
fi'

  restore
  local applied out rc
  if ! applied="$(apply "${SUITE}" "${floor_old}" "${floor_new}" 2>&1)"; then
    mismatches+=("${name}: COULD NOT APPLY the induced failure (${applied})")
    restore
    return
  fi
  if ! preflight "${SUITE}"; then
    mismatches+=("${name}: INVALID MUTATION -- the induced failure breaks the suite")
    restore
    return
  fi
  out="$(bash "${SUITE}" 2>&1)"
  rc=$?
  if [[ ${rc} -eq 0 ]]; then
    mismatches+=("${name}: CONTROL FAILED -- the intact guard did not reject a forced failure")
    restore
    return
  fi
  if ! needle_matches "${out}" "${induced}"; then
    mismatches+=("${name}: CONTROL FAILED -- the forced failure was not the induced one, so step 2 would measure nothing")
    restore
    return
  fi

  if ! applied="$(apply "${SUITE}" "${guard_old}" "${guard_new}" 2>&1)"; then
    mismatches+=("${name}: COULD NOT APPLY the guard mutation (${applied})")
    restore
    return
  fi
  if ! preflight "${SUITE}"; then
    mismatches+=("${name}: INVALID MUTATION -- it breaks the suite")
    restore
    return
  fi
  out="$(bash "${SUITE}" 2>&1)"
  rc=$?
  if [[ ${rc} -ne 0 ]]; then
    mismatches+=("${name}: the neutralised guard STILL exited non-zero (${rc})")
  elif ! needle_matches "${out}" "${induced}"; then
    mismatches+=("${name}: exited 0 but without the induced failure in the output, so it measured nothing")
  else
    MUTATIONS_BITING=$((MUTATIONS_BITING + 1))
    printf '  bites  %s\n         forced failure "the suite asserted a non-trivial number of things" reported, exit status suppressed (control run exited non-zero on the same failure)\n' "${name}"
  fi
  restore
}

# THE MINE THIS FLOOR DEFENDS AGAINST: a shard filter matching nothing, or a
# future edit that deletes a declaration, shrinks the set silently and still reports
# success -- a smaller or empty run reads exactly like a clean pass. MIN_MUTATIONS is
# the count this file declares in a full unsharded run, so it is a LOWER BOUND: a run
# below it is a broken harness, not a green one.
MIN_MUTATIONS=29
DECLARED_MUTATIONS=0

MUTATIONS_RUN=0
MUTATIONS_BITING=0
MUTATION_INDEX=0
mismatches=()

echo "== is it really the released artifact? =="

# The check the whole gate exists for: the bytes under test are the ones inside the
# ZIP. An ambiguous archive is where a packaging regression could quietly decide which
# binary ships; the gate refuses to guess, and must keep refusing.
mutate "an ambiguous archive's second copy of the executable is silently accepted" \
  '  if ((count > 1)); then
    find "${EXTRACT_DIR}" -type f -iname "${EXE_NAME}" 2>/dev/null | sed '"'"'s/^/  /'"'"' >&2 || true
    fail "the archive contains ${count} copies of ${EXE_NAME}; refusing to guess which one is the app"
  fi' \
  '  if ((count > 1)); then
    log "the archive contains ${count} copies of ${EXE_NAME}; using the last match"
  fi' \
  "two copies of the executable is refused"

# The packaged sidecars are invisible to "the app launched" -- the Flutter UI runs
# perfectly well without galleryd.exe -- so the structural check is the only thing
# that sees this packaging regression.
mutate "the native sidecars are no longer a required packaged entry" \
  'REQUIRED_ENTRIES="${WINDOWS_SMOKE_REQUIRED_ENTRIES:-galleryd.exe;ml_sidecar}"' \
  'REQUIRED_ENTRIES="${WINDOWS_SMOKE_REQUIRED_ENTRIES:-}"' \
  "no native sidecars is rejected"

# The separator normalisation is what lets a correctly built Compress-Archive ZIP
# pass. Broken, it does not merely lose coverage -- it starts rejecting the real
# release artifact, which is what gets a gate switched off in the first place.
mutate "backslash entry separators are no longer normalised to forward slashes" \
  'normalised="$(sed '"'"'s|\\|/|g'"'"' <<<"${entries}")"' \
  'normalised="${entries}"' \
  "backslash-separated entries"

# A name that merely shares a prefix must not satisfy a required entry. This is the
# mutation that reproduces the real defect the decoy fixture was written to catch:
# with a bare prefix match, `galleryd.exe.old` counts as `galleryd.exe` and
# `ml_sidecar_stale/` counts as `ml_sidecar`, so an archive shipping neither sidecar
# is reported as having shipped both.
mutate "entry matching accepts anything that merely starts with the required name" \
  'if [[ "${entry}" == "${name}" || "${entry}" == "${name}/"* ]]; then' \
  'if [[ "${entry}" == "${name}"* ]]; then' \
  "a decoy entry that only shares a prefix"

# The bytes, not the name. `private_gallery_app.exe` that is not a 64-bit PE image is
# exactly what a truncated or mis-copied binary looks like, and the launch step
# cannot see it: a real Win32 launcher would fail obliquely and a fake one would
# start anything. Removing the header walk must let the bad-PE fixture through and
# turn the named assertion red.
mutate "a packaged executable that is not a PE image is accepted" \
  '  assert_pe_executable "${exe_path}" ||
    fail "the packaged executable is not the expected Windows PE image (see the errors above)"' \
  '  log "packaged executable: ${exe_path} (PE header check disabled by mutation)"' \
  "a packaged executable that is not a PE image is rejected"

# The harness must not damage the artifact it is gating. The original defect here was
# the fake pwsh reading PowerShell's own flags as the helper's arguments and starting
# its redirections at the wrong index, silently truncating the packaged executable to
# zero bytes before it was ever launched. Re-introducing that must go red.
mutate "the test harness truncates the packaged executable it is supposed to launch" \
  '    # Start-Process -Redirect* creates these two files up front, empty.
    : >"$2"
    : >"$3"' \
  '    # Start-Process -Redirect* creates these two files up front, empty.
    : >"$1"
    : >"$3"' \
  "the extracted executable is still non-empty after a full run" \
  "${SUITE}"

echo "== crash and panic detection =="

# A silent zero-code exit is the subtle one: the app started and exited cleanly, so a
# check that only rejects non-zero codes reads it as success. The gate's render loop
# catches ANY death with a readable code; mutating it to reject only non-zero codes
# must go red on the zero-code assertion specifically.
mutate "a zero exit code on start stops being a failure" \
  '      if exit_code="$(read_exit_code)"; then' \
  '      if exit_code="$(read_exit_code)" && [[ "${exit_code}" != "0" ]]; then' \
  "silent zero-code exit on start also fails"

# The Rust panic markers. Removing the list makes a panicking app pass, which is the
# most direct "we shipped a binary that crashes" false pass available.
mutate "the Rust panic markers are no longer crash markers" \
  '    "panicked at" \
    "RUST_BACKTRACE" \' \
  '    "zzz-no-such-rust-panic-marker-zzz" \
    "zzz-no-such-rust-backtrace-marker-zzz" \' \
  "a Rust panic/backtrace in the app's own output fails the gate"

# The Dart half of the same assertion, so a future edit cannot remove only the Rust
# half and still leave the suite green.
mutate "the Dart unhandled-exception marker is no longer a crash marker" \
  '    "Unhandled exception" \' \
  '    "zzz-no-such-dart-marker-zzz" \' \
  "a Dart unhandled exception in the app's own output fails the gate"

# The Application event log, read as a pre/post baseline so pre-existing entries on
# the shared runner image do not fail every healthy build. Removing the baseline
# comparison makes every NEW crash event invisible.
mutate "the crash-event baseline is discarded, so only absolute counts matter" \
  'if ((after > baseline)); then' \
  'if ((after > 999999)); then' \
  "new Windows crash event after launch fails the gate"

# The event-log read has TWO fail-closed branches, and mutating only one leaves the
# other to fail the run for the right reason -- which is why the first version of this
# harness reported a non-biting mutation for a check that is in fact load-bearing.
# They are therefore mutated separately, each against its own assertion.
#
# Branch 1: the helper itself exits non-zero.
mutate "a failing event-log helper is treated as zero crashes" \
  '  if ! out="$(run_ps_helper "${PS_EVENTLOG_SCRIPT}" "${EXE_NAME}")"; then
    return 2
  fi' \
  '  if ! out="$(run_ps_helper "${PS_EVENTLOG_SCRIPT}" "${EXE_NAME}")"; then
    out="PO-EVENTLOG-OK 0"
  fi' \
  "an unreadable event log fails the gate rather than reporting clean"

# Branch 2: the helper exits 0 but its reply carries no sentinel. This is the shape a
# naive "did it error?" check misses entirely.
mutate "an event-log reply with no sentinel is treated as zero crashes" \
  '  if [[ -z "${line}" ]]; then
    return 2
  fi' \
  '  if [[ -z "${line}" ]]; then
    printf "0"
    return 0
  fi' \
  "an event-log reply with no sentinel is refused, not read as zero crashes"

echo "== frame stability, complexity, and the change diff =="

# The stability threshold itself. Weakened to 0, every frame is "stable" on its first
# capture and a screen still animating would pass -- the same class of false pass the
# Android gate documents for a splash screen drawn inside the app's own window.
mutate "frame stability needs no second capture, so an animating screen passes" \
  'if ((stable >= 1)) && [[ "${frame_changed}" =~ ^[0-9]+$ ]] &&
            ((frame_changed >= MIN_CHANGED_PIXELS)); then' \
  'if ((stable >= 0)) && [[ "${frame_changed}" =~ ^[0-9]+$ ]] &&
            ((frame_changed >= MIN_CHANGED_PIXELS)); then' \
  "a frame that never settles fails the gate"

# The complexity threshold. Zeroed, a blank black screen satisfies it.
mutate "a blank screen clears the distinct-colour threshold" \
  '((frame_colors >= MIN_DISTINCT_COLORS)); then' \
  '((frame_colors >= 0)); then' \
  "a blank screen counts as never rendered"

# The changed-pixel half. Zeroed, "the desktop was already busy" satisfies the check
# on its own, because the pre-launch baseline is a real desktop screenshot.
mutate "the changed-pixel requirement is dropped from the verdict" \
  '((frame_changed >= MIN_CHANGED_PIXELS)); then' \
  '((frame_changed >= 0)); then' \
  "identical to the pre-launch desktop fails the gate"

# A frame that cannot be compared must be refused, not reported as "0 pixels
# changed". Reporting 0 makes an incomparable comparison look like an unchanged
# screen, and with MIN_CHANGED_PIXELS=0 it would satisfy the check outright.
mutate "an incomparable baseline is reported as zero changed pixels" \
  'sys.exit("cannot diff %s: geometry %dx%d differs from the baseline'"'"'s %dx%d"
                 % (path, w, ht, bw, bht))' \
  'pass' \
  "different geometry is refused by the decoder"

# An undecodable frame is not a frame. If the decoder returned a synthetic empty
# frame for garbage, the complexity check would be satisfied by a file that is not a
# picture at all.
mutate "an undecodable capture is reported as a zero-colour frame" \
  'sys.exit("cannot decode %s: %s" % (path, exc))' \
  'rows = [b""] * 8
    w = ht = 64
    channels = 3' \
  "a non-PNG frame is rejected by the decoder"

echo "== the Win32 layer must never be mistaken for a clean device =="

# Each of these is a fail-closed branch. Removing any one turns an unanswerable
# question into a "no", and the gate goes green on a broken Win32 bridge -- the most
# dangerous failure mode available to a gate running on a machine it does not control.

mutate "an unqueryable process table is reported as a dead process" \
  '    if ((rc == 2)); then
      fail "could not query the process table; refusing to report a liveness check that never ran"
    fi' \
  '    if ((rc == 2)); then
      rc=1
    fi' \
  "process table fails the gate rather than reporting dead"

# The window enumeration's own "no sentinel" rule. Returning 1 here reports a broken
# bridge as "the app has no window", which is a confident answer to a question that
# was never answered.
mutate "an uninterpretable window enumeration is reported as no window" \
  '  # A reply with no sentinel is an unanswered question, not "no window".
  ((header == 1)) || return 2
  return 1' \
  '  ((header == 1)) || return 1
  return 1' \
  "uninterpretable window enumeration is refused"

# wait_until flattens the tri-state unless told not to. This mutation catches the
# flattening itself: with it, a broken Win32 bridge is reported as the confident and
# entirely wrong "the app never created a visible top-level window".
mutate "the window wait collapses could-not-ask into no-window" \
  '  if ((win_rc == 2)); then
    fail "could not enumerate top-level windows while waiting for one; refusing to report a window check that never ran"
  fi' \
  '  if ((win_rc == 2)); then
    win_rc=1
  fi' \
  "window enumeration that throws fails rather than reporting no window"

# The pre-launch baseline. This is the degradation the gate was corrected FOR: an
# uncapturable baseline used to print a warning, disarm the diff, and exit 0 with a
# strictly weaker assertion. Re-introducing the downgrade must go red.
mutate "an uncapturable pre-launch baseline downgrades to a warning and still exits 0" \
  '  if ! capture_screenshot "${PRELAUNCH_PATH}"; then
    printf '"'"'::error::could not capture the pre-launch desktop.\n'"'"' >&2' \
  '  if ! capture_screenshot "${PRELAUNCH_PATH}"; then
    printf '"'"'::warning::could not capture the pre-launch desktop\n'"'"' >&2
    DIFF_ENABLED=0
  fi
  if false; then' \
  "missing pre-launch baseline fails the gate instead of disabling the diff"

# ...and the summary's end of it: a run that reaches the summary must not be able to
# describe itself as clean while the changed-pixel check was off. This is the word
# "the summary has no wording for a disabled changed-pixel check" actually reads, so
# that is what has to break for it to bite.
#
# The first version of this mutation disarmed the DIFF_ENABLED invariant at the far
# end of the run instead. It was a non-bite, and not a flaky one: the invariant is
# unreachable BY CONSTRUCTION now that a missing baseline is a hard failure rather
# than a degradation -- there is no path that reaches the summary with DIFF_ENABLED
# unset. Defence in depth that no assertion can reach is reported in HONEST GAPS,
# not given a mutation that pretends otherwise.
mutate "a disarmed changed-pixel check is described as armed in the summary" \
  'pre-launch diff: armed' \
  'pre-launch diff: DISABLED' \
  "summary has no wording for a disabled changed-pixel check"

# Focus must be re-asserted INSIDE the render loop. Checking it once before the loop
# would forgive a window that lost focus while the gate waited.
mutate "focus is checked once and never re-asserted inside the render loop" \
  '    if ((rc != 0)); then
      log "a window exists but is not the foreground window yet"' \
  '    if ((rc != 0 && stable == 999)); then
      log "a window exists but is not the foreground window yet"' \
  "focus lost during the render wait fails the gate"

# A window with no title is not proof the app drew anything.
mutate "a window with an empty title is accepted as a rendered frame" \
  '[[ -n "${title}" && "${title}" != "-" ]] || continue' \
  '[[ "${title}" != "==" ]] || continue' \
  "a window with no title does not satisfy the gate"

echo "== a gate step must not be allowed to fail softly =="

# `continue-on-error: true` on a gate step turns its refusal into a green job while
# the release proceeds -- the v0.1.7 partial-release shape. The assertion that guards
# it is in the suite, and it is proven to bite from both sides without ever touching
# `.github/workflows/`.

# Side 1: the rule itself. release.yml explains, in a COMMENT, why it uses
# `if: always()` instead of `continue-on-error`. The assertion anchors its pattern at
# line start so that comment is not read as a violation. Loosen that to a bare
# substring match and the assertion must go red on the real workflow -- which is what
# makes the anchoring load-bearing rather than decorative.
mutate "the continue-on-error rule is loosened to a bare substring match" \
  "elif grep -nE '^[[:space:]]*continue-on-error[[:space:]]*:' \"\${release_workflow}\"" \
  "elif grep -nE 'continue-on-error' \"\${release_workflow}\"" \
  "the release workflow has no continue-on-error on any step" \
  "${SUITE}"

# Side 2: the file the rule is applied to. Point the default at a path that does not
# exist and the assertion must go red on its own "could not run" branch, rather than
# passing because it never read anything. This is the mutation that catches an
# existence check accidentally inverted into a pass.
mutate "the continue-on-error check reads a workflow that is not there" \
  'release_workflow="${WINDOWS_SMOKE_RELEASE_WORKFLOW:-${ROOT_DIR}/.github/workflows/release.yml}"' \
  'release_workflow="${WINDOWS_SMOKE_RELEASE_WORKFLOW:-${ROOT_DIR}/.github/workflows/no-such-workflow.yml}"' \
  "the release workflow has no continue-on-error on any step" \
  "${SUITE}"

echo "== the suite's own correctness =="

# Assertions that protect the suite rather than the gate. Without these the suite can
# go green while asserting almost nothing, which is worse than red.

# The non-vacuity floor. Lowered to 0, the suite reports green having asserted next to
# nothing -- and nothing else would notice, because the gate is unchanged and still
# passes.
# The non-vacuity floor. Lowering it to 0 cannot make this go red -- the condition
# is `PASS_COUNT >= FLOOR`, so lowering a floor only ever makes the assertion MORE
# satisfied. The floor bites when the count falls below it, so the mutation raises
# it above the number of assertions this suite really makes. That is also the
# induced failure the exit-code mutation below reuses, and it is why that one needs
# a control run of its own.
mutate "the suite's own non-vacuity floor rejects the number of assertions it makes" \
  'if ((PASS_COUNT >= MIN_TRIVIAL_ASSERTIONS)); then' \
  'if ((PASS_COUNT >= 100000)); then' \
  "asserted a non-trivial number of things" \
  "${SUITE}"

# The exit code. This is the mutation that motivated the whole file: the first version
# of this suite had no final exit statement and reported "71 passed, 13 failed" while
# exiting 0, so CI read it as success.
mutate_exit_code_guard

# The contamination guard. The fake pwsh once wrote files named after PowerShell's own
# flags into the caller's working directory because it read them as the helper's
# arguments. The guard for that was itself inverted for a while -- it printed `ok`
# when files HAD appeared -- which is why the mutation flips its condition rather than
# deleting it.
mutate "the suite stops checking the working directory for contamination" \
  'if [[ -z "${diff_names// /}" ]]; then' \
  'if [[ -n "${diff_names// /}" ]]; then' \
  "no new files were created in the working directory by this suite" \
  "${SUITE}"

restore

printf '\n%s mutations run, %s bit (declared %s, floor %s)\n' \
  "${MUTATIONS_RUN}" "${MUTATIONS_BITING}" "${DECLARED_MUTATIONS}" "${MIN_MUTATIONS}"
if ((DECLARED_MUTATIONS < MIN_MUTATIONS)); then
  mismatches+=("the harness declared ${DECLARED_MUTATIONS} mutations, below the floor of ${MIN_MUTATIONS}")
fi
if ((SHARDS > 1)) && ((MUTATIONS_RUN == 0)); then
  mismatches+=("shard ${SHARD} of ${SHARDS} ran zero mutations")
fi
if ((${#mismatches[@]} > 0)); then
  printf '\nproblems:\n' >&2
  for problem in "${mismatches[@]}"; do
    printf '  %s\n' "${problem}" >&2
  done
  exit 1
fi
exit 0
