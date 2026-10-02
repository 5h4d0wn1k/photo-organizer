#!/usr/bin/env bash
#
# Asserts that every test suite in scripts/tests/ is actually EXECUTED by a
# required CI check (issue #136).
#
# Why this file exists, and why it is about wiring rather than behaviour: three
# separate assertions in this repository were satisfied by something that ran
# nothing.
#
#   1. A step whose `name` mentioned a suite, with the `run` body commented out.
#   2. A `#` shell comment inside a step naming a suite.
#   3. The ShellCheck step's argument list -- itself a `run:` block -- naming every
#      script it lints. That list was added to ci.yml while fixing an unrelated
#      review finding, and it silently defanged two assertions that had been
#      passing on it ever since. A mutation pass is what caught it, two days of
#      green required checks later.
#
# The lesson generalises: "the suite is mentioned in ci.yml" is not a property
# anyone wants to assert, and "the suite ran" is a property nobody can see without
# a mutation pass to say so. This file makes the first cheap enough to check on
# every run, so the second has something to be measured against.
set -uo pipefail

ROOT_DIR="${PO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
TESTS_DIR="${ROOT_DIR}/scripts/tests"
WORKFLOWS_DIR="${ROOT_DIR}/.github/workflows"
MAKEFILE="${ROOT_DIR}/Makefile"
# The release-gate driver, which runs suites on behalf of ci.yml.
DRIVER="${ROOT_DIR}/scripts/tests/run_release_gate_tests.sh"

PASS_COUNT=0
FAIL_COUNT=0

ok() {
  PASS_COUNT=$((PASS_COUNT + 1))
  printf '  ok   %s\n' "$1"
}

no() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  printf '  FAIL %s\n' "$1" >&2
  if [[ -n "${2:-}" ]]; then
    printf '        %s\n' "$2" >&2
  fi
}

for required in "${TESTS_DIR}" "${WORKFLOWS_DIR}" "${MAKEFILE}" "${DRIVER}"; do
  if [[ ! -e "$required" ]]; then
    no "${required} exists" "not found"
    printf '  %d passed, %d failed\n' "${PASS_COUNT}" "${FAIL_COUNT}"
    exit 1
  fi
done

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# The suites to account for. A suite that is not `_test.sh` is a helper by this
# repository's convention and is not required to be wired.
mapfile -t SUITES < <(cd "${TESTS_DIR}" && ls -1 *_test.sh 2>/dev/null | sort)
if ((${#SUITES[@]} == 0)); then
  no "scripts/tests contains at least one suite" "no *_test.sh found"
  printf '  %d passed, %d failed\n' "${PASS_COUNT}" "${FAIL_COUNT}"
  exit 1
fi
ok "found ${#SUITES[@]} suites under scripts/tests"

# The per-suite verdicts come back as machine-readable lines so this shell does not
# have to re-implement the step parser, and so a bug in the parser shows up as a
# parser failure rather than as a silently-passing assertion.
if ! python3 - "${WORKFLOWS_DIR}" "${MAKEFILE}" "${DRIVER}" "${WORK}" "${#SUITES[@]}" "${TESTS_DIR}" >"${WORK}/verdicts" <<'PYTHON'
import os
import re
import sys

workflows_dir, makefile, driver, work, expected_count, tests_dir = (
    sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], int(sys.argv[5]), sys.argv[6]
)

# Every place a suite can legitimately be wired. Reading only ci.yml is a check that
# reports correct-looking failures about ten suites which are run by release.yml,
# project.yml, canary.yml, the Makefile, or the release-gate driver -- the same class
# of confident wrong answer this file exists to catch, aimed at itself.
#
# The three sources are read differently on purpose:
#   * a workflow's step COMMAND is what runs, with shell comments stripped;
#   * a Makefile recipe and a driver script's body are shell, so the same treatment
#     applies;
#   * a suite listed as an ARGUMENT (the ShellCheck step lints by filename) is NOT
#     an execution. That distinction is the whole point of the file, so the linter's
#     argument list is deliberately excluded rather than grepped.
steps = []
# Labels contributed by a workflow, as opposed to the Makefile or the driver. The
# distinction matters: `make project-board` running a suite is a convenience, and a
# suite nobody ever wires into a workflow is a suite whose assertions nobody reads
# before a merge. Three suites in this repository were in exactly that state.
WORKFLOW_LABELS = set()


def strip_comments(text):
    """Drop whole-line and trailing shell comments.

    A `#` that starts a word begins a comment; a `#` inside a quoted string does
    not, and that distinction is not tracked here. None of the commands in this
    repository's workflows or Makefile contain a quoted `#` today, so the
    approximation is exact for the present input, and the probe below is where a
    command that breaks it would show up rather than a silent false positive.

    This started as a real gap rather than a hypothetical one: the block-scalar
    reader stripped comments and the `run: <command>` reader did not, so a scalar
    reading `# bash scripts/tests/x_test.sh` after its real command was counted as
    an execution. The probe named "a suite named only in a shell comment" is the
    assertion that would have caught it, and it is in this file for that reason.
    """
    kept = []
    for line in text.splitlines():
        stripped = line.lstrip()
        if stripped.startswith("#"):
            continue
        cut = re.search(r"(?:^|\s)#", line)
        kept.append(line[: cut.start()] if cut else line)
    return "\n".join(kept)


def add(label, command):
    steps.append((label, command))


def add_workflow(label, command):
    WORKFLOW_LABELS.add(label)
    add(label, command)


for name in sorted(os.listdir(workflows_dir)):
    if not name.endswith((".yml", ".yaml")):
        continue
    path = os.path.join(workflows_dir, name)
    with open(path, encoding="utf-8") as handle:
        ci = handle.read()
    for match in re.finditer(r"^(\s*)- name: (.+)$", ci, re.M):
        indent, label = match.group(1), match.group(2).strip()
        rest = ci[match.end():]
        block = []
        for line in rest.splitlines(keepends=True):
            if not line.strip():
                block.append(line)
                continue
            if len(line) - len(line.lstrip()) <= len(indent):
                break
            block.append(line)
        body = "".join(block)
        # `run:` comes in two shapes and both have to be read:
        #   run: bash scripts/tests/foo_test.sh     a plain scalar, on the same line
        #   run: |                                 a block scalar, indented below
        # An earlier version handled only the block form, so eleven of ci.yml's
        # twenty-three steps were invisible to it.
        scalar = re.search(r"^\s*run: (?!\||>)(.+)$", body, re.M)
        if scalar:
            add_workflow(
                f"{name}: {label}", strip_comments(scalar.group(1).strip())
            )
            continue
        blockmatch = re.search(r"^\s*run: [|>][-+]?\s*$", body, re.M)
        if blockmatch:
            key_line = body[: blockmatch.start()].split("\n")[-1]
            key_indent = len(key_line) - len(key_line.lstrip())
            script = []
            for line in body[blockmatch.end():].splitlines(keepends=True):
                if not line.strip():
                    script.append("\n")
                    continue
                indent_now = len(line) - len(line.lstrip())
                if indent_now <= key_indent:
                    break
                script.append(line[key_indent:])
            add_workflow(f"{name}: {label}", strip_comments("".join(script)))

# A Makefile recipe is plain shell, so the same comment rule applies and a bare path
# is not an execution either.
with open(makefile, encoding="utf-8") as handle:
    add("Makefile", strip_comments(handle.read()))

# The release-gate driver is the one site that runs its suites from a bash ARRAY:
#   SUITES=( release_workflow_test.sh ... )
#   for suite in "${SUITES[@]}"; do bash "${TESTS_DIR}/${suite}"; done
# A path-literal matcher cannot see that -- there is no literal path to find, and the
# loop variable is spelled `${suite}`. So the array is read and expanded into literal
# invocations, which is what the runtime actually does.
with open(driver, encoding="utf-8") as handle:
    driver_text = handle.read()
    driver_shell = strip_comments(driver_text)
array = re.search(r"SUITES=\(\n(.*?)\n\)", driver_text, re.S)
if array:
    entries = re.findall(r"^\s+(\S+_test\.sh)\s*$", array.group(1), re.M)
    add("run_release_gate_tests.sh: driver loop", driver_shell)
    for entry in entries:
        # The loop body is literally `bash "${TESTS_DIR}/${suite}"`, so the expanded
        # command is reproduced with a plain path. Reproducing the unexpanded form
        # instead -- `bash "${TESTS_DIR}/${suite}"` -- was tried and does not work:
        # the path character class excludes `$`, so nothing matches. A matcher that
        # cannot see its own subject is a check that reports false failures, which is
        # worse than no check.
        add(f"run_release_gate_tests.sh: SUITES[{entry}]", f"bash scripts/tests/{entry}")
else:
    add("run_release_gate_tests.sh", driver_shell)

if not steps:
    print("STEP PARSER FOUND NO STEPS")
    sys.exit(2)

suites = sorted(
    name for name in os.listdir(tests_dir) if name.endswith("_test.sh")
)
if len(suites) != expected_count:
    print(f"SUITE COUNT MISMATCH: shell saw {expected_count}, python saw {len(suites)}")
    sys.exit(3)

# The comparison above cannot fail on its own: the shell's glob and this listing
# read the same directory, so they always agree, and a check that cannot fail is
# worse than none because it reads as one. This is the comparison that can fail.
# Deleting or adding a suite is then a diff in this line rather than a silent loss
# of coverage, and the failure names what changed.
KNOWN_SUITE_COUNT = 20
if len(suites) != KNOWN_SUITE_COUNT:
    print(
        f"SUITE COUNT TRIPWIRE: found {len(suites)}, recorded {KNOWN_SUITE_COUNT}. "
        f"If that is intentional, update KNOWN_SUITE_COUNT here so the change is a "
        f"reviewed diff. Found: {', '.join(suites)}"
    )
    sys.exit(5)

# The invocation forms that actually run a suite: the suite name as an argument to
# an interpreter or to `.`. A bare path is not one of them.
INVOCATION = re.compile(
    r"(?:^|[\s;&|(])(?:bash|sh|zsh|dash|ksh|env|source|\./)\s+"
    r"(?:[A-Za-z0-9_./-]*/)?"
    r"(?P<suite>[A-Za-z0-9_.-]*_test\.sh)\b"
)

executed = {}
for suite in suites:
    hits = set()
    for label, command in steps:
        for match in INVOCATION.finditer(command):
            if match.group("suite") == suite:
                hits.add(label)
    executed[suite] = sorted(hits)

for suite in suites:
    hits = executed[suite]
    status = "ok" if hits else "fail"
    print(f"{status}\t{suite}\t{'; '.join(hits)}")

# Sanity: if the matcher cannot see a suite that IS run, every failure below is
# vacuously true. This is the check that would have caught the ShellCheck argument
# list being mistaken for an execution.
executed_any = [suite for suite in suites if executed[suite]]
if not executed_any:
    print("NO SUITE FOUND EXECUTED BY ANY STEP -- the invocation matcher is wrong")
    sys.exit(4)

# The driver runs its suites from a loop, so a suite can reach a required check
# without a workflow naming it. Counting that as "local only" would be a false
# accusation -- and an earlier draft of this file made exactly that claim about the
# four Android release-gate suites, which ci.yml does run, through
# `bash scripts/tests/run_release_gate_tests.sh`. So the driver counts as a
# workflow site only when a workflow actually invokes it, and that is checked rather
# than assumed.
DRIVER_NAME = os.path.basename(driver)
# INVOCATION above only matches *_test.sh, and the driver is not one, so it needs its
# own form -- still requiring an interpreter, for the same reason.
DRIVER_INVOCATION = re.compile(
    r"(?:^|[\s;&|(])(?:bash|sh|zsh|dash|ksh|env|source|\./)\s+"
    r"(?:[A-Za-z0-9_./-]*/)?" + re.escape(DRIVER_NAME) + r"\b"
)
driver_in_workflow = any(
    DRIVER_INVOCATION.search(command)
    for label, command in steps
    if label in WORKFLOW_LABELS
)
if not driver_in_workflow:
    print(f"DRIVER-UNWIRED\t{DRIVER_NAME}\tno workflow invokes it")

# A suite can be "wired" purely through the Makefile. That is not nothing, but it is
# not a required check either: nobody reads `make project-board` before merging. So
# the two verdicts are separate, and a suite with no workflow site -- directly or
# through the driver -- is called out rather than quietly counted as covered.
for suite in suites:
    hits = executed.get(suite) or []
    if not hits:
        continue
    in_workflow = any(label in WORKFLOW_LABELS for label in hits)
    if not in_workflow and driver_in_workflow and all(
        label.startswith(f"{DRIVER_NAME}:") for label in hits
    ):
        in_workflow = True
    if not in_workflow:
        print(f"LOCALONLY\t{suite}\t{'; '.join(hits)}")

# The matcher is the part of this suite that has been wrong -- twice -- in this
# repository, and it cannot be checked by the verdicts above: a matcher that accepts
# any bare path satisfies every suite from the ShellCheck argument list and reports a
# clean run. So it is probed against synthetic commands, with the expected answer
# written next to the command. `want=None` means "must not match at all".
probes = [
    ("a bare `bash <suite>` invocation", "bash scripts/tests/probe_test.sh", "probe_test.sh"),
    (
        "a `run:` scalar invoking a suite",
        "        run: bash scripts/tests/probe_test.sh",
        "probe_test.sh",
    ),
    (
        "a suite named in a step label (prose, not an execution)",
        "        run: echo done",
        None,
    ),
    (
        "a suite in the ShellCheck argument list (linted, never run)",
        "shellcheck --severity=warning scripts/tests/probe_test.sh",
        None,
    ),
    (
        "a suite named only in a shell comment",
        strip_comments("# bash scripts/tests/probe_test.sh"),
        None,
    ),
    (
        "a real invocation followed by a trailing comment",
        strip_comments("bash scripts/tests/probe_test.sh  # kept for the record"),
        "probe_test.sh",
    ),
    (
        "a suite named only in a comment beside a real invocation",
        strip_comments("bash scripts/tests/other_test.sh  # bash scripts/tests/probe_test.sh"),
        "other_test.sh",
    ),
    (
        "a suite named in a step's `name:` (prose, not an execution)",
        "        run: make test",
        None,
    ),
]
for name, command, want in probes:
    found = [m.group("suite") for m in INVOCATION.finditer(command)]
    good = (found == [want]) if want else (not found)
    print(
        f"{'PROBE-OK' if good else 'PROBE-FAIL'}\t{name}\t"
        f"want={want!r} got={found!r}"
    )
PYTHON
then
  # The parser's own diagnostics go to stdout, which is captured to a file that is
  # read only on success -- so at the one moment they mattered they were discarded,
  # and the next line pointed the reader at stderr, where they were not. They are
  # the most specific evidence available ("the invocation matcher is wrong", "SUITE
  # COUNT TRIPWIRE: found 19, recorded 18"), so they are shown rather than
  # summarised away. An empty capture is reported too, because a parser that dies
  # silently is a different failure from one that explains itself.
  if [[ -s "${WORK}/verdicts" ]]; then
    sed 's/^/        /' "${WORK}/verdicts" >&2
  else
    printf '        the parser wrote no diagnostics at all\n' >&2
  fi
  no "the step parser produced verdicts" "the parser's own diagnostics are above"
  printf '  %d passed, %d failed\n' "${PASS_COUNT}" "${FAIL_COUNT}"
  exit 1
fi

while IFS=$'\t' read -r status suite detail; do
  case "$status" in
    ok)
      ok "${suite} is executed by a CI step" "${detail}"
      ;;
    fail)
      no "${suite} is executed by a CI step" \
        "named nowhere in a step's command; a step label or the ShellCheck argument list is not an execution"
      ;;
    MENTIONED-NOT-RUN)
      no "${suite} is only mentioned, never run" \
        "a step's label or comment names it, but no step's command invokes it"
      ;;
    LOCALONLY)
      no "${suite} is run by a workflow, not only by the Makefile" \
        "wired only here: ${detail}. It passes locally and in no required check, so no one reads it before a merge. Add a step for it."
      ;;
    DRIVER-UNWIRED)
      no "the release-gate driver is invoked by a workflow" \
        "${detail} -- so the four suites it loops over are wired into no required check either"
      ;;
    PROBE-OK)
      ok "matcher probe: ${suite}"
      ;;
    PROBE-FAIL)
      no "matcher probe: ${suite}" "${detail}"
      ;;
    *)
      no "unexpected parser verdict '${status}'" "${suite} ${detail}"
      ;;
  esac
done <"${WORK}/verdicts"

# --- the no-op substitution check -------------------------------------------
# A step that names a suite and then runs `bash -c true` is the same defect wearing
# a different hat: the label is honest, the command is empty. The ShellCheck step
# legitimately contains `bash -c` in an argument list position, so this looks for the
# invocation form specifically.
# Checked across every workflow and the Makefile, not the one file this check
# originally read: `bash -c true` in a release-gate step would otherwise be invisible.
offenders="$(grep -rnE '(^|[[:space:];&|(])bash[[:space:]]+-c[[:space:]]+true' \
  "${WORKFLOWS_DIR}" "${MAKEFILE}" 2>/dev/null | head -3)"
if [[ -n "$offenders" ]]; then
  no "no step runs \`bash -c true\` in place of a suite" "$offenders"
else
  ok "no step runs \`bash -c true\` in place of a suite"
fi

printf '  %d passed, %d failed\n' "${PASS_COUNT}" "${FAIL_COUNT}"
[[ ${FAIL_COUNT} -eq 0 ]]
