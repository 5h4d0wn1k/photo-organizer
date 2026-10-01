#!/usr/bin/env bash
#
# Runs every test for the release artifact gates: the Android signing policy, the
# Android install/launch/render gate, the Linux AppImage+.deb install/launch/render
# gate, and the structural invariants of the release workflow.
#
# These are the tests that cover the code which decides whether an artifact
# users cannot install reaches a release (issues #97 and #98). They need no
# device, no emulator and no network, so they run in seconds and belong in the
# inner loop.
#
# A suite here tests the GATE's logic, not the artifact: every one runs on
# synthetic fixtures on a bare runner. What actually installs and launches a
# release artifact is the gate itself, wired in release.yml -- a suite in this
# list is evidence the check discriminates, never evidence a real artifact
# passed it.
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
  linux_release_artifact_smoke_test.sh
)

# Suites print this exact string when an assertion could not run. Keep it in sync
# with the DEGRADED_MARKER each suite defines.
DEGRADED_MARKER='RELEASE_GATE_SUITE_DEGRADED:'

failed=0
degraded=0
declare -a results=()
# A Ctrl-C mid-suite would otherwise leave the log behind in /tmp.
suite_log=""
trap '[[ -n "${suite_log}" ]] && rm -f "${suite_log}"' EXIT INT TERM

for suite in "${SUITES[@]}"; do
  printf '\n==> %s\n' "${suite}"
  suite_log="$(mktemp)"
  if bash "${TESTS_DIR}/${suite}" 2>&1 | tee "${suite_log}"; then
    # A suite that could not run its assertions still exits 0 (an unavailable
    # emulator SDK is not a code defect). Reporting that as a plain PASS would
    # let a real gap hide behind a green build, so degrade it loudly instead.
    # Anchored to a marker the suites emit, not the bare word: the log also
    # contains human prose, including assertion names, and prose that happens to
    # say "DEGRADED" must not be read as a skipped suite.
    if grep -qF "${DEGRADED_MARKER}" "${suite_log}"; then
      results+=("DEGRADED ${suite} (see the SKIP output above -- assertions did NOT run)")
      degraded=1
    else
      results+=("PASS ${suite}")
    fi
  else
    results+=("FAIL ${suite}")
    failed=1
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
