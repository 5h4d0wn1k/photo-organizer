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
# Measured on this harness before the fix, rewriting each action's commit and its
# `# vN` comment the way Dependabot does:
#
#   download-artifact v4 -> v5 alone                   45 run, 44 bit, 1 could not apply
#   download-artifact v4 -> v5, attest-build-provenance
#     v4.2.2 -> v5 and sbom-action v0.24.2 -> v0.25.0,
#     all three at once                                45 run, 42 bit, 3 could not apply
#   checkout v7 -> v8 and action-gh-release v3 -> v4   45 run, 45 bit
#
# The three that died are the three whose literals sat in a needle. The last pair
# changed nothing because their literals sit in *replacements* -- the deliberately
# broken state a mutation writes, which never has to exist in the file, so a
# version bump cannot break it. That is why a harness can sit green for months
# with a stale pin in it and still look healthy: the replacements are the only
# SHAs a bump could have broken, and by luck they were the ones written out of.
#
# This file held eight commit-SHA literals across five distinct commits: three in
# needles (download-artifact, attest-build-provenance, sbom-action) and five in
# replacements (checkout twice, action-gh-release three times). All eight are now
# derived, and the guard below keeps them that way.
#
# The mutations that died were titled "the macOS artifact is never downloaded",
# "the SBOM step is deleted entirely" and "the Linux attestation step is
# silently replaced by a checkout". All three assertions are healthy; all three
# were measuring "is this SHA still current".
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
# the one that can be handed a wrong depth. Measured on release.yml by inserting
# a `uses:` line into a real steps list at each depth: 0, 2, 4 and 6 are all parse
# errors, so `preflight` rejects them, but 10 and 12 both parse -- a `uses:` line
# deeper than the step's own keys becomes a duplicate key inside the neighbouring
# step, PyYAML keeps the last one, and the mutation silently retargets that step
# instead of inventing a new one. `preflight` cannot see that. `from-file` exists
# for exactly this reason: it takes the depth from the file and refuses when the
# file has no single depth, which is the only situation in which there is no
# honest answer to hand back.
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


def step_span(start):
    """Indices of the step's own lines: its name through the line before the
    next step. Blank separators are kept, because removing a step from the file
    without its trailing blank line is a different edit from removing the step."""
    for i in range(start + 1, len(lines)):
        if re.match(r"^[ ]*- name: ", lines[i]):
            return range(start, i)
    return range(start, len(lines))


def uses_index(start):
    for i in range(start + 1, len(lines)):
        if re.match(r"^[ ]*- name: ", lines[i]):
            break
        if re.match(r"^[ ]*uses: ", lines[i]):
            return i
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
# leave the variable empty and let the harness carry on, and `apply` would then
# report an empty anchor under a heading that reads as "these assertions do not
# bite" -- accusing healthy assertions because the harness's own selector was
# wrong. Measured, by renaming the step three needles select:
#
#   NON-BITING / WRONG-RED / INVALID MUTATIONS (2):
#     - the Linux attestation step is silently replaced by a checkout, so a step
#       named [Attest build provenance] attests nothing: could not apply the
#       mutation (ANCHOR IS NOT UNIQUE (44082 occurrences): '')
#
# Going through a file rather than `$( )` keeps the derivation in this shell, so
# the exit is real, and it avoids `$( )` stripping the trailing newline a derived
# block ends with. One scratch file is reused rather than made per call: wf_derive
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
  DERIVED="$(cat "${DERIVE_SCRATCH}.out")"
}

printf 'project_board_workflow mutation test\n'

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
derive "the first step's uses: line" step-uses "${WORKFLOW}" 'Checkout'
checkout_uses="${DERIVED}"
derive "the whole first step" step-block "${WORKFLOW}" 'Checkout'
checkout_step="${DERIVED}"
mutate "unpinning the checkout action to a tag is caught" \
  "${checkout_uses}|||${checkout_uses%%@*}@v4" \
  'FAIL the checkout action is pinned to a commit SHA'

# The half that is about identity rather than form, which is what the constant's
# removal left asserting. Without this, "the first step is actions/checkout" and
# "the first step has a `uses:` at all" are indistinguishable from each other: a
# step that runs a shell command still has no `uses:`, but nothing above would
# notice if a first step named Checkout quietly ran something else instead. The
# step keeps its name, which is the point -- the assertion is not satisfied by
# the label.
mutate "a first step named Checkout that checks out nothing is caught" \
  "${checkout_uses}|||${checkout_uses%%uses:*}run: echo 'this checks out nothing'" \
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
literal_pins="$(grep -oE '[0-9a-f]{40}' "${self}" | sort -u || true)"
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