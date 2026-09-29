#!/usr/bin/env bash
#
# Tests for scripts/canary_liveness.sh.
#
# This suite exists because the first version of that script was wrong. It asked
# "is every contract-required check green on main HEAD?" -- and `Dependency
# review` is contract-required but only ever triggers on pull_request, so the
# canary would have failed on every run, forever, on a check that cannot report
# there. A canary that is red for a structural reason is a canary people mute.
#
# The script talks to GitHub through `gh api`, so these tests put a fake `gh` on
# PATH that answers from fixtures. That makes every branch -- success, dead
# schedule, absent check, failing check, API error -- reachable without a
# network, which is what lets the mutations below bite.

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="${ROOT_DIR}/scripts/canary_liveness.sh"
WORK="$(mktemp -d)"
PASS_COUNT=0
FAIL_COUNT=0
# See the floor at the end of this file: a suite that measures nothing is a
# suite that silently stopped testing.
MINIMUM_ASSERTIONS="${MINIMUM_ASSERTIONS:-20}"

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

cleanup() {
  rm -rf "${WORK}"
}
trap cleanup EXIT

if ! python3 -c "import yaml" >/dev/null 2>&1; then
  printf '  SKIP pyyaml is unavailable, so the workflow fixtures cannot be written\n'
  printf '  !! CANARY_SUITE_DEGRADED: no pyyaml\n'
  exit 0
fi
if ! command -v shellcheck >/dev/null 2>&1; then
  printf '  SKIP shellcheck is unavailable; the script under test is not checked\n'
  printf '  !! CANARY_SUITE_DEGRADED: no shellcheck\n'
  exit 0
fi

# ---------------------------------------------------------------------------
# Fixture tree: two scheduled workflows, one push workflow, one
# pull_request-only workflow, and a contract that names all three contexts.
# ---------------------------------------------------------------------------
make_fixture_tree() {
  local root="$1"
  mkdir -p "${root}/.github/workflows"
  cat >"${root}/.github/workflows/scorecard.yml" <<'YAML'
name: Scorecard
on:
  schedule:
    - cron: "0 4 * * 1"
  push:
    branches: ["main"]
permissions: read-all
jobs:
  analysis:
    name: Scorecard analysis
    runs-on: ubuntu-latest
    timeout-minutes: 15
    steps:
      - run: echo hi
YAML
  cat >"${root}/.github/workflows/stale.yml" <<'YAML'
name: Stale
on:
  schedule:
    - cron: "30 3 * * 1"
permissions:
  issues: write
jobs:
  mark:
    name: Mark stale items
    runs-on: ubuntu-latest
    timeout-minutes: 10
    steps:
      - run: echo hi
YAML
  cat >"${root}/.github/workflows/ci.yml" <<'YAML'
name: CI
on:
  pull_request:
  push:
    branches:
      - main
permissions:
  contents: read
jobs:
  rust:
    name: Rust service
    runs-on: ubuntu-latest
    timeout-minutes: 50
    steps:
      - run: cargo test
YAML
  cat >"${root}/.github/workflows/dependency-review.yml" <<'YAML'
name: Dependency Review
on:
  pull_request:
    branches: ["main"]
permissions:
  contents: read
jobs:
  dependency-review:
    name: Dependency review
    runs-on: ubuntu-latest
    timeout-minutes: 10
    steps:
      - run: echo review
YAML
  cat >"${root}/.github/required-checks.json" <<'JSON'
{
  "required": [
    { "context": "Rust service", "source": "ci.yml", "why": "correctness floor" },
    { "context": "Dependency review", "source": "dependency-review.yml", "why": "deps" },
    { "context": "Scorecard analysis", "source": "scorecard.yml", "why": "supply chain" }
  ],
  "pending": [],
  "advisory": []
}
JSON
}

# Fixtures that are patch inputs rather than part of the base tree, so a case can
# add them without every other case seeing them.
write_optional_fixtures() {
  cat >"${WORK}/ghost_patch.py" <<'PYTHON'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    contract = json.load(handle)
contract["required"].append(
    {"context": "Ghost Job", "source": "nowhere", "why": "renamed away"}
)
with open(path, "w", encoding="utf-8") as handle:
    json.dump(contract, handle)
PYTHON
  # A scheduled workflow whose job invokes the canary script under a different
  # filename. If the self-exclusion is structural this passes; if it is keyed on
  # the filename `canary.yml`, it fails, which is the point of the case.
  cat >"${WORK}/renamed_canary.yml" <<'YAML'
name: Schedule canary
on:
  schedule:
    - cron: "0 5 * * 1"
permissions:
  contents: read
jobs:
  canary:
    name: Scheduled workflows and contract checks are alive
    runs-on: ubuntu-latest
    timeout-minutes: 10
    steps:
      - run: bash scripts/canary_liveness.sh
YAML
}

# ---------------------------------------------------------------------------
# Fake `gh`. Real `gh api --jq <expr>` prints the extracted value, not the raw
# payload, so each fixture here holds exactly the bytes that `--jq` would have
# printed. Emulating the jq language would test my emulator instead of the
# script; storing the rendered value keeps the test honest about what the script
# actually consumes.
#
# Fixture keys, each one a URL shape the script must get right:
#   schedule:<file>   the `--jq` output of workflows/<file>/runs?event=schedule
#   runs:<file>       the `--jq` output of workflows/<file>/runs (any event)
#   head              the SHA printed for commits/<branch>
#   checks:<sha>      the `--jq` output of commits/<sha>/check-runs
# Anything unset answers as the jq output for "no such run", which the script
# must read as a finding rather than crashing.
# ---------------------------------------------------------------------------
write_fake_gh() {
  local bin="$1"
  mkdir -p "${bin}"
  cat >"${bin}/gh" <<'FAKE'
#!/usr/bin/env bash
set -uo pipefail
url=""
jq=""
prev=""
for arg in "$@"; do
  if [[ "${prev}" == "--jq" ]]; then
    jq="${arg}"
  fi
  case "${arg}" in
    repos/*) url="${arg}" ;;
  esac
  prev="${arg}"
done
fixtures="${GH_FIXTURES:?GH_FIXTURES must be set}"
key=""
if [[ "${url}" == *"check-runs"* ]]; then
  # The check-runs query filters by name *inside* the jq expression, not in the
  # URL, so the context has to be recovered from the jq argument. That is also a
  # useful thing to assert on: if the script stopped selecting by name, the
  # fixture lookup would miss and the case would see `absent`.
  context="$(printf '%s' "${jq}" | sed -n 's/.*select(\.name == "\([^"]*\)").*/\1/p')"
  key="checks:${context}"
elif [[ "${url}" == *"/commits/"* ]]; then
  key="head"
elif [[ "${url}" == *"event=schedule"* ]]; then
  key="schedule:${url%%/runs*}"
  key="schedule:${key##*/workflows/}"
elif [[ "${url}" == *"actions/workflows/"* ]]; then
  key="runs:${url%%/runs*}"
  key="runs:${key##*/workflows/}"
fi
file="${fixtures}/${key}"
# A sibling `<key>.error` makes this call fail the way a real API failure does:
# non-zero exit, nothing on stdout. The script must treat that as a finding, not
# as an empty result.
if [[ -f "${file}.error" ]]; then
  echo "gh: simulated API failure for ${url}" >&2
  exit 1
fi
if [[ -f "${file}" ]]; then
  cat "${file}"
else
  case "${key}" in
    head) printf '%s\n' "${GH_HEAD_SHA:-deadbeef}" ;;
    # jq's `first // <default>` on an empty list, and `.workflow_runs[0]` on an
    # empty list rendering as `null`, are both "no such thing".
    checks:*) printf '%s\n' "absent" ;;
    *) printf '%s\n' "null" ;;
  esac
fi
FAKE
  chmod +x "${bin}/gh"
}

# Every test starts from an empty fixture set and a fresh repo tree, so a
# fixture left behind by an earlier case can never make a later one pass.
fresh_fixtures() {
  rm -rf "${WORK}/fixtures"
  mkdir -p "${WORK}/fixtures"
}

# Optional per-case edits to the fixture tree, applied after make_fixture_tree so
# a case that mutates the tree is not undone by the reset above.
#   EXTRA_WORKFLOW_FILE   copied into .github/workflows/
#   EXTRA_CONTRACT_PATCH  a python snippet run with the contract path as argv[1]
run_case() {
  local bin="${WORK}/bin"
  local root="${WORK}/repo"
  rm -rf "${root}" "${bin}"
  make_fixture_tree "${root}"
  if [[ -n "${EXTRA_WORKFLOW_FILE:-}" ]]; then
    cp "${EXTRA_WORKFLOW_FILE}" "${root}/.github/workflows/"
  fi
  if [[ -n "${EXTRA_CONTRACT_PATCH:-}" ]]; then
    python3 "${EXTRA_CONTRACT_PATCH}" "${root}/.github/required-checks.json"
  fi
  write_fake_gh "${bin}"
  PATH="${bin}:${PATH}" \
    GH_FIXTURES="${WORK}/fixtures" \
    CANARY_REPO="photo-organizer/test" \
    CANARY_WORKFLOWS_DIR="${root}/.github/workflows" \
    CANARY_CONTRACT="${root}/.github/required-checks.json" \
    bash "${SCRIPT}" 2>&1
}

# run_plan -- asks the script for its resolved plan and nothing else. Needs no
# gh, so the column layout is assertable without any API fixtures at all.
run_plan() {
  local root="${WORK}/repo"
  make_fixture_tree "${root}"
  if [[ -n "${EXTRA_CONTRACT_PATCH:-}" ]]; then
    python3 "${EXTRA_CONTRACT_PATCH}" "${root}/.github/required-checks.json"
  fi
  CANARY_WORKFLOWS_DIR="${root}/.github/workflows" \
    CANARY_CONTRACT="${root}/.github/required-checks.json" \
    CANARY_REPO="photo-organizer/test" \
    bash "${SCRIPT}" --plan 2>&1
}

iso_days_ago() {
  python3 -c "
import datetime, sys
print((datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=int(sys.argv[1]))).strftime('%Y-%m-%dT%H:%M:%SZ'))
" "$1"
}

schedule_run() {
  # schedule_run <file> <days-ago> <conclusion> -- the exact bytes
  # `--jq '.workflow_runs[0] | "\(.created_at) \(.conclusion)"'` would print.
  printf '%s %s\n' "$(iso_days_ago "$2")" "$3" >"${WORK}/fixtures/schedule:${1}"
}

any_run() {
  # any_run <file> <days-ago> <event> <conclusion>
  printf '%s %s %s\n' "$(iso_days_ago "$2")" "$3" "$4" >"${WORK}/fixtures/runs:${1}"
}

checks_payload() {
  # checks_payload <context> <conclusion> -- the exact bytes the check-runs
  # query would print for that context. Anything not given here reads `absent`,
  # which is what an unmatched `.conclusion | first // "absent"` produces.
  printf '%s\n' "$2" >"${WORK}/fixtures/checks:$1"
}

api_fails() {
  # api_fails <key> -- the next call for that key exits non-zero with no stdout.
  : >"${WORK}/fixtures/${1}.error"
}

expect_case() {
  # expect_case <name> <pass|fail> <substring the output must contain>
  # Does NOT reset anything: each case calls fresh_fixtures first and then sets
  # exactly the answers it wants to exercise. A reset inside here would wipe the
  # arrangement the case just made.
  local name="$1" want="$2" needle="$3"
  local output rc verdict="pass"
  output="$(run_case)"
  rc=$?
  if [[ "${want}" == "pass" && ${rc} -ne 0 ]]; then
    verdict="fail"
  elif [[ "${want}" == "fail" && ${rc} -eq 0 ]]; then
    verdict="fail"
  fi
  EXTRA_WORKFLOW_FILE=""
  EXTRA_CONTRACT_PATCH=""
  if [[ "${verdict}" == "fail" ]]; then
    bad "${name}" "expected exit ${want}, got ${rc}"$'\n'"${output}"
  elif [[ -n "${needle}" ]] && ! grep -qF "${needle}" <<<"${output}"; then
    bad "${name}" "output did not contain: ${needle}"$'\n'"${output}"
  else
    ok "${name}"
  fi
}

# The arrangement every "everything is fine" case shares.
all_green() {
  schedule_run "scorecard.yml" 1 "success"
  schedule_run "stale.yml" 1 "success"
  any_run "dependency-review.yml" 0 "pull_request" "success"
  checks_payload "Rust service" "success"
  checks_payload "Scorecard analysis" "success"
}

write_optional_fixtures

# --- 0. The script itself is clean under the same lint CI runs ---------------
shellcheck_out="$(shellcheck --severity=warning "${SCRIPT}" 2>&1)"
if [[ -z "${shellcheck_out}" ]]; then
  ok "shellcheck: scripts/canary_liveness.sh"
else
  bad "shellcheck: scripts/canary_liveness.sh" "${shellcheck_out}"
fi

# --- 1. The regression this suite exists for --------------------------------
# Everything green, with Dependency review answering only from its own
# pull_request run and never on main HEAD. The original inline logic failed here.
fresh_fixtures
all_green
expect_case "pull_request-only required check passes via its own latest run" pass \
  "Dependency review:"

# --- 2. ...and that pass must not be reachable by ignoring the check --------
fresh_fixtures
schedule_run "scorecard.yml" 1 "success"
schedule_run "stale.yml" 1 "success"
checks_payload "Rust service" "success"
checks_payload "Scorecard analysis" "success"
expect_case "pull_request-only check with no runs at all fails" fail \
  "produces no runs at all"

# --- 3. A failing check fails the canary ------------------------------------
fresh_fixtures
schedule_run "scorecard.yml" 1 "success"
schedule_run "stale.yml" 1 "success"
any_run "dependency-review.yml" 0 "pull_request" "failure"
checks_payload "Rust service" "success"
checks_payload "Scorecard analysis" "success"
expect_case "a failing pull_request-only check fails the canary" fail \
  "concluded 'failure'"

# --- 4. A dead schedule fails the canary ------------------------------------
fresh_fixtures
schedule_run "scorecard.yml" 1 "success"
any_run "dependency-review.yml" 0 "pull_request" "success"
checks_payload "Rust service" "success"
checks_payload "Scorecard analysis" "success"
expect_case "a scheduled workflow with no runs fails the canary" fail \
  "no schedule-triggered runs"

# --- 5. A schedule that stopped firing (ran, but long ago) fails -------------
fresh_fixtures
schedule_run "scorecard.yml" 40 "success"
schedule_run "stale.yml" 40 "success"
any_run "dependency-review.yml" 0 "pull_request" "success"
checks_payload "Rust service" "success"
checks_payload "Scorecard analysis" "success"
expect_case "a schedule that stopped firing fails the canary" fail \
  "the schedule is not firing"

# --- 6. A scheduled run that failed fails the canary ------------------------
fresh_fixtures
schedule_run "scorecard.yml" 1 "failure"
schedule_run "stale.yml" 1 "success"
any_run "dependency-review.yml" 0 "pull_request" "success"
checks_payload "Rust service" "success"
checks_payload "Scorecard analysis" "success"
expect_case "a failing scheduled run fails the canary" fail \
  "newest schedule run concluded 'failure'"

# --- 7. A pull_request-only workflow that stopped running fails -------------
fresh_fixtures
schedule_run "scorecard.yml" 1 "success"
schedule_run "stale.yml" 1 "success"
any_run "dependency-review.yml" 60 "pull_request" "success"
checks_payload "Rust service" "success"
checks_payload "Scorecard analysis" "success"
expect_case "a pull_request-only check that stopped running fails the canary" fail \
  "is no longer running"

# --- 8. A required context with no producing workflow fails -----------------
fresh_fixtures
schedule_run "scorecard.yml" 1 "success"
schedule_run "stale.yml" 1 "success"
any_run "dependency-review.yml" 0 "pull_request" "success"
checks_payload "Rust service" "success"
checks_payload "Scorecard analysis" "success"
EXTRA_CONTRACT_PATCH="${WORK}/ghost_patch.py"
expect_case "a contract context no workflow produces fails the canary" fail \
  "cannot report"

# --- 8b. The plan's column layout is what the reader assumes ----------------
# The regression that made case 8 above inert: an empty filename field is
# collapsed away by the tab split, every later field shifts left, and the ghost
# context arrives as `tier=""` -- which the reader treats as "pending" and skips.
# Asserted against `--plan` output, so reverting the sentinel to an empty string
# fails here instead of silently disabling the ghost check.
plan="$(EXTRA_CONTRACT_PATCH="${WORK}/ghost_patch.py" run_plan)"
row_count="$(grep -c '^contract' <<<"${plan}" || true)"
if [[ "${row_count}" == "4" ]]; then
  ok "the plan emits one row per contract entry, ghosts included"
else
  bad "the plan emits one row per contract entry" "expected 4 rows, got ${row_count}:"$'\n'"${plan}"
fi
# This is the assertion that would have caught the original collapse. Reverting
# the sentinel to an empty string still yields six awk fields, so the field
# count alone is not enough -- the emptiness check is what bites.
empty_field_rows="$(awk '/^contract/ && /\t\t/ {n++} END {print n + 0}' <<<"${plan}")"
if [[ "${empty_field_rows}" == "0" ]]; then
  ok "every plan row has no empty field that a tab split would collapse"
else
  bad "every plan row has no empty field that a tab split would collapse" \
    "${empty_field_rows} row(s) would shift under a tab split:"$'\n'"${plan}"
fi
if grep -qF $'contract\tGhost Job\t(no workflow)\t' <<<"${plan}"; then
  ok "a context no workflow produces carries the (no workflow) sentinel"
else
  bad "a context no workflow produces carries the (no workflow) sentinel" \
    "rows: $(grep '^contract' <<<"${plan}" | tr '\t' '|')"
fi
# Source-level, because no input can reach this guard: the reader's
# reject-empty-field check is defence in depth that the plan's own contract makes
# unreachable. Case 8 above is the behavioural test for the sentinel itself.
if grep -qF 'has an empty field' "${SCRIPT}"; then
  ok "the reader rejects any row with an empty field (unreachable defence in depth)"
else
  bad "the reader rejects any row with an empty field" "the column-shift guard is gone"
fi

# --- 8c. A failed API call is not a pass ------------------------------------
# The most dangerous failure mode in a canary: "I could not check" quietly
# becoming "fine". Both branches -- the push query and the recent-run query --
# must report the failure rather than defaulting to success.
fresh_fixtures
schedule_run "scorecard.yml" 1 "success"
schedule_run "stale.yml" 1 "success"
checks_payload "Rust service" "success"
checks_payload "Scorecard analysis" "success"
api_fails "runs:dependency-review.yml"
expect_case "a failed API call on a non-push check fails the canary" fail \
  "liveness is unknown, and unknown is not a pass"

fresh_fixtures
schedule_run "scorecard.yml" 1 "success"
schedule_run "stale.yml" 1 "success"
any_run "dependency-review.yml" 0 "pull_request" "success"
api_fails "checks:Rust service"
expect_case "a failed API call on a push check fails the canary" fail \
  "reported no check run"

# --- 8d. An unparseable timestamp is a finding, not a fresh run --------------
fresh_fixtures
schedule_run "scorecard.yml" 1 "success"
printf 'not-a-timestamp success\n' >"${WORK}/fixtures/schedule:stale.yml"
any_run "dependency-review.yml" 0 "pull_request" "success"
checks_payload "Rust service" "success"
checks_payload "Scorecard analysis" "success"
expect_case "an unparseable run timestamp fails the canary" fail \
  "unparseable timestamp"

# --- 9. A push-reported check missing from main HEAD fails -------------------
fresh_fixtures
schedule_run "scorecard.yml" 1 "success"
schedule_run "stale.yml" 1 "success"
any_run "dependency-review.yml" 0 "pull_request" "success"
checks_payload "Scorecard analysis" "success"
expect_case "a required check absent from main HEAD fails the canary" fail \
  "reported no check run on main HEAD"

# --- 10. Everything green passes --------------------------------------------
fresh_fixtures
all_green
expect_case "all schedules fired and all contract checks pass" pass \
  "canary passed"

# --- 11. An unresolvable default-branch HEAD is not a pass ------------------
fresh_fixtures
all_green
export GH_HEAD_SHA=null
expect_case "an unresolvable default-branch HEAD fails the canary" fail \
  "did not run"
unset GH_HEAD_SHA

# --- 12. The canary must not be made to require its own run -----------------
# The exclusion cannot be "skip the file named canary.yml": renaming the file
# would then turn the canary into something that demands a run of itself, which
# can never happen. It is structural instead -- any workflow that invokes
# scripts/canary_liveness.sh is this canary.
fresh_fixtures
all_green
EXTRA_WORKFLOW_FILE="${WORK}/renamed_canary.yml"
expect_case "a renamed copy of the canary is not made to require itself" pass \
  "cannot observe its own absence"

# --- 12. Structural: the file canary.yml really delegates to the script -----
# These assert against the PARSED workflow, not its text. A `grep -F` for the
# script path was satisfied by the explanatory comment at the top of the file,
# so deleting the step that actually runs the script left the assertion green --
# proved by the mutation pass, which is why it is now a check on `run:` values.
canary_yml="${ROOT_DIR}/.github/workflows/canary.yml"
if [[ ! -f "${canary_yml}" ]]; then
  bad "canary.yml exists" "${canary_yml} not found"
else
  if python3 - "${canary_yml}" <<'PYTHON'
import sys

import yaml

with open(sys.argv[1], encoding="utf-8") as handle:
    workflow = yaml.safe_load(handle)

runs = []
for job in (workflow.get("jobs") or {}).values():
    for step in job.get("steps", []) or []:
        if isinstance(step, dict) and step.get("run"):
            runs.append(str(step["run"]))

# The canary's own logic must be *executed* by a step. A substring search for
# the path is not enough: the shellcheck step also mentions it, and so does the
# comment block, so `grep -F` was satisfied by text that runs nothing. Match the
# invocation instead.
if not any(run.strip() == "bash scripts/canary_liveness.sh" for run in runs):
    print("no step executes: bash scripts/canary_liveness.sh", file=sys.stderr)
    sys.exit(1)
# And the suite that proves that logic must actually be run too, or the canary
# executes unmeasured code -- which is exactly the original defect.
if not any(run.strip() == "bash scripts/tests/canary_liveness_test.sh" for run in runs):
    print("no step executes: bash scripts/tests/canary_liveness_test.sh", file=sys.stderr)
    sys.exit(1)
# The suite must be gated in front of the live run, not merely present.
try:
    live = next(i for i, run in enumerate(runs) if run.strip() == "bash scripts/canary_liveness.sh")
    suite = next(i for i, run in enumerate(runs) if run.strip() == "bash scripts/tests/canary_liveness_test.sh")
except StopIteration:
    sys.exit(1)  # already reported above
if suite > live:
    print("the suite runs after the live check, so a broken canary reports first", file=sys.stderr)
    sys.exit(1)
# Inline API calls are how the broken logic survived: an untestable heredoc.
offenders = [run for run in runs if "gh api" in run or "api.github.com" in run]
if offenders:
    print(f"inline API logic in a step: {offenders}", file=sys.stderr)
    sys.exit(1)
# Least privilege: this check only ever reads.
permissions = workflow.get("permissions")
if permissions != {"contents": "read"}:
    print(f"permissions must be exactly contents:read, got {permissions!r}", file=sys.stderr)
    sys.exit(1)
concurrency = workflow.get("concurrency") or {}
if not concurrency.get("group") or "cancel-in-progress" not in concurrency:
    print(f"concurrency must declare a group and cancel-in-progress, got {concurrency!r}", file=sys.stderr)
    sys.exit(1)
PYTHON
  then
    ok "canary.yml runs the tested script as a step"
    ok "canary.yml runs its own suite as a step"
    ok "canary.yml keeps API logic out of its steps"
    ok "canary.yml holds exactly contents:read"
    ok "canary.yml declares a concurrency group and cancel-in-progress"
  else
    bad "canary.yml's wiring matches what the canary needs" \
      "a step is missing, inline API logic returned, permissions widened, or concurrency dropped"
  fi
fi

# --- 13. Structural: the script is where the logic lives --------------------
if [[ -x "${SCRIPT}" ]]; then
  ok "scripts/canary_liveness.sh is executable"
else
  bad "scripts/canary_liveness.sh is executable" "not executable; the workflow invokes it via bash, but make runs it directly"
fi
if grep -qF "CANARY_REPO" "${SCRIPT}"; then
  ok "script honours CANARY_REPO"
else
  bad "script honours CANARY_REPO" "the test seam is gone"
fi

printf '\n%s passed, %s failed\n' "${PASS_COUNT}" "${FAIL_COUNT}"
if ((FAIL_COUNT > 0)); then
  exit 1
fi
# A suite that runs nothing must not exit 0. Without this floor, neutering the
# invocation of the script under test -- or losing every case to a refactor --
# would report success with nothing behind it, which is the exact failure this
# repo treats as worse than a red build. The floor is deliberately well below the
# real count so adding cases cannot break it, and well above zero so deleting
# them does.
if ((PASS_COUNT < MINIMUM_ASSERTIONS)); then
  printf 'suite only made %d assertions; expected at least %d, so it is not measuring the script\n' \
    "${PASS_COUNT}" "${MINIMUM_ASSERTIONS}" >&2
  exit 1
fi
