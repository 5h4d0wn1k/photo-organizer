#!/usr/bin/env bash
#
# Tests for scripts/gen_test_requirements.py and the committed
# scripts/requirements-test.txt (issue #136).
#
# Two things are being protected here, and it is worth being exact about which
# is which, because an earlier draft of this file claimed more than it checked.
#
#   1. The generator refuses to emit a lockfile it cannot vouch for. A
#      requirements file that silently drops an artifact, reuses one digest for
#      two files, or pins a version nobody audited is worse than no file: it
#      looks authoritative. Every refusal below is a shape a hand-maintained
#      file actually takes.
#
#   2. The committed file is exactly what the generator emits for the pin it
#      declares: same header, same pin, same digests in the same order, every
#      digest well-formed and unique, and an artifact count at or above the
#      floor. Checked by round-trip equality, offline.
#
# What (2) does NOT prove, established by mutation rather than assumed: a digest
# edited in place, two hashes swapped, or a hash line deleted all round-trip
# faithfully and are NOT caught here. The only non-circular check on a digest is
# the artifact bytes themselves, which is `pip install --require-hashes` running
# in the required `Security gates` job on every CI run. Comparing against PyPI
# here instead would put the network in a required check, which is the defect
# #136 exists to remove, and would not prove more.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GENERATOR="${ROOT_DIR}/scripts/gen_test_requirements.py"
REQUIREMENTS="${ROOT_DIR}/scripts/requirements-test.txt"

FAIL_COUNT=0
ok() { printf '  ok   %s\n' "$1"; }
bad() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  printf '  FAIL %s\n' "$1" >&2
  if [[ -n "${2:-}" ]]; then
    printf '%s\n' "$2" | sed 's/^/        /' >&2
  fi
}

if ! python3 -c "import yaml" >/dev/null 2>&1; then
  echo "  !! pyyaml is unavailable, so NO requirements assertion ran" >&2
  echo "  !! Install the hash-pinned test dependencies with: make deps" >&2
  exit 1
fi

RESULTS="$(python3 - "${GENERATOR}" "${REQUIREMENTS}" <<'PYTHON'
import importlib.util
import re
import sys

generator_path, requirements_path = sys.argv[1], sys.argv[2]

spec = importlib.util.spec_from_file_location("gen_test_requirements", generator_path)
gen = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gen)

results = []
GOOD = "a" * 64
OTHER = "b" * 64


def expect_rejected(label, artifacts, needle, package="pyyaml", version="6.0.2"):
    """validate_artifacts must refuse these, and say something recognisable."""
    try:
        gen.validate_artifacts(artifacts, package=package, version=version)
    except ValueError as error:
        if needle in str(error):
            results.append(("ok", label))
        else:
            results.append(("fail", label, f"rejected, but not for the expected reason; wanted {needle!r} in {str(error)!r}"))
    else:
        results.append(("fail", label, "accepted an artifact set it must refuse"))


def expect_accepted(label, artifacts, package="pyyaml", version="6.0.2"):
    try:
        gen.validate_artifacts(artifacts, package=package, version=version)
    except ValueError as error:
        results.append(("fail", label, f"refused a valid artifact set: {error}"))
    else:
        results.append(("ok", label))


# --- normalise_name -------------------------------------------------------
# The bug this prevents: rejecting every real artifact because PyYAML's wheels
# are capitalised "PyYAML" while the pin says "pyyaml".
for raw, want in [("PyYAML", "pyyaml"), ("pyyaml", "pyyaml"), ("py-yaml", "py-yaml"),
                  ("ruamel.yaml", "ruamel-yaml"), ("zope.interface", "zope-interface")]:
    got = gen.normalise_name(raw)
    results.append(("ok" if got == want else "fail",
                    f"normalise_name({raw!r}) == {want!r}", "" if got == want else f"got {got!r}"))

# --- the happy path is accepted ------------------------------------------
expect_accepted(
    "a well-formed wheel + sdist set validates",
    [("PyYAML-6.0.2-cp313-cp313-manylinux_2_17_x86_64.whl", GOOD),
     ("pyyaml-6.0.2.tar.gz", OTHER)],
)

# --- every refusal shape --------------------------------------------------
expect_rejected("an empty artifact list is refused", [], "no installable artifacts")
expect_rejected(
    "a truncated digest is refused",
    [("PyYAML-6.0.2-cp313-cp313-win_amd64.whl", "a" * 63)],
    "not 64 lowercase hex",
)
expect_rejected(
    "an uppercase digest is refused (pip compares lowercase)",
    [("PyYAML-6.0.2-cp313-cp313-win_amd64.whl", "A" * 64)],
    "not 64 lowercase hex",
)
expect_rejected(
    "an artifact for another project is refused",
    [("PyYAML-6.0.2-cp313-cp313-win_amd64.whl", GOOD),
     ("requests-2.32.3-py3-none-any.whl", OTHER)],
    "distribution is 'requests'",
)
expect_rejected(
    "an artifact at another version is refused",
    [("PyYAML-6.0.3-cp313-cp313-win_amd64.whl", GOOD)],
    "version is '6.0.3'",
)
expect_rejected(
    "one digest claimed by two filenames is refused",
    [("PyYAML-6.0.2-cp313-cp313-win_amd64.whl", GOOD),
     ("PyYAML-6.0.2-cp312-cp312-win_amd64.whl", GOOD)],
    "must authorise exactly one file",
)
expect_rejected(
    "a repeated filename is refused",
    [("PyYAML-6.0.2-cp313-cp313-win_amd64.whl", GOOD),
     ("PyYAML-6.0.2-cp313-cp313-win_amd64.whl", OTHER)],
    "appears more than once",
)
expect_rejected(
    "a malformed wheel filename is refused",
    [("PyYAML-6.0.2-cp313.whl", GOOD)],
    "5 or more segments",
)

# --- extract_artifacts ----------------------------------------------------
pypi = {
    "urls": [
        # unsorted on purpose: the output must be sorted so regeneration is stable
        {"filename": "PyYAML-6.0.2-cp312-cp312-win_amd64.whl", "digests": {"sha256": "b" * 64}},
        {"filename": "pyyaml-6.0.2.tar.gz", "digests": {"sha256": "a" * 64}},
        # filtered: not an installable input
        {"filename": "PyYAML-6.0.2-cp312-cp312-win_amd64.whl.asc", "digests": {"sha256": "c" * 64}},
        {"filename": "PyYAML-6.0.2-py3-none-any.whl.metadata", "digests": {"sha256": "d" * 64}},
        # filtered: no digest, so it could never be pinned
        {"filename": "PyYAML-6.0.2-1-py3-none-any.whl"},
    ]
}
extracted = gen.extract_artifacts(pypi)
names = [name for name, _ in extracted]
results.append(("ok" if names == sorted(names) else "fail",
                "extract_artifacts sorts by filename (stable regeneration)", "" if names == sorted(names) else f"got {names}"))
results.append(("ok" if len(extracted) == 2 else "fail",
                "extract_artifacts keeps only installable, digest-bearing artifacts",
                "" if len(extracted) == 2 else f"got {names}"))

# --- render shape ---------------------------------------------------------
rendered = gen.render_requirements([("f", GOOD), ("g", OTHER)])
lines = rendered.rstrip("\n").split("\n")
results.append(("ok" if lines[0] == "pyyaml==6.0.2 \\" else "fail",
                "the first line is the pinned requirement with a continuation",
                "" if lines[0] == "pyyaml==6.0.2 \\" else f"got {lines[0]!r}"))
results.append(("ok" if lines[-1].endswith("\\") is False else "fail",
                "the last hash has no trailing continuation (pip rejects a dangling \\)",
                "" if lines[-1].endswith("\\") is False else f"got {lines[-1]!r}"))
results.append(("ok" if sum(1 for l in lines if l.strip().startswith("--hash=")) == 2 else "fail",
                "render_requirements emits one --hash per artifact", ""))

# --- parse_requirements ---------------------------------------------------
for label, text, needle in [
    ("an unpinned requirement is rejected on parse", "pyyaml>=6.0.2\n    --hash=sha256:" + GOOD + "\n", "not pinned with '=='"),
    ("a requirements file with no hashes is rejected", "pyyaml==6.0.2\n", "no --hash entries"),
    ("a non-sha256 hash is rejected on parse", "pyyaml==6.0.2 \\\n    --hash=md5:" + GOOD + "\n", "only sha256 hashes"),
    ("a second requirement is rejected", "pyyaml==6.0.2 \\\n    --hash=sha256:" + GOOD + "\nrequests==2.0\n", "second requirement"),
    # The layout that was built and then removed: annotating each digest with its
    # artifact filename. pip ignores every hash after a comment inside the
    # continuation block, so a file in that shape would enforce nothing while
    # looking fully pinned. It is rejected here so it cannot come back.
    ("a comment inside the hash block is rejected on parse",
     "pyyaml==6.0.2 \\\n    # some-wheel.whl\n    --hash=sha256:" + GOOD + "\n",
     "comment inside the hash block"),
]:
    try:
        gen.parse_requirements(text)
    except ValueError as error:
        results.append(("ok" if needle in str(error) else "fail", label,
                        "" if needle in str(error) else f"wanted {needle!r} in {str(error)!r}"))
    else:
        results.append(("fail", label, "accepted input it must reject"))

parsed_pkg, parsed_ver, parsed_digests = gen.parse_requirements(gen.render_requirements([("f", GOOD), ("g", OTHER)]))
results.append(("ok" if (parsed_pkg, parsed_ver) == ("pyyaml", "6.0.2") else "fail",
                "parse_requirements recovers the pin", f"got {(parsed_pkg, parsed_ver)}"))
results.append(("ok" if [d for _, d in parsed_digests] == [GOOD, OTHER] else "fail",
                "parse_requirements recovers the digests in order", ""))

# --- the committed file ---------------------------------------------------
try:
    with open(requirements_path, encoding="utf-8") as handle:
        committed = handle.read()
except OSError as error:
    results.append(("fail", f"{requirements_path} is readable", str(error)))
    committed = ""

if committed:
    pkg, ver, digests = gen.parse_requirements(committed)
    # The whole file, header included, must be what the generator emits from
    # that pin and those digests. This is the check that catches a hand-edit, a
    # reordering, and a reformat alike.
    rebuilt = gen.file_header(pkg, ver) + gen.render_requirements(digests)
    results.append(("ok" if rebuilt == committed else "fail",
                    "the committed requirements file is exactly what the generator emits",
                    "" if rebuilt == committed else "differs from the generator's output (hand-edited?)"))
    results.append(("ok" if ver == gen.VERSION else "fail",
                    f"the committed file pins the generator's default version ({gen.VERSION})",
                    "" if ver == gen.VERSION else f"file pins {ver}"))
    results.append(("ok" if gen.normalise_name(pkg) == gen.normalise_name(gen.PACKAGE) else "fail",
                    f"the committed file pins the generator's default package ({gen.PACKAGE})",
                    ""))
    # Structure of the pin itself, asserted without the generator: a bare `==`
    # with no hash is the exact defect #136 was filed for.
    digests_in_file = re.findall(r"--hash=sha256:([0-9a-f]{64})", committed)
    results.append(("ok" if len(digests_in_file) == len(digests) else "fail",
                    "every hash in the file is 64 hex chars and is counted once",
                    f"file has {len(digests_in_file)}, parse found {len(digests)}"))
    results.append(("ok" if len(set(digests_in_file)) == len(digests_in_file) else "fail",
                    "no digest appears twice in the committed file", ""))
    results.append(("ok" if re.search(rf"^{re.escape(gen.PACKAGE)}==\S+ \\$", committed, re.M) else "fail",
                    "the requirement line is a `==` pin with a continuation", ""))
    # Floors, so the list cannot shrink without the floor being visibly changed in
    # the same diff. Measured against PyPI 6.0.2 on 2026-09-30: 53 artifacts. A
    # lower floor is not "safe to lower" -- a smaller list is a narrower set of
    # artifacts that can be installed, which is a regression in who can install,
    # not a tidy-up. Legitimate shrinkage means a version bump, which regenerates
    # the file and is expected to move this number.
    results.append(("ok" if len(digests_in_file) >= 53 else "fail",
                    "artifact floor: the file still covers every published artifact",
                    f"only {len(digests_in_file)} artifacts listed; 6.0.2 publishes 53. "
                    "Removing a hash narrows who can install -- do that only by bumping the version."))

for row in results:
    if row[0] == "ok":
        print(f"  ok   {row[1]}")
    else:
        print(f"  FAIL {row[1]}")
        if len(row) > 2 and row[2]:
            print(f"        {row[2]}")

# The floor is checked against the number of checks EMITTED, not the number that
# passed. A floor on passed-counts would be satisfied by a suite that emitted
# fewer assertions as long as the ones it emitted were correct -- which is
# exactly the deletion the floor exists to catch.
print(f"__COUNTS__ {len(results)} {sum(1 for r in results if r[0] == 'fail')}")
PYTHON
)"
STATUS=$?

if [[ ${STATUS} -ne 0 ]]; then
  printf '%s\n' "${RESULTS}" | sed 's/^/  /' >&2
  bad "the assertion block itself exited ${STATUS}" "see the traceback above"
  printf '\n  %d passed, %d failed\n' 0 1 >&2
  exit 1
fi

COUNTS="$(printf '%s\n' "${RESULTS}" | grep '^__COUNTS__ ' | tail -n 1)"
EMITTED="$(printf '%s' "${COUNTS}" | awk '{print $2}')"
FAILED="$(printf '%s' "${COUNTS}" | awk '{print $3}')"
PASSED=$((EMITTED - FAILED))

printf '%s\n' "${RESULTS}" | grep -v '^__COUNTS__ ' | while IFS= read -r line; do
  case "${line}" in
    "  ok   "*) ok "${line#  ok   }" ;;
    "  FAIL "*)
      name="${line#  FAIL }"
      printf '  FAIL %s\n' "${name}" >&2
      ;;
  esac
done

if [[ "${FAILED}" != "0" ]]; then
  FAIL_COUNT="${FAILED}"
fi

# A floor, so deleting assertions cannot turn this suite green. It is checked
# against the number of assertions EMITTED, so deleting one fails the floor even
# if every remaining assertion passes.
MINIMUM_ASSERTIONS=30
if [[ "${EMITTED}" -lt "${MINIMUM_ASSERTIONS}" ]]; then
  bad "assertion floor: ${EMITTED} >= ${MINIMUM_ASSERTIONS}" \
    "an assertion was deleted, or the block stopped emitting checks"
fi

printf '\n  %d passed, %d failed\n' "${PASSED}" "${FAIL_COUNT}"
[[ "${FAIL_COUNT}" -eq 0 ]]
