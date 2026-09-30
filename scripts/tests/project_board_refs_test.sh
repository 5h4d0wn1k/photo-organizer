#!/usr/bin/env bash
#
# Tests for scripts/project_board_refs.py -- the closing-reference parser the
# project-board workflow uses to decide which items move to In Review / Shipped.
#
# The bug this replaces, in one line: the workflow used to read *any* `#N` in a
# PR body. A cross-reference such as "related to #57" moved this repository's
# issue #57 onto the board, and to Shipped when the PR merged. Every case below
# exists because that mistake is easy to reintroduce with a shorter regex.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PARSER="${ROOT_DIR}/scripts/project_board_refs.py"
PASS_COUNT=0
FAIL_COUNT=0
# A parser that quietly stops parsing is worse than one that errors, so a
# regression shows up as a wrong count rather than as a missing warning.
MINIMUM_ASSERTIONS="${MINIMUM_ASSERTIONS:-20}"

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

# expect <description> <expected-json> <body>
# Values are compared, not text: `json.dumps` writes `[1, 2]` and a test
# expecting `[1,2]` would fail on formatting while the parser is correct.
expect() {
  local description="$1" expected="$2" body="$3" actual
  actual="$(printf '%s' "${body}" | python3 "${PARSER}" 2>&1)"
  if python3 -c '
import json
import sys

expected_raw, actual_raw = sys.argv[1], sys.argv[2]
try:
    expected = json.loads(expected_raw)
except json.JSONDecodeError:
    print("test bug: expected value is not JSON", file=sys.stderr)
    sys.exit(3)
try:
    actual = json.loads(actual_raw)
except json.JSONDecodeError:
    sys.exit(1)
sys.exit(0 if actual == expected else 1)
' "${expected}" "${actual}"; then
    ok "${description}"
  else
    bad "${description}" "expected ${expected}, got ${actual}"
  fi
}

# Non-zero, not zero. This suite became a step of the board job's required check
# in this change, and a step that exits 0 without running an assertion is a green
# run that proves nothing. The marker names the cause; the exit status is what
# fails the run, because no runner greps for CANARY_SUITE_DEGRADED.
if ! python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "${PARSER}" 2>/dev/null; then
  printf '  !! CANARY_SUITE_DEGRADED: %s does not parse as Python\n' "${PARSER}"
  exit 1
fi

# --- The regression: a bare cross-reference must not close anything ---------
expect "a bare cross-reference closes nothing" '[]' 'Related to #57'
expect "a bare cross-reference in a sentence closes nothing" '[]' \
  'This supersedes the approach in #112, which was wrong.'
expect "two bare cross-references close nothing" '[]' 'See #1 and #2 for background.'
expect "a hash that is not a reference closes nothing" '[]' 'Colour #ff8800 and issue #3'

# --- The keywords GitHub honours ------------------------------------------
expect "closes" '[7]' 'Closes #7'
expect "close" '[7]' 'close #7'
expect "closed" '[7]' 'Closed #7'
expect "fix" '[7]' 'Fix #7'
expect "fixes" '[7]' 'Fixes #7'
expect "fixed" '[7]' 'Fixed #7'
expect "resolve" '[7]' 'Resolve #7'
expect "resolves" '[7]' 'Resolves #7'
expect "resolved" '[7]' 'Resolved #7'
expect "lowercase keyword" '[7]' 'closes #7'
expect "mixed-case keyword" '[7]' 'ClOsEs #7'
expect "optional colon" '[7]' 'Closes: #7'
expect "extra whitespace" '[7]' 'Closes    #7'
# Deliberately NOT supported, both of them. This parser is allowed to be
# stricter than GitHub, never looser: a board that under-moves is noticed by a
# human, a board that moves something GitHub never linked is not.
expect "'Closes#7' without a space closes nothing (deliberately strict)" '[]' 'Closes#7'
expect "'Closes:#7' without a space after the colon closes nothing (strict)" '[]' 'Closes:#7'

# --- A keyword inside a longer word is not a keyword -----------------------
expect "'prefixes' is not the fix keyword" '[]' 'The prefixes #7 are documented'
expect "'closure' is not the close keyword" '[]' 'The closure #7 is documented'
expect "'refixes' is not the fix keyword" '[]' 'refixes #7'

# --- Lists -----------------------------------------------------------------
expect "comma-separated list" '[1,2]' 'Closes #1, #2'
expect "and-separated list" '[1,2]' 'Closes #1 and #2'
expect "comma-and list" '[1,2,3]' 'Closes #1, #2 and #3'
expect "list across lines" '[1,2]' 'Closes #1
and #2'
expect "one list per keyword" '[1,2]' 'Closes #1
Fixes #2'
expect "duplicates collapse" '[1]' 'Closes #1 and #1'
expect "order is preserved" '[3,1]' 'Closes #3, #1'
expect "multiple closing sentences" '[1,2,3,4]' \
  'Closes #1, #2.

Fixes #3 and #4.'

# --- Qualified references belong to another repository ---------------------
# The most damaging case: the old parser stripped the '#' and looked the bare
# number up *here*, so `other/repo#57` moved this repository's issue #57.
expect "owner/repo#N is another repository and is dropped" '[]' 'Closes other/repo#57'
expect "a qualified ref beside a local one keeps only the local one" '[12]' \
  'Closes other/repo#57 and #12'
expect "org/project#N is dropped" '[]' 'Resolves octo-org/huge-project#9'
expect "a ref carved out of a path is not a reference" '[]' 'See src/app#index for #5'

# --- Quoted references are not references ---------------------------------
expect "a closing ref inside a fenced block is ignored" '[]' '```md
Closes #7
```'
expect "a closing ref inside a tilde fence is ignored" '[]' '~~~text
Closes #7
~~~'
expect "a closing ref inside inline code is ignored" '[]' 'use `Closes #7` in the template'
expect "a closing ref inside an HTML comment is ignored" '[]' '<!-- Closes #7 -->'
expect "a real ref beside a quoted one still counts" '[8]' 'Closes #8
```md
Closes #7
```'

# --- Prose after the list must not be swept in ----------------------------
# The failure mode of an over-greedy parser: "Closes #1 because #2 was wrong"
# must not close #2.
expect "prose after a list is not swept in" '[1]' 'Closes #1 because #2 was wrong'
expect "a trailing sentence is not swept in" '[1]' 'Closes #1. See #2 and #3 for context.'
expect "a sentence with no reference ends the list" '[1]' 'Closes #1
This is unrelated prose without any hash.'

# Whitespace alone is not a separator. GitHub would link both of these -- it
# finds `#N` anywhere -- but this parser requires *visible* punctuation between
# references so that prose cannot smuggle one in. Under-moving is the safe
# direction, and this is the assertion that keeps the separator strict rather
# than merely permissive.
expect "two references separated only by spaces take the first" '[1]' 'Closes #1  #2'
expect "two references separated by a tab take the first" '[1]' $'Closes #1\t#2'
expect "a comma is enough on its own" '[1,2]' 'Closes #1 , #2'

# --- Degenerate input ------------------------------------------------------
expect "empty body" '[]' ''
expect "no body at all" '[]' ''
expect "a keyword with no reference" '[]' 'Closes'
expect "a keyword with nothing after it" '[]' 'Fixes '
expect "a hash with no number" '[]' 'Closes #'
expect "a zero-padded number keeps its value" '[7]' 'Closes #007'
expect "a very large number is preserved" '[4294967296]' 'Closes #4294967296'
expect "a leading zero is not a reference" '[]' 'Closes #0123abc'

# --- The workflow contract -------------------------------------------------
# github-script reads stdout as JSON, so a non-array or an error string here
# would silently produce a broken board.
shape="$(printf 'Closes #1' | python3 "${PARSER}" | python3 -c 'import json,sys; v=json.load(sys.stdin); print("array-of-int" if isinstance(v, list) and all(isinstance(n, int) for n in v) else "WRONG")')"
if [[ "${shape}" == "array-of-int" ]]; then
  ok "output is a JSON array of integers"
else
  bad "output is a JSON array of integers" "got: ${shape}"
fi

rejects_argv="$(python3 "${PARSER}" some-argument 2>&1; echo "rc=$?")"
if grep -q "rc=2" <<<"${rejects_argv}"; then
  ok "a stray command-line argument is rejected"
else
  bad "a stray command-line argument is rejected" "${rejects_argv}"
fi

# --- The --github-output contract the workflow actually consumes -------------
# The workflow appends these lines to $GITHUB_OUTPUT, so the key names, the
# compactness and the count are a real interface, not a convenience. A
# multi-line value would be truncated at the first newline by the runner, which
# is why compactness is asserted rather than assumed.
gh_out="$(printf 'Closes #1, #2 and #3' | python3 "${PARSER}" --github-output 2>&1)"
if [[ "${gh_out}" == $'refs=[1,2,3]\ncount=3' ]]; then
  ok "--github-output writes refs=<compact json> and count=<n>"
else
  bad "--github-output writes refs=<compact json> and count=<n>" "got: $(printf '%s' "${gh_out}" | tr '\n' '|')"
fi

gh_empty="$(printf 'Related to #57' | python3 "${PARSER}" --github-output 2>&1)"
if [[ "${gh_empty}" == $'refs=[]\ncount=0' ]]; then
  ok "--github-output reports an empty list for a body with no closing reference"
else
  bad "--github-output reports an empty list" "got: $(printf '%s' "${gh_empty}" | tr '\n' '|')"
fi

gh_lines="$(printf 'Closes #1, #2' | python3 "${PARSER}" --github-output | wc -l | tr -d '[:space:]')"
if [[ "${gh_lines}" == "2" ]]; then
  ok "--github-output is exactly two lines, so no value can be split by a newline"
else
  bad "--github-output is exactly two lines" "got ${gh_lines} lines"
fi

gh_rejects="$(python3 "${PARSER}" --github-output --github-output 2>&1; echo "rc=$?")"
if grep -q "rc=2" <<<"${gh_rejects}"; then
  ok "a repeated --github-output flag is rejected rather than silently accepted"
else
  bad "a repeated --github-output flag is rejected" "${gh_rejects}"
fi

# The count must describe the same list the workflow will act on. If it were
# computed from something else -- the number of keywords, say -- the log line
# would lie about what moved.
gh_agrees="$(printf 'Closes #1 and #1, fixes #2, related to #3' \
  | python3 "${PARSER}" --github-output | sed -n 's/^count=//p')"
gh_refs="$(printf 'Closes #1 and #1, fixes #2, related to #3' \
  | python3 "${PARSER}" --github-output | sed -n 's/^refs=//p')"
if [[ "${gh_agrees}" == "2" && "${gh_refs}" == "[1,2]" ]]; then
  ok "--github-output count agrees with the reference list"
else
  bad "--github-output count agrees with the reference list" "refs=${gh_refs} count=${gh_agrees}"
fi

printf '\n%s passed, %s failed\n' "${PASS_COUNT}" "${FAIL_COUNT}"
if ((FAIL_COUNT > 0)); then
  exit 1
fi
# A suite that stops testing must not report success -- the failure mode this
# repo treats as worse than a red build.
if ((PASS_COUNT < MINIMUM_ASSERTIONS)); then
  printf 'suite only made %d assertions; expected at least %d, so it is not measuring the parser\n' \
    "${PASS_COUNT}" "${MINIMUM_ASSERTIONS}" >&2
  exit 1
fi
