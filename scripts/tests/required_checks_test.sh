#!/usr/bin/env bash
#
# The required-check list lives in repository settings, where no test can see
# it -- so a job added to ci.yml lands unrequired until a human notices (this
# is exactly how the Release gate sat outside the required list in #102).
#
# This suite closes that gap from the merge-time side: .github/required-checks.json
# is the reviewable source of truth, and every ci.yml job must be accounted for
# in it -- required, or advisory with a written reason. An unlisted job fails;
# a listed-but-renamed job fails; a contract entry pointing at a job that does
# not exist fails. The live ruleset-vs-file drift check is the scheduled
# canary's job (issue #108), because GITHUB_TOKEN cannot read branch
# protection and this test therefore deliberately makes no API calls.
#
# Device-free. Runs in CI inside the `Security gates` job. Output format
# matches scripts/tests/workflow_hygiene_test.sh so the two can be folded
# together later.

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CI_YML="${ROOT_DIR}/.github/workflows/ci.yml"
CONTRACT="${ROOT_DIR}/.github/required-checks.json"
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

checks="$(python3 - "${CI_YML}" "${CONTRACT}" "${ROOT_DIR}/.github/workflows" <<'PYTHON'
import glob
import json
import os
import sys

import yaml

ci_path, contract_path, workflows_dir = sys.argv[1], sys.argv[2], sys.argv[3]

with open(ci_path, encoding="utf-8") as handle:
    ci = yaml.safe_load(handle)
with open(contract_path, encoding="utf-8") as handle:
    contract = json.load(handle)

# Stable display names of every job CI defines. The check name GitHub records
# is the job's `name:`, falling back to the job id -- so that is what the
# contract must use, and a rename on either side must fail loudly.
ci_names = set()
for job_id, job in (ci.get("jobs") or {}).items():
    ci_names.add(str((job or {}).get("name", job_id)))

required = {c["context"]: c for c in contract.get("required", [])}
pending = {c["context"]: c for c in contract.get("pending", [])}
advisory = {c["context"]: c for c in contract.get("advisory", [])}

# 1. Every job CI defines is accounted for: required, pending with a source,
#    or advisory with a reason. An unlisted job is the #102 defect recurring.
for name in sorted(ci_names):
    if name in required:
        print(f"covered\t{name}\tyes\t")
    elif name in pending:
        print(f"covered\t{name}\tyes\t")
    elif name in advisory:
        print(f"covered\t{name}\tyes\t")
    else:
        print(f"covered\t{name}\tno\tci.yml defines this job but the contract does not list it")

# 2. Every required entry names a job that exists *somewhere* in the repo's
#    workflows (ci.yml or otherwise). A contract entry for a renamed or deleted
#    job would otherwise demand a check that can never report -- which blocks
#    every PR permanently. Checked across all workflow files, because required
#    checks need not live in ci.yml (Dependency review does not).
all_names = set()
for path in glob.glob(os.path.join(workflows_dir, "*.yml")):
    with open(path, encoding="utf-8") as handle:
        try:
            workflow = yaml.safe_load(handle)
        except yaml.YAMLError:
            continue
    for job_id, job in ((workflow or {}).get("jobs") or {}).items():
        all_names.add(str((job or {}).get("name", job_id)))
for context, entry in sorted(required.items()):
    if context in all_names:
        print(f"exists\t{context}\tyes\t")
    else:
        print(f"exists\t{context}\tno\trequired by the contract but no workflow defines a job with this name")

# 3. Advisory entries carry a reason. An exception without a written reason is
#    an unreviewed hole, not a decision.
for context, entry in sorted(advisory.items()):
    if str(entry.get("reason", "")).strip():
        print(f"reason\t{context}\tyes\t")
    else:
        print(f"reason\t{context}\tno\tadvisory without a written reason")

# 4. Pending entries carry a source. Pending is a waiting room with a named
#    waiter (a PR, an issue), not a place to park checks indefinitely.
for context, entry in sorted(pending.items()):
    if str(entry.get("source", "")).strip():
        print(f"pending\t{context}\tyes\t")
    else:
        print(f"pending\t{context}\tno\tpending without a named source")
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

printf '\n%s passed, %s failed\n' "${PASS_COUNT}" "${FAIL_COUNT}"
if ((FAIL_COUNT > 0)); then
  exit 1
fi
