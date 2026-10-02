#!/usr/bin/env bash
#
# Mutation pass for scripts/tests/tests_wiring_test.sh.
#
# The wiring check is the newest suite in the repository and it guards a property
# that has silently failed three times here already: a suite that is NAMED rather
# than RUN. A check like that is precisely the kind that reads as proof on a pull
# request, so it gets a mutation pass of its own instead of being trusted because
# it is green.
#
# Every mutation must be caught BY NAME. "The suite exited non-zero" is not a
# result; a specific assertion going red is. `needle_matches` scopes to everything
# the suite said except its passing verdicts, and a wrong-red is reported as a
# failure.
#
# Two guards exist because both failure modes below were hit while writing this
# file, and both look like coverage:
#
#   * `preflight` rejects a mutation that leaves the mutated file unparseable. A
#     mutation which breaks the code under test measures nothing, and it reads as a
#     legitimate red: the first version of the "matcher stops matching" mutation
#     ate a newline, swallowed `re.compile(` into a shell comment, and turned the
#     suite red for a reason that had nothing to do with the matcher.
#   * `needle_matches` requires a named assertion. A red suite with the wrong
#     assertion red is a false pass wearing a failure's clothes.
#
# The matcher probes exist because of the sharpest lesson in this file's history:
# a matcher that accepts any bare path satisfies every suite from the ShellCheck
# argument list -- which is itself a `run:` block -- and reports a clean run. The
# per-suite verdicts cannot detect that, so it is pinned by probes that state the
# expected answer next to each synthetic command.
set -uo pipefail

ROOT_DIR="${PO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SUITE="${ROOT_DIR}/scripts/tests/tests_wiring_test.sh"
CI="${ROOT_DIR}/.github/workflows/ci.yml"
PROJECT="${ROOT_DIR}/.github/workflows/project.yml"
DRIVER="${ROOT_DIR}/scripts/tests/run_release_gate_tests.sh"
MAKEFILE="${ROOT_DIR}/Makefile"
TESTS_DIR="${ROOT_DIR}/scripts/tests"

WORK="$(mktemp -d)"
trap 'restore; rm -rf "${WORK}"' EXIT

cp "${CI}" "${WORK}/ci.orig"
cp "${PROJECT}" "${WORK}/project.orig"
cp "${DRIVER}" "${WORK}/driver.orig"
cp "${MAKEFILE}" "${WORK}/make.orig"
cp "${SUITE}" "${WORK}/suite.orig"

restore() {
  cp "${WORK}/ci.orig" "${CI}"
  cp "${WORK}/project.orig" "${PROJECT}"
  cp "${WORK}/driver.orig" "${DRIVER}"
  cp "${WORK}/make.orig" "${MAKEFILE}"
  cp "${WORK}/suite.orig" "${SUITE}"
  rm -f "${SCRATCH_SUITE:-}"
}

# apply <file> <old> <new> -- replace exactly one occurrence, then read the file
# back and confirm it now says what was intended. Writing a file is not evidence
# that the file contains the intended text.
#
# The old and new texts are passed as separate arguments and may contain literal
# newlines. An earlier version took a single `old|||new` argument and unescaped
# `\n` inside it, which is where the eaten-newline mutation above came from: the
# convention had to be remembered at every call site, and one site that got it
# wrong produced a mutation that was wrong in a way nothing downstream detected.
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

# preflight <file> -- fail if the mutation left the file unparseable.
#
# For a shell script that means `bash -n`. For the wiring suite it also means the
# embedded Python must compile, because the suite is bash that runs a Python
# heredoc: a Python syntax error there produces a red suite that has said nothing
# about the property under test. For a workflow it means the YAML still loads.
preflight() {
  local file="$1" out rc
  case "${file}" in
  *.yml | *.yaml)
    if ! out="$(python3 -c '
import sys
import yaml
yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
' "${file}" 2>&1)"; then
      printf 'the workflow no longer parses: %s\n' "${out}" >&2
      return 1
    fi
    ;;
  *)
    if ! out="$(bash -n "${file}" 2>&1)"; then
      printf 'the shell script no longer parses: %s\n' "${out}" >&2
      return 1
    fi
    if [[ "${file}" == "${SUITE}" ]]; then
      if ! out="$(python3 - "${file}" <<'PYTHON' 2>&1
import sys

lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
try:
    start = next(i for i, l in enumerate(lines) if l.rstrip().endswith("<<'PYTHON'"))
    end = next(i for i, l in enumerate(lines) if i > start and l.rstrip() == "PYTHON")
except StopIteration:
    sys.exit("no python heredoc found")
compile("\n".join(lines[start + 1 : end]), sys.argv[1], "exec")
PYTHON
      )"; then
        printf 'the embedded python no longer compiles: %s\n' "${out}" >&2
        return 1
      fi
    fi
    ;;
  esac
  return 0
}

# Everything the suite said except its passing verdicts: the FAIL lines, their
# detail lines, and the parser's own diagnostics. A FAIL line is a symptom;
# "the invocation matcher is wrong" is the cause, and it is the more precise
# evidence, so parser messages are read here too.
#
# `grep -c` rather than `grep -q` on purpose. `grep -q` exits on its first match,
# which SIGPIPEs the upstream `grep -v`; under `set -o pipefail` that turns a
# successful match into a non-zero pipeline, and whether it happens depends on
# whether the writer finished before the reader exited. That is a race, and it
# made two mutations here report as non-biting when the assertion they targeted had
# in fact gone red. `grep -c` consumes all of its input, so there is no early exit
# and no signal, and its exit status means exactly "did anything match".
needle_matches() {
  grep -vE '^  ok ' <<<"$1" | grep -cF -- "$2" >/dev/null
}

mutate() {
  local name="$1" file="$2" old="$3" new="$4" needle="$5"
  MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
  restore
  local line
  if ! line="$(apply "${file}" "${old}" "${new}" 2>&1)"; then
    mismatches+=("${name}: could not apply the mutation (${line})")
    restore
    return
  fi
  if ! preflight "${file}"; then
    mismatches+=("${name}: INVALID MUTATION -- it breaks the file under test, so a red suite would prove nothing")
    restore
    return
  fi
  local out rc
  out="$(PYTHONDONTWRITEBYTECODE=1 bash "${SUITE}" 2>&1)"
  rc=$?
  if [[ ${rc} -eq 0 ]]; then
    mismatches+=("${name}: SUITE STILL PASSED (the assertion does not bite)")
  elif ! needle_matches "${out}" "${needle}"; then
    mismatches+=("${name}: went red but not on '${needle}'")
    mismatches+=("        line ${line}; saw: $(grep -E '^  FAIL ' <<<"${out}" | head -3 | tr '\n' ' ')")
  else
    MUTATIONS_BITING=$((MUTATIONS_BITING + 1))
    printf '  bites  %s\n' "${name}"
  fi
  restore
}

MUTATIONS_RUN=0
MUTATIONS_BITING=0
mismatches=()

echo "== a suite that stops being run must be caught =="

# The real-world shapes, in the order this repository hit them.

# 1. The run body is commented out while the step label still names the suite. The
#    `run:` here is a scalar, so the replacement has to become a block for the shape
#    to be faithful.
mutate "a suite's run body is commented out, its step label intact" \
  "${CI}" \
  '        run: bash scripts/tests/required_checks_test.sh' \
  '        run: |
          # bash scripts/tests/required_checks_test.sh' \
  "required_checks_test.sh is executed by a CI step"

# 2. The run line is deleted outright, leaving the suite alive only in the
#    ShellCheck argument list. That list is itself a `run:` block naming every
#    script it lints, and it is what defanged two assertions in this repository.
mutate "a suite survives only in the ShellCheck argument list" \
  "${CI}" \
  '          bash scripts/tests/suites_offline_test.sh' \
  '' \
  "suites_offline_test.sh is executed by a CI step"

# 3. A suite wired only through the Makefile is a suite nobody reads before a
#    merge, and the check calls that out separately from "not wired at all".
mutate "a suite keeps its Makefile target but loses its workflow step" \
  "${PROJECT}" \
  '          bash scripts/tests/project_board_workflow_test.sh' \
  '' \
  "project_board_workflow_test.sh is run by a workflow, not only by the Makefile"

echo "== the driver is a workflow site only if a workflow runs it =="

mutate "a suite is dropped from the release-gate driver's array" \
  "${DRIVER}" \
  '  apksigner_gate_test.sh' \
  '' \
  "apksigner_gate_test.sh is executed by a CI step"

# The array emptied, so the loop has nothing left to iterate.
# The whole SUITES array is emptied, so the assertion that fires is whichever
# suite happens to sort first, not this one specifically. Naming one suite in the
# needle would be asserting an accident of list order; the property under test is
# that the driver stops executing suites at all, and "is executed by a CI step"
# is what that looks like from outside.
mutate "the release-gate driver's suite list is emptied" \
  "${DRIVER}" \
  'SUITES=(
  release_workflow_test.sh
  android_release_signing_test.sh
  apksigner_gate_test.sh
  android_release_artifact_smoke_test.sh
  linux_release_artifact_smoke_test.sh
)' \
  'SUITES=()' \
  "is executed by a CI step"

# The driver itself stops being run, so the four suites it loops over silently stop
# being in a required check.
mutate "no workflow invokes the release-gate driver" \
  "${CI}" \
  '        run: bash scripts/tests/run_release_gate_tests.sh' \
  '        run: bash -c true' \
  "the release-gate driver is invoked by a workflow"

echo "== the matcher must not be defeatable =="

# A matcher that matches nothing makes every per-suite verdict vacuously false. The
# suite's own guard fires before any verdict is printed, so the needle is the
# guard's message rather than a probe: it is the most specific thing available.
mutate "the invocation matcher stops matching anything" \
  "${SUITE}" \
  '
INVOCATION = re.compile(
    r"(?:^|[\s;&|(])(?:bash|sh|zsh|dash|ksh|env|source|\./)\s+"' \
  '
INVOCATION = re.compile(
    r"(?:^|[\s;&|(])(?:nonesuch|alsononesuch)\s+"' \
  "NO SUITE FOUND EXECUTED BY ANY STEP"

# A matcher that accepts a bare path is the original defect, in the exact form it
# took: satisfied by the ShellCheck argument list.
#
# The mutation makes the interpreter token optional. Adding an alternative to the
# token's alternation is NOT the same thing and was tried first: the alternation is
# followed by `\s+` and then an optional directory component, so an extra
# alternative consumes the directory and then finds no whitespace after it. That
# version compiles, runs, and leaves every verdict unchanged -- green in both
# directions, which is worse than a mutation that refuses to apply, because it looks
# like coverage.
mutate "the invocation matcher accepts a bare path" \
  "${SUITE}" \
  '
INVOCATION = re.compile(
    r"(?:^|[\s;&|(])(?:bash|sh|zsh|dash|ksh|env|source|\./)\s+"' \
  '
INVOCATION = re.compile(
    r"(?:^|[\s;&|(])(?:bash|sh|zsh|dash|ksh|env|source|\./)?\s*"' \
  "matcher probe: a suite in the ShellCheck argument list"

# Comment stripping is what makes "named in a comment" a non-execution, and it is
# load-bearing in three places rather than one. The named assertion that catches it
# is the comment probe. The no-op-substitution check further down fires too, so
# naming that here would be a wrong-red.
mutate "comments are no longer stripped from step commands" \
  "${SUITE}" \
  '    kept = []
    for line in text.splitlines():' \
  '    return text
    kept = []
    for line in text.splitlines():' \
  "matcher probe: a suite named only in a shell comment"

echo "== the count tripwire =="

# KNOWN_SUITE_COUNT exists so that adding or deleting a suite is a diff rather than
# a silent loss of coverage, and a scratch suite is enough to prove it bites.
#
# Worth being explicit about why this is separate from the shell-versus-python count
# comparison in the suite: the shell globs the directory and the parser lists it,
# so those two can never disagree about a file that exists. A comparison that cannot
# fail is worse than none, because it reads as one. The recorded constant is the
# thing that can actually go stale.
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
restore
SCRATCH_SUITE="${TESTS_DIR}/zz_scratch_mutation_probe_test.sh"
printf '#!/usr/bin/env bash\nexit 0\n' >"${SCRATCH_SUITE}"
out="$(PYTHONDONTWRITEBYTECODE=1 bash "${SUITE}" 2>&1)"
rc=$?
rm -f "${SCRATCH_SUITE}"
SCRATCH_SUITE=""
if [[ ${rc} -eq 0 ]]; then
  mismatches+=("a suite is added without updating the recorded count: SUITE STILL PASSED")
elif ! needle_matches "${out}" "the step parser produced verdicts"; then
  mismatches+=("a suite is added without updating the recorded count: went red but not on the parser failure")
  mismatches+=("        saw: $(grep -E '^  FAIL ' <<<"${out}" | head -3 | tr '\n' ' ')")
else
  MUTATIONS_BITING=$((MUTATIONS_BITING + 1))
  printf '  bites  %s\n' "a suite is added without updating the recorded count"
fi
restore

echo "== compound: reading only one wiring site =="

# A check that reads ci.yml and nothing else reports the suites that canary.yml,
# project.yml, the Makefile and the driver run as unrun -- a confident false
# failure, which is the same class of error the check exists to catch. Two halves
# are required: dropping the workflow scan alone is masked by the Makefile, which
# duplicates a site for almost every suite, and dropping the Makefile alone is
# masked by the workflows.
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
restore
compound="the check stops reading every wiring site but one"
if ! apply "${SUITE}" \
  'for name in sorted(os.listdir(workflows_dir)):' \
  'for name in ["ci.yml"]:' >/dev/null 2>&1; then
  mismatches+=("${compound}: could not apply the workflow-scan half")
elif ! apply "${SUITE}" \
  '    add("Makefile", strip_comments(handle.read()))' \
  '    pass' >/dev/null 2>&1; then
  mismatches+=("${compound}: could not apply the Makefile half")
elif ! preflight "${SUITE}"; then
  mismatches+=("${compound}: INVALID MUTATION -- it breaks the file under test")
else
  out="$(PYTHONDONTWRITEBYTECODE=1 bash "${SUITE}" 2>&1)"
  if [[ $? -eq 0 ]]; then
    mismatches+=("${compound}: SUITE STILL PASSED")
  elif ! needle_matches "${out}" "canary_mutation_test.sh is executed by a CI step"; then
    mismatches+=("${compound}: went red but not on the expected suite")
    mismatches+=("        saw: $(grep -E '^  FAIL ' <<<"${out}" | head -3 | tr '\n' ' ')")
  else
    MUTATIONS_BITING=$((MUTATIONS_BITING + 1))
    printf '  bites  %s\n' "${compound}"
  fi
fi
restore

restore
final_out="$(PYTHONDONTWRITEBYTECODE=1 bash "${SUITE}" 2>&1)"
final_rc=$?
echo
if [[ ${final_rc} -ne 0 ]]; then
  mismatches+=("restoring the originals did not return the suite to green")
  printf '%s\n' "${final_out}" | tail -5 | sed 's/^/        /' >&2
fi

printf 'mutations: %d run, %d bit, suite after restore: %s\n' \
  "${MUTATIONS_RUN}" "${MUTATIONS_BITING}" \
  "$(grep -E '^[[:space:]]*[0-9]+ passed' <<<"${final_out}" || echo 'no summary')"

if ((${#mismatches[@]} > 0)); then
  printf '\nNON-BITING / WRONG-RED / INVALID MUTATIONS (%d):\n' "${#mismatches[@]}" >&2
  printf '  - %s\n' "${mismatches[@]}" >&2
  exit 1
fi
printf 'all %d mutations bit\n' "${MUTATIONS_RUN}"
