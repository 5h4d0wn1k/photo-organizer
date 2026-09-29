#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "Running lightweight checks from: ${ROOT_DIR}"

if command -v cargo >/dev/null 2>&1; then
  echo
  echo "[cargo] fmt --check"
  cargo fmt --manifest-path "${ROOT_DIR}/native_core/Cargo.toml" --all -- --check

  echo
  echo "[cargo] test"
  cargo test --manifest-path "${ROOT_DIR}/native_core/Cargo.toml"
else
  echo "cargo not available; skipping Rust validation."
fi

if command -v flutter >/dev/null 2>&1; then
  echo
  echo "[flutter] analyze"
  flutter analyze "${ROOT_DIR}/app"
else
  echo "flutter not available; skipping Flutter validation."
fi

# The Android release gate is the code that decides whether an artifact users
# cannot install can be published. It is fast and device-free, so it always runs.
#
# A DEGRADED suite (a suite that could not run an assertion -- for example, no
# Android SDK for the signature test) is a warning here, not a failure. Failing
# `make check` on a contributor's machine for an environment reason would train
# people to ignore a red inner loop; CI's release-gate job keeps the hard failure,
# because its runners do have the SDK. A suite that actually FAILS still fails
# here -- only the "could not run" outcome is downgraded, and it says so loudly.
echo
echo "[canary] schedule/liveness canary tests"
bash "${ROOT_DIR}/scripts/tests/canary_liveness_test.sh"

echo
echo "[project-board] closing-reference parser, board helpers, and their wiring"
bash "${ROOT_DIR}/scripts/tests/project_board_refs_test.sh"
if command -v node >/dev/null 2>&1; then
  node --test "${ROOT_DIR}/scripts/tests/project_board_graphql_test.js"
else
  echo "  !! DEGRADED: node is not installed, so the board helper suite did not run." >&2
  echo "     Install node to check this locally; CI's project job has it." >&2
fi
bash "${ROOT_DIR}/scripts/tests/project_board_workflow_test.sh"

echo
echo "[release-gate] artifact + signing policy tests"
gate_log="$(mktemp)"
if bash "${ROOT_DIR}/scripts/tests/run_release_gate_tests.sh" >"${gate_log}" 2>&1; then
  cat "${gate_log}"
  rm -f "${gate_log}"
else
  cat "${gate_log}"
  # A real failure dominates: a run where one suite failed and another could not
  # run is still a failure, not a warning. Only a run with no failures at all --
  # degraded suites and passing suites -- is downgraded.
  if grep -qE '^  FAIL ' "${gate_log}" 2>/dev/null; then
    rm -f "${gate_log}"
    echo "release gate tests FAILED" >&2
    exit 1
  elif grep -qF 'RELEASE_GATE_SUITE_DEGRADED:' "${gate_log}" 2>/dev/null; then
    rm -f "${gate_log}"
    echo "release gate tests DEGRADED (a suite could not run an assertion; see the SKIP output above)." >&2
    echo "This is a warning on a developer machine, not a failure -- but it means this machine cannot prove the release gate, so do not cut a release from here." >&2
  else
    rm -f "${gate_log}"
    echo "release gate tests FAILED" >&2
    exit 1
  fi
fi
