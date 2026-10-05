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
  windows_release_artifact_mutation_test.sh
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
    macos_release_artifact_mutation_test.sh) printf '8' ;;
    windows_release_artifact_mutation_test.sh) printf '8' ;;
    *) printf '1' ;;
  esac
}

failed=0
degraded=0
declare -a results=() active_pids=()

# Suite and shard logs are written under one job-scoped directory rather than as
# anonymous `mktemp` files, and that directory is NOT deleted on exit.
#
# A shard's log is the only record of what that shard actually did, and reading it
# was the only way to diagnose the macOS leg when it failed. The previous shape --
# one `mktemp` per shard, concatenated into a second `mktemp` only after `wait`
# returned, then `rm -f` -- meant that anything which interrupted the job destroyed
# the evidence before it was read. That is exactly what happened: the job log
# contained eight `cat: /tmp/tmp.XXXXXXXX: No such file or directory` lines, one
# per shard, and no way to tell which mutations had run.
#
# Keeping them costs a few hundred KB per job and makes the failure legible.
# `RELEASE_GATE_LOG_DIR` lets CI point this at its artifact directory; the default
# keeps local runs self-contained.
# Default under the checkout, NOT under TMPDIR. On a CI runner /tmp is part of the
# machine being torn down, so a log written there does not survive the very event
# it exists to record -- claiming otherwise is worse than not keeping the log at
# all. The checkout is what `upload-artifact` can actually reach after a job dies.
LOG_DIR="${RELEASE_GATE_LOG_DIR:-${ROOT_DIR}/release-gate-logs}"
mkdir -p "${LOG_DIR}"
printf 'release-gate logs: %s\n' "${LOG_DIR}"

# A Ctrl-C mid-suite would otherwise leave the shards running. The signal handlers
# exit, for the same reason the mutation harness's do: a handler that returns lets
# the script resume, and a resumed driver re-reports work it never finished.
stop_active_shards() {
  local pid
  for pid in "${active_pids[@]}"; do
    [[ -n "${pid}" ]] || continue
    kill -TERM -- "-${pid}" 2>/dev/null || true
  done
  # Mutation scripts may be waiting on a foreground tool that defers its own
  # trap. Give cooperative children a moment, then kill the entire isolated
  # process group so cancellation cannot leave work running in the background.
  sleep 2
  for pid in "${active_pids[@]}"; do
    [[ -n "${pid}" ]] || continue
    kill -KILL -- "-${pid}" 2>/dev/null || true
  done
  for pid in "${active_pids[@]}"; do
    [[ -n "${pid}" ]] || continue
    wait "${pid}" 2>/dev/null || true
  done
  active_pids=()
}

on_signal() {
  local name="$1" signo="$2"
  trap - INT TERM
  printf '\nFATAL: received signal %s; stopping the release-gate run.\n' "${name}" >&2
  stop_active_shards
  printf '       Per-shard logs are kept in %s for diagnosis.\n' "${LOG_DIR}" >&2
  exit "$((128 + signo))"
}
trap 'on_signal INT 2' INT
trap 'on_signal TERM 15' TERM

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

# run_suite <suite> -- run exactly one suite, sharded when it declares shards,
# and record PASS/FAIL/DEGRADED. Extracted so the local "run everything" path and
# the CI "--only-suite" path execute the identical code: a matrix leg cannot drift
# from what a local full run does.
run_suite() {
  local suite="$1" shards shard log rc suite_log status completed progressed shard_rc
  shards="$(shards_for_suite "${suite}")"
  if ((shards > 1)); then
    printf '\n==> %s (%s shards, run concurrently)\n' "${suite}" "${shards}"
    declare -a pids=() shard_logs=() shard_reported=()
    active_pids=()
    if ! command -v setsid >/dev/null 2>&1; then
      printf 'FATAL: setsid is required to isolate release-gate shard process groups\n' >&2
      results+=("FAIL ${suite}${shards:+ (${shards} shards)}")
      failed=1
      return 1
    fi
    shard=0
    while ((shard < shards)); do
      # Named, not `mktemp`: see LOG_DIR above. The name carries the suite and
      # the shard index so a human opening the artifact can tell the eight files
      # apart and see which shard died where.
      log="${LOG_DIR}/${suite%.sh}.shard${shard}.log"
      : >"${log}"
      shard_logs+=("${log}")
      status="${log}.exit"
      rm -f "${status}"
      # shellcheck disable=SC2016 # the wrapper script expands these at runtime
      setsid bash -c '
        MUTATION_SHARDS="$1" MUTATION_SHARD="$2" SHARD_WRAPPER_PID="$$" \
          bash "$3" >"$4" 2>&1
        suite_rc=$?
        status_tmp="$5.tmp.$$"
        printf "%s\n" "$suite_rc" >"$status_tmp"
        mv -- "$status_tmp" "$5"
      ' _ "${shards}" "${shard}" "${TESTS_DIR}/${suite}" "${log}" "${status}" &
      pids+=("$!")
      active_pids+=("$!")
      shard_reported+=(no)
      shard=$((shard + 1))
    done
    rc=0
    completed=0
    while ((completed < shards)); do
      progressed=no
      shard=0
      while ((shard < shards)); do
        if [[ "${shard_reported[$shard]}" == no && -f "${shard_logs[$shard]}.exit" ]]; then
          if ! IFS= read -r shard_rc <"${shard_logs[$shard]}.exit" || [[ ! "${shard_rc}" =~ ^[0-9]+$ ]]; then
            shard_rc=1
          fi
          wait "${pids[$shard]}" 2>/dev/null || true
          active_pids[shard]=""
          if ((shard_rc != 0)); then
            rc=1
          fi
          printf -- '--- shard %s/%s ---\n' "${shard}" "${shards}"
          cat "${shard_logs[$shard]}"
          shard_reported[shard]=yes
          completed=$((completed + 1))
          progressed=yes
        fi
        shard=$((shard + 1))
      done
      if [[ "${progressed}" == no ]]; then
        sleep 1
      fi
    done
    active_pids=()
    # Concatenated once more for the DEGRADED scan, so that check still covers
    # everything the pass produced. This is derived from the shard logs rather
    # than being the primary record of them, and it is not deleted on exit.
    suite_log="${LOG_DIR}/${suite%.sh}.combined.log"
    cat "${shard_logs[@]}" >"${suite_log}"
    record_suite_result "${suite}" "${rc}" "${suite_log}" "${shards}"
    return
  fi

  printf '\n==> %s\n' "${suite}"
  suite_log="${LOG_DIR}/${suite%.sh}.log"
  if bash "${TESTS_DIR}/${suite}" 2>&1 | tee "${suite_log}"; then
    record_suite_result "${suite}" 0 "${suite_log}" 1
  else
    record_suite_result "${suite}" 1 "${suite_log}" 1
  fi
}

usage() {
  cat >&2 <<'EOF'
usage: run_release_gate_tests.sh [--only-suite NAME]

  (no arguments)      run every release-gate suite (local full run)
  --only-suite NAME   run exactly one committed suite (one CI matrix leg)
EOF
}

only_suite=""
while (($#)); do
  case "$1" in
    --only-suite)
      if (($# < 2)); then
        printf 'FATAL: --only-suite needs a suite name\n' >&2
        usage
        exit 2
      fi
      only_suite="$2"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      printf 'FATAL: unknown argument: %s\n' "$1" >&2
      usage
      exit 2
      ;;
  esac
done

if [[ -n "${only_suite}" ]]; then
  # Fail closed on an unknown suite. A typo in a CI matrix leg must not run
  # nothing and be reported as a passing leg.
  if ! printf '%s\n' "${SUITES[@]}" | grep -qxF "${only_suite}"; then
    printf 'FATAL: %s is not a release-gate suite\n' "${only_suite}" >&2
    usage
    exit 2
  fi
  run_suite "${only_suite}"
else
  for suite in "${SUITES[@]}"; do
    run_suite "${suite}"
  done
fi

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
