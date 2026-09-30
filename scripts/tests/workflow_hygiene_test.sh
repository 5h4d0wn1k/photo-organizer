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
  # Pinned so a future PyYAML release cannot change the assertions' behaviour,
  # and best-effort: the next check fails loudly if it did not work.
  python3 -m pip install --quiet "pyyaml==6.0.2" >/dev/null 2>&1 || true
fi
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
  printf '  !! Install it with: python3 -m pip install "pyyaml==6.0.2"\n' >&2
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
