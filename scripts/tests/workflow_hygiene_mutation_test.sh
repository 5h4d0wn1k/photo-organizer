#!/usr/bin/env bash
#
# Mutation pass for the pin-version / pin-major / dependabot-grouping
# assertions added to scripts/tests/workflow_hygiene_test.sh (issue #130), and for
# the four-way concurrency split (#105, #124).
#
# Those assertions exist because Dependabot moved
# actions/download-artifact from 4.1.8 to 8.0.1 inside a grouped PR while
# leaving the trailing `# v4` comment in place, and nothing in CI noticed; and
# because a concurrency group keyed on `github.ref` alone let a push to main
# cancel the weekly scorecard scan, in two files at once. An assertion that
# cannot be made to fail is a comment, so each one is broken here and the suite
# is required to go red.
#
# Leaves the working tree untouched.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SUITE="${ROOT_DIR}/scripts/tests/workflow_hygiene_test.sh"
WORK="$(mktemp -d)"
trap 'restore; rm -rf "${WORK}"' EXIT

PINNED_FILES=(
  "${ROOT_DIR}/.github/workflows/ci.yml"
  "${ROOT_DIR}/.github/workflows/release.yml"
  "${ROOT_DIR}/.github/workflows/scorecard.yml"
  "${ROOT_DIR}/.github/workflows/codeql-analysis.yml"
  "${ROOT_DIR}/.github/workflows/canary.yml"
  "${ROOT_DIR}/.github/workflows/dependency-review.yml"
  "${ROOT_DIR}/.github/workflows/stale.yml"
  "${ROOT_DIR}/.github/workflows/labeler.yml"
  "${ROOT_DIR}/.github/workflows/project.yml"
)
DEPENDABOT="${ROOT_DIR}/.github/dependabot.yml"

for f in "${PINNED_FILES[@]}"; do
  if [[ -f "$f" ]]; then
    cp "$f" "${WORK}/$(basename "$f").orig"
  fi
done
cp "${DEPENDABOT}" "${WORK}/dependabot.yml.orig"

restore() {
  for f in "${PINNED_FILES[@]}"; do
    base="$(basename "$f")"
    [[ -f "${WORK}/${base}.orig" ]] && cp "${WORK}/${base}.orig" "$f"
  done
  cp "${WORK}/dependabot.yml.orig" "${DEPENDABOT}"
}

MUTATIONS_RUN=0
MUTATIONS_BITING=0
mismatches=()

# apply <file> <old|||new>
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
    print(f"MUTATION TARGET NOT FOUND: {old!r}", file=sys.stderr)
    sys.exit(3)
with open(path, "w", encoding="utf-8") as handle:
    handle.write(text.replace(old, new, 1))
PYTHON
}

# The single definition of "did the right assertion go red". `mutate()` uses it
# to judge every mutation, and `needle_selfcheck` uses the *same function* -- not
# a re-implementation -- so the self-check exercises the code path the results
# actually depend on. A self-check written against a second copy of the logic
# would be free to drift into checking something else entirely, which is the
# failure mode it exists to catch.
#
# FAIL lines and their indented detail lines only. `ok` lines are excluded by
# construction because they share substrings with the FAIL lines: 62 of them
# begin `ok   pin-version:`. Matching the whole output meant a mutation that went
# red for an unrelated reason still satisfied its needle from a *passing* line.
needle_matches() {
  grep -E '^  FAIL |^        ' <<<"$1" | grep -qF "$2"
}

# mutate <name> <file> <old|||new> <expected-needle>
# The needle matters: "the suite went red" is not the same as "the suite went
# red on the assertion this mutation is about". A wrong-red is reported as a
# failure, not counted. See needle_matches for why the needle is scoped to FAIL
# lines, and needle_selfcheck for the proof that the scoping works.
mutate() {
  local name="$1" file="$2" expr="$3" needle="$4"
  MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
  restore
  if ! apply "$file" "$expr"; then
    mismatches+=("${name}: could not apply the mutation")
    restore
    return
  fi
  local out rc
  out="$(bash "${SUITE}" 2>&1)"
  rc=$?
  if [[ ${rc} -eq 0 ]]; then
    mismatches+=("${name}: SUITE STILL PASSED (assertion does not bite)")
  elif ! needle_matches "${out}" "${needle}"; then
    mismatches+=("${name}: went red but not on '${needle}'")
    mismatches+=("        saw: $(grep -E '^  FAIL ' <<<"${out}" | head -3 | tr '\n' ' ')")
  else
    MUTATIONS_BITING=$((MUTATIONS_BITING + 1))
    printf '  bites  %s\n' "${name}"
  fi
  restore
}

# A matcher that accepted every needle would report every mutation as biting
# while proving nothing, and no amount of green output would reveal it. So the
# harness checks its own discrimination, on a real mutation, using needle_matches
# itself:
#   (a) the label that actually failed is matched
#   (b) a different REAL label that passed is NOT matched -- while provably
#       being present in the output, so this is the matcher rejecting it and not
#       the string simply being absent
# (b) is the whole check. With the needle scoped to the whole output,
# `pin-version` is satisfied by 62 passing `ok` lines, (b) fails, and the harness
# reports itself as broken -- which is what makes the numbers above mean anything.
needle_selfcheck() {
  local target="${ROOT_DIR}/.github/workflows/ci.yml"
  local out
  restore
  if ! apply "${target}" \
    'actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a # v7|||actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a # v9'; then
    mismatches+=("needle self-check: could not apply its own mutation")
    restore
    return
  fi
  out="$(bash "${SUITE}" 2>&1)"

  if ! needle_matches "${out}" 'pin-major'; then
    mismatches+=("needle self-check: 'pin-major' was not matched although that is the assertion this mutation breaks")
  fi
  if ! grep -qF 'pin-version' <<<"${out}"; then
    mismatches+=("needle self-check: 'pin-version' is absent from the output entirely, so rejecting it below would prove nothing")
  elif needle_matches "${out}" 'pin-version'; then
    mismatches+=("needle self-check: 'pin-version' WAS matched, but this mutation moves a major and not a comment -- the matcher is reading the whole output instead of the failures")
  fi

  restore
  printf '  checks  needle matcher: matches the real failure, rejects a real but passing label (%s FAIL / %s ok lines in the mutated run)\n' \
    "$(grep -cE '^  FAIL ' <<<"${out}" || true)" "$(grep -cE '^ +ok ' <<<"${out}" || true)"
}

echo "== the mislabelled-pin regression (the reason these assertions exist) =="

# 1. One of two uses of the same action declares a different major.
#
#    The name and needle here were both wrong, and the tightened matcher is what
#    exposed it. This mutation rewrites the FIRST of release.yml's two
#    `actions/download-artifact` pins (`replace(old, new, 1)`), so it creates a
#    disagreement between two uses of one action -- which `pin-major` catches. It
#    does not reproduce #128, and it is not caught by `pin-version`.
#
#    #128 proper was a comment left stale against its own SHA, and that is NOT
#    detectable here: proving the declared major is true means resolving the SHA
#    to its tag, the network lookup this suite deliberately does not make. The
#    needle is `pin-major` because that is the assertion that bites; claiming
#    `pin-version` would have been the exact defect this harness exists to
#    detect -- a mutation counted as proving something it did not prove.
mutate "one of two uses of an action declares a different major" \
  "${ROOT_DIR}/.github/workflows/release.yml" \
  'actions/download-artifact@fa0a91b85d4f404e444e00e005971372dc801d16 # v4|||actions/download-artifact@fa0a91b85d4f404e444e00e005971372dc801d16 # v8' \
  "declared at more than one major"

# 2. A pin with no version comment at all -- the reviewer has nothing to read.
mutate "a pin loses its version comment entirely" \
  "${ROOT_DIR}/.github/workflows/ci.yml" \
  'actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a # v7|||actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a' \
  "no parseable '# vN' version comment"

# 3. A garbage comment that looks like a version but is not one.
mutate "a pin's version comment is unparseable" \
  "${ROOT_DIR}/.github/workflows/ci.yml" \
  'gitleaks/gitleaks-action@e0c47f4f8be36e29cdc102c57e68cb5cbf0e8d1e # v3|||gitleaks/gitleaks-action@e0c47f4f8be36e29cdc102c57e68cb5cbf0e8d1e # latest' \
  "no parseable '# vN' version comment"

# 4. A minor-version comment is still a parseable major claim, and must pass.
#    (This one is expected NOT to bite; it guards against an over-strict
#    regex that would reject `# v2.1.3` and force someone to delete the comment.)
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
restore
if apply "${ROOT_DIR}/.github/workflows/ci.yml" \
  'actions-rust-lang/setup-rust-toolchain@ecabd13d1c56bd1345c230e542e9144811ad706f # v2|||actions-rust-lang/setup-rust-toolchain@ecabd13d1c56bd1345c230e542e9144811ad706f # v2.1.3' \
  && bash "${SUITE}" >/dev/null 2>&1; then
  MUTATIONS_BITING=$((MUTATIONS_BITING + 1))
  printf '  bites  a full version comment (# v2.1.3) is accepted (over-strict regex guard)\n'
else
  mismatches+=("over-strict regex: a full version comment was rejected; the regex must accept # vN.M.P")
fi
restore

# 5. The cross-file major check: same action, two declared majors.
mutate "one action declared at two different majors" \
  "${ROOT_DIR}/.github/workflows/scorecard.yml" \
  'github/codeql-action/upload-sarif@2892aa5e19bbd11bc0cff5427e3b750a04d9e3c2 # v4|||github/codeql-action/upload-sarif@2892aa5e19bbd11bc0cff5427e3b750a04d9e3c2 # v5' \
  "declared at more than one major"

echo "== the dependabot bundling root cause =="

# 6. The exact fix being reverted: drop update-types so majors ride along again.
mutate "dependabot github-actions group loses update-types" \
  "${DEPENDABOT}" \
  '        update-types: ["minor", "patch"]\n        patterns: ["*"]|||        patterns: ["*"]' \
  "no update-types"

# 7. Re-group, but include 'major' -- the subtler version of the same mistake.
mutate "dependabot group re-adds 'major' to update-types" \
  "${DEPENDABOT}" \
  '        update-types: ["minor", "patch"]|||        update-types: ["minor", "patch", "major"]' \
  "includes 'major'"

# 8. The group keeps update-types but loses `patterns`, which is what an
#    ungrouped-by-accident config looks like. An earlier version of this
#    assertion treated a pattern-less group as the safe "scoped" case and passed
#    it; the mutation is what showed that.
mutate "dependabot group loses its patterns" "${DEPENDABOT}" \
  '      github-actions-minor-patch:\n        update-types: ["minor", "patch"]\n        patterns: ["*"]|||      github-actions-minor-patch:\n        update-types: ["minor", "patch"]' \
  "no patterns"

# 9. `groups:` removed entirely -- one PR per bump. Safe, but stated rather than
#    passing silently, because "deliberately ungrouped" and "accidentally
#    ungrouped" are indistinguishable from the file alone. Done as a line-range
#    edit rather than an exact-text match: the block carries a long comment, and
#    an exact match on a comment is exactly the kind of assertion that rots.
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
restore
if python3 - "${DEPENDABOT}" <<'PYTHON2'
import re
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    text = handle.read()
# Drop the `groups:` block of the github-actions update only.
pattern = re.compile(
    r"(package-ecosystem: \"github-actions\".*?)\n    groups:\n(?:.*\n)*?(?=  - package-ecosystem)",
    re.DOTALL,
)
if not pattern.search(text):
    print("MUTATION TARGET NOT FOUND: github-actions groups block", file=sys.stderr)
    sys.exit(3)
with open(path, "w", encoding="utf-8") as handle:
    handle.write(pattern.sub(lambda m: m.group(1) + "\n", text, count=1))
PYTHON2
then
  # Captured rather than piped: `set -o pipefail` is on, so
  # `bash suite | grep` returns the suite's non-zero exit even when grep matched,
  # which reports a biting assertion as non-biting. The exit status of interest
  # is the suite's, so it is kept separate from the text search.
  no_groups_out="$(bash "${SUITE}" 2>&1)"
  # Scoped to the failures for the same reason needle_matches does: an `ok` line
  # and a `FAIL` line here both contain "github-actions", so whole-output
  # matching would report this as biting even if the group check were gone.
  if needle_matches "${no_groups_out}" "no groups"; then
    MUTATIONS_BITING=$((MUTATIONS_BITING + 1))
    printf '  bites  dependabot with no groups at all is reported, not silently accepted\n'
  else
    mismatches+=("no groups: the suite did not report an absent groups block")
  fi
else
  mismatches+=("no groups: could not apply the mutation")
fi
restore

# 10. The bypass this suite used to have, kept as a mutation so it cannot come
#     back. Majors re-included *and* the wildcard re-spelled, so the group still
#     covers every action. Before the fix, `patterns: ["*"]` was the only literal
#     that reached the update-types check, so this exact configuration passed: the
#     same exact-literal-versus-shape-equivalent trap as the two `3d3d42e5...`
#     pins in #133.
mutate "majors bundled but the wildcard re-spelled as ['**']" \
  "${DEPENDABOT}" \
  '        update-types: ["minor", "patch"]\n        patterns: ["*"]|||        update-types: ["minor", "patch", "major"]\n        patterns: ["**"]' \
  "includes 'major'"

# 11. A glob that covers every action without being a bare `*`. Same hazard, same
#     bypass, third spelling -- so no single pattern list satisfies the assertion.
mutate "majors bundled behind a covering ['actions/**'] glob" \
  "${DEPENDABOT}" \
  '        update-types: ["minor", "patch"]\n        patterns: ["*"]|||        update-types: ["minor", "patch", "major"]\n        patterns: ["actions/**"]' \
  "includes 'major'"

# 12. The whole github-actions ecosystem deleted. Every `grouped:` assertion above
#     then has nothing to read and the loop emits nothing at all, so the group
#     checks vanish instead of failing. Deleting the thing a gate reads must not
#     be a way to switch the gate off.
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
restore
if python3 - "${DEPENDABOT}" <<'PYTHON3'
import re
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    text = handle.read()
pattern = re.compile(
    r"  - package-ecosystem: \"github-actions\"\n(?:.*\n)*?(?=  - package-ecosystem)",
)
if not pattern.search(text):
    print("MUTATION TARGET NOT FOUND: github-actions ecosystem block", file=sys.stderr)
    sys.exit(3)
with open(path, "w", encoding="utf-8") as handle:
    handle.write(pattern.sub("", text, count=1))
PYTHON3
then
  eco_out="$(bash "${SUITE}" 2>&1)"
  if needle_matches "${eco_out}" 'declares no github-actions ecosystem'; then
    MUTATIONS_BITING=$((MUTATIONS_BITING + 1))
    printf '  bites  deleting the github-actions ecosystem is reported, not silently vacuous\n'
  else
    mismatches+=("ecosystem deleted: the suite did not report the absence; its group checks were vacuous")
  fi
else
  mismatches+=("ecosystem deleted: could not apply the mutation")
fi
restore

echo "== the concurrency policy (issue #105) =="

# 13-14. The defect #124 actually shipped, in both files it shipped in.
#
#     `schedule` and `push` (canary: `schedule` and `workflow_dispatch`) both run
#     on the default branch, so a group keyed on `github.ref` alone cannot tell
#     them apart -- and with `cancel-in-progress: true` the newer run cancels the
#     older one across trigger classes. One mutation per file, because fixing
#     only the one that was reported is how the second one stays.
mutate "scorecard's group can no longer tell a push from the weekly scan" \
  "${ROOT_DIR}/.github/workflows/scorecard.yml" \
  'scorecard-${{ github.ref }}-${{ github.event_name }}|||scorecard-${{ github.ref }}' \
  "can cancel a run of another"

mutate "canary's group can no longer tell a dispatch from the weekly run" \
  "${ROOT_DIR}/.github/workflows/canary.yml" \
  'canary-${{ github.ref }}-${{ github.event_name }}|||canary-${{ github.ref }}' \
  "can cancel a run of another"

# 15. A group that exists but names nothing. Every ref and every branch in the
#     repository then shares one bucket, so "cancel superseded runs" becomes
#     "cancel whatever else was running" -- the opposite of the intent, and a
#     group is still present, so the pre-split `concurrency` check passed.
mutate "a concurrency group is a bare literal naming no ref" \
  "${ROOT_DIR}/.github/workflows/dependency-review.yml" \
  'dependency-review-${{ github.event.pull_request.number || github.ref }}|||dependency-review' \
  "bare literal"

# 16. Cancellation silently absent. `cancel-in-progress` is optional and defaults
#     to false, so this is the #105 queueing behaviour wearing a group -- and the
#     single "a group exists" check that #124 shipped passed it.
mutate "a read-only workflow's cancel-in-progress is removed entirely" \
  "${ROOT_DIR}/.github/workflows/stale.yml" \
  '  group: stale-${{ github.ref }}\n  cancel-in-progress: true\n|||  group: stale-${{ github.ref }}\n' \
  "queue instead of being cancelled"

# 17. release.yml flips the other way. Not a queueing problem -- the opposite:
#     a second tag build would cancel a release that is mid-flight, skipping the
#     artifact QA gate that AGENTS.md calls blocking.
mutate "release.yml allows a new tag to cancel an in-flight release" \
  "${ROOT_DIR}/.github/workflows/release.yml" \
  '  cancel-in-progress: false|||  cancel-in-progress: true' \
  "must keep cancel-in-progress: false"

# 18. The group removed altogether: the pre-#124 state of all five files.
mutate "a workflow's concurrency group is removed altogether" \
  "${ROOT_DIR}/.github/workflows/dependency-review.yml" \
  'concurrency:\n  group: dependency-review-${{ github.event.pull_request.number || github.ref }}\n  cancel-in-progress: true\n\n|||\n' \
  "no concurrency group declared"

# 19. Over-strictness guard for the expression path. `cancel-in-progress` may be
#     an expression gated on the trigger -- that is how codeql-analysis.yml
#     declines to cancel a pull_request run, and rejecting it would pressure
#     someone into deleting a deliberate conditional. This one is expected NOT to
#     bite; a "bites" here means the assertion has become a literal `true` test.
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
restore
if apply "${ROOT_DIR}/.github/workflows/canary.yml" \
  '  cancel-in-progress: true|||  cancel-in-progress: ${{ github.event_name == '"'"'schedule'"'"' }}' \
  && bash "${SUITE}" >/dev/null 2>&1; then
  MUTATIONS_BITING=$((MUTATIONS_BITING + 1))
  printf '  bites  a trigger-gated cancel-in-progress expression is accepted (over-strict guard)\n'
else
  mismatches+=("over-strict: a trigger-gated cancel-in-progress expression was rejected; the assertion must accept it")
fi
restore

# 20-24. The hash-pinned test-dependency wiring (issue #136). The property being
#     protected is that the suites get a verified PyYAML *before* they run, rather
#     than installing their own dependency inside a required check.
#
#     Mutation 20 is the one that makes the rest meaningful. An earlier version of
#     the flag assertion read the step's raw `run` text, and the release-gate
#     install step's own comment contains the string `--require-hashes` -- so
#     deleting the flag from the command left the comment to satisfy the check and
#     the suite stayed green. These entries mutate the command only, so if the
#     comment-stripping in step_text ever regresses, 20 and 21 go red instead of
#     passing on a comment.
CI="${ROOT_DIR}/.github/workflows/ci.yml"

mutate "the install drops --require-hashes" \
  "${CI}" \
  'python -m pip install --disable-pip-version-check --require-hashes --only-binary=:all:|||python -m pip install --disable-pip-version-check --only-binary=:all:' \
  "the install verifies what it downloads"

mutate "the install drops --only-binary, so a wheelless interpreter silently compiles" \
  "${CI}" \
  'python -m pip install --disable-pip-version-check --require-hashes --only-binary=:all:|||python -m pip install --disable-pip-version-check --require-hashes ' \
  "the install verifies what it downloads"

mutate "the pinned interpreter is one with no published wheel (3.14)" \
  "${CI}" \
  '          python-version: "3.13"|||          python-version: "3.14"' \
  "pins the interpreter"

mutate "the pinned interpreter is left to float" \
  "${CI}" \
  '          python-version: "3.13"|||          python-version: "lts"' \
  "pins the interpreter"

# The "is wired into CI" assertions. These exist because the first version of them
# was `if suite in open(ci_path).read()`, and I showed that is comment-satisfiable:
# commenting out the invocation and leaving the suite named in a shell comment kept
# all 373 assertions green.
#
# The anchors below include the leading `bash ` and are therefore unique. They have
# to be: the bare suite path also appears in the workflow's ShellCheck argument
# list, and `apply` replaces the FIRST occurrence, so a bare-path anchor mutated the
# linter argument list, left the real execution untouched, and the assertion correctly
# stayed green. A mutation that does not bite because it hit the wrong line is
# indistinguishable from a missing assertion unless you read which line changed --
# so `apply` reports it and these anchors are written to be single-occurrence.
mutate "the generator test suite is commented out of CI" \
  "${CI}" \
  '          bash scripts/tests/gen_test_requirements_test.sh|||          # bash scripts/tests/gen_test_requirements_test.sh' \
  "gen_test_requirements_test.sh is wired into CI"

mutate "the offline-proof suite is commented out of CI" \
  "${CI}" \
  '          bash scripts/tests/suites_offline_test.sh|||          # bash scripts/tests/suites_offline_test.sh' \
  "suites_offline_test.sh is wired into CI"

# And the case a step-name check would also accept: the step's title and a shell
# comment both name the suite, while the command runs something else entirely. The
# replacement deliberately mentions the suite NOT AT ALL, because an `echo` naming
# it would legitimately satisfy a substring check on the command.
mutate "the step names the offline suite but runs something else" \
  "${CI}" \
  '          bash scripts/tests/suites_offline_test.sh|||          bash -c "true"' \
  "suites_offline_test.sh is wired into CI"

# And the step deleted outright, which is the way someone would "work around a
# flake". The count is unchanged here (a line was removed, not a step), so this
# needs its own mutation.
mutate "the hash-pinned test dependencies step is deleted" \
  "${CI}" \
  '      - name: Hash-pinned test dependencies\n        run: |\n          set -euo pipefail\n          bash scripts/tests/gen_test_requirements_test.sh\n          bash scripts/tests/suites_offline_test.sh\n|||' \
  "wired into CI"

# The install relocated to after the suites, which is the ordering failure. This
# one is hand-rolled rather than a `mutate` call because a move is two edits and
# `mutate` applies a single replacement: deleting the block instead would go red
# on "provisions the test dependency" (no install at all) and pass a needle
# scoped to "before use", which would be reporting the wrong reason as a bite.
#
# `setup-python` is deliberately left where it is, so the pinning assertions keep
# passing and the ordering assertion is the only thing that can go red. A
# mutation that trips several assertions at once is how a real regression gets
# papered over behind a green suite.
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
restore
# Built with printf rather than a literal so the trailing backslash of the pip
# line survives: a move is two edits, and `apply` takes a single replacement, so
# the block has to be reconstructed rather than deleted.
NL=$'\n'
# The security job's install step, verbatim. Deliberately WITHOUT the two
# explanatory comment lines: those belong to the release-gate job's install step,
# and a block that carried them would not be found here.
#
# The trailing ${NL} is load-bearing and was a real bug. Command substitution
# strips trailing newlines, so the block as first written ended without one, and
# re-inserting it before `      - name: Generate SBOM` GLUED the two together:
# the SBOM step's name line was absorbed into the install step's literal `run`
# scalar and the step was destroyed as collateral. The suite still went red on
# the ordering assertion, so it reported "bites" while quietly mutating a second
# unrelated thing -- and the isolation guard below only ever looked for FAIL
# lines, so it could not see the deletion. Step counting is what catches that
# class of collateral now.
INSTALL_BLOCK="$(printf '%s\n' \
  '      - name: Install hash-pinned test dependencies' \
  '        run: |' \
  '          set -euo pipefail' \
  '          python -m pip install --disable-pip-version-check --require-hashes --only-binary=:all: \' \
  '            -r scripts/requirements-test.txt')"${NL}

# The step count must survive the move. `grep -c` on the step-name key is enough:
# it is a structural property of the file, needs no YAML parser, and a destroyed
# or duplicated step changes it. Asserted on the pristine file first, so a
# mismatch cannot be blamed on the mutation.
STEP_COUNT_BEFORE="$(grep -c '^      - name:' "${CI}")"
if [[ "${STEP_COUNT_BEFORE}" -lt 1 ]]; then
  mismatches+=("ordering: could not count steps in the pristine ci.yml (${STEP_COUNT_BEFORE})")
fi
if ! apply "${CI}" "${INSTALL_BLOCK}|||" \
  || ! apply "${CI}" "      - name: Generate SBOM${NL}|||${INSTALL_BLOCK}      - name: Generate SBOM${NL}"; then
  mismatches+=("ordering: could not move the install step")
elif [[ "$(grep -c '^      - name:' "${CI}")" != "${STEP_COUNT_BEFORE}" ]]; then
  # Caught before the suite runs, because "the suite went red" is not evidence
  # that it went red about ordering rather than about a step this mutation broke.
  mismatches+=("ordering: the move changed the number of steps, so it mutates something else too")
  mismatches+=("        steps before=${STEP_COUNT_BEFORE} after=$(grep -c '^      - name:' "${CI}")")
elif out="$(bash "${SUITE}" 2>&1)" && rc=0; then
  mismatches+=("ordering: SUITE STILL PASSED (the ordering assertion does not bite)")
elif ! needle_matches "${out}" "provisions the test dependency before use"; then
  mismatches+=("ordering: went red but not on 'provisions the test dependency before use'")
  mismatches+=("        saw: $(grep -E '^  FAIL ' <<<"${out}" | head -3 | tr '\n' ' ')")
elif grep -E '^  FAIL ' <<<"${out}" | grep -qF "pins the interpreter"; then
  # The move should leave the pinning assertions green. If they went red too, this
  # mutation is no longer isolating ordering, and "it went red" would no longer be
  # evidence about the ordering assertion at all. Checked by looking for the FAIL
  # line directly rather than through needle_matches, which deliberately only
  # matches failures and so would report a passing assertion as a mismatch.
  mismatches+=("ordering: the move also broke the pinning assertions, so it is not isolating ordering")
  mismatches+=("        saw: $(grep -E '^  FAIL ' <<<"${out}" | head -3 | tr '\n' ' ')")
else
  MUTATIONS_BITING=$((MUTATIONS_BITING + 1))
  printf '  bites  the install moves after the suites that need it\n'
fi
restore

# The needle matcher decides whether the numbers above mean anything, so it is
# checked rather than believed. Runs on a real mutation of its own, and restores.
echo "== the needle matcher itself =="
needle_selfcheck

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
