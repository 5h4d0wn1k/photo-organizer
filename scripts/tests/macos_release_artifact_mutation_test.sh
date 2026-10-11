#!/usr/bin/env bash
#
# Mutation harness for scripts/tests/macos_release_artifact_smoke_test.sh.
#
# Why this file exists separately from the suite: the suite proves the *gate*
# behaves. It cannot prove the suite still *tests* the gate. A suite whose
# assertions quietly stop biting -- because a fixture drifted, a scenario key
# was renamed, or a check was deleted along with the thing it checked -- is
# green and worthless, and it is green in exactly the way a release gate must
# never be. So for each piece of logic the suite claims to cover, the protected
# code is broken here, the suite is run, and three things must hold:
#
#   1. the suite exits NON-ZERO. This is why the suite needed its own exit-code
#      block: without one, nine failing assertions still exited 0, every
#      mutation below would have read as "non-biting", and the harness would
#      have reported a clean bill of health for a gate it never exercised.
#   2. the FAIL lines name the assertion the mutation was aimed at. A red suite
#      that goes red on some *other* assertion is a false pass wearing a
#      failure's clothes: the mutation broke the file, so something had to turn
#      red, but not the thing under test.
#   3. the mutation applied at all. A mutation that matches no text, or matches
#      it twice, is reported as a failure and never counted as biting. This is
#      the trap the sibling `release_atomic_publish_mutation_test.sh` calls out:
#      "the mutation silently did nothing" is indistinguishable from "the
#      mutation was harmless" unless you check.
#
# `preflight` additionally rejects a mutation that leaves the gate unparseable.
# Such a mutation measures nothing -- it makes the whole file die at line 1 --
# and reads as a legitimate red.
#
# This harness proves the suite is load-bearing. It does NOT prove the gate is
# correct on a real Mac: it runs the gate against the suite's synthetic fake
# toolchain on Linux, where no `hdiutil`, `open`, `lsappinfo` or
# `screencapture` exists. See the LIMITATIONS block in the gate itself.
#
# `--check` verifies every anchor and preflight WITHOUT running the suite. A full
# pass costs one suite run per mutation -- around two minutes each here, so over
# an hour -- and a drifted anchor is only discoverable at the end of that. This
# mode makes the cheap part cheap: it answers "do these mutations still describe
# the code they claim to?" in a second, which is the question that has to be
# re-answered every time the gate or the suite is edited.
#
# `--list` prints one line per mutation, so the table in the report can be
# regenerated from the harness instead of transcribed by hand.

set -uo pipefail

# Set by --check/--list so mutate() can verify without running the suite.
MODE_VERIFY_ONLY=""
MODE_LIST=""

SOURCE_ROOT="${PO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

for arg in "$@"; do
  case "${arg}" in
    --check) MODE_VERIFY_ONLY=1 ;;
    --list) MODE_LIST=1 ;;
    *)
      printf 'usage: %s [--check] [--list]\n' "$(basename "${BASH_SOURCE[0]}")" >&2
      printf '  (no arguments)  run every mutation and require the suite to go red\n' >&2
      printf '  --check        verify every anchor and preflight only, no suite runs\n' >&2
      printf '  --list         print "mutation | needle" per mutation and exit\n' >&2
      exit 2
      ;;
  esac
done

# --- sharding ---------------------------------------------------------------
#
# A full pass re-runs the whole suite once per mutation, and the macOS suite
# takes about two minutes -- the whole set is over an hour, longer than the
# required check's timeout. `MUTATION_SHARDS=N MUTATION_SHARD=i` runs only the
# mutations where `index % N == i`, so the set can be split across concurrent
# shards. Every shard 0..N-1 is always run, so the union is the full mutation
# set: nothing is skipped to make the pass fast. Default: one shard (everything).
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
# The trap only deletes the private tree: the run never mutates anything outside
# it, so there is no worktree snapshot to restore even if the shard is killed.
# (restore() still exists -- it resets the copy between mutations in one shard.)
#
# The signal handlers MUST exit, and that is the whole point of splitting this
# out. A single `trap 'rm -rf "${WORK}"' EXIT INT TERM HUP` is a trap that lies:
# for EXIT that is the correct handler, but bash runs a signal handler and then
# *resumes the script*. So a signalled shard deleted its own tree and carried on,
# and every later mutation then reported itself as `COULD NOT APPLY -- ` with an
# empty reason (the reason file lived in the tree that had just been removed),
# followed by "restoring the originals did not return the suite to green". Read
# naively that says four mutations do not bite; they were never tested. It also
# meant a cancelled job could not honour the cancellation and left orphans behind.
#
# So: normal exit cleans up and reports; a signal cleans up, then exits 128+signo
# WITHOUT printing a verdict. A shard that did not finish must never be able to
# say anything that could be read as a result.
on_signal() {
  local name="$1" signo="$2"
  trap - EXIT INT TERM HUP
  rm -rf "${WORK}"
  printf 'FATAL: received signal %s; this shard did not finish and reports no verdict\n' \
    "${name}" >&2
  exit "$((128 + signo))"
}
trap 'rm -rf "${WORK}"' EXIT
trap 'on_signal INT 2' INT
trap 'on_signal TERM 15' TERM
trap 'on_signal HUP 1' HUP

# The whole `scripts/` tree is COPIED and mutated in place.
#
# A shard re-runs the suite once per mutation and keeps the gate mutated for the
# whole run. Two shards sharing one file would each be testing the other's edit,
# and each would restore a different snapshot at the end -- exactly the kind of
# cross-talk the concurrent fan-out in run_release_gate_tests.sh must not have.
# Copying gives every shard a private tree, which is what makes that fan-out
# safe, and it means a killed shard can never leave the developer's worktree
# mutated.
mkdir -p "${WORK}/tree"
cp -R "${SOURCE_ROOT}/scripts" "${WORK}/tree/scripts"

ROOT_DIR="${WORK}/tree"
SUITE="${ROOT_DIR}/scripts/tests/macos_release_artifact_smoke_test.sh"
GATE="${ROOT_DIR}/scripts/macos_release_artifact_smoke.sh"

for required in "${SUITE}" "${GATE}"; do
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

# apply <file> <old> <new> -- replace exactly one occurrence, then read the
# file back and confirm it now says what was intended. Writing a file is not
# evidence that the file contains the intended text.
apply() {
  python3 - "$1" "$2" "$3" <<'PYTHON'
import sys

path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, encoding="utf-8") as handle:
    text = handle.read()
count = text.count(old)
if count != 1:
    print(
        f"expected exactly one occurrence, found {count}: {old[:70]!r}",
        file=sys.stderr,
    )
    sys.exit(3)
with open(path, "w", encoding="utf-8") as handle:
    handle.write(text.replace(old, new))
PYTHON
}

# preflight <file> -- refuse a mutation that leaves the file unparseable.
preflight() {
  local out
  if ! out="$(bash -n "$1" 2>&1)"; then
    printf 'the mutated file no longer parses: %s\n' "${out}" >&2
    return 1
  fi
  return 0
}

# fail_lines_name <needle> <output> -- true when a FAIL line names the needle.
#
# Matched against the FAIL lines only. The needle is an assertion's own name and
# the suite prints it on both the `ok` and the `FAIL` line, so a whole-output
# search finds the pass line for the assertion under test and would score any
# unrelated red as a hit.
fail_lines_name() {
  grep -E '^[[:space:]]*FAIL ' <<<"$2" | grep -Fq "$1"
}

# The number of passing assertions a suite run claimed. Used as the liveness
# signal: a harness that only ever checked the exit status would accept a suite
# that failed immediately, and "everything is broken" would score as "every
# mutation bites".
pass_count() {
  grep -Eo '[0-9]+ passed' <<<"$1" | head -1 | grep -Eo '[0-9]+' || printf 0
}

# MIN_MUTATIONS is a lower bound, not a target. Without it a future edit that
# deletes a mutation, or a shard filter that matches nothing, would let the
# harness report success over a smaller -- or empty -- set: a silent shrink must
# never read as a pass. DECLARED_MUTATIONS counts every declaration before any
# shard filtering, so a shard that runs zero mutations and an unsharded run that
# lost one are both caught.
MIN_MUTATIONS=45
DECLARED_MUTATIONS=0

MUTATIONS_RUN=0
MUTATIONS_BITING=0
MUTATION_INDEX=0
mismatches=()

# Per-mutation knobs, set around the mutate() call that needs them.
# MUTATE_ENV  extra environment for the suite run, e.g. a forced-failure lever.
# MUTATE_RC   the exit status the mutated suite is EXPECTED to produce. It is 1
#             for every mutation that breaks the gate, because a gate that
#             accepts a broken artifact makes the suite fail an assertion. It is
#             0 for exactly one mutation -- the one that removes the suite's own
#             `exit 1` -- where a zero exit is the symptom being demonstrated.
MUTATE_ENV=""
MUTATE_RC=1

# mutate <name> <needle> <old> <new>
#
# Mutations that break the *suite* are applied to the suite file; the rest break
# the gate. Both are restored afterwards.
mutate() {
  local name="$1" needle="$2" old="$3" new="$4"
  local target="${GATE}"
  # A mutation aimed at the suite itself names a suite file explicitly.
  if [[ "${old}" == "@suite:"* ]]; then
    target="${SUITE}"
    old="${old#@suite:}"
    new="${new#@suite:}"
  fi
  local index=${MUTATION_INDEX}
  MUTATION_INDEX=$((MUTATION_INDEX + 1))
  # Counted before MODE_LIST and before the shard filter: every declaration is
  # counted on every invocation so the floor sees the full set, not the shard's.
  DECLARED_MUTATIONS=$((DECLARED_MUTATIONS + 1))

  if [[ -n "${MODE_LIST}" ]]; then
    printf '%s | %s\n' "${name}" "${needle}"
    return
  fi

  # Shard selection. The index is captured above, before MODE_LIST, so a mutation
  # keeps its index -- and therefore its shard -- on every run and in every mode.
  # The driver always spawns every shard 0..N-1, so the union is the full set.
  if (( index % SHARDS != SHARD )); then
    return
  fi

  MUTATIONS_RUN=$((MUTATIONS_RUN + 1))

  if ! apply "${target}" "${old}" "${new}" 2>"${WORK}/apply.err"; then
    # An empty reason here is not cosmetic. apply() reports *why* it could not
    # substitute the needle, and reading that reason is the only way to tell a
    # genuine drift (the anchor moved, so this mutation needs re-anchoring) from
    # a broken run (the tree this file lives in has been removed underneath us).
    # The second case previously printed `COULD NOT APPLY -- ` with nothing after
    # it and was indistinguishable from the first, which is how a killed shard
    # managed to look like four mutations that do not bite. A reason we cannot
    # read is therefore itself a hard error, not a per-mutation note.
    local reason
    reason="$(tr '\n' ' ' <"${WORK}/apply.err" 2>/dev/null || true)"
    if [[ -z "${reason// /}" ]]; then
      printf 'FATAL: %s could not be applied and apply.err is missing or empty.\n' "${name}" >&2
      printf '       The private tree %s is gone, so this run cannot say which\n' "${WORK}"
      printf '       mutations bit. Re-run the shard; do not read this as a result.\n' >&2
      exit 3
    fi
    mismatches+=("${name}: COULD NOT APPLY -- ${reason}")
    restore
    return
  fi
  if ! preflight "${target}"; then
    mismatches+=("${name}: INVALID MUTATION -- it breaks the file under test, so a red suite would prove nothing")
    restore
    return
  fi
  if [[ -n "${MODE_VERIFY_ONLY}" ]]; then
    MUTATIONS_BITING=$((MUTATIONS_BITING + 1))
    printf '  applies  %s\n' "${name}"
    restore
    return
  fi

  local out rc passes
  if [[ -n "${MUTATE_ENV}" ]]; then
    out="$(env "${MUTATE_ENV}" PYTHONDONTWRITEBYTECODE=1 bash "${SUITE}" 2>&1)"
  else
    out="$(PYTHONDONTWRITEBYTECODE=1 bash "${SUITE}" 2>&1)"
  fi
  rc=$?
  passes="$(pass_count "${out}")"

  # Liveness: the suite must actually have run its assertions. A mutation that
  # made the suite die before reporting anything would otherwise be scored as
  # "bit" purely because the exit status came out as expected. Half the suite's
  # assertions is a floor that a live run clears comfortably (it reports ~100)
  # and a crashed one never reaches.
  if ((passes < 50)); then
    mismatches+=("${name}: the suite stopped running (reported '${passes} passed'); it cannot be scored as biting")
    restore
    return
  fi
  if [[ ${rc} -ne ${MUTATE_RC} ]]; then
    if [[ ${MUTATE_RC} -eq 1 ]]; then
      mismatches+=("${name}: SUITE STILL PASSED (the assertion does not bite)")
    else
      mismatches+=("${name}: the suite exited ${rc}, expected ${MUTATE_RC} (the symptom was not reproduced)")
    fi
  elif ! fail_lines_name "${needle}" "${out}"; then
    # Searched against the FAIL lines and not against the whole output: a needle
    # is an assertion's name, and the suite prints that name whether the
    # assertion passed or failed. Grepping everything would find the `ok` line
    # for the very assertion under test and score a mutation that turned some
    # *other* assertion red as a hit -- which is precisely the false pass this
    # file exists to rule out.
    mismatches+=("${name}: the expected symptom did not appear: no FAIL for '${needle}'")
    mismatches+=("        saw: $(grep -E '^[[:space:]]*FAIL ' <<<"${out}" | head -3 | tr '\n' ' ')")
  else
    MUTATIONS_BITING=$((MUTATIONS_BITING + 1))
    printf '  bites  %s\n' "${name}"
  fi
  restore
}

echo "== the artifact is really the published disk image =="

# The koly trailer is what stops a truncated upload, a zip, or a Git LFS
# pointer from being "mounted". Without it the whole DMG check is theatre.
mutate "the DMG trailer signature is no longer required" \
  'a non-disk-image upload is rejected' \
  'if [[ "${trailer}" != "koly" ]]; then' \
  'if false; then'

# ...and the size floor independently, so neither check can be dropped while the
# other still holds the test.
mutate "the minimum-size floor for a disk image is removed" \
  'a truncated artifact is rejected before it is mounted' \
  'if ((size < 1024)); then' \
  'if false; then'

echo "== the image must really mount =="

# The whole branch is replaced, because a partial one does not measure anything.
# Written as `if false || ! hdiutil attach` it would be a no-op -- `false || ! cmd`
# evaluates to `! cmd`, the condition that was already there -- and the suite
# would stay green while the harness reported the mutation as proved. Replacing
# the branch instead removes the refusal: the gate then proceeds to look for an
# app bundle in a directory nothing was ever mounted into.
mutate "a .dmg that fails to mount is tolerated" \
  'a .dmg that will not mount fails the gate' \
  "if ! \"\${HDITOOL_BIN}\" attach -readonly -nobrowse -noautoopen -noverify \\
      -mountpoint \"\${MOUNT_DIR}\" \"\${artifact}\" >\"\${MOUNT_PATH}\" 2>&1; then
      cat \"\${MOUNT_PATH}\" >&2
      fail \"the .dmg could not be mounted; an unreadable or corrupted image is a release-blocking packaging failure\"
    fi" \
  "cat \"\${MOUNT_PATH}\" 2>/dev/null >&2 || true"

echo "== the bundle must be the one a user would open =="

mutate "an image with no app bundle is accepted" \
  'an image with no app bundle is rejected' \
  'if ((${#candidates[@]} == 0)); then' \
  'if false; then'

# The ambiguity refusal is a distinct property: picking one of two bundles would
# make "which artifact got gated" a function of `ls` order.
mutate "two app bundles at the image root no longer refused" \
  'an image with two app bundles is rejected rather than one being picked' \
  'if ((${#candidates[@]} > 1)); then' \
  'if false; then'

echo "== the bundle must ship what the app needs to work =="

# The #97 bug class verbatim: the bundle installs, launches, renders, and is
# useless because the daemon is missing.
mutate "a missing bundled daemon is tolerated" \
  'a bundle with no Rust daemon is rejected' \
  'if [[ ! -e "${app}/Contents/MacOS/${required}" ]]; then' \
  'if false; then'

# A dropped chmod +x is invisible to any launch test that only watches the app
# process.
mutate "a non-executable bundled daemon is tolerated" \
  'a daemon that lost its executable bit is rejected' \
  'if [[ ! -x "${app}/Contents/MacOS/${required}" ]]; then' \
  'if false; then'

# A zero-byte main executable launches to nothing, and would be indistinguishable
# from a render failure.
mutate "a zero-byte main executable is tolerated" \
  'a zero-byte main executable is rejected' \
  'if [[ ! -s "${app}/Contents/MacOS/${executable}" ]]; then' \
  'if false; then'

mutate "a bundle with no CFBundleExecutable is tolerated" \
  'an Info.plist with no CFBundleExecutable is rejected' \
  'if [[ -z "${executable}" ]]; then' \
  'if false; then'

echo "== the artifact must be runnable on the runner that gates it =="

mutate "a bundle built for another architecture is tolerated" \
  'a bundle built for an architecture this runner cannot execute fails' \
  'if ((matched == 0)); then' \
  'if false; then'

# "cannot be shown to be runnable" is not "runnable".
mutate "an unreadable Mach-O header is tolerated" \
  'a bundle whose Mach-O headers cannot be read is rejected' \
  'if ! raw="$("${LIPO_BIN}" -archs "${app}/Contents/MacOS/${binary}" 2>&1)"; then' \
  'if ! raw="$("${LIPO_BIN}" -archs "${app}/Contents/MacOS/${binary}" 2>&1)"; then :; fi; if false; then'

echo "== a quarantined download is refused, and refused before launch =="

mutate "a quarantined published bundle is tolerated" \
  'a quarantined published bundle is rejected' \
  'if ((rc == 0)) && ! is_blank "${raw}"; then' \
  'if false; then'

echo "== the display harness is proven before the app exists =="

# Attribution: a broken capture harness must never be reported as an app that
# failed to render.
mutate "a runner that cannot capture the screen is trusted anyway" \
  'a runner that cannot capture the screen fails rather than being trusted' \
  'if ! "${SCREENSHOT_BIN}" -x -o "${dest}" >/dev/null 2>&1 || [[ ! -s "${dest}" ]]; then' \
  'if false; then'

echo "== the launch must be cold, and must happen =="

mutate "an OS-level refusal to launch is tolerated" \
  'an OS-level refusal to launch fails the gate' \
  'if ((rc != 0)); then
    printf '"'"'%s\n'"'"' "open refused to launch the bundle (exit ${rc}):" >&2' \
  'if false; then
    printf '"'"'%s\n'"'"' "open refused to launch the bundle (exit ${rc}):" >&2'

# Without the cold-launch assertion, `open` would merely activate an existing
# copy and every later observation would describe a warm process.
#
# Repointed when the lsappinfo fix landed: the guard used to be a single
# `if [[ -n "${asn}" ]]`, which no longer exists. This now stops the guard firing
# at all. The other direction -- the guard firing on a reply that is not a serial
# number -- is mutation 2 further down; a guard can be wrong in each direction and
# one mutation cannot cover both.
mutate "a warm launch is accepted as a cold one" \
  'a warm launch is refused because this gate requires a cold one' \
  '  if [[ "${raw}" =~ ^ASN:0x[0-9a-fA-F]+:0x[0-9a-fA-F]+:$ ]]; then
    fail "${APP_BUNDLE_ID} is already registered' \
  '  if false; then
    fail "${APP_BUNDLE_ID} is already registered'

# ---------------------------------------------------------------------------
# The `lsappinfo` query itself. These four mutations are the record of how the
# macOS smoke gate failed in release run 37184543519: the gate aborted at the
# "already registered with the window server" check, on an app it had just
# installed, reporting a phantom instance. Three separate defects stacked:
# an undocumented verb, no shape-check on the reply, and an exit status that
# killed the gate silently. Each is listed here so none of them can come back
# unnoticed -- an assertion nobody has seen fail is a comment.
# ---------------------------------------------------------------------------

# 1. The verb. `findLSApplication` is not a thing `lsappinfo` answers; on the
#    26.6.2 runner it replies `Unrecognized command: findLSApplication` on
#    *stdout*. The gate read that error text as a serial number and refused to
#    launch an app that was not running.
#
#    The needle is a plain `expect_pass`, because that is what this mutation
#    breaks: with the verb reverted, the reply is unparseable on the *healthy*
#    path too, so the gate fails before it ever launches and every scenario that
#    expects a pass reports a failure instead.
mutate "the lsappinfo query reverts to the undocumented verb" \
  'mounts the published .dmg, cold-launches, renders and passes' \
  '"${LSAPPINFO_BIN}" find "bundleid=${APP_BUNDLE_ID}" 2>/dev/null' \
  '"${LSAPPINFO_BIN}" findLSApplication "=${APP_BUNDLE_ID}" 2>/dev/null'

# 2. No shape-check. Even with the right verb, `lsappinfo` writes some errors to
#    stdout, so a query it declines is indistinguishable from an ASN unless the
#    reply is matched. Without the match, an unanswerable window server is
#    reported as "already running" -- the exact failure mode of the release run,
#    and the one that sends an operator to kill a process that does not exist.
#
#    The regex is weakened to `.`, not the branch deleted, and that distinction is
#    the whole point. Deleting the branch does NOT reproduce the defect: an
#    unparseable reply would then fall through to the "cannot tell whether" failure,
#    which still refuses and still tells the operator the truth. The defect only
#    exists when something *claims* the reply is a serial number, so the mutation
#    has to make it claim that. A mutation that passes here would have looked like
#    coverage of this assertion while testing nothing.
mutate "an unparseable lsappinfo reply is claimed to be a serial number" \
  'an unanswerable window server is not reported as a warm app' \
  '  if [[ "${raw}" =~ ^ASN:0x[0-9a-fA-F]+:0x[0-9a-fA-F]+:$ ]]; then
    fail "${APP_BUNDLE_ID} is already registered' \
  '  if [[ "${raw}" =~ . ]]; then
    fail "${APP_BUNDLE_ID} is already registered'

# 3. `lsappinfo_asn`'s own filter. Unreachable from the scenarios, because
#    `assert_nothing_already_running` refuses the gate before `lsappinfo_asn` is
#    ever called -- which is exactly why it needed its own unit assertions, and
#    why this mutation is here: without them, deleting the filter would be
#    invisible. The needle is one of those unit assertions.
mutate "lsappinfo_asn passes any reply through unfiltered" \
  'lsappinfo_asn drops a rejected query instead of passing it on' \
  '  if [[ "${LSAPPINFO_RAW}" =~ ^ASN:0x[0-9a-fA-F]+:0x[0-9a-fA-F]+:$ ]]; then
    printf '"'"'%s\n'"'"' "${LSAPPINFO_RAW}"' \
  '  if true; then
    printf '"'"'%s\n'"'"' "${LSAPPINFO_RAW}"'

# 4. The exit status discarded again. `lsappinfo` exits non-zero for a query it will
#    not answer, and `|| true` collapsed that into the same empty reply a genuinely
#    not-running app produces -- so the cold-launch check passed precisely when it
#    had not been performed. This is the fail-open the review found, and the needle
#    is the assertion that a *silent* non-zero exit is refused rather than read as
#    absence. Deliberately a different knob from the garbage-answer cases: the fake
#    has `LSAPPINFO_ANSWER=garbage` for a refusal that prints text, and this
#    mutation must be caught by the case that prints nothing at all.
mutate "the lsappinfo exit status is discarded into an empty reply again" \
  'an unanswerable window server fails rather than proving a cold launch' \
  '  out="$("${LSAPPINFO_BIN}" find "bundleid=${APP_BUNDLE_ID}" 2>/dev/null)" || rc=$?' \
  '  out="$("${LSAPPINFO_BIN}" find "bundleid=${APP_BUNDLE_ID}" 2>/dev/null || true)"'

# 4b. The fail-closed branch itself removed. Mutation 4 alone is not enough coverage
#     of it: that mutation still *computes* rc, it just stops consulting it. This
#     one deletes the refusal, so a silent non-zero exit has no path to a red gate.
mutate "the unanswerable-window-server refusal is deleted" \
  'an unanswerable window server fails rather than proving a cold launch' \
  '    if ((LSAPPINFO_RC != 0)); then
      fail "could not ask the window server' \
  '    if false; then
      fail "could not ask the window server'

# 4c. The refusal demoted to a warning: the same lost guarantee as 4b, reached a
#     different way -- the gate carries on without having proven a cold launch.
mutate "the unanswerable-window-server refusal is downgraded to a warning" \
  'an unanswerable window server fails rather than proving a cold launch' \
  '      fail "could not ask the window server' \
  '      log "could not ask the window server'

# 4d. The status-bearing call put back inside a command substitution. Not
#     hypothetical: the first version of this fix did exactly that, the assignment
#     died with the subshell, and the gate went red on every single run. If the
#     globals stop surviving the call, no caller can read a status at all.
mutate "the lsappinfo status is read inside a command substitution (subshell)" \
  'an unanswerable window server fails rather than proving a cold launch' \
  '  lsappinfo_query
  raw="${LSAPPINFO_RAW}"' \
  '  raw="$(lsappinfo_query)"
  LSAPPINFO_RAW="${raw}"'

# 4e. The gate kills a process before the cold launch. The gate'"'"'s own comments
#     insist it never does -- terminating a stray instance would make the check pass
#     without the launch being cold -- and before the pkill fake existed the suite
#     could not have caught this at all, because nothing in the farm recorded it.
mutate "the gate kills a process before the cold launch" \
  'the gate never kills a process before the cold launch' \
  'assert_nothing_already_running() {' \
  'pkill -f "${APP_BUNDLE_ID}" || true
assert_nothing_already_running() {'

# 5. Backticks in the diagnostic. The refusal message quoted the `open` command
#    inside a double-quoted string, so bash executed `open` with no arguments
#    while assembling the message -- printing the real tool's usage dump into the
#    CI log immediately above the failure. The gate was correct and the evidence
#    was a lie about what it had run.
#
#    Asserted by observing the fake rather than by grepping the source, so it
#    also catches the same substitution anywhere else in the message.
mutate "the cold-launch refusal executes open while writing its own message" \
  'the already-running refusal does not invoke open' \
  "and 'open' would only activate it" \
  'and `open` would only activate it'

# A process that dies on start never reaches the window server.
mutate "an app that dies on launch is tolerated" \
  'an app that dies on launch fails' \
  '"${LAUNCH_TIMEOUT_SECONDS}" app_is_registered ||' \
  '"${LAUNCH_TIMEOUT_SECONDS}" true ||'

echo "== a window must exist, be on screen, and be a real UI =="

# This is the check that stops a running-but-windowless app from sailing through
# on a full-screen capture of the desktop behind it.
mutate "an app with no window is accepted" \
  'an app that runs with no window at all fails' \
  'if [[ "${VISIBLE}" == "1" && ( -z "${HIDDEN}" || "${HIDDEN}" == "0" ) ]]; then' \
  'if true; then'

# A HIDDEN app with a window id is the dangerous combination: the id must not buy
# a pass, because the capture behind a hidden app is the desktop.
mutate "a hidden window is accepted when a window id is present" \
  'an app whose window is hidden fails even though it reports a window id' \
  'if [[ "${HIDDEN}" == "1" ]]; then' \
  'if false; then'

# A 16x16 window is what a crashing Flutter engine produces.
mutate "the minimum window size floor is removed" \
  'a window below the size floor is not accepted as a rendered UI' \
  'if ((width >= MIN_WINDOW_POINTS && height >= MIN_WINDOW_POINTS)); then' \
  'if true; then'

# Re-checking the window inside the render loop is what stops a window that
# appeared and then hid from satisfying the gate.
mutate "the window is no longer re-checked inside the render loop" \
  'a window that disappears before the frame is judged fails' \
  'if ! window_is_present; then' \
  'if false; then'

echo "== the frame must be complex AND stable =="

# The complexity threshold is the only thing distinguishing "rendered" from "a
# solid blank", so it is the first thing a lazy gate drops.
mutate "the frame complexity threshold is not enforced" \
  'a frame just under the complexity threshold is rejected' \
  'if [[ "${colors}" =~ ^[0-9]+$ ]] && ((colors >= MIN_DISTINCT_COLORS)); then' \
  'if true; then'

# Stability is the second half of the same judgement: a screen caught
# mid-transition is complex but not settled.
mutate "the first complex frame is accepted without requiring stability" \
  'a frame that never settles fails the gate' \
  'if ((stable_captures >= 1)); then' \
  'if ((stable_captures >= 0)); then'

# A silent downgrade from "the app's window" to "whatever is on the desktop" is
# the quiet that turns a gate into a comment. This removes the announcement that
# a window-scoped capture failed and the frame came from the whole screen; the
# suite's guard on *that* announcement is 'a window-scoped capture that fails
# falls back and says so', which is the assertion the needle must name.
mutate "the full-screen capture fallback is taken silently" \
  'a window-scoped capture that fails falls back and says so' \
  'log "${CAPTURE_FALLBACK_REASON}; falling back to a full-screen capture (the window assertion still gates this frame)"' \
  'true'

# ...and the same quiet on the path that never had a window id to begin with:
# there the full-screen capture is the *primary* answer, not a downgrade, so the
# verdict must still name that scope or "whatever is on the desktop" reads like
# the app's own frame. This is the assertion the mutation above used to name.
mutate "the full-screen capture is not identified as such" \
  'the full-screen fallback is announced in the log, not taken silently' \
  'log "settled app frame (${scope} capture): ${colors}+ distinct colours, identical across two consecutive captures"' \
  'log "settled app frame: ${colors}+ distinct colours, identical across two consecutive captures"'

echo "== crash detection must actually look =="

# This is the #97 false pass on this platform: "found nothing" in a directory
# that was never read is the absence of a question. The replacement drops the
# `return 1` and keeps the diagnostic, so what is being removed is the refusal,
# not the message -- replacing the whole block with a bare `return 1` removes
# only the message and the suite correctly stays green.
mutate "an unreadable crash-report directory reports clean" \
  'an unreadable crash-report directory fails rather than reporting clean' \
  'if ((rc != 0)); then
      printf '"'"'could not list crash reports in %s (find exit %s)\n'"'"' "${dir}" "${rc}" >&2
      return 1
    fi' \
  'if ((rc != 0)); then
      printf '"'"'could not list crash reports in %s (find exit %s)\n'"'"' "${dir}" "${rc}" >&2
    fi'

# A runner on which no report directory exists has not been shown to have a
# working reporting path.
mutate "a missing crash-report directory reports clean" \
  'a runner with no crash-report directory fails rather than reporting clean' \
  'if [[ -d "${dir}" ]]; then' \
  'if [[ -d "${dir}" ]] || true; then'

# The body filter is what stops a same-named helper from failing the release.
mutate "the crash-report body filter is dropped" \
  "a same-prefix helper's crash report is not mistaken for the app's" \
  'if grep -qF "${APP_EXECUTABLE}" "${report}" 2>/dev/null; then' \
  'if true; then'

echo "== a missing tool is never a skip =="

mutate "a missing hdiutil is skipped instead of failing" \
  'a missing hdiutil fails the gate rather than skipping the mount' \
  'require_tool "${HDITOOL_BIN}"' \
  ': "${HDITOOL_BIN}"'

# The crash check must be wired to the real report directories at all: if the
# gate searched a directory that does not contain reports, "no crashes" would be
# vacuously true on every runner.
mutate "crash detection is never invoked" \
  'an unreadable crash-report directory fails rather than reporting clean' \
  'assert_no_crash_reports "${marker}"' \
  ':'

echo "== the evidence must be readable and machine-independent =="

# Without the verdict line, a run that died half-way and a run that passed would
# produce indistinguishable evidence.
mutate "the summary records no verdict" \
  'the summary records the verdict' \
  "printf 'result: PASS\\n'" \
  "printf 'result: UNKNOWN\\n'"

# An empty digest field is a claim a reader cannot check.
mutate "the artifact digest is recorded as an empty field" \
  'the summary records the exact artifact digest' \
  "printf 'artifact sha256: %s\\n' \"\$(artifact_digest \"\${artifact}\")\"" \
  "printf 'artifact sha256: \\n'"

# Absolute runner paths make evidence incomparable across machines.
mutate "evidence records absolute runner paths" \
  'summary paths are workspace-relative when inside the workspace' \
  'if [[ -n "${workspace}" && "${path}" == "${workspace}/"* ]]; then' \
  'if false; then'

echo "== the PNG complexity decoder is real =="

# The decoder is the one piece of real logic in the gate. If it accepted
# anything, "rendered" would mean "the screenshot tool returned".
mutate "the PNG decoder accepts a solid frame as complex" \
  'the just-under-threshold fixture really is under it, so the threshold is a real bar' \
  'print(len(seen))
PY' \
  'print(max(len(seen), 64))
PY'

# ...and it must still reject a non-PNG, or a failed capture would be counted as
# a rendered frame.
# Pointed at the corrupted-signature fixture rather than at `garbage.png`.
# Mutating only the signature check leaves a genuinely non-PNG file rejected as
# an unsupported header, so an assertion aimed at `garbage.png` stays green and
# this mutation measures nothing. `badsig.png` is a valid image in every other
# respect, so the signature is the only thing that can refuse it.
mutate "the PNG decoder stops rejecting non-PNG input" \
  'a PNG whose signature is corrupted is rejected on the signature alone' \
  'if data[:8] != b"\x89PNG\r\n\x1a\n":
    sys.exit("not a PNG file")' \
  'if False:
    sys.exit("not a PNG file")'

echo "== the suite itself must still be running =="

# Two mutations against the suite rather than the gate. If either of these could
# turn the suite green or make it silently assert nothing, then every mutation
# above would have been measuring the harness rather than the gate.
#
# The first removes the `exit 1` on failure. With MACOS_SMOKE_SUITE_FORCE_FAIL=1
# the suite then has a real failing assertion and still exits 0 -- which is
# precisely the defect this harness was written to catch, reproduced on purpose.
# `expect_rc 0` is not a relaxation: for this one mutation a zero exit IS the
# symptom, and asserting it is what proves the exit block was load-bearing rather
# than decorative.
MUTATE_ENV=MACOS_SMOKE_SUITE_FORCE_FAIL=1
MUTATE_RC=0
mutate "the suite stops requiring a non-zero exit on failure" \
  'forced failure, requested by MACOS_SMOKE_SUITE_FORCE_FAIL=1' \
  '@suite:if ((FAIL_COUNT > 0)); then
  exit 1
fi
exit 0' \
  '@suite:if ((FAIL_COUNT > 0)); then
  :
fi
exit 0'
MUTATE_ENV=
# This one exits 0 on purpose, and the zero exit IS the symptom: the counter the
# suite would derive a non-zero status from is the very thing the mutation
# disabled, so `bad` cannot move FAIL_COUNT below it either. The suite still
# notices in-process -- the needle is its own counter assertion -- and that is
# what the harness checks here. Expecting rc=1 would be expecting the suite to
# exit on a counter it no longer has.
MUTATE_RC=0

# A `bad` that stopped counting is the same defect from the other side: the suite
# would print failures and exit 0. The needle is the suite's own assertion about
# its counters, so this one is caught in-process rather than by exit status.
mutate "the suite no longer counts a failure" \
  "the suite's own counters move when an assertion is recorded" \
  '@suite:  FAIL_COUNT=$((FAIL_COUNT + 1))' \
  '@suite:  FAIL_COUNT=$((FAIL_COUNT + 0))'
MUTATE_RC=1

restore

if [[ -n "${MODE_LIST}" ]]; then
  exit 0
fi

if [[ -n "${MODE_VERIFY_ONLY}" ]]; then
  echo
  if ((${#mismatches[@]} > 0)); then
    printf 'anchors: %d checked, %d broken\n' "${MUTATIONS_RUN}" "${#mismatches[@]}" >&2
    printf '  - %s\n' "${mismatches[@]}" >&2
    exit 1
  fi
  printf 'anchors: all %d mutations still apply, and every mutated file still parses\n' \
    "${MUTATIONS_RUN}"
  exit 0
fi

final_out="$(PYTHONDONTWRITEBYTECODE=1 bash "${SUITE}" 2>&1)"
final_rc=$?
echo
if [[ ${final_rc} -ne 0 ]]; then
  mismatches+=("restoring the originals did not return the suite to green")
  printf '%s\n' "${final_out}" | grep -E '^[[:space:]]*FAIL ' | head -5 | sed 's/^/        /' >&2
fi

printf 'mutations: %d run, %d bit, declared: %d (floor %d), suite after restore: %s\n' \
  "${MUTATIONS_RUN}" "${MUTATIONS_BITING}" \
  "${DECLARED_MUTATIONS}" "${MIN_MUTATIONS}" \
  "$(grep -E '^[0-9]+ passed' <<<"${final_out}" || echo 'no summary')"

if ((DECLARED_MUTATIONS < MIN_MUTATIONS)); then
  mismatches+=("the harness declared ${DECLARED_MUTATIONS} mutations, below the floor of ${MIN_MUTATIONS}")
fi
if ((SHARDS > 1)) && ((MUTATIONS_RUN == 0)); then
  mismatches+=("shard ${SHARD} of ${SHARDS} ran zero mutations")
fi

if ((${#mismatches[@]} > 0)); then
  printf '\nNON-BITING / WRONG-RED / INVALID MUTATIONS (%d):\n' "${#mismatches[@]}" >&2
  printf '  - %s\n' "${mismatches[@]}" >&2
  exit 1
fi
printf 'all %d mutations bit\n' "${MUTATIONS_RUN}"
