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
  # Pinned so a future PyYAML release cannot change the assertions' behaviour,
  # and best-effort: the next check fails loudly if it did not work.
  python3 -m pip install --quiet "pyyaml==6.0.2" >/dev/null 2>&1 || true
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

# --- dependabot grouping must not hide a major bump ------------------------
# The actual root cause behind the mislabelled download-artifact pin in #128:
# with a bare `patterns: ["*"]`, Dependabot puts every github-actions update in
# one PR no matter how far it moves, so a 4.1.8 -> 8.0.1 jump rides along beside
# two-line patch bumps. Asserted here because the fix is one line of YAML and
# easy to "tidy" away without anyone noticing what it was for.
dependabot="${ROOT_DIR}/.github/dependabot.yml"
if [[ ! -f "${dependabot}" ]]; then
  bad "dependabot.yml exists" "${dependabot} not found"
else
  dependabot_findings="$(python3 - "${dependabot}" <<'PYTHON'
import sys

import yaml

with open(sys.argv[1], encoding="utf-8") as handle:
    config = yaml.safe_load(handle)

for update in config.get("updates", []) or []:
    if update.get("package-ecosystem") != "github-actions":
        continue
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
        if patterns != ["*"]:
            # A narrower group already separates by action name.
            print(f"grouped: github-actions/{group_name}|yes|patterns {patterns}")
            continue
        update_types = group.get("update-types")
        if not update_types:
            print(
                f"grouped: github-actions/{group_name}|no|"
                "patterns ['*'] with no update-types, so a multi-major bump of an action in the"
                " release path is bundled with patch bumps and reviewed as one small diff"
            )
        elif "major" in update_types:
            print(
                f"grouped: github-actions/{group_name}|no|"
                "update-types includes 'major', so majors are still bundled with patch bumps"
            )
        else:
            print(
                f"grouped: github-actions/{group_name}|yes|"
                f"update-types {update_types}, so major bumps arrive as their own PR"
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
