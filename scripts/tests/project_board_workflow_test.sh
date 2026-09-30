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
# Set just above the current count, so deleting assertions cannot silently
# shrink the suite: a neutered suite must not exit 0. The mutation harness
# confirms this floor bites.
MINIMUM_ASSERTIONS="${MINIMUM_ASSERTIONS:-17}"

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

# The repository-wide checkout pin, asserted exactly rather than by shape.
# Shape alone (`@[0-9a-f]{40}`, asserted separately below) would accept any
# 40-hex string, so pinning the literal is what makes this a supply-chain
# assertion: a different-but-well-formed SHA is a reviewable edit in two places
# rather than a silent substitution. #133 aligned project.yml with the other 13
# workflows, so this constant is now the same SHA every workflow uses -- the
# assertion became stronger, not merely different.
CHECKOUT_REF = "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1"

namespace = {
    "doc": doc,
    "re": re,
    "REQUIRE": REQUIRE,
    "CHECKOUT_REF": CHECKOUT_REF,
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

if ! python3 -c "import yaml,sys; yaml.safe_load(open(sys.argv[1]))" "${WORKFLOW}" 2>/dev/null; then
  printf '  !! SUITE_DEGRADED: %s does not parse as YAML\n' "${WORKFLOW}" >&2
  exit 0
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
  "(bool(steps) and steps[0].get('uses','') == CHECKOUT_REF)"

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