#!/usr/bin/env bash
#
# Mutation test for scripts/project_board_refs.py.
#
# A green suite proves nothing on its own. Each case below breaks one specific
# rule in the parser and asserts the suite catches it. A mutation that leaves
# the suite green is a rule nothing is testing, and counts as a failure of this
# harness -- the same bar the canary suite set (#117).
#
# Two rules were deleted rather than kept, because they were provably dead:
# `LEADING_SEP_RE` (KEYWORD_RE already consumes the whitespace after a keyword,
# so it never matched anything) and the `(?<![\w/])` lookbehind in REFERENCE_RE
# (every match site follows whitespace or punctuation). Both left this suite at
# 57/57 when removed. Neither appears below, because a mutation of absent code
# cannot fail a suite that never covered it.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PARSER="${ROOT_DIR}/scripts/project_board_refs.py"
SUITE="${ROOT_DIR}/scripts/tests/project_board_refs_test.sh"
BACKUP="$(mktemp)"
BITE_COUNT=0
MISS_COUNT=0

cleanup() {
  cp "${BACKUP}" "${PARSER}"
  rm -f "${BACKUP}"
}
trap cleanup EXIT

cp "${PARSER}" "${BACKUP}"

# apply <old|||new> -- a single textual replacement, and it must be unique:
# an ambiguous target means the mutation would not mean what it claims to.
apply() {
  local old="${1%%|||*}" new="${1#*|||}"
  python3 - "${PARSER}" "${old}" "${new}" <<'PY'
import sys

path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(path).read()
if text.count(old) != 1:
    print(
        f"mutation target occurs {text.count(old)} times, expected exactly 1",
        file=sys.stderr,
    )
    sys.exit(4)
open(path, "w").write(text.replace(old, new))
PY
}

# mutate <name> <old|||new> <needle>
# The needle is what the suite must complain about, so the suite goes red for
# the *right* reason. Without it, a mutation that merely broke the file (a
# syntax error, a NameError) would count as a successful catch.
mutate() {
  local name="$1" expression="$2" needle="$3" output=""
  if ! apply "${expression}"; then
    printf '  FAIL %s (mutation did not apply)\n' "${name}" >&2
    MISS_COUNT=$((MISS_COUNT + 1))
    return
  fi
  # Captured, not piped: `bash suite | grep` returns the suite's own non-zero
  # exit status under `pipefail` even when grep matched, which made a biting
  # assertion look like a non-biting one.
  output="$(bash "${SUITE}" 2>&1)"
  cp "${BACKUP}" "${PARSER}"
  if [[ ${output} == *"${needle}"* ]]; then
    BITE_COUNT=$((BITE_COUNT + 1))
    printf '  ok   %s\n' "${name}"
  else
    MISS_COUNT=$((MISS_COUNT + 1))
    printf '  FAIL %s: suite did not report "%s"\n' "${name}" "${needle}" >&2
    printf '%s\n' "${output}" | tail -6 | sed 's/^/        /' >&2
  fi
}

printf 'project_board_refs mutation test\n'

# --- The original bug, faithfully reproduced -------------------------------
# The workflow used to read *any* `#N` in the body. Widening the keyword from a
# short list of closing verbs to "any word followed by a space" reproduces that
# behaviour faithfully inside this parser's structure, and is what made
# "related to #57" close issue 57.
mutate "treating any word as a closing keyword is caught" \
  'KEYWORD_RE = re.compile(rf"\b(?:{KEYWORDS})\b\s*:?\s+", re.IGNORECASE)|||KEYWORD_RE = re.compile(r"\b\w+\s+")' \
  'FAIL a bare cross-reference in a sentence closes nothing'

mutate "dropping the owner/repo prefix is caught" \
  'REFERENCE_RE = re.compile(r"(?:[\w.-]+/[\w.-]+)?#(\d+)\b")|||REFERENCE_RE = re.compile(r"#(\d+)\b")' \
  'FAIL a qualified ref beside a local one keeps only the local one'

mutate "treating a qualified reference as local is caught" \
  'if "/" not in match.group(0):|||if True:' \
  'FAIL owner/repo#N is another repository and is dropped'

# --- Keyword rules ---------------------------------------------------------
mutate "dropping the keyword word-boundary is caught" \
  'KEYWORD_RE = re.compile(rf"\b(?:{KEYWORDS})\b\s*:?\s+", re.IGNORECASE)|||KEYWORD_RE = re.compile(rf"(?:{KEYWORDS})\s*:?\s+", re.IGNORECASE)' \
  "FAIL 'prefixes' is not the fix keyword"

mutate "honouring only 'close' verbs is caught" \
  'KEYWORDS = r"clos(?:e[sd]?)?|fix(?:e[sd]?)?|resolv(?:e[sd]?)?"|||KEYWORDS = r"clos(?:e[sd])?"' \
  'FAIL fixes'

mutate "making the post-keyword whitespace optional is caught" \
  'KEYWORD_RE = re.compile(rf"\b(?:{KEYWORDS})\b\s*:?\s+", re.IGNORECASE)|||KEYWORD_RE = re.compile(rf"\b(?:{KEYWORDS})\b\s*:?\s*", re.IGNORECASE)' \
  "FAIL 'Closes#7' without a space closes nothing"

mutate "making the keyword case-sensitive is caught" \
  'KEYWORD_RE = re.compile(rf"\b(?:{KEYWORDS})\b\s*:?\s+", re.IGNORECASE)|||KEYWORD_RE = re.compile(rf"\b(?:{KEYWORDS})\b\s*:?\s+")' \
  'FAIL mixed-case keyword'

# --- Separator rules --------------------------------------------------------
mutate "treating bare spaces as a list separator is caught" \
  'LIST_SEP_RE = re.compile(
    r"(?:\r?\n[ \t]*(?:and\b[ \t]*)?)"
    r"|(?:[ \t]*,[ \t]*(?:and\b[ \t]*)?)"
    r"|(?:[ \t]+and[ \t]+)"
)|||LIST_SEP_RE = re.compile(r"\s*")' \
  'FAIL two references separated only by spaces take the first'

# --- Quoted regions ---------------------------------------------------------
mutate "dropping the fenced-code strip is caught" \
  'text = FENCED_CODE_RE.sub(" ", text)|||pass' \
  'FAIL a closing ref inside a fenced block is ignored'

mutate "dropping the inline-code strip is caught" \
  'return INLINE_CODE_RE.sub(" ", text)|||return text' \
  'FAIL a closing ref inside inline code is ignored'

mutate "dropping the HTML-comment strip is caught" \
  'text = HTML_COMMENT_RE.sub(" ", text)|||pass' \
  'FAIL a closing ref inside an HTML comment is ignored'

# --- Bookkeeping ------------------------------------------------------------
mutate "dropping the de-duplication is caught" \
  'if number not in seen:
                seen.add(number)|||if True:
                pass' \
  'FAIL duplicates collapse'

# --- The --github-output contract the workflow consumes ---------------------
mutate "a non-compact --github-output value is caught" \
  'compact = json.dumps(numbers, separators=(",", ":"))|||compact = json.dumps(numbers)' \
  'FAIL --github-output writes refs=<compact json> and count=<n>'

mutate "a count computed from something other than the list is caught" \
  'print(f"count={len(numbers)}")|||print(f"count={len(body.split())}")' \
  'FAIL --github-output count agrees with the reference list'

mutate "swallowing unknown arguments instead of rejecting them is caught" \
  'elif arguments:
        print(
            f"usage: {argv[0]} [--github-output] < pull-request-body.md",
            file=sys.stderr,
        )
        return 2|||pass' \
  'FAIL a stray command-line argument is rejected'

printf '\n%s bit, %s did not\n' "${BITE_COUNT}" "${MISS_COUNT}"
if ((MISS_COUNT > 0)); then
  exit 1
fi
if ((BITE_COUNT < 15)); then
  printf 'only %d mutations bit; the harness is not exercising the parser\n' \
    "${BITE_COUNT}" >&2
  exit 1
fi