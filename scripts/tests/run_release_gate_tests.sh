#!/usr/bin/env bash
#
# Runs every test for the release gate: the signing policy, the per-platform
# install/launch/render gates, and the structural invariants of the release
# workflow.
#
# These are the tests that cover the code which decides whether an artifact
# users cannot install reaches a release (issue #97). They need no device, no
# emulator and no network.
#
# Usage: scripts/tests/run_release_gate_tests.sh

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TESTS_DIR="${ROOT_DIR}/scripts/tests"

SUITES=(
  release_workflow_test.sh
  android_release_signing_test.sh
  apksigner_gate_test.sh
  android_release_artifact_smoke_test.sh
  windows_release_artifact_smoke_test.sh
  linux_release_artifact_smoke_test.sh
  macos_release_artifact_smoke_test.sh
  macos_release_artifact_mutation_test.sh
  ios_release_artifact_smoke_test.sh
  ios_release_artifact_mutation_test.sh
)

# Suites print this exact string when an assertion could not run. Keep it in sync
# with the DEGRADED_MARKER each suite defines.
DEGRADED_MARKER='RELEASE_GATE_SUITE_DEGRADED:'

# A mutation pass re-runs its whole gate once per mutation, so its serial cost is
# (mutations x gate). The iOS pass is 36 mutations on a gate that takes about two
# minutes -- roughly 72 minutes, longer than the required check's timeout.
#
# Its harness splits the mutations by `index % MUTATION_SHARDS == MUTATION_SHARD`,
# so running every shard concurrently covers exactly the same mutation set and
# changes only wall time. Every shard from 0 to N-1 is always run below, so the
# union is the full set: there is no value of N that runs fewer mutations, and
# nothing is skipped to make this fast. Suites not listed return 1 and run whole.
shards_for_suite() {
  case "$1" in
    ios_release_artifact_mutation_test.sh) printf '8' ;;
    *) printf '1' ;;
  esac
}

failed=0
degraded=0
declare -a results=()
declare -a suite_logs=()

# A Ctrl-C mid-suite would otherwise leave the logs behind in /tmp.
cleanup_logs() {
  local log
  for log in "${suite_logs[@]}"; do
    rm -f "${log}"
  done
}
trap cleanup_logs EXIT INT TERM

record_suite_result() {
  local suite="$1" rc="$2" log="$3" shards="$4" suffix=""
  if ((shards > 1)); then
    suffix=" (${shards} shards)"
  fi
  if ((rc != 0)); then
    results+=("FAIL ${suite}${suffix}")
    failed=1
  elif grep -qF "${DEGRADED_MARKER}" "${log}"; then
    # A suite that could not run its assertions still exits 0 (an unavailable
    # emulator SDK is not a code defect). Reporting that as a plain PASS would
    # let a real gap hide behind a green build, so degrade it loudly instead.
    # Anchored to a marker the suites emit, not the bare word: the log also
    # contains human prose, including assertion names, and prose that happens to
    # say "DEGRADED" must not be read as a skipped suite.
    results+=("DEGRADED ${suite}${suffix} (see the SKIP output above -- assertions did NOT run)")
    degraded=1
  else
    results+=("PASS ${suite}${suffix}")
  fi
}

for suite in "${SUITES[@]}"; do
  shards="$(shards_for_suite "${suite}")"
  if ((shards > 1)); then
    printf '\n==> %s (%s shards, run concurrently)\n' "${suite}" "${shards}"
    declare -a pids=() shard_logs=()
    shard=0
    while ((shard < shards)); do
      log="$(mktemp)"
      shard_logs+=("${log}")
      suite_logs+=("${log}")
      MUTATION_SHARDS="${shards}" MUTATION_SHARD="${shard}" \
        bash "${TESTS_DIR}/${suite}" >"${log}" 2>&1 &
      pids+=("$!")
      shard=$((shard + 1))
    done
    rc=0
    shard=0
    while ((shard < shards)); do
      if ! wait "${pids[$shard]}"; then
        rc=1
      fi
      shard=$((shard + 1))
    done
    # Concatenate the shards into one log so the DEGRADED marker is checked over
    # everything the pass produced, and so the CI log carries the same evidence a
    # serial run would.
    suite_log="$(mktemp)"
    suite_logs+=("${suite_log}")
    cat "${shard_logs[@]}" >"${suite_log}"
    for log in "${shard_logs[@]}"; do
      rm -f "${log}"
    done
    cat "${suite_log}"
    record_suite_result "${suite}" "${rc}" "${suite_log}" "${shards}"
    rm -f "${suite_log}"
    continue
  fi

  printf '\n==> %s\n' "${suite}"
  suite_log="$(mktemp)"
  suite_logs+=("${suite_log}")
  if bash "${TESTS_DIR}/${suite}" 2>&1 | tee "${suite_log}"; then
    record_suite_result "${suite}" 0 "${suite_log}" 1
  else
    record_suite_result "${suite}" 1 "${suite_log}" 1
  fi
  rm -f "${suite_log}"
done

printf '\n==> summary\n'
for line in "${results[@]}"; do
  printf '  %s\n' "${line}"
done

if ((failed != 0)); then
  printf '\nrelease gate tests FAILED\n' >&2
  exit 1
fi

if ((degraded != 0)); then
  printf '\nrelease gate tests passed, but at least one suite was DEGRADED (skipped).\n' >&2
  printf 'The skipped assertions did not run. Fix the missing prerequisite before\n' >&2
  printf 'treating this as full coverage.\n' >&2
  exit 1
fi

printf '\nrelease gate tests passed\n'
