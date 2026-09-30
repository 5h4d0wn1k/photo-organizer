#!/usr/bin/env bash
#
# Proves the suites under scripts/tests/ never reach PyPI at test time
# (issue #136).
#
# The structural check ("no `pip install` appears in these files") is necessary
# but not sufficient: it cannot see a call reached indirectly, through a helper,
# a variable, or a `make` target. So this proves the behaviour instead, by
# interposing a `python3` that records and refuses every `pip` invocation and
# then running the suites for real behind it.
#
# The shim is asserted to have actually been used. Without that, "no pip calls
# were recorded" would also be true of a run where the shim was never on PATH
# and the suites quietly used the system interpreter -- a green test that
# proved nothing. Counting interpreter invocations is what separates the two.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

FAIL_COUNT=0
ok() { printf '  ok   %s\n' "$1"; }
bad() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  printf '  FAIL %s\n' "$1" >&2
  if [[ -n "${2:-}" ]]; then
    printf '%s\n' "$2" | sed 's/^/        /' >&2
  fi
}

SUITES=(
  "workflow_hygiene_test.sh"
  "required_checks_test.sh"
  "release_workflow_test.sh"
)

# Resolve the real interpreter BEFORE the shim goes on PATH, or the shim would
# resolve to itself and recurse.
REAL_PYTHON="$(command -v python3 || true)"
if [[ -z "${REAL_PYTHON}" ]]; then
  printf '  !! python3 not found; cannot run the assertion\n' >&2
  exit 1
fi
if ! "${REAL_PYTHON}" -c "import yaml" >/dev/null 2>&1; then
  printf '  !! pyyaml is unavailable, so NO assertion in this suite ran\n' >&2
  printf '  !! Install the hash-pinned test dependencies with: make deps\n' >&2
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
SHIM_DIR="${WORK}/bin"
mkdir -p "${SHIM_DIR}"

PIP_LOG="${WORK}/pip-invocations.log"
PY_LOG="${WORK}/python-invocations.log"
: >"${PIP_LOG}"
: >"${PY_LOG}"

cat >"${SHIM_DIR}/python3" <<SHIM
#!/usr/bin/env bash
# Records every invocation, and refuses pip outright. If a suite reaches PyPI
# again, the refusal makes the install fail AND leaves a record, so the test
# fails either way -- a swallowed \`|| true\` cannot hide it.
printf '%s\n' "\$*" >>"${PY_LOG}"
for arg in "\$@"; do
  if [[ "\${arg}" == "pip" ]]; then
    printf '%s\n' "\$*" >>"${PIP_LOG}"
    echo "shim: pip invocation refused (a test suite must not install its own dependency)" >&2
    exit 1
  fi
done
exec "${REAL_PYTHON}" "\$@"
SHIM
chmod +x "${SHIM_DIR}/python3"

export PATH="${SHIM_DIR}:${PATH}"

for suite in "${SUITES[@]}"; do
  script="${ROOT_DIR}/scripts/tests/${suite}"
  if [[ ! -f "${script}" ]]; then
    bad "${suite} exists"
    continue
  fi

  output="$(bash "${script}" 2>&1)"
  status=$?

  if [[ ${status} -ne 0 ]]; then
    bad "${suite} passes with pip unreachable" \
      "exit ${status}
${output}"
    continue
  fi
  ok "${suite} passes with pip unreachable"

  # A suite that exits 0 having asserted nothing is the failure mode #136 was
  # filed for. Require that it really ran assertions, rather than trusting 0.
  # The summary line these suites print is "<N> passed, M failed" with no
  # indentation, and N must be non-zero: "0 passed, 0 failed" is the vacuous
  # case this exists to catch.
  if ! printf '%s\n' "${output}" | grep -qE '^[1-9][0-9]* passed, [0-9]+ failed'; then
    bad "${suite} reported running assertions" \
      "no 'N passed, M failed' line with N>0 in the output, so exit 0 proved nothing:
${output}"
  else
    ok "${suite} reported running assertions"
  fi
done

# The discriminating assertion: the shim must have been on PATH and used, or
# every "no pip call" result above is vacuous.
shimmed_calls="$(wc -l <"${PY_LOG}" | tr -d '[:space:]')"
if [[ "${shimmed_calls}" -lt 1 ]]; then
  bad "the python3 shim was actually used" \
    "the shim recorded 0 invocations, so the suites bypassed it and the results above prove nothing"
else
  ok "the python3 shim was actually used (${shimmed_calls} interpreter invocations recorded)"
fi

pip_calls="$(wc -l <"${PIP_LOG}" | tr -d '[:space:]')"
if [[ "${pip_calls}" -ne 0 ]]; then
  bad "no suite reaches PyPI at test time" \
    "$(cat "${PIP_LOG}")"
else
  ok "no suite reaches PyPI at test time"
fi

# The structural half, so the property is also visible without running this file.
# Scoped to the same three suites as the behavioural checks above, not to all of
# scripts/tests/. The mutation harnesses legitimately contain `python -m pip
# install ...` as *fixtures* -- a string that has to be there for them to mutate
# the CI install step -- so a directory-wide scan reports them as offenders and
# would have to be special-cased away. The property being protected is about the
# suites that run in a required check, and that is exactly the list above.
for suite in "${SUITES[@]}"; do
  script="${ROOT_DIR}/scripts/tests/${suite}"
  if grep -qE '(^|[[:space:];])pip[0-9]*[[:space:]]+install|python[0-9.]*[[:space:]]+-m[[:space:]]+pip' \
    "$script" 2>/dev/null; then
    bad "${suite} contains no pip install" \
      "$(grep -nE '(^|[[:space:];])pip[0-9]*[[:space:]]+install|python[0-9.]*[[:space:]]+-m[[:space:]]+pip' "$script" | sed 's/^/        /')"
  else
    ok "${suite} contains no pip install"
  fi
done

printf '\n  %d failed\n' "${FAIL_COUNT}"
[[ "${FAIL_COUNT}" -eq 0 ]]
