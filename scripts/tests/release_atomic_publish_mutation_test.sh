#!/usr/bin/env bash
#
# Mutation pass for the atomic-publication assertions in
# scripts/tests/release_workflow_test.sh.
#
# These assertions are the ones that stopped a live, public, non-draft release
# from shipping four platforms with no Android APK. A green run of them is worth
# very little on its own: every one of them is a substring or a shape check over
# a YAML file, which is exactly the kind of check that reads as proof while
# measuring nothing. So each is mutated here and has to be caught BY NAME.
#
# "The suite exited non-zero" is not a result; a specific assertion going red is.
# Two guards exist because both failure modes below were hit while writing the
# sibling harness:
#
#   * `preflight` rejects a mutation that leaves release.yml unparseable. Such a
#     mutation measures nothing and reads as a legitimate red.
#   * `needle_matches` requires the named assertion. A red suite with the wrong
#     assertion red is a false pass wearing a failure's clothes.
#
# `grep -c` rather than `grep -q` in `needle_matches`, deliberately: `grep -q`
# exits on its first match, SIGPIPEs the upstream `grep -v`, and under
# `set -o pipefail` that turns a successful match into a non-zero pipeline
# depending on whether the writer finished first. It is a race, and it made two
# mutations in the sibling harness report as non-biting when the assertion they
# targeted had in fact gone red.
set -uo pipefail

ROOT_DIR="${PO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SUITE="${ROOT_DIR}/scripts/tests/release_workflow_test.sh"
WORKFLOW="${ROOT_DIR}/.github/workflows/release.yml"
CI="${ROOT_DIR}/.github/workflows/ci.yml"
DRIVER="${ROOT_DIR}/scripts/tests/run_release_gate_tests.sh"

WORK="$(mktemp -d)"
trap 'restore; rm -rf "${WORK}"' EXIT

cp "${WORKFLOW}" "${WORK}/workflow.orig"
cp "${SUITE}" "${WORK}/suite.orig"
cp "${CI}" "${WORK}/ci.orig"
cp "${DRIVER}" "${WORK}/driver.orig"

restore() {
  cp "${WORK}/workflow.orig" "${WORKFLOW}"
  cp "${WORK}/suite.orig" "${SUITE}"
  cp "${WORK}/ci.orig" "${CI}"
  cp "${WORK}/driver.orig" "${DRIVER}"
}

# apply <file> <old> <new> -- replace exactly one occurrence, then read the file
# back and confirm it now says what was intended. Writing a file is not evidence
# that the file contains the intended text.
apply() {
  python3 - "$1" "$2" "$3" <<'PYTHON'
import sys

path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, encoding="utf-8") as handle:
    text = handle.read()
count = text.count(old)
if count != 1:
    print(
        f"ANCHOR IS NOT UNIQUE ({count} occurrences): {old[:90]!r}", file=sys.stderr
    )
    sys.exit(4 if count else 3)
with open(path, "w", encoding="utf-8") as handle:
    handle.write(text.replace(old, new, 1))
with open(path, encoding="utf-8") as handle:
    after = handle.read()
if new and new not in after:
    print("MUTATION DID NOT LAND: replacement text absent", file=sys.stderr)
    sys.exit(5)
if old and old in after and old not in new:
    print("MUTATION DID NOT LAND: original text still present", file=sys.stderr)
    sys.exit(6)
print(text[: text.index(old)].count("\n") + 1)
PYTHON
}

# preflight <file> -- refuse a mutation that leaves the file unparseable.
preflight() {
  local out
  case "$1" in
  *.yml | *.yaml)
    if ! out="$(python3 -c '
import sys
import yaml
yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
' "$1" 2>&1)"; then
      printf 'the workflow no longer parses: %s\n' "${out}" >&2
      return 1
    fi
    ;;
  *)
    if ! out="$(bash -n "$1" 2>&1)"; then
      printf 'the shell script no longer parses: %s\n' "${out}" >&2
      return 1
    fi
    ;;
  esac
  return 0
}

# Everything the suite said except its passing verdicts. A FAIL line is a symptom;
# the assertion's own detail line is the cause, and it is the more precise
# evidence.
needle_matches() {
  grep -vE '^[[:space:]]*ok ' <<<"$1" | grep -cF -- "$2" >/dev/null
}

# mutate <name> <old> <new> <needle> [target]
#
# `target` defaults to the workflow. Mutating the *suite* is legitimate and needed:
# some assertions are load-bearing for the suite's own correctness rather than for
# catching a workflow defect, and the only way to show those is to break them and
# watch a correct workflow start failing.
mutate() {
  local name="$1" old="$2" new="$3" needle="$4"
  local target="${5:-${WORKFLOW}}"
  MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
  restore
  local line
  if ! line="$(apply "${target}" "${old}" "${new}" 2>&1)"; then
    mismatches+=("${name}: could not apply the mutation (${line})")
    restore
    return
  fi
  if ! preflight "${target}"; then
    mismatches+=("${name}: INVALID MUTATION -- it breaks the file under test, so a red suite would prove nothing")
    restore
    return
  fi
  local out rc
  out="$(PYTHONDONTWRITEBYTECODE=1 bash "${SUITE}" 2>&1)"
  rc=$?
  if [[ ${rc} -eq 0 ]]; then
    mismatches+=("${name}: SUITE STILL PASSED (the assertion does not bite)")
  elif ! needle_matches "${out}" "${needle}"; then
    mismatches+=("${name}: went red but not on '${needle}'")
    mismatches+=("        line ${line}; saw: $(grep -E '^[[:space:]]*FAIL ' <<<"${out}" | head -3 | tr '\n' ' ')")
  else
    MUTATIONS_BITING=$((MUTATIONS_BITING + 1))
    printf '  bites  %s\n' "${name}"
  fi
  restore
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
# leave the variable empty and let the harness carry on, and `apply` would then
# report an empty anchor under a heading that reads as "these assertions do not
# bite" -- accusing healthy assertions because the harness's own selector was
# wrong. Reproduced by putting the derivations back inline and renaming the one
# step they select, so all three derived values came back empty:
#
#     - the Linux attestation step is silently replaced by a checkout, so a step
#       named [Attest build provenance] attests nothing: could not apply the
#       mutation (ANCHOR IS NOT UNIQUE (N occurrences): '')
#     - the SBOM step is deleted entirely: could not apply the mutation
#       (ANCHOR IS NOT UNIQUE (N occurrences): '')
#     - the macOS artifact is never downloaded: could not apply the mutation
#       (ANCHOR IS NOT UNIQUE (N occurrences): '')
#
# Three mutations, three empty needles. N is release.yml's byte count plus one,
# because `''.count('')` over a file of B bytes is B+1 -- tens of thousands of
# "occurrences" of a needle that does not exist. The number is left as N rather
# than a literal: it moves every time release.yml gains a line, and a quoted
# measurement that is already stale on the day it is written is the failure this
# comment is in the file to describe.
#
# This was reproduced rather than recalled. The inline form never reached a
# commit -- it existed only in the working tree between authoring and this fix --
# so the reproduction puts it back by rewriting the two call shapes, and the
# block above is that run's output, not a transcript remembered from the bug.
# An earlier version of this comment quoted a block headed "(2)" containing one
# entry, and a byte count 12 off the file. Both were unreproducible, which is
# worse than quoting nothing.
#
# Going through a file rather than `$( )` keeps the derivation in this shell, so
# the exit is real. One scratch file is reused rather than made per call: wf_derive
# runs a handful of times per pass and this is not a hot path, but a fresh
# tempfile per call would be a cleanup obligation on each one.
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

MUTATIONS_RUN=0
MUTATIONS_BITING=0
mismatches=()

# The suite must be green before anything is mutated, or "this mutation bit" and
# "the suite was already broken" are the same report. Measured on this harness's
# parent commit: with project.yml's Checkout step moved to the end of its job,
# the suite printed 16 passed / 2 failed and exited 1, and the harness still
# reported 13 bit, 1 did not and exited 0 -- a full-looking result produced by a
# harness measuring a suite that was already red. A red baseline is refused here
# for the same reason a bad derivation is: it is not a missing assertion, and
# reporting it as one is how a reader loses an afternoon.
baseline_out="$(PYTHONDONTWRITEBYTECODE=1 bash "${SUITE}" 2>&1)"
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

# Everything this harness needs out of release.yml, read once from the
# pristine file. `mutate` restores release.yml before every attempt, so the
# text derived here is the text `apply` will look for -- and deriving once
# puts the whole dependency on the workflow's shape in one place instead
# of scattering it through the argument list of five separate mutations.
# ${WORK} is the scratch dir the EXIT trap already cleans up.
DERIVE_SCRATCH="${WORK}/derive"

# the [Attest build provenance] step as the workflow writes it
derive "the [Attest build provenance] step as the workflow writes it" \
  step-action "${WORKFLOW}" 'Attest build provenance'
ATTEST_STEP="${DERIVED}"

# the [Attest build provenance] step with its action swapped for a checkout
derive "the [Attest build provenance] step with its action swapped for a checkout" \
  step-swap "${WORKFLOW}" 'Attest build provenance' actions/checkout
ATTEST_AS_CHECKOUT="${DERIVED}"

# the [Generate SBOM] step as the workflow writes it
derive "the [Generate SBOM] step as the workflow writes it" \
  step-action "${WORKFLOW}" 'Generate SBOM'
SBOM_STEP="${DERIVED}"

# the [Generate SBOM] step with its action swapped for a checkout
derive "the [Generate SBOM] step with its action swapped for a checkout" \
  step-swap "${WORKFLOW}" 'Generate SBOM' actions/checkout
SBOM_AS_CHECKOUT="${DERIVED}"

# the whole [Download macOS artifact] step
derive "the whole [Download macOS artifact] step" \
  step-block "${WORKFLOW}" 'Download macOS artifact'
MACOS_STEP="${DERIVED}"

echo "== one publisher, and it is the only one that can write =="

# The one action whose pin a mutation has to invent a step for. `release.yml`
# pins it once, so the derived line is unambiguous; the helper refuses if that
# ever stops being true rather than guessing.
derive "the action-gh-release uses: line to invent a publish step with" \
  action-line "${WORKFLOW}" softprops/action-gh-release from-file
SOFTPROPTS_USES="${DERIVED}"

echo "== nothing reaches the release that was never downloaded =="

# The original defect: `linux` publishing itself again, with no `needs:` and no
# relation to the other platforms. This is the shape that produced a four-platform
# "stable" release with no APK.
mutate "a platform job publishes again, independently" \
  '          path: |
            photo-organizer-linux-x86_64-*.AppImage
            photo-organizer_*_amd64.deb' \
  "          path: |
            photo-organizer-linux-x86_64-*.AppImage
            photo-organizer_*_amd64.deb

      - name: Release Linux
${SOFTPROPTS_USES}
        with:
          files: photo-organizer-linux-x86_64-*.AppImage
          append_body: true
          body: |
            Linux build." \
  "exactly one job may publish"

# The token, not the publish step. A job that cannot publish but holds the token
# can still create a release the moment someone adds a step to it, so the
# assertion is about the permission, not about the current step list.
mutate "a build job that cannot publish holds contents: write" \
  '  macos:
    name: macOS (DMG)
    # Fail fast: a missing keystore must not cost five long platform builds.
    needs:
      - release-signing-preflight
    runs-on: macos-latest
    timeout-minutes: 150
    permissions:
      contents: read' \
  '  macos:
    name: macOS (DMG)
    # Fail fast: a missing keystore must not cost five long platform builds.
    needs:
      - release-signing-preflight
    runs-on: macos-latest
    timeout-minutes: 150
    permissions:
      contents: write' \
  "so it must not hold contents: write"

mutate "the workflow's default permission becomes contents: write" \
  'permissions:
  contents: read

concurrency:' \
  'permissions:
  contents: write

concurrency:' \
  "top-level default must stay contents: read"

# The carve-out, which is the one place a non-`contents` write survives. `id-token` and
# `attestations` are required by `actions/attest-build-provenance` and neither can
# publish. A reviewer applying least-privilege reflexively would delete them, and the
# only thing that would notice is these two mutations going green-by-deletion.
mutate "the Linux provenance attestation loses its id-token" \
  '    permissions:
      contents: read
      id-token: write
      attestations: write' \
  '    permissions:
      contents: read
      attestations: write' \
  "the \`linux\` attestation step needs id-token: write and attestations: write"

mutate "the Linux provenance attestation loses its attestations scope" \
  '    permissions:
      contents: read
      id-token: write
      attestations: write' \
  '    permissions:
      contents: read
      id-token: write' \
  "the \`linux\` attestation step needs id-token: write and attestations: write"

mutate "the Linux attestation step is silently replaced by a checkout, so a step named [Attest build provenance] attests nothing" \
  "${ATTEST_STEP}" \
  "${ATTEST_AS_CHECKOUT}" \
  "the \`linux\` job is expected to attest its build provenance"

# Both `always()` guards previously compared the raw string to the literal
# "always()". GitHub also accepts `${{ always() }}` and any expression containing the
# call, so neither check could see the form its own documentation uses. Found by an
# independent review, which added `if: ${{ always() }}` and got 51 passed -- the exact
# escape the workflow comment claims is structurally closed.
# The job-level check is "no `if:` at all", because per GitHub's
# `jobs.<job_id>.needs` documentation ANY job-level conditional drops the implicit
# `success()`. The three mutations below are the three spellings that matter: the
# literal `always()`, the `${{ }}` form GitHub's own docs use, and `!cancelled()`
# -- which reads like the opposite of `always()` and which an independent review
# used to keep the suite fully green while re-opening the partial-release escape.
mutate "the publish job runs even when a dependency failed (job level, literal form)" \
  '  release:
    name: Publish release
    runs-on: ubuntu-latest' \
  '  release:
    name: Publish release
    runs-on: ubuntu-latest
    if: always()' \
  "must carry no job-level"

mutate "the publish job runs even when a dependency failed (job level, expression form)" \
  '  release:
    name: Publish release
    runs-on: ubuntu-latest' \
  '  release:
    name: Publish release
    runs-on: ubuntu-latest
    if: ${{ always() }}' \
  "must carry no job-level"

# The escape the review found: not `always()` at all, and still an override.
mutate "the publish job runs when a dependency failed via !cancelled(), which is not the string always()" \
  '  release:
    name: Publish release
    runs-on: ubuntu-latest' \
  '  release:
    name: Publish release
    runs-on: ubuntu-latest
    if: ${{ !cancelled() }}' \
  "must carry no job-level"

mutate "always() is hidden inside a compound condition" \
  '  release:
    name: Publish release
    runs-on: ubuntu-latest' \
  '  release:
    name: Publish release
    runs-on: ubuntu-latest
    if: "${{ success() || failure() }}"' \
  "must carry no job-level"

# Step-level is a different key on a different object, and it is the one that
# matters most here: the staging step refuses by exiting non-zero, so a publish
# step carrying `if: always()` runs anyway with a glob that matches nothing.
mutate "the publish step runs even when the staging step refused (step level)" \
  '      - name: Publish the release
        uses: softprops/action-gh-release' \
  '      - name: Publish the release
        if: ${{ always() }}
        uses: softprops/action-gh-release' \
  "on the publish step runs it even when the staging step refused"

# This one searched a blob built as "job: [needs]" for the token `needs:`, which that
# string can never contain -- so it could not fail. Adding a job that genuinely depends
# on `release` left the suite green.
mutate "a job depends on \`release\`, the terminal publisher" \
  '  release-signing-preflight:' \
  '  debug-consumer:
    runs-on: ubuntu-latest
    needs:
      - release
    steps:
      - run: "true"

  release-signing-preflight:' \
  "no job may need \`release\` itself"

# The release body's signing disclosure. An independent review replaced the whole
# `${{ ... }}` expression with the optimistic literal and got 51 passed, so an
# ephemeral-key release could have told users their next version installs cleanly over
# this one -- and that is the disclosure this PR exists to stop.
#
# The needle is the whole expression, not a key next to it. A first attempt at this
# mutation added a harmless `body_prefix_hardcoded: true` key and the suite correctly
# stayed green: the mutation did not remove anything the assertion protects, so "passed"
# was the right answer and the mutation was worthless. Found because the harness
# reports non-biting mutations loudly instead of counting them.
# The needle must cover the expression itself. Anchoring on `body: |` + the heading
# and appending a line does NOT remove the expression, so the suite correctly stayed
# green -- the mutation was worthless and the harness said so rather than counting it.
mutate "the release body drops the signing-mode expression and keeps the optimistic claim" \
  "$(python3 - <<'PYEXPR'
import pathlib
import re

text = pathlib.Path(".github/workflows/release.yml").read_text()
match = re.search(r"\$\{\{ needs\.release-signing-preflight\.outputs\.signing_mode[^\n]*\}\}", text)
print(match.group(0) if match else "NO-EXPRESSION-FOUND")
PYEXPR
)" \
  'THIS ARTIFACT IS SIGNED WITH THE PROJECT RELEASE KEY SO UPGRADES JUST WORK.' \
  "the release body must branch on the preflight's signing_mode"

mutate "the release body drops the ephemeral-key warning" \
  "This artifact is signed with an ephemeral per-run CI key, so it installs once but a future version will require uninstalling it first" \
  "Signed." \
  "the release body must describe the ephemeral-key outcome"

# Anchored on the job header, not on the step name: `outputs:` sits on the job and the
# step that computes the mode is named differently. An earlier version of this needle
# used the step name and matched zero times.
mutate "the preflight stops publishing signing_mode to the release body" \
  '    name: Android release signing preflight
    runs-on: ubuntu-latest
    timeout-minutes: 5
    permissions:
      contents: read
    outputs:
      signing_mode: ${{ steps.signing.outputs.mode }}' \
  '    name: Android release signing preflight
    runs-on: ubuntu-latest
    timeout-minutes: 5
    permissions:
      contents: read
    outputs:
      unrelated: ${{ steps.signing.outputs.mode }}' \
  "the preflight must expose signing_mode"

# An independent review found that consolidating publication silently dropped a release
# asset: on origin/main the Linux job attached `sbom.spdx.json`, and here the SBOM is
# generated but uploaded under a file list that omits it. No test mentioned the SBOM, so
# `docs/RELEASE_CHECKLIST.md` kept requiring an SBOM that no longer shipped. Both
# mutations below were confirmed to leave the suite at 52 passed before this block
# existed.
mutate "the SBOM is generated but no longer uploaded as a release asset" \
  '            photo-organizer_*_amd64.deb
            sbom.spdx.json' \
  '            photo-organizer_*_amd64.deb' \
  "the Linux artifact upload must include sbom.spdx.json"

mutate "the SBOM step is deleted entirely" \
  "${SBOM_STEP}" \
  "${SBOM_AS_CHECKOUT}" \
  "job must still generate the SBOM it uploads"

# The preflight was described as failing "in seconds, not after two and a half hours of
# builds", but the platform jobs had no `needs:` at all, so the claim was false. The
# `needs:` was added to make it true; these two keep it true.
mutate "a long platform build stops waiting for the fast-fail preflight" \
  '  macos:
    name: macOS (DMG)
    # Fail fast: a missing keystore must not cost five long platform builds.
    needs:
      - release-signing-preflight' \
  '  macos:
    name: macOS (DMG)' \
  "job must need the signing preflight"

echo "== every upstream gates the publication =="

for upstream in release-signing-preflight linux linux-smoke windows windows-smoke macos macos-smoke ios android-verify; do
  mutate "\`release\` stops needing \`${upstream}\`" \
    "    needs:
      - release-signing-preflight
      - linux
      - linux-smoke
      - windows
      - windows-smoke
      - macos
      - macos-smoke
      - ios
      - android-verify" \
    "$(python3 - "${upstream}" <<'PYTHON'
import sys

drop = sys.argv[1]
entries = [
    "release-signing-preflight",
    "linux",
    "linux-smoke",
    "windows",
    "windows-smoke",
    "macos",
    "macos-smoke",
    "ios",
    "android-verify",
]
remaining = [entry for entry in entries if entry != drop]
print("    needs:\n" + "\n".join(f"      - {entry}" for entry in remaining))
PYTHON
)" \
    "\`release\` must need \`${upstream}\`"
done

# The Linux/Windows smoke jobs shipped without being listed in `release.needs`,
# so they ran and went red while `release` still published. The loop above proves
# the gating; the assertions below prove each smoke job still points at its own
# gate script and depends only on the build it consumes. Without these, a smoke
# job could be reduced to `run: true` and stay in `needs`, gating nothing.
mutate "the linux-smoke job stops running its gate script" \
  '          bash scripts/linux_release_artifact_smoke.sh linux-artifacts' \
  '          true' \
  "\`linux-smoke\` must run \`scripts/linux_release_artifact_smoke.sh\`"

mutate "the windows-smoke job stops running its gate script" \
  '          bash scripts/windows_release_artifact_smoke.sh "${ZIP}"' \
  '          true' \
  "\`windows-smoke\` must run \`scripts/windows_release_artifact_smoke.sh\`"

mutate "the macos-smoke job stops running its gate script" \
  '          bash scripts/macos_release_artifact_smoke.sh "${DMG}"' \
  '          true' \
  "\`macos-smoke\` must run \`scripts/macos_release_artifact_smoke.sh\`"

mutate "the ios job stops running the simulator gate" \
  '          bash scripts/ios_release_artifact_smoke.sh "app/build/ios/iphonesimulator/Runner.app"' \
  '          true' \
  "the \`ios\` job must invoke \`scripts/ios_release_artifact_smoke.sh\`"

# The pieces that make the iOS gate mean something: a host daemon, a session
# injected into the debug build, a probe tied to an app-only path, and a
# simulator slice `simctl` can install. Each is separately load-bearing -- drop
# one and the gate fails closed and blocks the release, but the workflow suite
# would not notice the regression without these.
mutate "the ios job stops starting the host daemon it probes" \
  '          target/release/galleryd >"${WORK}/galleryd.log" 2>&1 &' \
  '          "${SOME_OTHER_DAEMON}" >"${WORK}/galleryd.log" 2>&1 &' \
  "the \`ios\` job must start a host galleryd"

mutate "the ios job stops injecting the debug session" \
  '          export IOS_SMOKE_LAUNCH_ARGUMENTS="--private-gallery-desktop-url ${BASE} --private-gallery-bearer-token ${bearer}"' \
  '          export SESSION_ARGS_FOR_THE_GATE="--private-gallery-desktop-url ${BASE} --private-gallery-bearer-token ${bearer}"' \
  "the \`ios\` job must set IOS_SMOKE_LAUNCH_ARGUMENTS"

mutate "the ios job stops supplying a backend probe" \
  '          export IOS_SMOKE_BACKEND_PROBE="${probe}"' \
  '          export BACKEND_PROBE_PATH="${probe}"' \
  "the \`ios\` job must set IOS_SMOKE_BACKEND_PROBE"

mutate "the ios job stops building the simulator slice the gate can install" \
  '          flutter build ios --simulator' \
  '          flutter build ios --release' \
  "the \`ios\` job must build the simulator slice"

mutate "the macos-smoke job stops depending on the macOS build it consumes" \
  '  macos-smoke:
    name: macOS install+launch smoke
    runs-on: macos-latest
    timeout-minutes: 45
    needs: macos' \
  '  macos-smoke:
    name: macOS install+launch smoke
    runs-on: macos-latest
    timeout-minutes: 45' \
  "\`macos-smoke\` must need only \`macos\`"

# `if: always()` is what #82 proposed and is the exact opposite of atomic
# publication: it runs the publish job even when a dependency failed.
mutate "the publish job runs even when a dependency failed" \
  '    needs:
      - release-signing-preflight
      - linux
      - linux-smoke
      - windows
      - windows-smoke
      - macos
      - macos-smoke
      - ios
      - android-verify
    permissions:
      contents: write' \
  '    needs:
      - release-signing-preflight
      - linux
      - linux-smoke
      - windows
      - windows-smoke
      - macos
      - macos-smoke
      - ios
      - android-verify
    if: always()
    permissions:
      contents: write' \
  "must carry no job-level"

# Reachability has to be transitive: `android` produces the APK but `release`
# names `android-verify`, so a direct-only walk would report the correct workflow
# as broken. The mutation below proves the walk is real by breaking it and
# watching a correct workflow go red -- the inverse shape from every other case
# here, and the reason it is called out separately.
mutate "reachability stops being transitive" \
  'release_reaches = reachable_from("release")' \
  'release_reaches = set(needs_of("release"))' \
  'does not depend on it (directly or transitively)' \
  "${SUITE}"

echo "== nothing reaches the release, and the checksum is not re-derived =="

mutate "the macOS artifact is never downloaded" \
  "${MACOS_STEP}" \
  '' \
  'must download `macos-artifact`'

mutate "the Linux artifact is downloaded under a name no job uploads" \
  '          name: linux-artifacts
          path: incoming/linux' \
  '          name: linux-artifacts-final
          path: incoming/linux' \
  'downloads artifacts no job uploads'

# The staging step is what makes "complete or nothing" true at the byte level.
# Inverting its guard is the interesting mutation: a complete set is then refused
# and an incomplete one sails through to publish whatever arrived.
#
# The anchor is the one-line condition rather than the whole block, because the
# block contains a `printf '  %s\n'` whose literal backslash-n has to be carried
# through the shell quoting intact, and getting that wrong produces a mutation
# that quietly fails to apply.
mutate "the partial-release refusal is inverted" \
  '          if [[ "${#missing[@]}" -ne 0 ]]; then' \
  '          if [[ "${#missing[@]}" -eq 0 ]]; then' \
  "a missing platform directory refuses the release"

mutate "the staging step counts zero-byte files as produced" \
  '            count="$(find "${dir}" -type f -size +0c | wc -l)"' \
  '            count="$(find "${dir}" -type f | wc -l)"' \
  "a platform whose only file is empty refuses the release"

# This is the one that matters for the string-presence assertions. Replacing the
# guard with `if false` leaves the message, the comment and the `exit 1` all in
# place -- a suite that greps for them reports a guard that does not exist. Only
# executing the step catches it.
mutate "the basename-collision guard is present but dead" \
  '              if [[ -e "dist/${base}" ]]; then' \
  '              if false; then' \
  "two artifacts sharing a basename refuse the release"

echo "== what is published is what was verified =="

mutate "the publish step attaches a different tree than the staged one" \
  '          files: dist/*' \
  '          files: incoming/*/*' \
  "must attach exactly the staged directory and nothing else"

mutate "a platform's signing status is dropped from the release body" \
  '            * **macOS** — unsigned. No notarization.' \
  '            * **macOS** — see the notes above.' \
  "must state macOS's signing status"

mutate "the Android verify job stops re-checking the checksum" \
  '          ( cd apk && sha256sum -c app-release.apk.sha256 )' \
  '          ( cd apk && sha256sum app-release.apk.sha256 )' \
  "re-verifies the checksum"

mutate "the Android re-verification step is renamed so it is not found" \
  '      - name: Re-verify the artifact about to be published' \
  '      - name: Look at the artifact again' \
  "the publish job has a re-verification step"

echo "== the preflight cannot be bypassed =="

# If the preflight stops asserting the resolved mode, an unexpected value passes.
mutate "the preflight accepts any signing mode" \
  '            *)
              echo "::error::android_release_signing.sh returned an unexpected mode: '"'"'${mode}'"'"'" >&2
              exit 1
              ;;' \
  '            *)
              ;;' \
  "the preflight must exit non-zero on an unexpected signing mode"

# ...and it has to be the shared policy script, not a local re-implementation,
# or the workflow and the local readiness check can drift apart silently.
# `continue-on-error: true` on the staging step is the one-key version of the
# v0.1.7 failure: the refusal exits 1, GitHub marks the step failed-but-continued,
# the job succeeds, `dist` was never created (the `rm -rf dist` follows the
# refusal), and `dist/*` matches nothing. An independent review added this key and
# the suite stayed fully green.
mutate "the staging step swallows its own refusal with continue-on-error" \
  '      - name: Stage every platform artifact, refusing an incomplete set
        run: |' \
  '      - name: Stage every platform artifact, refusing an incomplete set
        continue-on-error: true
        run: |' \
  "no step in \`release\` may set \`continue-on-error\`"

# The action's default creates a release with zero assets when the glob matches
# nothing, which is a live public release missing every platform.
mutate "the publish step loses fail_on_unmatched_files and can create an empty release" \
  '          fail_on_unmatched_files: true
' \
  '' \
  "must set \`fail_on_unmatched_files: true\`"

# A second publish step *inside* `release`. Every publish property was asserted
# with `any(...)`/join over whichever steps a job happened to have, and
# `publishers` is a set of job NAMES, so a second publish call in the single
# publishing job was invisible: the name was still `release`, the real step still
# set `fail_on_unmatched_files`, and the join still contained `dist/*`. An
# independent review inserted this and the suite stayed green. The pinned action
# drafts the release, uploads, then flips `draft: false`, so the sneaker leaves a
# live Latest release carrying only what it named -- with every staging refusal
# running afterwards, too late. That is the v0.1.7 incident inside the job built
# to prevent it.
mutate "a second publish step is added inside \`release\`, before staging" \
  '      - name: Stage every platform artifact, refusing an incomplete set' \
  "      - name: Sneak publish before staging
${SOFTPROPTS_USES}
        with:
          files: incoming/android/*
      - name: Stage every platform artifact, refusing an incomplete set" \
  "exactly one publish step may exist anywhere in the workflow"

# Same shape, but placed after the real publish step, so only the ordering
# assertion can catch it: the count is 2 and the last step is not a publish step,
# but `fail_on_unmatched_files` and `dist/*` are both still present on the real
# step. Without a position assertion this ordering defect would survive.
mutate "a publish step is appended after the real one, so something runs post-publish" \
  '          fail_on_unmatched_files: true' \
  "          fail_on_unmatched_files: true

      - name: Late publish after the release is live
${SOFTPROPTS_USES}
        with:
          files: incoming/macos/*" \
  "must be the last step of \`release\`"

# The real step keeps `fail_on_unmatched_files`, and the join over all publish
# steps still contains `dist/*` -- but the step now also attaches an unvetted
# glob, which is what actually gets uploaded. Containment cannot see this.
mutate "the publish step attaches an extra unvetted glob alongside the staged tree" \
  '          files: dist/*' \
  '          files: dist/*
            incoming/*' \
  "must attach exactly the staged directory and nothing else"

# The `platforms=(...)` array is what decides the published asset set. An
# independent review built a composite `freebsd` job -- created, added to `needs`,
# artifact uploaded, artifact downloaded into `incoming/freebsd` -- and the suite
# stayed at 52 passed, because the download landed in a directory the staging loop
# never visits. The artifact was fetched, verified, and attached to nothing.
mutate "the staging array drops a platform that every other check still knows about" \
  'platforms=(android linux windows macos ios)' \
  'platforms=(android linux windows macos)' \
  "must be exactly the set of directories the download-artifact steps write into"

# A second writer does not have to use the action.
mutate "a second job publishes through the gh CLI instead of the release action" \
  '  release-signing-preflight:' \
  '  sneaky-publish:
    name: Sneaky publish
    runs-on: ubuntu-latest
    permissions:
      contents: read
    steps:
      - name: Sneak
        run: gh release create "${GITHUB_REF_NAME}" --repo "${GITHUB_REPOSITORY}"

  release-signing-preflight:' \
  "exactly one job may publish"

# A download path rename is the same defect spelled differently: the artifact is
# fetched into a directory the staging loop never reads.
mutate "the ios artifact is downloaded into a directory the staging loop never visits" \
  '          path: incoming/ios' \
  '          path: incoming/ios-app' \
  "must be exactly the set of directories the download-artifact steps write into"

mutate "the preflight stops using the shared signing policy script" \
  '          mode="$(bash scripts/android_release_signing.sh mode | tail -n 1)"' \
  '          mode="release"' \
  "the preflight must resolve signing through the shared policy script"

echo "== the release-gate driver runs every shard of its sharded pass =="

# The driver splits the iOS mutation pass across concurrent shards and the probe
# in release_workflow_test.sh pins the union of those shards. Collapsing the pass
# to one shard must turn that assertion red, or the probe's "the union is the
# full set" line could be vacuous -- green because no shard ran at all.
mutate "the release-gate driver un-shards the iOS mutation pass" \
  "    ios_release_artifact_mutation_test.sh) printf '8' ;;" \
  "    ios_release_artifact_mutation_test.sh) printf '1' ;;" \
  "every shard of the sharded suite runs (the union is the full set)" \
  "${DRIVER}"

echo "== the release-gate matrix and its aggregate actually gate =="

# The gate is fanned out over one job per suite and aggregated by the single
# required check. release_workflow_test.sh binds the matrix to the driver's own
# SUITES list and executes the aggregate's result step; these mutations prove
# each of those assertions bites.
mutate "the suite matrix drops a suite the driver still runs" \
  '          - ios_release_artifact_mutation_test.sh
' \
  '' \
  "lists exactly the driver's SUITES" \
  "${CI}"

mutate "a matrix leg stops being bound to its own suite" \
  'bash scripts/tests/run_release_gate_tests.sh --only-suite "${{ matrix.suite }}"' \
  'bash scripts/tests/run_release_gate_tests.sh' \
  "runs exactly its own suite" \
  "${CI}"

mutate "the aggregate stops running when a leg fails" \
  '    if: ${{ !cancelled() }}
' \
  '' \
  "runs even when a leg fails" \
  "${CI}"

mutate "the aggregate result step stops binding the legs' result" \
  '        env:
          RELEASE_GATE_SUITES_RESULT: ${{ needs.release-gate-suites.result }}
' \
  '' \
  "binds needs.<matrix>.result" \
  "${CI}"

# The comparison is inverted, so the gate now accepts a failed leg. The
# structural substring check still passes (the run text still contains `success`
# and `exit 1`); only EXECUTING the step catches it. This is the mutation that
# shows the behavioural assertion is load-bearing rather than a second spelling
# of the same substring check.
mutate "the aggregate accepts a failed leg (the comparison is inverted)" \
  '          if [[ "${RELEASE_GATE_SUITES_RESULT}" != "success" ]]; then' \
  '          if [[ "${RELEASE_GATE_SUITES_RESULT}" == "success" ]]; then' \
  "fails a leg that failed" \
  "${CI}"

mutate "the aggregate hides a failed result behind continue-on-error" \
  '      - name: Require every release-gate suite to have passed
' \
  '      - name: Require every release-gate suite to have passed
        continue-on-error: true
' \
  "hides a failure behind continue-on-error" \
  "${CI}"

# A conjunct on the aggregate's `if:` is the subtle form of the same skip. The
# pre-hardening assertion searched for the `!cancelled()` token, which
# `!cancelled() && github.event_name != 'pull_request'` still contains -- so on a
# pull_request event the single REQUIRED check is skipped, and GitHub reports a
# skipped required job as Success. The exact-value comparison is what catches it.
mutate "the aggregate's run condition gains a conjunct that can skip it on a pull_request" \
  '    if: ${{ !cancelled() }}
' \
  '    if: ${{ !cancelled() && github.event_name != '\''pull_request'\'' }}
' \
  "runs even when a leg fails" \
  "${CI}"

# Job-level `continue-on-error` is the coarser version of the step-level hole
# already covered above: GitHub marks the whole aggregate green even when a leg
# failed, and the single REQUIRED check reports Success with the failure behind it.
mutate "the aggregate job hides every failed leg behind a job-level continue-on-error" \
  '    if: ${{ !cancelled() }}
' \
  '    if: ${{ !cancelled() }}
    continue-on-error: true
' \
  "hides a failure behind continue-on-error" \
  "${CI}"

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
  # Reported on its own rather than appended to `mismatches`: that array is
  # headed NON-BITING / WRONG-RED / INVALID MUTATIONS, and a literal pin is none
  # of those. It is a statement about this file, and a maintainer looking for it
  # under a heading about mutations will not find it.
  printf 'GUARD FAILED: this harness spells out a commit SHA again, so a Dependabot\n' >&2
  printf 'bump would refuse these mutations and report a missing assertion:\n' >&2
  printf '  %s\n' "${literal_pins}" >&2
  printf 'Read the pin out of the workflow with wf_derive instead.\n' >&2
  exit 1
fi
printf '  ok   no literal commit SHA anywhere in this file; every pin is read from the workflow\n'

restore
final_out="$(PYTHONDONTWRITEBYTECODE=1 bash "${SUITE}" 2>&1)"
final_rc=$?
echo
if [[ ${final_rc} -ne 0 ]]; then
  mismatches+=("restoring the originals did not return the suite to green")
  printf '%s\n' "${final_out}" | tail -5 | sed 's/^/        /' >&2
fi

printf 'mutations: %d run, %d bit, suite after restore: %s\n' \
  "${MUTATIONS_RUN}" "${MUTATIONS_BITING}" \
  "$(grep -E '^[[:space:]]*[0-9]+ passed' <<<"${final_out}" || echo 'no summary')"

if ((${#mismatches[@]} > 0)); then
  printf '\nNON-BITING / WRONG-RED / INVALID MUTATIONS (%d):\n' "${#mismatches[@]}" >&2
  printf '  - %s\n' "${mismatches[@]}" >&2
  exit 1
fi
printf 'all %d mutations bit\n' "${MUTATIONS_RUN}"