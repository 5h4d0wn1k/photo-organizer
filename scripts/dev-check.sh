#!/usr/bin/env bash
#
# The local inner loop. Its contract with CI is simple to state and was not
# true until #84: every check CI runs must run here, with the same flags, so
# "green locally" implies "green in CI". Two ways that promise used to break:
#
#   * CI ran clippy with --all-features -D warnings and this script ran neither
#     clippy nor a locked test, so a lint error or a stale lockfile only ever
#     surfaced after a push.
#   * CI ran `flutter test` (71 tests) and this script ran `flutter analyze`
#     alone, so a broken widget test looked green until CI said otherwise.
#
# Anything that genuinely needs hardware or an SDK the developer may not have is
# skipped loudly rather than silently -- see the DEGRADED note at the release
# gate below. Skipping must never look like passing.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CARGO_MANIFEST="${ROOT_DIR}/native_core/Cargo.toml"

# The exact flags CI uses. Kept in one place so a future CI change is a
# one-line edit here rather than a silent divergence.
RUST_FMT_ARGS=(--manifest-path "${CARGO_MANIFEST}" --all -- --check)
RUST_CLIPPY_ARGS=(--manifest-path "${CARGO_MANIFEST}" --all-targets --all-features --locked -- -D warnings)
RUST_TEST_ARGS=(--manifest-path "${CARGO_MANIFEST}" --all-features --locked)

echo "Running lightweight checks from: ${ROOT_DIR}"

if command -v cargo >/dev/null 2>&1; then
  echo
  echo "[cargo] fmt --check"
  cargo fmt "${RUST_FMT_ARGS[@]}"

  echo
  echo "[cargo] clippy --all-targets --all-features --locked -D warnings"
  cargo clippy "${RUST_CLIPPY_ARGS[@]}"

  echo
  echo "[cargo] test --all-features --locked"
  cargo test "${RUST_TEST_ARGS[@]}"
else
  echo "cargo not available; skipping Rust validation." >&2
  exit 1
fi

if command -v flutter >/dev/null 2>&1; then
  # `cd` in a subshell rather than passing absolute paths, so the commands are
  # character-for-character the ones CI runs from `working-directory: app`. A
  # path argument that Flutter resolves differently from the default is exactly
  # the kind of drift this script exists to remove.
  echo
  echo "[flutter] analyze"
  (cd "${ROOT_DIR}/app" && flutter analyze)

  echo
  echo "[flutter] test"
  (cd "${ROOT_DIR}/app" && flutter test)
else
  echo "flutter not available; skipping Flutter validation." >&2
  exit 1
fi

# Structural tests for the things a reviewer cannot see in a diff: the workflow
# files (which decide what code runs with which secrets) and the required-check
# contract (which decides what gates a merge). Both are device-free and fast, so
# there is no reason for them to be CI-only -- that was exactly how the Release
# gate sat unrequired for a release cycle (#102).
echo
echo "[workflow-hygiene] .github/workflows structure"
bash "${ROOT_DIR}/scripts/tests/workflow_hygiene_test.sh"

echo
echo "[required-checks] ci.yml job contract"
bash "${ROOT_DIR}/scripts/tests/required_checks_test.sh"

echo
echo "[api-list] docs/architecture.md matches api.rs"
python3 "${ROOT_DIR}/scripts/generate-api-list.py" --check

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

echo
echo "All checks passed."
