#!/usr/bin/env bash
#
# Mutation test for scripts/tests/project_board_workflow_test.sh.
#
# A wiring suite is the easiest kind to write a decorative assertion into,
# because the workflow already *contains* the very strings it is supposed to
# forbid: the comments documenting the bug quote the buggy regex, and the
# script's own comments name the module it requires. Each case below mutates
# the workflow and asserts the suite notices.
#
# The CLOSING_REFS mutation is the one that matters most. While this harness
# was being written, renaming the env key to CLOSING_REFS_WRONG left the
# end-to-end simulation passing, because the simulation supplies that variable
# itself rather than going through the workflow. That is exactly the gap these
# assertions close.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORKFLOW="${ROOT_DIR}/.github/workflows/project.yml"
SUITE="${ROOT_DIR}/scripts/tests/project_board_workflow_test.sh"
SANDBOX="$(mktemp -d)"
BITE_COUNT=0
MISS_COUNT=0

cleanup() {
  rm -rf "${SANDBOX}"
}
trap cleanup EXIT

cp "${WORKFLOW}" "${SANDBOX}/workflow.yml"

# restore <mutated-workflow> -- always runs, so a failed mutation cannot leave
# the real workflow damaged.
restore() {
  cp "${SANDBOX}/workflow.yml" "${WORKFLOW}"
}

# mutate <name> <python-mutation> <needle>
# The mutation is Python rather than sed because the workflow is full of `${{ }}`
# and `|`, both of which sed handles badly and neither of which is safe to
# quote through three layers of shell.
mutate() {
  local name="$1" mutation="$2" needle="$3" output=""
  restore
  if ! python3 - "${WORKFLOW}" "${mutation}" <<'PY'
import sys

path, mutation = sys.argv[1], sys.argv[2]
# partition, not split: an empty replacement must survive the trip through the
# shell without leaving a stray line of whitespace behind, which would break the
# YAML and make the suite report SUITE_DEGRADED instead of the real failure.
old, _, new = mutation.partition("|||")
text = open(path).read()
if text.count(old) != 1:
    print(f"target occurs {text.count(old)} times, expected 1", file=sys.stderr)
    sys.exit(4)
open(path, "w").write(text.replace(old, new))
PY
  then
    printf '  FAIL %s (mutation did not apply)\n' "${name}" >&2
    MISS_COUNT=$((MISS_COUNT + 1))
    return
  fi
  output="$(bash "${SUITE}" 2>&1)"
  restore
  if [[ ${output} == *"${needle}"* ]]; then
    BITE_COUNT=$((BITE_COUNT + 1))
    printf '  ok   %s\n' "${name}"
  else
    MISS_COUNT=$((MISS_COUNT + 1))
    printf '  FAIL %s: suite did not report "%s"\n' "${name}" "${needle}" >&2
    printf '%s\n' "${output}" | tail -6 | sed 's/^/        /' >&2
  fi
}

printf 'project_board_workflow mutation test\n'

# Two separate mutations, because one assertion covered both properties and
# could only bite for one of them. Unpinning to a tag satisfies "uses
# actions/checkout"; dropping the checkout entirely satisfies "pinned to a SHA".
mutate "unpinning the checkout action to a tag is caught" \
  'uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2|||uses: actions/checkout@v4' \
  'FAIL the checkout action is pinned to a commit SHA'

mutate "removing the checkout step is caught" \
  '      - name: Checkout
        uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2
        with:
          # Shallow is enough: this workflow runs the parser'"'"'s suites from
          # disk and reads no history. Board automation should not spend the
          # runner'"'"'s time on a full clone to do that.
          fetch-depth: 1

|||' \
  'FAIL the job checks the repository out before running anything from it'

mutate "renaming the CLOSING_REFS env key is caught" \
  '          CLOSING_REFS: ${{ steps.refs.outputs.refs }}|||          CLOSING_REFS_WRONG: ${{ steps.refs.outputs.refs }}' \
  'FAIL the github-script step receives refs via the CLOSING_REFS env var'

# Exactly three separators: partition() splits on the first one, so a fourth
# pipe would leave a stray "|" behind and break the YAML -- which makes the
# suite report SUITE_DEGRADED instead of the failure under test.
mutate "removing the require of the tested module is caught" \
  '            const { closingIssueNumbers, findItemId } = require("./scripts/project_board_graphql.js");
|||' \
  'FAIL the github-script step requires the tested helper module'

mutate "splicing the PR body into the script block is caught" \
  '            const PROJECT_ID = "PVT_kwHOBVymY84BlB6V";|||            const PROJECT_ID = "PVT_kwHOBVymY84BlB6V" + "${{ github.event.pull_request.body }}";' \
  'FAIL the PR body is never interpolated directly into the script block'

mutate "dropping synchronize from the triggers is caught" \
  '    types: [opened, synchronize, ready_for_review, closed]|||    types: [opened, ready_for_review, closed]' \
  'FAIL synchronize is still a trigger'

mutate "keying concurrency on the head ref again is caught" \
  '  group: project-board-${{ github.event_name }}-${{ github.event.pull_request.number || github.event.issue.number || github.sha }}|||  group: project-board-${{ github.event.pull_request.head.ref }}' \
  'FAIL the concurrency group is keyed on a number, not on a head ref'

mutate "removing the parser suite step is caught" \
  '        run: bash scripts/tests/project_board_refs_test.sh|||        run: true' \
  'FAIL the parser suite runs as a step of the board job'

mutate "removing the helper suite step is caught" \
  '        run: node --test scripts/tests/project_board_graphql_test.js|||        run: true' \
  'FAIL the helper suite runs as a step of the board job'

mutate "feeding the body in as a step output instead of an env var is caught" \
  '          PR_BODY: ${{ github.event.pull_request.body }}|||          PR_BODY_WRONG: ${{ github.event.pull_request.body }}' \
  'FAIL the parser step feeds the body in as an environment variable'

mutate "renaming the parse step id is caught" \
  '        id: refs|||        id: refs_WRONG' \
  "FAIL the parse step is id'd 'refs'"

mutate "no longer writing the output to GITHUB_OUTPUT is caught" \
  '          printf '"'"'%s\n'"'"' "${refs_output}" >> "${GITHUB_OUTPUT}"|||          printf '"'"'%s\n'"'"' "${refs_output}"' \
  'FAIL the parse step appends the parser'

mutate "hard-coding the closing references is caught" \
  '          CLOSING_REFS: ${{ steps.refs.outputs.refs }}|||          CLOSING_REFS: "[1,2,3]"' \
  'FAIL the CLOSING_REFS value comes from the parse step'

mutate "restoring the inline over-match is caught" \
  '            const PROJECT_ID = "PVT_kwHOBVymY84BlB6V";|||            const numbers = (context.payload.pull_request.body.match(/#(\d+)/g) || []);
            const PROJECT_ID = "PVT_kwHOBVymY84BlB6V";' \
  'FAIL the script block contains no body.match'

printf '\n%s bit, %s did not\n' "${BITE_COUNT}" "${MISS_COUNT}"
if ((MISS_COUNT > 0)); then
  exit 1
fi
if ((BITE_COUNT < 10)); then
  printf 'only %d mutations bit; the harness is not exercising the wiring\n' \
    "${BITE_COUNT}" >&2
  exit 1
fi