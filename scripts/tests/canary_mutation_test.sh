#!/usr/bin/env bash
#
# Mutation pass for scripts/tests/canary_liveness_test.sh.
#
# An assertion that cannot be made to fail is not evidence. For each mutation:
# break the protected code, confirm the suite goes red (for the right reason),
# restore, confirm green. Leaves the working tree untouched.
#
# Two directions, and the distinction matters:
#   * Mutating the script under test or the workflow it is wired into proves the
#     assertions are load-bearing.
#   * Mutating an assertion itself only proves the assertion is weak. Two of
#     those are kept deliberately, to show what the suite's own floor catches.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SUITE="${ROOT_DIR}/scripts/tests/canary_liveness_test.sh"
SCRIPT="${ROOT_DIR}/scripts/canary_liveness.sh"
CANARY_YML="${ROOT_DIR}/.github/workflows/canary.yml"
WORK="$(mktemp -d)"

MUTATIONS_RUN=0
MUTATIONS_BITING=0
mismatches=()

# Pristine copies, taken before anything is touched.
cp "${SCRIPT}" "${WORK}/canary_liveness.sh.orig"
cp "${SUITE}" "${WORK}/suite.orig"
cp "${CANARY_YML}" "${WORK}/canary.yml.orig"

restore() {
  cp "${WORK}/canary_liveness.sh.orig" "${SCRIPT}"
  cp "${WORK}/suite.orig" "${SUITE}"
  cp "${WORK}/canary.yml.orig" "${CANARY_YML}"
}
trap 'restore; rm -rf "${WORK}"' EXIT

# apply <file> <old|||new> -- one replacement, or a loud failure if the target
# text is gone. `\n` in the expression means a real newline so multi-line
# targets can be written readably on one line here.
apply() {
  python3 - "$1" "$2" <<'PYTHON'
import sys

path, expr = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as handle:
    text = handle.read()
old, new = expr.split("|||")
old = old.replace("\\n", "\n")
new = new.replace("\\n", "\n")
if old not in text:
    print(f"MUTATION TARGET NOT FOUND: {old!r}")
    sys.exit(3)
with open(path, "w", encoding="utf-8") as handle:
    handle.write(text.replace(old, new, 1))
PYTHON
}

# check <name> [needle] -- runs the suite against the mutated tree, judges it,
# and restores every file from its pristine copy.
check() {
  local name="$1" needle="${2:-}"
  local out rc
  out="$(bash "${SUITE}" 2>&1)"
  rc=$?
  if [[ ${rc} -eq 0 ]]; then
    mismatches+=("${name}: SUITE STILL PASSED with the code broken")
  elif [[ -n "${needle}" ]] && ! grep -qF "${needle}" <<<"${out}"; then
    mismatches+=("${name}: went red but not on the expected assertion ('${needle}')")
  else
    MUTATIONS_BITING=$((MUTATIONS_BITING + 1))
    printf '  bites  %s\n' "${name}"
  fi
  restore
}

# mutate <name> <file> <old|||new> [needle] -- break a file, judge, restore all.
mutate() {
  local name="$1" file="$2" expr="$3" needle="${4:-}"
  MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
  restore
  if ! apply "${file}" "${expr}"; then
    mismatches+=("${name}: could not apply the mutation")
    restore
    return
  fi
  check "${name}" "${needle}"
}

echo "== mutating scripts/canary_liveness.sh =="

# 1. The regression this whole file exists for: treat a pull_request-only
#    workflow as if it reported on the default branch.
mutate "push/recent decision inverted for non-push workflows" "${SCRIPT}" \
  'event = "push" if has_push else "recent"|||event = "push"'

# 2. Sentinel reverted to an empty string -- the column-collapse bug that made
#    the ghost check skip itself.
mutate "missing-workflow sentinel reverted to an empty string" "${SCRIPT}" \
  'filename, triggers = match if match else (NO_WORKFLOW, [])|||filename, triggers = match if match else ("", [])'

# 3. The canary starts demanding a run of itself.
mutate "self-exclusion removed (canary must demand its own run)" "${SCRIPT}" \
  'if [[ "${self}" == "self" ]]; then|||if false; then'

# 4. Dead schedule stops being a failure.
mutate "dead schedule tolerated" "${SCRIPT}" \
  'note_failure "${workflow} has no schedule-triggered runs; its schedule is dead or the file was renamed"|||true'

# 5. A schedule that stopped firing stops being a failure.
mutate "stale schedule tolerated" "${SCRIPT}" \
  'if ((age > SCHEDULE_MAX_AGE_DAYS)); then|||if false; then'

# 6. A failed scheduled run stops being a failure.
mutate "scheduled-run conclusion check removed" "${SCRIPT}" \
  'note_failure "${workflow}'"'"'s newest schedule run concluded '"'"'${conclusion}'"'"'"|||true'

# 7. A failed pull_request-only check stops being a failure.
mutate "non-push check conclusion check removed" "${SCRIPT}" \
  'note_failure "'"'"'${context}'"'"' concluded '"'"'${conclusion}'"'"' on ${source}"|||true'

# 8. A pull_request-only workflow that stopped running is no longer caught.
mutate "run-age floor removed" "${SCRIPT}" \
  'if ((run_age > RUN_MAX_AGE_DAYS)); then|||if false; then'

# 9. A ghost contract context is no longer reported.
mutate "ghost contract context tolerated" "${SCRIPT}" \
  'note_failure "no workflow defines a job named '"'"'${context}'"'"'; the contract names a check that cannot report"|||true'

# 10. An absent check run on the default branch is no longer reported.
mutate "absent check run tolerated" "${SCRIPT}" \
  'note_failure "'"'"'${context}'"'"' reported no check run on ${source}; the workflow exists but the job never ran"|||true'

# 11. A failed API call becomes a silent pass -- the most dangerous mutation,
#     because it turns "I could not check" into "fine".
mutate "API error treated as a pass" "${SCRIPT}" \
  'note_failure "the API call for '"'"'${context}'"'"' failed; liveness is unknown, and unknown is not a pass"|||true'

# 12. An unresolvable default-branch HEAD is no longer a finding.
mutate "unresolvable HEAD tolerated" "${SCRIPT}" \
  'note_failure "could not resolve ${DEFAULT_BRANCH} HEAD; the liveness half of this canary did not run"|||true'

# 13. An unparseable timestamp is read as a fresh run. (Changing the except
#     clause is NOT a valid mutation here: an uncaught ValueError still exits
#     non-zero, so the observable behaviour is identical. The real risk is the
#     explicit zero, which is what this breaks.)
mutate "unparseable timestamp treated as a fresh run" "${SCRIPT}" \
  'except ValueError:\n    print(f"unparseable timestamp: {raw!r}", file=sys.stderr)\n    sys.exit(1)|||except ValueError:\n    print(0)\n    then = datetime.datetime.now(datetime.timezone.utc)' \
  "expected exit fail, got 0"

# 14. The plan is emitted with one field dropped, so every row after it shifts.
mutate "plan row loses its tier column" "${SCRIPT}" \
  '{event}\t{has_push}\t{tier}"|||{event}\t{has_push}"'

echo "== mutating .github/workflows/canary.yml (the wiring the suite watches) =="

# 15. canary.yml goes back to holding its logic inline, unmeasured.
mutate "canary.yml stops delegating to the tested script" "${CANARY_YML}" \
  'run: bash scripts/canary_liveness.sh|||run: echo canary' \
  "canary.yml's wiring"

# 16. canary.yml stops running the suite that proves the logic.
mutate "canary.yml stops running its own suite" "${CANARY_YML}" \
  'run: bash scripts/tests/canary_liveness_test.sh|||run: echo fine' \
  "canary.yml's wiring"

# 17. Inline API logic creeps back into a step -- the shape that let the original
#     defect survive with nothing able to test it.
mutate "canary.yml regains inline API logic in a step" "${CANARY_YML}" \
  '        run: bash scripts/canary_liveness.sh|||        run: gh api repos/x/commits/main' \
  "canary.yml's wiring"

# 18. canary.yml loses its least-privilege permissions.
mutate "canary.yml widens permissions beyond contents:read" "${CANARY_YML}" \
  'permissions:\n  contents: read|||permissions:\n  contents: write' \
  "canary.yml's wiring"

# 19. A shellcheck warning is introduced into the script under test. The suite
#     shells out to shellcheck, so this must go red rather than pass quietly.
mutate "the canary script gains a shellcheck warning" "${SCRIPT}" \
  'failures=0|||failures=0\nCANARY_MUTATION_PROBE="unused"' \
  "shellcheck"

echo "== mutating the suite's own guardrails =="

# 20. The suite's headline regression case is weakened to a tautology. Expected
#     to be caught: the needle can never be emitted, so the case must go red.
mutate "regression case 1 weakened to a tautology" "${SUITE}" \
  'expect_case "pull_request-only required check passes via its own latest run" pass|||expect_case "pull_request-only required check passes via its own latest run" pass "this string is never emitted"' \
  "did not contain"

# 21. The suite stops running the script under test at all. The assertion floor
#     has to catch this -- a neutered suite exiting 0 with nothing behind it is
#     the failure mode this repo treats as worse than a red build.
mutate "suite runs a no-op instead of the script" "${SUITE}" \
  '    bash "${SCRIPT}" 2>&1\n}|||    true\n}'

# 22. The assertion floor is load-bearing: raising it above the real count must
#     turn the suite red with its own message, proving the guard is what stops a
#     neutered suite from exiting 0 with nothing measured.
mutate "assertion floor raised above the real count" "${SUITE}" \
  'MINIMUM_ASSERTIONS="${MINIMUM_ASSERTIONS:-20}"|||MINIMUM_ASSERTIONS="${MINIMUM_ASSERTIONS:-9999}"' \
  "only made"

restore
final_out="$(bash "${SUITE}" 2>&1)"
final_rc=$?
echo
if [[ ${final_rc} -ne 0 ]]; then
  mismatches+=("restoring the originals did not return the suite to green")
fi

printf 'mutations: %d run, %d bit, suite after restore: %s\n' \
  "${MUTATIONS_RUN}" "${MUTATIONS_BITING}" \
  "$(grep -E '^[0-9]+ passed' <<<"${final_out}" || echo 'no summary')"

if ((${#mismatches[@]} > 0)); then
  printf '\nNON-BITING MUTATIONS (%d):\n' "${#mismatches[@]}" >&2
  printf '  - %s\n' "${mismatches[@]}" >&2
  exit 1
fi
printf 'all %d mutations bit\n' "${MUTATIONS_RUN}"
