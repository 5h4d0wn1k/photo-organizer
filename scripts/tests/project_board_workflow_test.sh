#!/usr/bin/env bash
#
# Structural tests for .github/workflows/project.yml.
#
# Why these exist separately from the parser and helper suites: those two prove
# the *logic* is right, but they are fed their inputs directly. Nothing proved
# the workflow actually wires the logic up. A missing `env:` mapping, a renamed
# step output, or a stale inline copy of a helper would leave both suites
# green while the board silently stopped moving.
#
# That is not hypothetical. While writing this, a mutation that renamed the
# `CLOSING_REFS:` key to `CLOSING_REFS_WRONG:` left the end-to-end simulation
# passing, because the simulation supplies that variable itself. Every
# assertion below exists to make a mutation of the wiring fail loudly.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORKFLOW="${ROOT_DIR}/.github/workflows/project.yml"
PASS_COUNT=0
FAIL_COUNT=0
# Set to the current count, so deleting an assertion cannot silently shrink the
# suite: a neutered suite must not exit 0. It has to be equal to the count and
# not one below it -- a floor under the count is no floor at all, and a floor
# above it can never be met. The mutation harness confirms it bites.
MINIMUM_ASSERTIONS="${MINIMUM_ASSERTIONS:-18}"

ok() {
  PASS_COUNT=$((PASS_COUNT + 1))
  printf '  ok   %s\n' "$1"
}

bad() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  printf '  FAIL %s\n' "$1" >&2
  if [[ -n "${2:-}" ]]; then
    printf '%s\n' "$2" | sed 's/^/        /' >&2
  fi
}

# Every assertion reads the workflow through one Python helper so the YAML is
# parsed, not grepped. A grep-based assertion here would be satisfied by the
# very comments that describe the bug, which is the trap the canary suite
# already fell into once (#117).
wf() {
  python3 - "${WORKFLOW}" "$1" <<'PY'
import re
import sys
import yaml

with open(sys.argv[1]) as handle:
    doc = yaml.safe_load(handle)

# `on` parses as the boolean True in YAML 1.1, so accept either key.
triggers = doc.get("on", doc.get(True))
board = doc["jobs"]["board"]
steps = board["steps"]


def step(name):
    for candidate in steps:
        if candidate.get("name") == name:
            return candidate
    raise SystemExit(f"no step named {name!r}")


expression = sys.argv[2]
# The literal require() call the workflow must contain, including the names it
# binds. Kept here rather than in the assertion so a rename shows up as one
# change, not a hunt through shell quoting.
REQUIRE = (
    'const { closingIssueNumbers, findItemId } = '
    'require("./scripts/project_board_graphql.js");'
)
# Each step's `run:` block with its comment lines stripped. Shell comments in
# a workflow explain exactly what the code below is supposed to do, which makes
# them the most attractive place for an assertion to be satisfied by accident.
CODE = {
    name: "\n".join(
        line
        for line in str(s.get("run", "")).splitlines()
        if not line.strip().startswith("#")
    )
    for name, s in (
        ("parse", step("Parse closing references")),
        ("parser_suite", step("Test the closing-reference parser")),
        ("helpers_suite", step("Test the board helpers")),
    )
}

# The checkout pin is asserted here in two halves, and neither half is a literal.
#
# The supply-chain half -- "this is the ref every other workflow uses, so it was
# reviewed once" -- belongs to `workflow_hygiene_test.sh`, whose `parity`
# assertion requires one ref per action across every workflow in the repo. It is
# the better home for that property on three counts, all measured rather than
# argued:
#
#   * It covers every action, not checkout alone, and it compares the refs to each
#     other instead of to a private copy of one of them, so it cannot be satisfied
#     by editing the copy.
#   * Injecting the one-character typo from #133 into project.yml -- the defect
#     that made the Android release path unrunnable -- makes it report
#     `FAIL parity: actions/checkout` (378 passed, 1 failed). The assertion this
#     file lost in the same edit does not react to that tree at all: 18 passed,
#     0 failed. That is the intended division of labour, not a gap.
#   * It runs somewhere that can block a merge. This file runs from
#     `.github/workflows/project.yml`, whose only job is the board sync and which
#     is not in the `required[]` list in `.github/required-checks.json`;
#     `workflow_hygiene_test.sh` runs inside ci.yml's `security` job, reported as
#     `Security gates`, which is. So the property that matters is enforced by the
#     check that gates merges, and the cheap local identity check stays here.
#
# This file used to restate the pin as a constant and assert equality against
# it, on the grounds that shape alone would accept any 40-hex string. The
# restatement was not free. Dependabot rewrites the commit and the `# vN`
# comment on every bump, so a routine bump of actions/checkout took this suite
# red:
#
#     FAIL the job checks the repository out before running anything from it
#     17 passed, 1 failed
#
# naming a checkout that was present, pinned, and working -- and the harness
# that mutates this suite lost two of its fourteen mutations to the same bump.
# A false red is not a cheap nuisance here: this suite runs from
# `.github/workflows/project.yml`, so it is the first thing a maintainer sees
# when a dependency bump lands, and the message points at the workflow rather
# than at the copy of the pin sitting in this file.
#
# #133 is why the property mattered, and it is why both halves below remain:
# project.yml had been left on v4.2.2 while every other pin was on v7, and
# chasing that straggler turned up two pins in release.yml reading `3d3d42e5...`
# where the rest read `3d3c42e5...` -- one character apart, both immaculately
# well-formed 40-hex strings, with the `android` job unable to resolve its own
# checkout, so the whole Android release path was unrunnable and nothing in the
# repo could see it. "This workflow checks out actions/checkout" and "it is
# pinned to a commit rather than a tag" are the two facts that survive that;
# *which* commit it is is the repo-wide assertion's job.

namespace = {
    "doc": doc,
    "re": re,
    "REQUIRE": REQUIRE,
    "CODE": CODE,
    "triggers": triggers,
    "board": board,
    "steps": steps,
    "step": step,
    "script": step("Sync project board").get("with", {}).get("script", ""),
    "github_script_step": next(s for s in steps if str(s.get("uses", "")).startswith("actions/github-script")),
}
print(eval(expression, namespace))  # noqa: S307 - fixed expressions from this file
PY
}

assert_true() {
  local description="$1" expression="$2" actual=""
  if ! actual="$(wf "${expression}" 2>&1)"; then
    bad "${description}" "${actual}"
    return
  fi
  if [[ "${actual}" == "True" ]]; then
    ok "${description}"
  else
    bad "${description}" "expected True, got: ${actual}"
  fi
}

# Non-zero, not zero. This suite became a step of the board job's required check
# in this change, and a step that exits 0 without running an assertion is a green
# run that proves nothing -- which is the specific failure this suite exists to
# catch, one level up. A plain SUITE_DEGRADED marker is enforced nowhere, unlike
# RELEASE_GATE_SUITE_DEGRADED, which the release-gate driver greps for.
if ! python3 -c "import yaml,sys; yaml.safe_load(open(sys.argv[1]))" "${WORKFLOW}" 2>/dev/null; then
  printf '  !! SUITE_DEGRADED: %s does not parse as YAML\n' "${WORKFLOW}" >&2
  exit 1
fi

# --- The parser is wired in, and the inline over-match is gone -------------
# Asserted on the script text rather than through `wf`: the over-match is a
# regex, and squeezing one through a shell-quoted Python expression invites
# escaping mistakes that read as passes.
# The over-match is quoted in the comments that document the bug, so this
# asserts on the script *block* rather than the file: the fix is "no live
# over-match", not "no mention of one".
assert_true "the script block contains no body.match(/#.../) over-match" \
  "'body.match(/#' not in github_script_step.get('with',{}).get('script','')"

# Matched as an actual require() call, not as a substring: the script's own
# comments name this file, and a comment satisfied the looser form of this
# assertion (found by mutating the require away and watching it stay green).
assert_true "the github-script step requires the tested helper module" \
  "REQUIRE in github_script_step.get('with',{}).get('script','')"

assert_true "the script does not redefine findItemId inline" \
  "'async function findItemId' not in github_script_step.get('script','')"

assert_true "the script does not redefine closingIssueNumbers inline" \
  "'function closingIssueNumbers' not in github_script_step.get('script','')"

# --- The step output actually reaches the script --------------------------
# This is the assertion whose absence let the CLOSING_REFS_WRONG mutation pass.
# The output key `refs` is declared by the parser's --github-output mode, which
# the parser suite asserts directly. What the workflow owns is the step id the
# env mapping reads from, so that is what is asserted here. An earlier version
# asserted `'refs=' in run`, which a *comment* in the step satisfied.
# The suites and the parser are files in the repository, so this job cannot run
# them without a checkout. It failed in CI exactly this way -- "No such file or
# directory" -- so the dependency is asserted rather than remembered.
assert_true "the job checks the repository out before running anything from it" \
  "(bool(steps) and steps[0].get('uses','').split('@')[0] == 'actions/checkout')"

# And that the ref is a full commit SHA, not a tag. `@v4` satisfies a naive
# "uses actions/checkout" check, which is how the first version of the
# assertion above was defeated by its own mutation.
assert_true "the checkout action is pinned to a commit SHA" \
  "re.fullmatch(r'actions/checkout@[0-9a-f]{40}', steps[0].get('uses','')) is not None"

assert_true "the parse step is id'd 'refs', matching the env mapping" \
  "step('Parse closing references').get('id','') == 'refs'"

# Checked against the step's *code*, with its comment lines removed. The
# previous version searched the whole `run:` string, and the step's own comment
# mentions both `--github-output` and `$GITHUB_OUTPUT` -- so deleting the real
# command still left the assertion satisfied. A wiring assertion satisfied by a
# comment is not an assertion.
assert_true "the parse step appends the parser's output to GITHUB_OUTPUT" \
  "'--github-output' in CODE['parse'] and 'GITHUB_OUTPUT' in CODE['parse']"

assert_true "the github-script step receives refs via the CLOSING_REFS env var" \
  "github_script_step.get('env',{}).get('CLOSING_REFS') == '\${{ steps.refs.outputs.refs }}'"

assert_true "the CLOSING_REFS value comes from the parse step's output, not a literal" \
  "'steps.refs.outputs.refs' in github_script_step.get('env',{}).get('CLOSING_REFS','')"

assert_true "the parser step feeds the body in as an environment variable, not into the script" \
  "'\${{ github.event.pull_request.body }}' in step('Parse closing references').get('env',{}).get('PR_BODY','')"

assert_true "the PR body is never interpolated directly into the script block" \
  '"github.event.pull_request.body" not in github_script_step.get("with",{}).get("script","")'

# --- Both suites run in the same job ---------------------------------------
assert_true "the parser suite runs as a step of the board job" \
  "'project_board_refs_test.sh' in CODE['parser_suite']"

assert_true "the helper suite runs as a step of the board job" \
  "'project_board_graphql_test.js' in CODE['helpers_suite']"

# --- Concurrency cannot be cancelled by a fork -----------------------------
assert_true "the concurrency group is keyed on a number, not on a head ref" \
  "'head.ref' not in doc.get('concurrency',{}).get('group','')"

assert_true "the concurrency group uses the pull request number" \
  "'github.event.pull_request.number' in doc.get('concurrency',{}).get('group','')"

# --- Triggers -------------------------------------------------------------
assert_true "synchronize is still a trigger, so a mid-review Closes works" \
  "'synchronize' in triggers['pull_request']['types']"

assert_true "new issues still join the board" \
  "triggers['issues']['types'] == ['opened']"

printf '\n%s passed, %s failed\n' "${PASS_COUNT}" "${FAIL_COUNT}"
if ((FAIL_COUNT > 0)); then
  exit 1
fi
if ((PASS_COUNT < MINIMUM_ASSERTIONS)); then
  printf 'suite only made %d assertions; expected at least %d, so it is not measuring the wiring\n' \
    "${PASS_COUNT}" "${MINIMUM_ASSERTIONS}" >&2
  exit 1
fi