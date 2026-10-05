set -euo pipefail
if [[ "${RELEASE_GATE_SUITES_RESULT}" != "success" ]]; then
  printf '::error::the release-gate suites did not all pass (result: %s); refusing to report the release gate green\n' "${RELEASE_GATE_SUITES_RESULT}" >&2
  exit 1
fi
printf 'every release-gate suite passed\n'
