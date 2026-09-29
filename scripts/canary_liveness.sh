#!/usr/bin/env bash
#
# Canary for the two ways a check in this repo can die silently.
#
#   1. A `schedule:`-triggered workflow (Scorecard, Stale) that stops running --
#      disabled schedule, renamed file, deleted workflow. There is no run, so
#      there is no failure, and the security check is simply gone.
#   2. Drift between .github/required-checks.json (the reviewable contract,
#      issue #104) and what CI actually enforces.
#
# This lives in a script rather than inline in canary.yml for one reason: an
# inline `run:` block cannot be tested, and this file's whole job is to be
# right about which runs should exist. It originally was inline, and it was
# wrong -- it demanded a `Dependency review` check run on the default branch
# HEAD, but that workflow triggers only on pull_request, so the canary would
# have failed forever on a check that can never report there. See
# scripts/tests/canary_liveness_test.sh, which fails when this logic is wrong.
#
# What it proves, precisely:
#   * every scheduled workflow has produced a schedule-triggered run;
#   * every contract-required context is produced by a workflow file that
#     exists, and that workflow has produced a *successful* run under a
#     trigger it actually declares -- checked against a push to the default
#     branch when it declares one, otherwise against its most recent run of any
#     event.
#
# What it does NOT prove, stated here so nobody reads more into it: that the
# context is marked *required* in the ruleset. GITHUB_TOKEN cannot read branch
# protection, so the required flag stays owner-verified (issue #102).

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="${CANARY_REPO:-${GITHUB_REPOSITORY:-}}"
WORKFLOWS_DIR="${CANARY_WORKFLOWS_DIR:-${ROOT_DIR}/.github/workflows}"
CONTRACT="${CANARY_CONTRACT:-${ROOT_DIR}/.github/required-checks.json}"
DEFAULT_BRANCH="${CANARY_DEFAULT_BRANCH:-main}"
# How far back a run may be and still count as proof the schedule is alive.
SCHEDULE_MAX_AGE_DAYS="${CANARY_SCHEDULE_MAX_AGE_DAYS:-10}"
RUN_MAX_AGE_DAYS="${CANARY_RUN_MAX_AGE_DAYS:-14}"

if [[ -z "${REPO}" ]]; then
  echo "::error::CANARY_REPO/GITHUB_REPOSITORY is not set; cannot query the API" >&2
  exit 1
fi

failures=0

note_failure() {
  echo "::error::$1" >&2
  failures=$((failures + 1))
}

# `--plan` prints the resolved plan and exits, with no API calls. It exists so
# the plan's column layout can be asserted directly: the reader splits these
# rows on tab, and an empty field there is silently collapsed, which once made a
# ghost contract context read as `pending` and skip its own check. A mode that
# prints the thing being parsed is the only way to test that.
PLAN_ONLY=false
if [[ "${1:-}" == "--plan" ]]; then
  PLAN_ONLY=true
fi

if ! python3 -c "import yaml" >/dev/null 2>&1; then
  echo "::error::pyyaml is unavailable, so the workflow files cannot be parsed; this canary did not run" >&2
  exit 1
fi

# Emits one tab-separated row per contract context, six fields, none of them ever
# empty:
#   kind <TAB> context <TAB> workflow-file <TAB> event <TAB> has-push <TAB> tier
# A missing workflow-file is the sentinel NO_WORKFLOW, not "": see below.
contract_plan() {
  python3 - "${WORKFLOWS_DIR}" "${CONTRACT}" <<'PYTHON'
import glob
import json
import os
import sys

import yaml

workflows_dir, contract_path = sys.argv[1], sys.argv[2]

# Sentinel for "no workflow in this repo defines that job name". See the note at
# its use below for why this is not the empty string.
NO_WORKFLOW = "(no workflow)"

with open(contract_path, encoding="utf-8") as handle:
    contract = json.load(handle)

# context -> (file, triggers) for every job name every workflow defines.
produced = {}
for path in sorted(glob.glob(os.path.join(workflows_dir, "*.yml"))):
    with open(path, encoding="utf-8") as handle:
        workflow = yaml.safe_load(handle)
    if not isinstance(workflow, dict):
        continue
    # Bare `on:` parses as boolean True under YAML 1.1; read both spellings.
    on = workflow.get(True, workflow.get("on", {}))
    if isinstance(on, dict):
        triggers = sorted(on)
    elif isinstance(on, list):
        triggers = sorted(on)
    elif isinstance(on, str):
        triggers = [on]
    else:
        triggers = []
    for job_id, job in ((workflow.get("jobs") or {}).items()):
        name = str((job or {}).get("name", job_id))
        produced.setdefault(name, (os.path.basename(path), triggers))

for tier in ("required", "pending"):
    for entry in contract.get(tier, []):
        context = entry["context"]
        match = produced.get(context)
        # NEVER an empty string here. The reader splits on tab, and tab is
        # whitespace, so an empty field is collapsed away and every later field
        # shifts left -- which made a ghost context read as `tier=""` and be
        # skipped as "pending", silently, instead of reported. A sentinel keeps
        # the column count fixed no matter what is missing.
        filename, triggers = match if match else (NO_WORKFLOW, [])
        has_push = "push" in triggers or "schedule" in triggers
        # The canary only needs a push-commit run when the workflow really
        # produces one there. `Dependency review` (pull_request only) and a
        # scheduled-only workflow both fall to the most-recent-run path.
        event = "push" if has_push else "recent"
        print(f"contract\t{context}\t{filename}\t{event}\t{has_push}\t{tier}")
PYTHON
}

scheduled_workflows() {
  python3 - "${WORKFLOWS_DIR}" <<'PYTHON'
import glob
import os
import sys

import yaml

workflows_dir = sys.argv[1]
for path in sorted(glob.glob(os.path.join(workflows_dir, "*.yml"))):
    with open(path, encoding="utf-8") as handle:
        workflow = yaml.safe_load(handle)
    if not isinstance(workflow, dict):
        continue
    on = workflow.get(True, workflow.get("on", {}))
    if isinstance(on, dict):
        triggers = set(on)
    elif isinstance(on, list):
        triggers = set(on)
    elif isinstance(on, str):
        triggers = {on}
    else:
        triggers = set()
    if "schedule" not in triggers:
        continue
    # This canary cannot demand a run of itself: its own absence is reported by
    # its own absence, which no check can observe from inside itself. The test
    # is structural -- does any step in this workflow invoke this script -- and
    # not "is the file called canary.yml", because renaming the file would
    # otherwise turn the canary into something permanently unsatisfiable.
    is_self = False
    for job in (workflow.get("jobs") or {}).values():
        if not isinstance(job, dict):
            continue
        for step in job.get("steps", []) or []:
            if isinstance(step, dict) and "canary_liveness.sh" in str(step.get("run", "")):
                is_self = True
    print(f"{os.path.basename(path)}\t{'self' if is_self else 'other'}")
PYTHON
}

days_old() {
  # An unparseable timestamp is a finding, not a zero. Returning non-zero here
  # lets the caller report it rather than treating a garbage value as "fresh".
  python3 - "$1" <<'PYTHON'
import datetime
import sys

raw = sys.argv[1].strip()
try:
    then = datetime.datetime.fromisoformat(raw.replace("Z", "+00:00"))
except ValueError:
    print(f"unparseable timestamp: {raw!r}", file=sys.stderr)
    sys.exit(1)
if then.tzinfo is None:
    then = then.replace(tzinfo=datetime.timezone.utc)
now = datetime.datetime.now(datetime.timezone.utc)
print(max(0, (now - then).days))
PYTHON
}

if [[ "${PLAN_ONLY}" == "true" ]]; then
  contract_plan
  exit 0
fi

echo "== scheduled workflow liveness =="
while IFS=$'\t' read -r workflow self; do
  [[ -n "${workflow}" ]] || continue
  # The canary's own absence is reported by its own absence, which no check can
  # observe from inside itself; its liveness is the Actions tab. Identified by
  # invoking this script, not by filename, so a rename cannot make the canary
  # unsatisfiable.
  if [[ "${self}" == "self" ]]; then
    echo "  ${workflow}: skipped (a check cannot observe its own absence)"
    continue
  fi
  latest="$(
    gh api "repos/${REPO}/actions/workflows/${workflow}/runs?per_page=1&event=schedule" \
      --jq '.workflow_runs[0] | "\(.created_at) \(.conclusion)"' 2>/dev/null || echo "none none"
  )"
  created="${latest%% *}"
  conclusion="${latest##* }"
  echo "  ${workflow}: latest schedule run ${created} -> ${conclusion}"
  if [[ "${created}" == "none" || "${created}" == "null" ]]; then
    note_failure "${workflow} has no schedule-triggered runs; its schedule is dead or the file was renamed"
    continue
  fi
  if ! age="$(days_old "${created}")"; then
    note_failure "${workflow}'s newest schedule run has an unparseable timestamp ('${created}')"
    continue
  fi
  if ((age > SCHEDULE_MAX_AGE_DAYS)); then
    note_failure "${workflow}'s newest schedule run is ${age} days old (limit ${SCHEDULE_MAX_AGE_DAYS}); the schedule is not firing"
  elif [[ "${conclusion}" != "success" ]]; then
    note_failure "${workflow}'s newest schedule run concluded '${conclusion}'"
  fi
done < <(scheduled_workflows)

echo "== contract-required check liveness =="
head_sha="$(
  gh api "repos/${REPO}/commits/${DEFAULT_BRANCH}" --jq '.sha' 2>/dev/null || echo ""
)"
# `null` is what jq prints for a missing SHA, and a failed call leaves the
# variable empty. Both mean the half of the canary below did not run, which is
# not a pass.
if [[ -z "${head_sha}" || "${head_sha}" == "null" ]]; then
  note_failure "could not resolve ${DEFAULT_BRANCH} HEAD; the liveness half of this canary did not run"
else
  echo "  ${DEFAULT_BRANCH} HEAD is ${head_sha}"
  # Column count is fixed by contract: every row is six tab-separated fields and
  # none may be empty, because tab is whitespace and an empty field would be
  # collapsed, shifting every later field left. The `has_push` field is read and
  # ignored -- `event` already encodes the decision it feeds -- but it is kept so
  # a future column addition is a visible change rather than a silent
  # misalignment.
  # shellcheck disable=SC2034
  while IFS=$'\t' read -r kind context workflow event has_push tier; do
    [[ "${kind}" == "contract" ]] || continue
    [[ -n "${context}" ]] || continue
    if [[ -z "${workflow}" || -z "${event}" || -z "${tier}" ]]; then
      note_failure "internal: contract plan row for '${context}' has an empty field; the plan and this reader disagree on the column layout"
      continue
    fi
    if [[ "${tier}" != "required" ]]; then
      echo "  ${context}: ${tier} tier, informational"
      continue
    fi
    if [[ "${workflow}" == "(no workflow)" ]]; then
      note_failure "no workflow defines a job named '${context}'; the contract names a check that cannot report"
      continue
    fi
    if [[ "${event}" == "push" ]]; then
      conclusion="$(
        gh api "repos/${REPO}/commits/${head_sha}/check-runs?per_page=100" \
          --jq "[.check_runs[] | select(.name == \"${context}\") | .conclusion] | first // \"absent\"" \
          2>/dev/null || echo "api-error"
      )"
      source="${DEFAULT_BRANCH} HEAD"
    else
      # The workflow does not report on the default branch, so the honest
      # question is not "did it run there" but "does it run at all, and pass".
      if ! latest="$(
        gh api "repos/${REPO}/actions/workflows/${workflow}/runs?per_page=1" \
          --jq '.workflow_runs[0] | "\(.created_at) \(.event) \(.conclusion)"' 2>/dev/null
      )"; then
        note_failure "the API call for '${context}' failed; liveness is unknown, and unknown is not a pass"
        continue
      fi
      created="${latest%% *}"
      rest="${latest#* }"
      conclusion="${rest##* }"
      source="${created} (${rest% *})"
      if [[ "${created}" == "null" || "${created}" == "none" ]]; then
        note_failure "'${context}' has never run; ${workflow} produces no runs at all"
        continue
      fi
      # A pull_request-only check that last ran months ago is as dead as a
      # schedule that stopped firing, and without this the age floor would
      # apply only to scheduled workflows.
      if ! run_age="$(days_old "${created}")"; then
        note_failure "'${context}' reported an unparseable run timestamp ('${created}')"
        continue
      fi
      if ((run_age > RUN_MAX_AGE_DAYS)); then
        note_failure "'${context}' last ran ${run_age} days ago (limit ${RUN_MAX_AGE_DAYS}); ${workflow} is no longer running"
        continue
      fi
    fi
    echo "  ${context}: ${source} -> ${conclusion} [${workflow}]"
    if [[ "${conclusion}" == "absent" ]]; then
      note_failure "'${context}' reported no check run on ${source}; the workflow exists but the job never ran"
    elif [[ "${conclusion}" == "api-error" ]]; then
      note_failure "the API call for '${context}' failed; liveness is unknown, and unknown is not a pass"
    elif [[ "${conclusion}" != "success" ]]; then
      note_failure "'${context}' concluded '${conclusion}' on ${source}"
    fi
  done < <(contract_plan)
fi

if ((failures > 0)); then
  echo "canary found ${failures} problem(s)" >&2
  exit 1
fi

echo "canary passed: every scheduled workflow fired, and every contract-required check runs and passes"
