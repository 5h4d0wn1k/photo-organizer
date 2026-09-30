#!/usr/bin/env bash
#
# Structural hygiene for .github/workflows/*.yml.
#
# Workflow files are the highest-leverage text in the repo: one trigger word
# decides whether a gate runs with fork code and base-repo secrets
# (`pull_request_target`), one unpinned action decides whether a compromised
# upstream can inject code into the release, and one missing timeout decides
# whether a hung job burns the Actions budget for six hours. All three have
# happened here or next door: `semantic-pr.yml` used `pull_request_target` and
# never successfully ran once (issue #103), which is how a privileged trigger
# sat unnoticed on every branch.
#
# These are parsed-YAML assertions, not greps, so reformatting cannot silently
# pass. Every assertion below was mutation-tested.
#
# This suite is device-free and runs in CI inside the `Security gates` job --
# a workflow-hygiene property is a security property -- not inside the release
# gate, which is about the APK.

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORKFLOWS_DIR="${ROOT_DIR}/.github/workflows"
PASS_COUNT=0
FAIL_COUNT=0

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

# PyYAML is a declared, hash-pinned test dependency: scripts/requirements-test.txt,
# installed once per CI job (and by `make deps` locally). This suite deliberately
# does NOT install it (issue #136). Installing at test time made a required
# check's verdict depend on the network, and it is also the path that let a
# version-pinned-but-not-hash-pinned wheel in -- the `PinnedDependenciesID`
# finding Scorecard raised against this very line.
#
# `actions/setup-python` puts the pinned interpreter first on PATH, so `python3`
# here is the same interpreter the dependency was installed for.
if ! python3 -c "import yaml" >/dev/null 2>&1; then
  # Runs inside the REQUIRED `Security gates` check, so continuing would report
  # that check green having asserted nothing, and the job would pass every other
  # step -- making an unverified contract indistinguishable from a verified one.
  # Fail closed, and say why here rather than letting the assertion floor below
  # report "an assertion was deleted or a gate was neutered", which points the
  # reader at a deleted assertion instead of at the missing dependency that
  # caused it. (That misdiagnosis is not hypothetical: this guard shipped once
  # as two copies of the install block with no exit at all, and the floor was
  # the only thing making it fail closed.)
  printf '  !! pyyaml is unavailable, so NO workflow-hygiene assertion ran\n' >&2
  printf '  !! Install the hash-pinned test dependencies with: make deps\n' >&2
  printf '  !! That needs CPython 3.8-3.13 on a FRESH environment: PyYAML 6.0.2\n' >&2
  printf '  !!  publishes no 3.14 wheel and the install is --only-binary, so it refuses\n' >&2
  printf '  !!  rather than compiling the sdist. If PyYAML is already installed pip\n' >&2
  printf '  !!  short-circuits and neither flag is exercised -- use a new venv to check.\n' >&2
  printf '  !! This is a required check and is failing rather than passing empty.\n' >&2
  exit 1
fi

checks="$(python3 - "${WORKFLOWS_DIR}" <<'PYTHON'
import glob
import os
import re
import sys

import yaml

workflows_dir = sys.argv[1]
results = []
# action name -> {declared major -> a file that declared it}
# (named pin_majors, not `declared`: the permissions check below already
# uses `declared` as a local boolean, and shadowing it silently turned a
# dict into a bool mid-loop.)
pin_majors = {}

SHA_PIN = re.compile(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+@[0-9a-f]{40}$")

# Cross-file: exactly one audited ref per action. Populated by the per-file
# loop below and reported after it, because the property is repo-wide and
# cannot be judged from inside a single file.
pins_by_action: dict[str, dict[str, list[str]]] = {}

for path in sorted(glob.glob(os.path.join(workflows_dir, "*.yml"))):
    name = os.path.basename(path)
    with open(path, encoding="utf-8") as handle:
        raw = handle.read()
    try:
        workflow = yaml.safe_load(raw)
    except yaml.YAMLError as exc:
        results.append(f"parse\t{name}\tno\tunparseable: {exc}")
        continue
    if not isinstance(workflow, dict):
        results.append(f"parse\t{name}\tno\tnot a mapping")
        continue
    results.append((f"parse\t{name}\tyes\t"))

    # No pull_request_target anywhere. That trigger runs fork code with
    # base-repo secrets access; nothing in this repo needs it, and the one
    # workflow that had it never ran once (#103). Checked on the parsed
    # trigger set, so a comment mentioning the word cannot satisfy it and a
    # trigger added under an alias cannot dodge it. Read under both `on` and
    # `True`: PyYAML parses the bare word `on:` as boolean true (YAML 1.1),
    # so `workflow["on"]` alone is always empty and the check would be vacuous.
    triggers = workflow.get(True, workflow.get("on", {}))
    if isinstance(triggers, dict):
        trigger_names = set(triggers)
    elif isinstance(triggers, list):
        trigger_names = set(triggers)
    else:
        trigger_names = {triggers}
    results.append((
        f"trigger\t{name}\t"
        + ("yes\t" if "pull_request_target" not in trigger_names else "no\tuses pull_request_target")
    ))

    # Concurrency. Four separate ways to get this wrong, and they are not the
    # same wrong, so they are four assertions rather than one "concurrency: yes".
    #
    #   (1) no group at all -- every run queues, so a force-push storm re-runs
    #       superseded commits (issue #105). #124 adds groups to the five
    #       workflows that had none.
    #   (2) a group that is a bare literal -- every ref, branch and event in the
    #       repository shares one bucket, which turns "cancel superseded runs"
    #       into "cancel whatever else happened to be running".
    #   (3) cancellation left off -- the same queueing in a subtler spelling: the
    #       group is present, so (1) passes, and nothing is ever superseded.
    #   (4) a workflow reachable by two different triggers, with cancellation on,
    #       must be able to tell those triggers apart *in the group*.
    #
    # (4) is the one that is easy to miss, because `github.ref` looks like it
    # identifies the run. It does not distinguish trigger classes: `schedule` and
    # `workflow_dispatch` both run on the default branch, so they share a ref.
    # With `cancel-in-progress: true` the newer run then cancels the older one
    # across trigger classes, silently -- and for canary.yml, whose entire
    # purpose is proving that a scheduled workflow is still running, a manual
    # "is the schedule alive?" dispatch cancels the weekly run that would have
    # reported it. #124 shipped exactly that, in scorecard.yml and canary.yml,
    # because nothing here asserted it.
    #
    # Read from the parsed mapping, so the explanatory comment beside a block
    # cannot satisfy any of these.
    concurrency = workflow.get("concurrency")
    group = str(concurrency.get("group", "") or "") if isinstance(concurrency, dict) else ""
    if not group.strip():
        results.append((f"concurrency\t{name}\tno\tno concurrency group declared"))
    else:
        results.append((f"concurrency\t{name}\tyes\t"))

        if "${{" not in group:
            results.append((
                f"concurrency-group\t{name}\tno\t"
                f"the group is the bare literal {group!r}, so every ref and every "
                "branch in the repository shares one bucket; a group has to "
                "interpolate at least the ref to mean anything"
            ))
        else:
            results.append((f"concurrency-group\t{name}\tyes\t"))

        # `cancel-in-progress` is optional and defaults to false, which is the
        # queueing #105 exists to remove. An expression is accepted only when it
        # is gated on the trigger, which is how codeql-analysis.yml declines to
        # cancel a pull_request run. `is True` rather than truthiness, so the
        # quoted string "false" -- which YAML hands back verbatim -- is not read
        # as cancellation being enabled.
        cip = concurrency.get("cancel-in-progress", None)
        cancels = cip is True or (isinstance(cip, str) and "github.event_name" in cip)

        if name == "release.yml":
            # The one place a cancelled run is worse than a wasted one: this is
            # the artifact QA gate, so cancelling a mid-flight release would
            # skip the install/launch/crash evidence entirely (see AGENTS.md).
            if cip is not False:
                results.append((
                    f"concurrency-cancel\t{name}\tno\t"
                    "release.yml must keep cancel-in-progress: false so a new tag "
                    "cannot cancel a release that is mid-flight"
                ))
            else:
                results.append((f"concurrency-cancel\t{name}\tyes\t"))
        elif not cancels:
            results.append((
                f"concurrency-cancel\t{name}\tno\t"
                f"cancel-in-progress is {cip!r}, so superseded runs queue instead of "
                "being cancelled; a read-only workflow declares true, or an "
                "expression gated on github.event_name if cancellation has to "
                "vary by trigger"
            ))
        else:
            results.append((f"concurrency-cancel\t{name}\tyes\t"))

        if cancels and len(trigger_names) > 1 and "github.event_name" not in group:
            results.append((
                f"concurrency-scope\t{name}\tno\t"
                f"triggers {sorted(trigger_names)} share the group {group!r} and "
                "cancel-in-progress is on, so a run of one trigger can cancel a "
                "run of another; the group has to reference github.event_name"
            ))
        else:
            results.append((f"concurrency-scope\t{name}\tyes\t"))

    # Least privilege, declared. A workflow without top-level permissions
    # inherits the repository default, which is a decision nobody made here.
    # `read-all` counts: it is an explicit posture (the OpenSSF Scorecard
    # default), not an omission. `write-all` does not count, for the opposite
    # reason.
    top_permissions = workflow.get("permissions")
    declared = isinstance(top_permissions, dict) or top_permissions == "read-all"
    results.append((
        f"permissions\t{name}\t"
        + ("yes\t" if declared else "no\tno top-level permissions declaration")
    ))

    jobs = workflow.get("jobs") or {}
    for job_id, job in jobs.items():
        if not isinstance(job, dict):
            results.append((f"job\t{name} {job_id}\tno\tnot a mapping"))
            continue
        # A hung job without a timeout burns Actions minutes until the
        # six-hour default kills it. Every job states its own budget.
        if "timeout-minutes" in job:
            results.append((f"timeout\t{name} {job_id}\tyes\t"))
        else:
            results.append((f"timeout\t{name} {job_id}\tno\tno timeout-minutes"))
        # Action inputs must be scalars. A YAML sequence or mapping under
        # `with:` is schema-invalid: GitHub rejects the whole workflow at
        # registration with zero jobs and a "workflow file issue" run, which
        # is exactly how semantic-pr.yml silently never ran (issue #103 -- a
        # flow-style `types: [...]` where the action expects a
        # newline-delimited string). Valid YAML is not enough; it must be a
        # valid workflow.
        for index, step in enumerate(job.get("steps", []) or []):
            if not isinstance(step, dict):
                continue
            inputs = step.get("with", {})
            if not isinstance(inputs, dict):
                continue
            for key, value in inputs.items():
                if isinstance(value, (dict, list)):
                    results.append((
                        f"input\t{name} {job_id} step {index} with.{key}\tno\t"
                        "not a scalar; GitHub rejects the workflow at registration"
                    ))
                else:
                    results.append((f"input\t{name} {job_id} step {index} with.{key}\tyes\t"))

    # Every third-party action pinned to a full commit SHA. A tag or branch
    # ref is mutable: whoever controls the upstream tag controls our CI.
    # docker:// and local ./ actions carry no ref and are not subject to this.
    #
    # The trailing `# vN` comment is captured too. It is the thing a reviewer
    # reads to decide how much attention a line deserves, and Dependabot rewrites
    # the SHA without rewriting the comment -- PR #128 moved
    # actions/download-artifact to v8 while leaving `# v4` in place, and nothing
    # in CI noticed. See #130.
    #
    # What this can and cannot see, stated rather than implied. `pin-version`
    # proves the comment is *parseable*; `pin-major` proves every pin of an
    # action declares the *same* major. Neither can prove the declared major is
    # the truth, because that needs the network: resolving a SHA to its tag is
    # exactly the lookup this suite deliberately does not make. So the split is:
    #
    #   comments that disagree with each other -> caught here (`pin-major`)
    #   a comment that disagrees with reality -> NOT caught; that is #135
    #
    # `parity` below covers the case that actually happened in #133 -- a ref
    # that differs from the repo-wide value. An audited action -> SHA map would
    # cover a wholesale consistent re-pin, and is filed as #135.
    for match in re.finditer(r"uses:\s*(\S+)[ \t]*(#[^\n]*)?", raw):
        action = match.group(1)
        comment = (match.group(2) or "").strip()
        if action.startswith("./") or action.startswith("docker://"):
            continue
        if SHA_PIN.match(action):
            results.append((f"pin\t{name} {action}\tyes\t"))
            repo, _, ref = action.partition("@")
            pins_by_action.setdefault(repo, {}).setdefault(ref, []).append(name)
        else:
            results.append((f"pin\t{name} {action}\tno\tnot pinned to a 40-char SHA"))
            continue
        version = re.fullmatch(r"#\s*v(\d+)(?:\.\d+)*", comment)
        if version is None:
            results.append((
                f"pin-version\t{name} {action}\tno\t"
                "no parseable '# vN' version comment, so a reader cannot tell how far the pin moved"
            ))
        else:
            results.append((f"pin-version\t{name} {action} # v{version.group(1)}\tyes\t"))
            # Key by repository, not by full action name. `github/codeql-action`
            # ships init/autobuild/analyze/upload-sarif as separate actions, and
            # the release candidate is shared -- four sub-actions at two majors
            # means the scan ran on something other than what it claims to have
            # scanned. Keying by the full name let that through.
            repo = "/".join(action.split("@")[0].split("/")[:2])
            pin_majors.setdefault(repo, {})[version.group(1)] = name

# One action must be declared at one major everywhere it is used. A grouped
# Dependabot PR that bumps some uses and not others would otherwise leave CI
# running two majors of the same action -- the exact shape of drift that let the
# mislabelled download-artifact pin through.
for action, majors in sorted(pin_majors.items()):
    where = ", ".join(f"v{major} in {path}" for major, path in sorted(majors.items()))
    if len(majors) == 1:
        major = next(iter(majors))
        results.append((f"pin-major\t{action} (v{major} everywhere)\tyes\t"))
    else:
        results.append((
            f"pin-major\t{action}\tno\tdeclared at more than one major: {where}"
        ))

# One ref per action, repo-wide.
#
# The per-file `pin` assertion only proves the *shape* of the ref, and that
# gap was load-bearing rather than theoretical. Two pins in release.yml read
# `actions/checkout@3d3d42e5...` where the other fourteen read `3d3c42e5...`:
# one character apart, both perfectly well-formed 40-hex strings. Every shape
# assertion passed, every mutation harness in the repository reported a clean
# bite, and the `android` job -- which declares no `needs:` and therefore always
# runs on a `v*` tag -- failed to resolve its own checkout before executing a
# single step. The entire Android release path, including the install+launch
# gate AGENTS.md calls blocking, was unrunnable and nothing in the repo could
# see it, because checking that a ref *looks* like a SHA is not checking that
# it is the SHA somebody audited.
#
# Parity closes that: a ref that differs from the repo-wide value is a finding
# even when both values are valid SHAs, because "reviewed once, used
# everywhere" is the property actually being relied on. Two majors of one
# action coexisting is the same defect wearing a different mask -- that was
# #133, project.yml on v4.2.2 while thirteen other pins were on v7 -- and
# parity rejects it for the same reason. Splitting an action's refs across
# workflows means one of them was pinned without review.
for repo in sorted(pins_by_action):
    refs = pins_by_action[repo]
    placements = sum(len(files) for files in refs.values())
    if len(refs) == 1:
        only = next(iter(refs))
        results.append((
            f"parity\t{repo}\tyes\t{placements} pin(s), all on {only}"
        ))
    else:
        detail = "; ".join(
            f"{ref} in {', '.join(sorted(set(files)))}"
            for ref, files in sorted(refs.items())
        )
        results.append((
            f"parity\t{repo}\tno\t{len(refs)} distinct refs for one action, so at "
            f"least one was pinned without review: {detail}"
        ))

for line in results:
    print(line)
PYTHON
)"
while IFS=$'\t' read -r kind where ok_flag detail; do
  [[ -n "${kind}" ]] || continue
  if [[ "${ok_flag}" == "yes" ]]; then
    ok "${kind}: ${where}"
  else
    bad "${kind}: ${where}" "${detail}"
  fi
done <<<"${checks}"

# --- the test dependency must be provisioned before it is used -------------
# The suites under scripts/tests/ parse YAML, so they need PyYAML. Where that
# PyYAML comes from is a security property, not a convenience, and it is asserted
# here because the failure mode is invisible: a suite that does not find yaml
# exits 1, but a suite that quietly installs its own does not -- it reaches the
# network inside a required check, with a version pin and no hash, which is the
# exact `PinnedDependenciesID` finding Scorecard raised against these lines
# (issue #136).
#
# Both halves matter and they fail differently:
#   * the *content* of the lockfile is proven by `--require-hashes`, which pip
#     runs against the bytes it downloads;
#   * the *presence and ordering* of the install is proven here, because a hash-
#     verified install that happens after the suites have already run enforces
#     nothing at all, and the suites would simply exit 1 having asserted nothing
#     (which they do fail closed on, but the required check would be red for a
#     reason that reads like a dependency problem rather than a wiring one).
check_deps="$(python3 - "${WORKFLOWS_DIR}" <<'PYTHON'
import os
import re
import sys

import yaml

# The supported-interpreter range is a property of the lockfile's pin, so it is
# read from the lockfile itself rather than restated here or held as a constant in
# the generator. The generator derives it from the artifact filenames and renders
# it into the header; the header is what round-trip equality proves, so a
# hand-edited range cannot survive. Two independent copies of that number would
# drift, and the drift would only show up as a confusing pip failure in CI.
import importlib.util

workflows_dir = sys.argv[1]
repo_root = os.path.dirname(os.path.dirname(workflows_dir))
ci_path = os.path.join(workflows_dir, "ci.yml")
requirements_rel = "scripts/requirements-test.txt"

_spec = importlib.util.spec_from_file_location(
    "gen_test_requirements", os.path.join(repo_root, "scripts", "gen_test_requirements.py")
)
_generator = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_generator)
REQUIREMENTS_PACKAGE = _generator.PACKAGE
REQUIREMENTS_VERSION = _generator.VERSION

# The range the generator derived from the artifact list, as it stands in the
# committed lockfile's header. If the header cannot be parsed the range is
# unknown, and every assertion below that depends on it has to fail rather than
# fall back to a default -- a default here is exactly the "unasserted precondition"
# failure mode, and it would let the check pass for a lockfile that says nothing.
_range_body = ""
_range_path = os.path.join(repo_root, "scripts", "requirements-test.txt")
if os.path.isfile(_range_path):
    with open(_range_path, encoding="utf-8") as _handle:
        _range_body = _handle.read()
_range_match = _generator.CP_RANGE_IN_HEADER.search(_range_body)
if not _range_match:
    MIN_WHEEL_CPYTHON = MAX_WHEEL_CPYTHON = None
else:
    MIN_WHEEL_CPYTHON = int(_range_match.group(1))
    MAX_WHEEL_CPYTHON = int(_range_match.group(2))

results = []


def ok(label, detail=""):
    results.append(f"testdeps\t{label}\tyes\t{detail}")


def no(label, detail):
    results.append(f"testdeps\t{label}\tno\t{detail}")


with open(ci_path, encoding="utf-8") as handle:
    ci = yaml.safe_load(handle)

jobs = ci.get("jobs") or {}

# Suites that need PyYAML, and the runner that reaches one of them indirectly.
YAML_SUITES = (
    "workflow_hygiene_test.sh",
    "required_checks_test.sh",
    "release_workflow_test.sh",
)
RUNNERS = ("scripts/tests/", "run_release_gate_tests.sh")


def step_text(step):
    """Everything about a step, with shell comments stripped.

    The stripping is load-bearing and this function is the second version of it.
    The first checked flags against the raw `run` text, and the release-gate
    install step's own explanatory comment contains the string
    `--require-hashes`. So deleting that flag from the command left the comment
    to satisfy the assertion: it reported `ok` for a step that verified nothing.
    A comment asserting the property is not the property.
    """
    command = "\n".join(
        line for line in str(step.get("run", "")).splitlines() if not line.strip().startswith("#")
    )
    return " ".join([command] + [str(step.get(key, "")) for key in ("name", "uses", "with")])


def step_command(step):
    """Only the command a step executes, with shell comments stripped.

    Narrower than step_text on purpose. step_text also folds in `name`, `uses` and
    `with`, which is right for asking "does this step have anything to do with X"
    and wrong for asking "does this step RUN X": a step named
    "Run gen_test_requirements_test.sh" whose `run` is commented out satisfies
    step_text while executing nothing. Mutation-tested: commenting out the
    invocation, and naming the suite while running something else, both fail only
    because this function ignores the name.
    """
    return "\n".join(
        line for line in str(step.get("run", "")).splitlines() if not line.strip().startswith("#")
    )


def is_install_step(step):
    return "pip install" in step_text(step) and requirements_rel in step_text(step)


for job_name, job in sorted(jobs.items()):
    steps = job.get("steps") or []

    install_positions = [i for i, step in enumerate(steps) if is_install_step(step)]
    consumer_positions = [
        i
        for i, step in enumerate(steps)
        if any(token in step_text(step) for token in RUNNERS)
        or any(suite in step_text(step) for suite in YAML_SUITES)
    ]

    if not consumer_positions:
        # This job runs no suite, so it needs no PyYAML. Asserting otherwise
        # would be over-assertion: it would force a meaningless install step into
        # every future job.
        continue

    if not install_positions:
        no(
            f"{job_name}: provisions the test dependency",
            "runs a YAML-parsing suite but has no step that pip-installs "
            f"{requirements_rel}",
        )
        continue

    if len(install_positions) > 1:
        no(
            f"{job_name}: provisions the test dependency",
            f"{len(install_positions)} install steps ({install_positions}); exactly one "
            "is expected, so there is no question about which dependency is in effect",
        )
        continue

    install_at = install_positions[0]
    first_use = min(consumer_positions)
    if install_at < first_use:
        ok(
            f"{job_name}: provisions the test dependency before use",
            f"install at step {install_at}, first suite at step {first_use}",
        )
    else:
        no(
            f"{job_name}: provisions the test dependency before use",
            f"install at step {install_at} runs at or after the first suite at step "
            f"{first_use}, so the suites run with no yaml module",
        )

    install_text = step_text(steps[install_at])
    missing = [
        flag
        for flag in ("--require-hashes", "--only-binary=:all:")
        if flag not in install_text
    ]
    if missing:
        no(
            f"{job_name}: the install verifies what it downloads",
            f"missing {', '.join(missing)}; without --require-hashes a version pin "
            "accepts a substituted artifact, and without --only-binary pip silently "
            "builds the sdist instead of failing on an interpreter that has no wheel",
        )
    else:
        ok(
            f"{job_name}: the install verifies what it downloads",
            "--require-hashes --only-binary=:all:",
        )

# The interpreter is pinned rather than inherited from the runner image. PyYAML
# 6.0.2 has no CPython 3.14 wheel, so on a 3.14 interpreter the install fails by
# design; pinning makes the interpreter a stated fact instead of a property of
# whichever image the runner happens to be.
for job_name, job in sorted(jobs.items()):
    steps = job.get("steps") or []
    if not any(is_install_step(step) for step in steps):
        continue
    setup = [
        step
        for step in steps
        if "actions/setup-python@" in str(step.get("uses", ""))
    ]
    if not setup:
        no(
            f"{job_name}: pins the interpreter",
            "installs hash-pinned with --only-binary but never pins the Python "
            "version, so the install depends on the runner image",
        )
        continue
    ref = str(setup[0].get("uses", "")).split("@", 1)[-1]
    if not re.fullmatch(r"[0-9a-f]{40}", ref):
        no(
            f"{job_name}: pins the interpreter",
            f"actions/setup-python is not pinned by full SHA (got {ref!r})",
        )
        continue
    version = str((setup[0].get("with") or {}).get("python-version", ""))
    if not re.fullmatch(r"\d+\.\d+(\.\d+)?", version):
        no(
            f"{job_name}: pins the interpreter",
            f"python-version {version!r} is not an exact minor/major, so it can float "
            "onto an interpreter with no published wheel",
        )
        continue
    # Exact is not the same as available. An interpreter outside the range for
    # which this pin publishes a wheel fails at install with a message that names
    # the package rather than the missing wheel, so it is worth catching here where
    # the diagnosis is obvious.
    minor_text = version.split(".")[1] if "." in version else version
    try:
        minor = int(minor_text)
    except ValueError:
        no(f"{job_name}: pins the interpreter", f"cannot read a minor from {version!r}")
        continue
    # The range is read from the committed lockfile, so a lockfile whose header
    # no longer states it must fail here rather than skip the comparison. `None`
    # compares false against every value, so this cannot be satisfied by accident.
    if MIN_WHEEL_CPYTHON is None:
        no(
            f"{job_name}: pins the interpreter",
            "the committed lockfile states no CPython range, so the pinned "
            f"interpreter {version} cannot be checked against it. Regenerate the "
            "lockfile with scripts/gen_test_requirements.py.",
        )
        continue
    if not MIN_WHEEL_CPYTHON <= minor <= MAX_WHEEL_CPYTHON:
        no(
            f"{job_name}: pins the interpreter",
            f"python {version} is outside CPython "
            f"3.{MIN_WHEEL_CPYTHON}-3.{MAX_WHEEL_CPYTHON}, the range for "
            f"which {REQUIREMENTS_PACKAGE}=={REQUIREMENTS_VERSION} publishes a wheel. "
            "CI's interpreter is always fresh, so --only-binary is exercised and the "
            "install would fail -- but with an error that blames the package rather "
            "than naming the missing wheel.",
        )
        continue
    ok(f"{job_name}: pins the interpreter", f"actions/setup-python@{ref[:12]} python {version}")

# The new suites have to actually run somewhere, or they are decoration.
#
# "Actually run" means an INVOCATION, not a mention. Three weaker forms were each
# demonstrated to pass while the suite ran nowhere:
#   * `if suite in open(ci_path).read()` is satisfied by a shell comment naming it;
#   * checking the step's `name` as well is satisfied by a step titled after the
#     suite whose `run` is commented out;
#   * checking the step's command for the bare path is satisfied by this workflow's
#     own ShellCheck argument list, which is a `run:` block naming every script it
#     lints -- including these two. I introduced that list while fixing a different
#     review finding, and it silently defanged these two assertions.
# So the command has to contain the suite as an argument to an interpreter or to
# `.`, which is what "executes it" means.
INVOCATION_TEMPLATES = (r"(?:^|[\s;&|(])(?:bash|sh|zsh|dash|env|source|\./)\s+[\w./-]*%s\b",)
for suite in ("gen_test_requirements_test.sh", "suites_offline_test.sh"):
    pattern = re.compile(
        "|".join(template % re.escape(suite) for template in INVOCATION_TEMPLATES),
        re.M,
    )
    invoking = [
        f"{job_name} step {i}"
        for job_name, job in sorted(jobs.items())
        for i, step in enumerate(job.get("steps") or [])
        if pattern.search(step_command(step))
    ]
    if invoking:
        ok(f"{suite} is wired into CI", f"executed by {', '.join(invoking)}")
    else:
        no(
            f"{suite} is wired into CI",
            "no step in ci.yml executes it; naming it in a comment, a step title, "
            "or the ShellCheck argument list is not an execution",
        )

# And the lockfile itself has to be committed, not generated into the runner.
requirements_path = os.path.join(repo_root, requirements_rel)
if os.path.isfile(requirements_path):
    with open(requirements_path, encoding="utf-8") as handle:
        body = handle.read()
    # The lookahead rejects an over-long digest rather than counting its first
    # 64 characters -- otherwise a 65-character digest would satisfy a floor
    # that exists to catch truncation.
    hashes = re.findall(r"--hash=sha256:([0-9a-f]{64})(?![0-9A-Za-z])", body)
    if hashes:
        ok(requirements_rel, f"committed, {len(hashes)} hashes")
    else:
        no(
            requirements_rel,
            "committed but contains no --hash entries, so --require-hashes has "
            "nothing to verify against",
        )
else:
    no(requirements_rel, "not present in the working tree")

for line in results:
    print(line)
PYTHON
)"
while IFS=$'\t' read -r kind where ok_flag detail; do
  [[ -n "${kind}" ]] || continue
  if [[ "${ok_flag}" == "yes" ]]; then
    ok "${kind}: ${where}"
  else
    bad "${kind}: ${where}" "${detail}"
  fi
done <<<"${check_deps}"

# --- dependabot grouping must not hide a major bump ------------------------
# The actual root cause behind the mislabelled download-artifact pin in #128:
# with a bare `patterns: ["*"]`, Dependabot puts every github-actions update in
# one PR no matter how far it moves, so a 4.1.8 -> 8.0.1 jump rides along beside
# two-line patch bumps. Asserted here because the fix is one line of YAML and
# easy to "tidy" away without anyone noticing what it was for.
#
# The property is "no group bundles a major bump with anything else", so the
# check is on `update-types` and NOT on the shape of `patterns`. An earlier
# version of this suite tested `patterns != ["*"]` and only then looked at
# `update-types` -- which meant the identical hazard re-expressed itself as
# `["**"]`, `["actions/**"]` or `["*", "actions/checkout"]` and walked straight
# through. Measured on that version, with majors re-included in every row:
#
#   patterns: ["*"]                      -> FAIL  (correct)
#   patterns: ["**"]                     -> ok    (bypass)
#   patterns: ["*", "actions/checkout"]  -> ok    (bypass)
#   patterns: ["actions/**"]             -> ok    (bypass)
#
# That is the same shape as the two `3d3d42e5...` pins in #133: an
# exact-literal test that a shape-equivalent value passes. `patterns` is now
# reported for information only; `update-types` decides.
dependabot="${ROOT_DIR}/.github/dependabot.yml"
if [[ ! -f "${dependabot}" ]]; then
  bad "dependabot.yml exists" "${dependabot} not found"
else
  dependabot_findings="$(python3 - "${dependabot}" <<'PYTHON'
import sys

import yaml

with open(sys.argv[1], encoding="utf-8") as handle:
    config = yaml.safe_load(handle)

saw_github_actions = False
for update in config.get("updates", []) or []:
    if update.get("package-ecosystem") != "github-actions":
        continue
    saw_github_actions = True
    groups = update.get("groups") or {}
    if not groups:
        print("grouped: github-actions|no|no groups; Dependabot opens one PR per bump, ungrouped")
        continue
    for group_name, group in groups.items():
        patterns = group.get("patterns")
        if not patterns:
            # A group with no patterns is not a scoped group, it is an invalid
            # one -- and it must not be mistaken for the safe case, which is how
            # an ungrouped-by-accident config would slip through this check.
            print(
                f"grouped: github-actions/{group_name}|no|"
                "group has no patterns, so it does not separate anything by action"
            )
            continue
        update_types = group.get("update-types")
        if not update_types:
            print(
                f"grouped: github-actions/{group_name}|no|"
                f"patterns {patterns} with no update-types, so a multi-major bump of an action in"
                " the release path is bundled with patch bumps and reviewed as one small diff"
            )
        elif "major" in update_types:
            print(
                f"grouped: github-actions/{group_name}|no|"
                f"patterns {patterns} and update-types includes 'major', so majors are still"
                " bundled with patch bumps"
            )
        else:
            print(
                f"grouped: github-actions/{group_name}|yes|"
                f"patterns {patterns}, update-types {update_types}, so major bumps arrive as"
                " their own PR"
            )

# Without this, deleting the whole `github-actions` ecosystem from
# dependabot.yml makes the loop above emit nothing at all, and every `grouped:`
# check silently disappears rather than failing. A gate that can be switched off
# by deleting the thing it reads is not a gate.
if saw_github_actions:
    print(
        "grouped: github-actions-ecosystem|yes|"
        "dependabot.yml configures the github-actions ecosystem, so the group checks above are"
        " reading real configuration"
    )
else:
    print(
        "grouped: github-actions-ecosystem|no|"
        "dependabot.yml declares no github-actions ecosystem, so action bumps are unconfigured"
        " and every group check above was vacuous"
    )
PYTHON
)"
  while IFS='|' read -r dep_where dep_ok dep_detail; do
    [[ -n "${dep_where}" ]] || continue
    if [[ "${dep_ok}" == "yes" ]]; then
      ok "grouped: ${dep_where#grouped: }"
    else
      bad "grouped: ${dep_where#grouped: }" "${dep_detail}"
    fi
  done <<<"${dependabot_findings}"
fi

# Floor, not a target. Set to the number of *real* assertions above, so that
# deleting one -- or neutering a gate by removing the line that records a pin,
# which drops the total without removing any visible check -- fails the suite
# instead of quietly reporting a smaller pass. This suite had no floor at all
# before, so "it went green" and "someone removed the check" were
# indistinguishable.
#
# The count only ever grows on its own, so the floor cannot go stale in the
# permissive direction: adding a workflow or a step raises the total and the
# floor is untouched. Work that legitimately *shrinks* the suite -- deleting
# semantic-pr.yml once #103 retires it, say -- must lower this number in the
# same change, in the open, where the reduction is visible in the diff. That is
# the point: shrinking the gate is allowed, doing it quietly is not.
MINIMUM_ASSERTIONS="${MINIMUM_ASSERTIONS:-232}"
if ((PASS_COUNT < MINIMUM_ASSERTIONS)); then
  bad "assertion floor" "only ${PASS_COUNT} assertions ran, floor is ${MINIMUM_ASSERTIONS}: an assertion was deleted or a gate was neutered"
else
  ok "assertion floor: ${PASS_COUNT} >= ${MINIMUM_ASSERTIONS}"
fi

printf '\n%s passed, %s failed\n' "${PASS_COUNT}" "${FAIL_COUNT}"
if ((FAIL_COUNT > 0)); then
  exit 1
fi
