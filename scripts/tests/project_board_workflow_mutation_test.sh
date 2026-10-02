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
# Reused as the scratch location for `derive`; cleanup() already removes it.
DERIVE_SCRATCH="${SANDBOX}/derive"

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
  local name="$1" mutation="$2" needle="$3" output="" rc=0
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
  rc=$?
  restore
  # The exit code is checked as well as the needle, and checked first. A needle
  # match is the sharper evidence, but it is only meaningful on a suite that
  # actually failed: an unparseable workflow makes this suite exit 1 printing
  # only `!! SUITE_DEGRADED` and no FAIL line at all, which without this check is
  # indistinguishable from an assertion that stopped biting. The sibling harness
  # has checked all three of rc, needle and preflight since it was written.
  if ((rc == 0)); then
    MISS_COUNT=$((MISS_COUNT + 1))
    printf '  FAIL %s: SUITE STILL PASSED (the assertion does not bite)\n' \
      "${name}" >&2
    printf '%s\n' "${output}" | tail -6 | sed 's/^/        /' >&2
  elif [[ ${output} == *"${needle}"* ]]; then
    BITE_COUNT=$((BITE_COUNT + 1))
    printf '  ok   %s\n' "${name}"
  else
    MISS_COUNT=$((MISS_COUNT + 1))
    printf '  FAIL %s: suite did not report "%s"\n' "${name}" "${needle}" >&2
    printf '%s\n' "${output}" | tail -6 | sed 's/^/        /' >&2
  fi
}

# Derive a workflow's own text instead of restating it, so a Dependabot bump
# cannot silently disarm a mutation.
#
# Every `uses:` pin in these workflows carries a commit SHA and a `# vN` comment,
# and Dependabot rewrites both on every bump. A `mutate` call that spells either
# one out therefore stops matching the file the moment the action is bumped --
# not because the assertion under test changed, but because the needle is stale.
# The harness then reports the mutation as non-applying, which is the exact
# signature of "the assertion does not bite". It is a false refusal: it names a
# defect that does not exist and points the reader at the wrong file.
#
# Measured on THIS harness at its parent commit, rewriting every pin in the repo
# the way Dependabot does -- commit and `# vN` comment together, which is the only
# way a bump ever lands -- against a tree whose bump script asserts that 0 pins
# survived unchanged:
#
#   nothing bumped             14 run, 14 bit
#   every pin in the repo bumped   12 bit, 2 did not
#
# The two that died are the two mutations that select the checkout pin, "unpinning
# the checkout action to a tag is caught" and "removing the checkout step is
# caught". Both assertions are healthy; both were measuring "is this SHA still
# current". The count of 2 matters on its own: 12 of 14 mutations never named a
# pin, so a bump costs this harness a third of its coverage and reports it as
# coverage that does not exist.
#
# This file held two commit-SHA literals, both the same action and the same
# commit, `actions/checkout`: one in a needle and one in a replacement. Both are
# now derived, and the guard at the end of this file keeps them that way.
#
# So the pin is read from the file. Five shapes are needed, and each is refused
# rather than guessed when its selector is missing or ambiguous -- a helper that
# picked one of two candidates would make a mutation apply to whichever step
# sorted first while its name claimed another.
#
# Every refusal is a distinct exit code so a caller cannot mistake one for
# another: 2 unreadable file, 3 no such step, 4 ambiguous step, 5 action not
# pinned, 6 action pinned to more than one commit, 7 step has no `uses:`,
# 8 unknown mode, 9 bad or missing argument, 10 the file has no single `uses:`
# depth.
#
#   wf_derive step-uses    FILE STEP      the step's own `uses:` line, verbatim
#   wf_derive step-action  FILE STEP      its `- name:` line and `uses:` line
#   wf_derive step-block   FILE STEP      the whole step, up to the next step
#   wf_derive step-swap    FILE STEP ACT  the step's name with its action
#                                         replaced by ACT, keeping ACT's real
#                                         pin and the step's own indentation
#   wf_derive action-line  FILE ACT IND  a `uses:` line for ACT at indentation
#                                         IND, for a step the mutation invents;
#                                         IND may be `from-file` to take the one
#                                         depth every `uses:` line in FILE uses
#
# `step-action` is two lines where one would do because several actions are
# pinned more than once: `actions/download-artifact` appears 7 times in
# release.yml, so a needle naming only the ref would be ambiguous and `apply`
# would refuse it.
#
# `step-swap` takes its indentation from the step it is rewriting rather than
# from the line that currently pins ACT, because the two can otherwise disagree.
# Every action in release.yml happens to sit at indentation 8 today, so no current
# bump is exposed to that; the disagreement was introduced here by hand and
# measured: a replacement that rewrote the ref without the leading spaces dedented
# `uses:` out of the step, the workflow stopped parsing, and the suite failed on
# the parse instead of on the assertion the mutation names. `preflight` catches the
# unparseable case, so it fails loudly -- but it reports the wrong defect, and a
# replacement that happens to parse would be tested against the wrong step.
#
# `action-line` is the one mode with no step to take an indent from, so it is also
# the one that can be handed a wrong depth. Measured on release.yml by inserting a
# `uses:` line at each depth above each of its 63 step-start lines, then asking
# PyYAML two separate questions -- does the file still parse, and did any step
# gain a `uses:` key it did not have:
#
#   depth  0, 2, 4, 6       0 of 63 parse, 0 retargets
#                          (rejected by `preflight`)
#   depth  8               54 of 63 parse, and 23 of those put the key *inside the
#                          neighbouring step* as a duplicate key. PyYAML keeps the
#                          last one, so the mutation silently retargets a step it
#                          never named, and `preflight` cannot see it.
#   depth 10               34 of 63 parse, 0 retargets
#   depth 12, 14, 16       14 of 63 parse, 0 retargets
#                          (the line lands in a neighbouring step's `run:` heredoc
#                          or `with:`, never as a step key)
#
# So the depth that needs deriving is 8, and it is the *shallowest* depth that
# parses, not the deepest. An earlier version of this comment named 10 and 12,
# which are among the depths that parse most often and never once retarget -- it
# reported the measurement without running it. `from-file` exists for exactly this
# reason: it takes the depth from the file and refuses when the file has no single
# depth, which is the only situation in which there is no honest answer to hand
# back.
wf_derive() {
  python3 - "$@" <<'PYTHON'
import re
import sys

mode = sys.argv[1]
path = sys.argv[2]
name = sys.argv[3]
extra = sys.argv[4] if len(sys.argv) > 4 else None

try:
    lines = open(path, encoding="utf-8").read().splitlines(keepends=True)
except OSError as exc:
    print(f"cannot read {path}: {exc}", file=sys.stderr)
    sys.exit(2)


def die(code, message):
    print(message, file=sys.stderr)
    sys.exit(code)


def step_start(step_name):
    pattern = re.compile(r"^[ ]*- name: " + re.escape(step_name) + r"[ \t]*$")
    hits = [i for i, line in enumerate(lines) if pattern.match(line)]
    if not hits:
        die(3, f"no step named {step_name!r} in {path}; "
               f"the needle would restate a step that is not there")
    if len(hits) > 1:
        die(4, f"{len(hits)} steps named {step_name!r} in {path}; "
               f"a derived needle would be ambiguous, so none was chosen")
    return hits[0]


def step_indent(start):
    return len(re.match(r"^[ ]*", lines[start]).group(0))


def step_span(start):
    """Indices of the step's own lines: its name through the line before the
    next step. Blank separators are kept, because removing a step from the file
    without its trailing blank line is a different edit from removing the step --
    and the blank really is there, because `derive` puts back the newline a `$( )`
    would have stripped.

    `- name:` alone does not bound a step list. The last step of a job is
    followed by the *next job's* header, so a scan that stopped only at
    `- name:` handed the caller the next job's `runs-on:`, `steps:` and first
    step as though they belonged to this one. Measured on the two-job fixture
    below, `step-block` for the first job's only step returned 132 bytes
    reaching into job two. So the scan also stops at the first line indented
    less than the step's own `- name:`. Blank and comment lines are skipped
    rather than treated as boundaries, so a blank separator inside the step
    still does not end it."""
    base = step_indent(start)
    for i in range(start + 1, len(lines)):
        if re.match(r"^[ ]*- name: ", lines[i]):
            return range(start, i)
        body = lines[i].strip()
        if body and not body.startswith("#") and \
                len(lines[i]) - len(lines[i].lstrip(" ")) < base:
            return range(start, i)
    return range(start, len(lines))


def uses_index(start):
    """The index of the step's own `uses:` key, or None.

    Bounded three ways, each forced by a real fixture rather than imagined:

      * to the step's key indentation. This used to accept any indent at all, so
        a line inside a `run: |` heredoc was read as the step's action. In the
        fixture below PyYAML reports that step's keys as `name` and `run` -- it
        has no `uses:` whatsoever -- and the unbounded scan still returned the
        heredoc line with exit 0, so `step-uses`, `step-action` and `step-swap`
        all reported success for a step with nothing to derive.
      * to lines outside a block scalar. A `run: |` or `path: |` header means
        everything indented deeper than the key is the scalar's content, so
        those lines are skipped until a sibling key comes back.
      * to the step's own span, so a later step's `uses:` is never returned.

    Returning None is the honest answer here and the callers already refuse on
    it (exit 7): a step with no `uses:` is a real thing to find, and returning
    the nearest line that looks like one is how a harness ends up asserting
    against the wrong step."""
    base = step_indent(start)
    keys = " " * (base + 2)
    in_block = False
    for i in range(start + 1, len(lines)):
        if re.match(r"^[ ]*- name: ", lines[i]):
            break
        body = lines[i].strip()
        if not body or body.startswith("#"):
            continue
        indent = len(lines[i]) - len(lines[i].lstrip(" "))
        if indent < base:
            break
        if in_block:
            if indent > base + 2:
                continue
            in_block = False
        if not lines[i].startswith(keys):
            continue
        if lines[i].startswith(keys + "uses: "):
            return i
        if re.match(re.escape(keys) + r"(run|script|path): [|>]", lines[i]):
            in_block = True
    return None


def pinned_line(action):
    """The one `uses:` line pinning `action` in this file, or refuse. The ref
    is what the mutation needs; which step it came from is irrelevant.

    Both spellings count. A step is usually `- name:` on one line and `uses:` on
    the next, but `- uses:` on a single line is equally valid and appears elsewhere
    in this repo's workflows. Matching only the first form was measured to be a
    blind spot: with the action pinned both ways to *different* commits, the
    helper returned the `- name:` form's commit and reported success, so a
    replacement built from it would have pinned a commit the file does not use.
    """
    pattern = re.compile(r"^([ ]*)(?:- )?uses: " + re.escape(action)
                         + r"@([0-9a-f]{40})(.*)$")
    hits = [(m, i) for i, line in enumerate(lines) if (m := pattern.match(line))]
    refs = {m.group(2) for m, _ in hits}
    if not hits:
        die(5, f"{action} is not pinned in {path}; "
               f"a replacement built from it would name an action that is not used")
    if len(refs) > 1:
        die(6, f"{action} is pinned to {len(refs)} different commits in {path}: "
               f"{sorted(refs)}; no single replacement would be honest")
    return hits[0][0]


def uses_depth():
    """The one indentation the `uses:` keys of this file sit at, or refuse.

    "A `uses:` key" here is a line whose first token is `uses:`, which is a named
    step's key at indentation 8 in these workflows and a job-level
    reusable-workflow call at indentation 4. Both are counted, so a workflow that
    has both is refused rather than resolved by picking the more common depth. The
    refusal is the conservative direction and it is the right one: a line written
    at the wrong depth is not always a parse error, and a parse error would at
    least be loud.

    A single-line `- uses:` step is *not* counted. Its `uses:` is not the first
    token on its line, it belongs to a structure this mode is not trying to
    extend, and its depth is two less than the named form's -- so counting it
    would manufacture a second depth out of a spelling difference rather than a
    real one. `pinned_line` still reads both spellings."""
    depths = {
        len(m.group(1))
        for m in (re.match(r"^([ ]*)uses: ", line) for line in lines)
        if m
    }
    if not depths:
        die(10, f"{path} has no `uses:` key, so there is no depth to write one at")
    if len(depths) > 1:
        die(10, f"{path} puts `uses:` keys at {sorted(depths)} spaces of "
               f"indentation; a derived line would have to guess which one is "
               f"meant, so none was written")
    return " " * depths.pop()


if mode == "step-uses":
    start = step_start(name)
    i = uses_index(start)
    if i is None:
        die(7, f"step {name!r} in {path} has no `uses:` line")
    sys.stdout.write(lines[i])

elif mode == "step-action":
    start = step_start(name)
    i = uses_index(start)
    if i is None:
        die(7, f"step {name!r} in {path} has no `uses:` line")
    sys.stdout.write(lines[start])
    sys.stdout.write(lines[i])

elif mode == "step-block":
    start = step_start(name)
    sys.stdout.write("".join(lines[i] for i in step_span(start)))

elif mode == "step-swap":
    if extra is None:
        die(9, "step-swap needs an action to swap in")
    start = step_start(name)
    i = uses_index(start)
    if i is None:
        die(7, f"step {name!r} in {path} has no `uses:` line to replace")
    target = pinned_line(extra)
    indent = re.match(r"^([ ]*)", lines[i]).group(1)
    comment = target.group(3).rstrip("\n")
    sys.stdout.write(lines[start])
    sys.stdout.write(f"{indent}uses: {extra}@{target.group(2)}{comment}\n")

elif mode == "action-line":
    # A `uses:` line for an action, at an indentation the caller states. Used
    # where the mutation invents a step that is not in the file, so there is no
    # step to take an indent from. `from-file` is preferred over a literal and is
    # the only form the caller uses; the literal is kept so a future caller with a
    # genuinely mixed-depth workflow can still be deliberate about it.
    if extra is None:
        die(9, "action-line needs an indentation, or the word from-file, to write "
               "the uses: line at")
    if extra == "from-file":
        extra = uses_depth()
    elif extra.strip():
        die(9, f"action-line takes an indentation or from-file, not text: {extra!r}")
    target = pinned_line(name)
    comment = target.group(3).rstrip("\n")
    sys.stdout.write(f"{extra}uses: {name}@{target.group(2)}{comment}\n")

else:
    die(8, f"unknown mode {mode!r}; expected one of: "
           f"step-uses, step-action, step-block, step-swap, action-line")
PYTHON
}

# derive <what> <wf_derive args...> -- read the workflow, or stop here.
#
# Every derivation goes through this rather than a bare `$(wf_derive ...)`. A
# command substitution is a subshell, so wf_derive's `exit 1` on a refusal would
# leave the variable empty and let the harness carry on, and `mutate` would then
# report an empty target under a heading that reads as "this mutation did not
# apply" -- accusing healthy assertions because the harness's own selector was
# wrong. Reproduced by putting the derivations back inline and renaming the one
# step they select, which is this workflow's Checkout step:
#
#     - unpinning the checkout action to a tag is caught: mutation did not apply
#       (target occurs N times, expected 1)
#     - a first step named Checkout that checks out nothing is caught: mutation
#       did not apply (target occurs N times, expected 1)
#     - removing the checkout step is caught: mutation did not apply
#       (target occurs N times, expected 1)
#
# Three of this file's fourteen mutations, all of them the ones that select the
# checkout pin. N is project.yml's byte count plus one, for the same reason as in
# the sibling harness: an empty needle's occurrences are counted against the
# whole file.
#
# An earlier version of this comment quoted the sibling harness's transcript --
# a Linux attestation step, an SBOM step, a macOS download, none of which exist
# in project.yml -- and named three needles in prose above a block holding one
# entry. A reader debugging this harness was sent after steps this workflow does
# not have, which is the same false accusation one file over, committed again.
#
# Going through a file rather than `$( )` keeps the derivation in this shell, so
# the exit is real. One scratch file is reused rather than made per call: wf_derive
# runs a handful of times per pass and this is not a hot path, but a fresh
# tempfile per call would be a cleanup obligation on each one.
# It writes the text to ${DERIVE_SCRATCH}.out and leaves it in ${DERIVED}, and is
# called on its own line -- NOT inside $( ). That is the whole point. A command
# substitution runs in a subshell, so an `exit 1` here would abort only the
# subshell: the harness would carry on with an empty needle, and `apply` would
# report an empty anchor under a heading that reads as "these assertions do not
# bite", accusing healthy assertions because the harness's own selector was wrong.
# Measured, by renaming the step three needles select. Calling it bare makes the
# exit the harness's exit, and the refusal the last thing on the terminal.
derive() {
  local what="$1" rc=0
  shift
  wf_derive "$@" >"${DERIVE_SCRATCH}.out" 2>"${DERIVE_SCRATCH}.err" || rc=$?
  if ((rc != 0)); then
    printf 'HARNESS REFUSAL: cannot derive %s (wf_derive exited %d)\n' "${what}" "${rc}" >&2
    sed 's/^/  /' "${DERIVE_SCRATCH}.err" >&2
    printf '\nThe harness is naming something the workflow does not contain, so no\n' >&2
    printf 'mutation below was tested. This is not a missing assertion.\n' >&2
    exit 1
  fi
  # A sentinel, because `$( )` strips every trailing newline and `step-block`
  # returns exactly that: the last line of a step plus the blank line that
  # separates it from the next one. Without the sentinel the newline is gone by
  # the time the value reaches `apply`, so removing a step with `new=` left three
  # blank lines behind where the step used to be -- and `step_span`'s "blank
  # separators are kept" was true of the scratch file and false of the anchor.
  # With a sentinel appended, the captured text ends in the sentinel rather than
  # in a newline, so there is nothing for `$( )` to strip and DERIVED holds
  # wf_derive's bytes exactly.
  DERIVED="$(cat "${DERIVE_SCRATCH}.out"; printf '\001')"
  DERIVED="${DERIVED%$'\001'}"
}

printf 'project_board_workflow mutation test\n'

# The suite must be green before anything is mutated, or "this mutation bit" and
# "the suite was already broken" are the same report. Measured on this harness's
# parent commit: with project.yml's Checkout step moved to the end of its job,
# the suite printed 16 passed / 2 failed and exited 1, and the harness still
# reported 13 bit, 1 did not and exited 0 -- a full-looking result produced by a
# harness measuring a suite that was already red. A red baseline is refused here
# for the same reason a bad derivation is: it is not a missing assertion, and
# reporting it as one is how a reader loses an afternoon.
baseline_out="$(bash "${SUITE}" 2>&1)"
baseline_rc=$?
if [[ ${baseline_rc} -ne 0 ]]; then
  printf 'HARNESS REFUSAL: %s is already red (exit %d) before any mutation ran,\n' \
    "${SUITE##*/}" "${baseline_rc}" >&2
  printf 'so a mutation reported as biting here would prove nothing:\n' >&2
  grep -E '^[[:space:]]*(FAIL|!!) ' <<<"${baseline_out}" | head -10 | sed 's/^/  /' >&2
  exit 1
fi
printf '  ok   baseline green: %s\n' \
  "$(grep -E '^[[:space:]]*[0-9]+ passed' <<<"${baseline_out}" || echo 'suite exited 0')"

# Two separate mutations, because one assertion covered both properties and
# could only bite for one of them. Unpinning to a tag satisfies "uses
# actions/checkout"; dropping the checkout entirely satisfies "pinned to a SHA".
# These two mutations used to spell out the repository-wide checkout pin, which
# meant three files had to be edited together on every Dependabot bump of
# actions/checkout: this needle, the pin in project.yml, and CHECKOUT_REF in
# project_board_workflow_test.sh. Miss one and the harness reported
# "FAIL ... (mutation did not apply)" -- a refusal that reads as a missing
# assertion and is not one. That is the drift #133 caught, and it was waiting to
# happen again on the next version bump.
#
# So the pin is read from the workflow instead. The replacement is built from the
# same derived line so the two cannot disagree about the step's indentation: an
# earlier version of this rewrote the ref without the leading spaces, which
# dedented `uses:` out of the step and made the workflow unparseable, so the
# suite failed on the parse rather than on the assertion under test.
#
# NL, and why the replacements below have to carry it themselves. `checkout_uses`
# used to arrive with its trailing newline already stripped, by `$( )`, and both
# replacements were written to lean on that: `${checkout_uses%%@*}` cuts at the
# first `@` and takes the newline with it, and the old code got its newline back
# for free because the needle never contained one. `derive` now hands back
# wf_derive's bytes exactly, so the needle ends in a real newline and the
# replacement has to end in one too -- without it the replacement swallows the
# line break and welds the next key onto the end of this one, the workflow stops
# parsing, and the suite reports SUITE_DEGRADED with no FAIL line. Measured: with
# the sentinel in place and these two unchanged, the harness reported
# "13 bit, 2 did not", blaming the two assertions when the harness had broken its
# own edit.
NL=$'\n'
derive "the first step's uses: line" step-uses "${WORKFLOW}" 'Checkout'
checkout_uses="${DERIVED}"
derive "the whole first step" step-block "${WORKFLOW}" 'Checkout'
checkout_step="${DERIVED}"
mutate "unpinning the checkout action to a tag is caught" \
  "${checkout_uses}|||${checkout_uses%%@*}@v4${NL}" \
  'FAIL the checkout action is pinned to a commit SHA'

# The half that is about identity rather than form, which is what the constant's
# removal left asserting. Without this, "the first step is actions/checkout" and
# "the first step has a `uses:` at all" are indistinguishable from each other: a
# step that runs a shell command still has no `uses:`, but nothing above would
# notice if a first step named Checkout quietly ran something else instead. The
# step keeps its name, which is the point -- the assertion is not satisfied by
# the label.
mutate "a first step named Checkout that checks out nothing is caught" \
  "${checkout_uses}|||${checkout_uses%%uses:*}run: echo 'this checks out nothing'${NL}" \
  'FAIL the job checks the repository out before running anything from it'

mutate "removing the checkout step is caught" \
  "${checkout_step}|||" \
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

# The step's command is a block rather than a scalar, because the three board
# suites that previously ran only under `make` were added to it. The anchor
# follows the shape actually in the file, with a real trailing newline: this
# harness partitions on `|||` and does no unescaping, so a `\n` written into the
# anchor would be two literal characters and would never match. A stale anchor is
# reported as "mutation did not apply", which is the harness saying it could not
# make the mutation -- not the suite having stopped covering anything.
mutate "removing the parser suite step is caught" \
  '          bash scripts/tests/project_board_refs_test.sh
' \
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

# The guard on everything above. Deriving the pins is only worth something while
# it stays derived, and the way it rots is quiet: the harness keeps reporting a
# full set of bites right up until the next Dependabot bump, and only then does a
# mutation refuse to apply -- reported as "could not apply the mutation", which
# reads as a missing assertion and is not one. So the file is checked for the
# thing it must no longer contain. A commit SHA in a needle, in a replacement, or
# in a comment is equally a failure: quoting a pin in prose is the habit this
# file is trying to break, and a reviewer copying it back out of a comment is
# exactly how the coupling returns.
self="${BASH_SOURCE[0]}"
# Case-insensitively, on purpose. Measured: a run of 40 UPPERCASE hex digits
# passed the lowercase form of this guard while `grep -i` caught it. Hex has no
# case, so restricting the scan to lowercase made the guard weaker than the thing
# it guards against -- and a guard that can be defeated by a keyboard is not a
# guard. The evasion that is left, and is not closed here, is a SHA split across
# a line boundary: the obvious fix is to join the lines before scanning, which
# manufactures false positives out of ordinary text that happens to straddle a
# line, and a guard that cries wolf gets deleted.
literal_pins="$(grep -ioE '[0-9a-f]{40}' "${self}" | tr 'A-F' 'a-f' | sort -u || true)"
if [[ -n "${literal_pins}" ]]; then
  printf 'GUARD FAILED: this harness spells out a commit SHA again, so a Dependabot\n' >&2
  printf 'bump would refuse these mutations and report a missing assertion:\n' >&2
  printf '  %s\n' "${literal_pins}" >&2
  printf 'Read the pin out of the workflow with wf_derive instead.\n' >&2
  exit 1
fi
printf '  ok   no literal commit SHA anywhere in this file; every pin is read from the workflow\n'

printf '\n%s bit, %s did not\n' "${BITE_COUNT}" "${MISS_COUNT}"
if ((MISS_COUNT > 0)); then
  exit 1
fi
if ((BITE_COUNT < 10)); then
  printf 'only %d mutations bit; the harness is not exercising the wiring\n' \
    "${BITE_COUNT}" >&2
  exit 1
fi