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

if ! python3 -c "import yaml" >/dev/null 2>&1; then
  python3 -m pip install --quiet "pyyaml==6.0.2" >/dev/null 2>&1 || true
fi
if ! python3 -c "import yaml" >/dev/null 2>&1; then
  printf '  SKIP pyyaml is unavailable, so the workflow files cannot be parsed\n'
  printf '  !! RELEASE_GATE_SUITE_DEGRADED: no pyyaml\n'
  printf '  !! These assertions did NOT run; do not read this suite as a pass.\n'
  exit 0
fi

checks="$(python3 - "${WORKFLOWS_DIR}" <<'PYTHON'
import glob
import os
import re
import sys

import yaml

workflows_dir = sys.argv[1]
results = []

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
    for action in re.findall(r"uses:\s*(\S+)", raw):
        if action.startswith("./") or action.startswith("docker://"):
            continue
        if SHA_PIN.match(action):
            results.append((f"pin\t{name} {action}\tyes\t"))
            repo, _, ref = action.partition("@")
            pins_by_action.setdefault(repo, {}).setdefault(ref, []).append(name)
        else:
            results.append((f"pin\t{name} {action}\tno\tnot pinned to a 40-char SHA"))

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
