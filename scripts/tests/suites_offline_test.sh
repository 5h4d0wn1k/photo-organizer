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
SHIM_LOG="${WORK}/shim-names.log"
: >"${PIP_LOG}"
: >"${PY_LOG}"
: >"${SHIM_LOG}"

# EVERY spelling, not just `python3`. The first version shimmed only `python3`,
# and I measured the gap: with only that on PATH, `python -m pip install ...`,
# a bare `pip install ...` and `pip3 install ...` all record nothing, pip_calls
# stays 0, and the suite reports `ok no suite reaches PyPI at test time`.
#
# That is not a theoretical hole. ci.yml itself spells the install
# `python -m pip install`, not `python3 -m pip install` -- so the shimmed spelling
# was not even the spelling the repo uses in CI, and the one indirect route this
# test exists to cover (a helper script, or a `make` target, that installs)
# would have gone unrecorded.
#
# Interpreter shims (python, python3, python3.x) record every invocation and
# refuse any call whose arguments include `pip`. Installer shims (pip, pip3,
# pip3.x) record and refuse outright, because an installer shim has nothing to
# exec: calling it IS the failure.
cat >"${SHIM_DIR}/python-interpreter" <<SHIM
#!/usr/bin/env bash
# Records every invocation, and refuses pip outright. If a suite reaches PyPI
# again, the refusal makes the install fail AND leaves a record, so the test
# fails either way -- a swallowed \`|| true\` cannot hide it.
printf '%s\n' "\$(basename "\$0") \$*" >>"${PY_LOG}"
for arg in "\$@"; do
  if [[ "\${arg}" == "pip" ]]; then
    printf '%s\n' "\$(basename "\$0") \$*" >>"${PIP_LOG}"
    echo "shim: pip invocation refused (a test suite must not install its own dependency)" >&2
    exit 1
  fi
done
exec "${REAL_PYTHON}" "\$@"
SHIM

cat >"${SHIM_DIR}/pip-installer" <<SHIM
#!/usr/bin/env bash
printf '%s\n' "\$(basename "\$0") \$*" >>"${PIP_LOG}"
echo "shim: pip invocation refused (a test suite must not install its own dependency)" >&2
exit 1
SHIM
chmod +x "${SHIM_DIR}/python-interpreter" "${SHIM_DIR}/pip-installer"

# The exact set of names put on PATH, so the coverage assertion below and the
# shim construction cannot drift apart.
INTERPRETER_SHIMS=("python" "python3")
INSTALLER_SHIMS=("pip" "pip3")
# Every python3.N currently on PATH, so an unversioned-shim gap cannot hide behind
# a versioned invocation.
while IFS= read -r candidate; do
  INTERPRETER_SHIMS+=("$(basename "${candidate}")")
done < <(compgen -c 2>/dev/null | grep -E '^python3(\.[0-9]+)?$' | sort -u)
# Same for pip: pip3.11 and friends are separate executables on some hosts.
while IFS= read -r candidate; do
  INSTALLER_SHIMS+=("$(basename "${candidate}")")
done < <(compgen -c 2>/dev/null | grep -E '^pip3?(\.[0-9]+)?$' | sort -u)

for name in "${INTERPRETER_SHIMS[@]}"; do
  printf '#!/usr/bin/env bash\nexec "%s/python-interpreter" "$@"\n' "${SHIM_DIR}" >"${SHIM_DIR}/${name}"
  chmod +x "${SHIM_DIR}/${name}"
  printf '%s\n' "${name}" >>"${SHIM_LOG}"
done
for name in "${INSTALLER_SHIMS[@]}"; do
  printf '#!/usr/bin/env bash\nexec "%s/pip-installer" "$@"\n' "${SHIM_DIR}" >"${SHIM_DIR}/${name}"
  chmod +x "${SHIM_DIR}/${name}"
  printf '%s\n' "${name}" >>"${SHIM_LOG}"
done

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
  bad "the interpreter shim was actually used" \
    "the shim recorded 0 invocations, so the suites bypassed it and the results above prove nothing"
else
  ok "the interpreter shim was actually used (${shimmed_calls} interpreter invocations recorded)"
fi

# The shim set itself, because a shim set that shrank to one spelling would make
# every result above mean less than it appears to. `python` and `python3` are the
# two spellings that matter and are always present; the versioned ones depend on
# the host, so they are counted rather than named.
shimmed_names="$(sort -u "${SHIM_LOG}" | tr '\n' ' ')"
for required in python python3 pip pip3; do
  if grep -qxF "${required}" "${SHIM_LOG}"; then
    ok "a pip refusal is interposed for '${required}'"
  else
    bad "a pip refusal is interposed for '${required}'" \
      "only these are shimmed: ${shimmed_names}"
  fi
done

pip_calls="$(wc -l <"${PIP_LOG}" | tr -d '[:space:]')"
if [[ "${pip_calls}" -ne 0 ]]; then
  bad "no suite reaches PyPI at test time" \
    "$(cat "${PIP_LOG}")"
else
  ok "no suite reaches PyPI at test time"
fi

# The shims are only worth anything if they actually intercept, so that is proven
# rather than assumed: each spelling is invoked for real, and each must both
# record and refuse. Without this, a shim whose PATH entry was never consulted
# would still leave `pip_calls` at 0 and the assertion above would pass.
echo "  -- the interposed shims are proven to intercept"
for spelling in python python3 pip pip3; do
  before="$(wc -l <"${PIP_LOG}" | tr -d '[:space:]')"
  probe_rc=0
  command -v "${spelling}" >/dev/null 2>&1 \
    || probe_rc=127
  if [[ "${probe_rc}" -eq 0 ]]; then
    PATH="${SHIM_DIR}:${PATH}" "${spelling}" -m pip install --quiet pyyaml >/dev/null 2>&1
    probe_rc=$?
  fi
  after="$(wc -l <"${PIP_LOG}" | tr -d '[:space:]')"
  if [[ "${probe_rc}" -eq 0 ]]; then
    bad "'${spelling} -m pip install' is refused by the shim" \
      "it exited 0, so a suite could reach PyPI through this spelling"
  elif [[ "${after}" -le "${before}" ]]; then
    bad "'${spelling} -m pip install' is refused by the shim" \
      "it was refused but recorded nothing, so the refusal came from elsewhere and proves nothing about the shim"
  else
    ok "'${spelling} -m pip install' is recorded and refused by the shim"
  fi
  # Undo the probe's contribution so the assertions above still measure only the
  # suites. The probes run last for exactly this reason.
  : >"${PIP_LOG}"
  : >"${PY_LOG}"
done

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
