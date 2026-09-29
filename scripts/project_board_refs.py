#!/usr/bin/env python3
"""Extract the issue numbers a pull request body actually closes.

Used by .github/workflows/project.yml to decide which board items move to
In Review / Shipped. Reads a PR body on stdin.

Output modes
------------
  (default)         a JSON array of integers on stdout, e.g. `[12, 57]`
  --github-output   `refs=[12,57]` and `count=2` lines for $GITHUB_OUTPUT

`--github-output` exists so the workflow does not re-serialize or re-validate
what this module already computed. The format the workflow actually consumes is
therefore produced by the same code path the suite exercises, instead of being a
second, untested `python3 -c` one-liner inside a YAML block.

Why this exists rather than a regex inline in the workflow
------------------------------------------------------------
The original was a one-liner in inline `github-script` JS:

    (body.match(/#(\\d+)/g) || []).map(m => m.slice(1))

which is wrong in a way that corrupts the board. It matches *any* `#N`
anywhere in the body, so a plain cross-reference -- "related to #57", a hex
colour, a line number, an issue quoted inside a code block -- is treated as a
closing reference. The workflow then looked that number up *in this
repository* and moved whatever it found to In Review, and to Shipped on merge.
One careless mention of an unrelated issue number silently ships a real issue
on the project board.

It was also untestable, which is how it survived. Inline `script:` in a
workflow cannot be exercised, so the parsing rules are here, on disk, with a
suite (`scripts/tests/project_board_refs_test.sh`).

The rules implemented
--------------------
Follows GitHub's own linking grammar, because the board must agree with what
GitHub will actually close:

  * Keywords: close/closes/closed, fix/fixed/fixes, resolve/resolves/resolved.
    Case-insensitive.
  * A colon is optional: `Closes: #12` links, `Fix #7` links.
  * A keyword introduces a *list* of references separated by commas or `and`,
    so `Closes #1, #2 and #3` yields three. A new keyword starts a new list.
  * `owner/repo#42` is a reference to *another* repository. This repository's
    board must not be moved by it, so qualified references are dropped. This is
    the case the original got most wrong -- it stripped the `#` and looked the
    bare number up here.
  * Fenced code blocks and inline code spans are removed first, so a closing
    reference shown inside a snippet is not a closing reference. This matches
    GitHub, which does not auto-link inside code.

Fails loudly rather than silently: a non-integer token where a number is
expected is a hard error, not a skipped line. A board that quietly drops half
its references is worse than one that stops and says so.
"""

from __future__ import annotations

import json
import re
import sys

KEYWORDS = r"clos(?:e[sd]?)?|fix(?:e[sd]?)?|resolv(?:e[sd]?)?"

# A keyword, optional colon, then REQUIRED whitespace, then the reference list.
# The required whitespace is a deliberate asymmetry: this parser is allowed to
# be stricter than GitHub, never looser. Missing a link GitHub would have made
# means the board under-moves, which a human notices. Matching a link GitHub
# would *not* have made means the board ships an issue nobody asked to ship.
KEYWORD_RE = re.compile(rf"\b(?:{KEYWORDS})\b\s*:?\s+", re.IGNORECASE)

# A reference, optionally qualified by owner/repo. `match` is always called at
# an offset that follows whitespace or punctuation (the end of a keyword, or a
# separator), never mid-word, so no lookbehind is needed here: an earlier
# version carried one and it was dead code -- removing it left the suite at
# 57/57, which is how it was found.
REFERENCE_RE = re.compile(r"(?:[\w.-]+/[\w.-]+)?#(\d+)\b")

# What may sit *between* two references in one list. Requires a comma, an
# `and`, or a line break -- never bare spaces. Bare spaces are what let
# "Closes #1 because #2 was wrong" pull #2 in: the earlier version consumed
# the word `because` as if it were punctuation and then matched the next
# reference. Over-collecting references is the failure that ships an issue
# nobody asked to ship, so the separator must be visible punctuation.
LIST_SEP_RE = re.compile(
    r"(?:\r?\n[ \t]*(?:and\b[ \t]*)?)"
    r"|(?:[ \t]*,[ \t]*(?:and\b[ \t]*)?)"
    r"|(?:[ \t]+and[ \t]+)"
)

FENCED_CODE_RE = re.compile(r"```.*?```|~~~.*?~~~", re.DOTALL)
INLINE_CODE_RE = re.compile(r"`[^`\n]*`")
# HTML comments: GitHub renders them, and a closing keyword inside one is a
# comment to a human but was still being read by the old regex.
HTML_COMMENT_RE = re.compile(r"<!--.*?-->", re.DOTALL)


def _strip_non_prose(text: str) -> str:
    """Remove regions where a reference is quoted rather than issued."""
    text = FENCED_CODE_RE.sub(" ", text)
    text = HTML_COMMENT_RE.sub(" ", text)
    return INLINE_CODE_RE.sub(" ", text)


def _consume_references(text: str, start: int) -> tuple[list[int], int]:
    """Read the reference list beginning at `start`.

    Returns the qualifying (this-repository) numbers and the offset just past
    the list.

    The first reference needs nothing beyond what the keyword already consumed
    (KEYWORD_RE ends in required whitespace, so there is no separator to skip
    here -- an earlier LEADING_SEP_RE did that job and was dead code, found the
    same way). Every *later* reference needs visible punctuation -- a comma, an
    `and`, or a line break -- so prose ends the list instead of hiding another
    reference inside a sentence. Stop without consuming, so the outer loop sees
    a following keyword.
    """
    found: list[int] = []
    offset = start
    while offset < len(text):
        match = REFERENCE_RE.match(text, offset)
        if match is None:
            break  # prose, or a new keyword. Either way the list is over.
        # owner/repo#42 references another repository. This board must not be
        # moved by it, but it may still sit inside a list of real references.
        if "/" not in match.group(0):
            found.append(int(match.group(1)))
        offset = match.end()
        # Look for a following reference, which needs real punctuation.
        separator = LIST_SEP_RE.match(text, offset)
        if separator is None:
            break
        offset = separator.end()
    return found, offset


def closing_issue_numbers(body: str | None) -> list[int]:
    """Return this repository's issue numbers that `body` closes, in order."""
    if not body:
        return []
    text = _strip_non_prose(body)
    numbers: list[int] = []
    seen: set[int] = set()
    position = 0
    while True:
        keyword = KEYWORD_RE.search(text, position)
        if keyword is None:
            break
        # A keyword only opens a list if a reference actually follows it, so
        # the word "fix" in prose does not pull the rest of the paragraph in.
        batch, position = _consume_references(text, keyword.end())
        for number in batch:
            if number not in seen:
                seen.add(number)
                numbers.append(number)
    return numbers


def main(argv: list[str]) -> int:
    arguments = argv[1:]
    github_output = False
    if arguments == ["--github-output"]:
        github_output = True
    elif arguments:
        print(
            f"usage: {argv[0]} [--github-output] < pull-request-body.md",
            file=sys.stderr,
        )
        return 2
    body = sys.stdin.read()
    numbers = closing_issue_numbers(body)
    if github_output:
        # `separators` keeps it on one line: a multi-line value in
        # $GITHUB_OUTPUT is truncated at the first newline, which would
        # silently turn a three-issue list into a one-issue list.
        compact = json.dumps(numbers, separators=(",", ":"))
        print(f"refs={compact}")
        print(f"count={len(numbers)}")
    else:
        print(json.dumps(numbers))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
