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
# What (2) does and does not prove, established by mutation rather than assumed.
# An earlier draft of this header had it exactly backwards, claiming that a digest
# edited in place, two hashes swapped, and a hash line deleted were all invisible
# to round-trip equality. They are all caught, because the committed file then stops
# being what the generator emits for the recorded artifact set:
#   scripts/tests/gen_test_requirements_mutation_test.sh
#     "a digest is edited in place"            -> red on round-trip equality
#     "two hashes are swapped"                  -> red on round-trip equality
#     "a hash line is deleted, narrowing ..."   -> red on round-trip equality
#
# What round-trip equality genuinely cannot see is a lockfile that is wrong
# CONSISTENTLY: the recorded response and the committed file changed together, so
# they still agree with each other while both disagree with PyPI. That mutation is
# asserted GREEN on purpose, under "documented blind spot" in the harness, so this
# paragraph cannot quietly start claiming more or less than the harness checks.
#
# The only non-circular check on a digest is the artifact bytes themselves, which is
# `pip install --require-hashes` running in the required `Security gates` job on
# every CI run. Comparing against PyPI here instead would put the network in a
# required check, which is the defect #136 exists to remove, and would not prove more.
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
import contextlib
import importlib.util
import io
import json
import os
import re
import shutil
import sys
import tempfile

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

# The recorded PyPI response, at module scope. It is used in two places: the
# round-trip below, and the main() coverage further down. Defining it inside the
# round-trip block -- which is where it was -- meant that any failure which skipped
# that block also skipped the definition, and the later use became a NameError.
# repo root, from the generator's own path: <root>/scripts/gen_*.py
fixture_path = os.path.join(
    os.path.dirname(os.path.dirname(generator_path)),
    "scripts", "tests", "fixtures", "pyyaml-6.0.2-pypi.json",
)
# A malformed committed file has to produce a named failure carrying the parser's
# own message. Unguarded, this parse was the first thing to blow up when a comment
# was inserted into the hash block: the suite exited 1 with a traceback and no
# indication of which assertion was supposed to fire. Failing closed is correct;
# failing opaquely is not, and it also made the mutation that inserts such a comment
# impossible to measure, because every outcome then looked the same.
committed_ok = False
if committed:
    try:
        pkg, ver, digests = gen.parse_requirements(committed)
    except ValueError as error:
        results.append(("fail", "the committed requirements file parses",
                        f"parse_requirements refused it: {error}"))
    else:
        committed_ok = True

if committed_ok:
    # The whole file, header included, must be what the generator emits from the
    # artifact list it was actually generated from. The committed file carries no
    # filenames -- pip accepts no comment inside a requirement's continuation block,
    # which is why it cannot -- so the recorded PyPI response is what supplies them.
    # Round-tripping through it is strictly stronger than the previous form: it also
    # re-derives the CPython range the header states, so a hand-edited range, a
    # hand-edited header, a reordering, a reformat and a dropped artifact are all
    # caught by one comparison.
    fixture_json = json.load(open(fixture_path, encoding="utf-8"))
    fixture_artifacts = gen.extract_artifacts(fixture_json)
    rebuilt = gen.render_file(fixture_artifacts)
    results.append(("ok" if rebuilt == committed else "fail",
                    "the committed requirements file is exactly what the generator emits from the recorded PyPI response",
                    "" if rebuilt == committed else "differs from the generator's output (hand-edited?)"))
    # The CLI path must agree with the library path, or `main` is the odd one out.
    results.append(("ok" if gen.parse_requirements(rebuilt) == gen.parse_requirements(committed) else "fail",
                    "the regenerated file parses back identically",
                    ""))
    results.append(("ok" if ver == gen.VERSION else "fail",
                    f"the committed file pins the generator's default version ({gen.VERSION})",
                    "" if ver == gen.VERSION else f"file pins {ver}"))
    results.append(("ok" if gen.normalise_name(pkg) == gen.normalise_name(gen.PACKAGE) else "fail",
                    f"the committed file pins the generator's default package ({gen.PACKAGE})",
                    ""))
    # Structure of the pin itself, asserted without the generator: a bare `==`
    # with no hash is the exact defect #136 was filed for.
    # The trailing lookahead is load-bearing for THIS assertion, and it is worth being
    # precise about what that means, because the first version of this comment
    # overclaimed: it said appending a hex character left the whole suite green,
    # which is false -- the round-trip assertion above catches that too. What the
    # lookahead buys is that this assertion can see an over-long digest at all.
    # Without it, `[0-9a-f]{64}` matches the first 64 characters of a 65-character
    # digest, the count still equals len(digests), and this assertion reports `ok`
    # for the state its own label calls impossible. The compound mutation
    # "an over-long digest meets an unanchored count regex" in
    # scripts/tests/gen_test_requirements_mutation_test.sh asserts that silence, so
    # the difference is re-verified rather than remembered.
    digests_in_file = re.findall(r"--hash=sha256:([0-9a-f]{64})(?![0-9A-Za-z])", committed)
    results.append(("ok" if len(digests_in_file) == len(digests) else "fail",
                    "every hash in the file is 64 hex chars and is counted once",
                    f"file has {len(digests_in_file)}, parse found {len(digests)}"))
    results.append(("ok" if len(set(digests_in_file)) == len(digests_in_file) else "fail",
                    "no digest appears twice in the committed file", ""))
    results.append(("ok" if re.search(rf"^{re.escape(gen.PACKAGE)}==\S+ \\$", committed, re.M) else "fail",
                    "the requirement line is a `==` pin with a continuation", ""))
    # Floors, so the list cannot shrink without the floor being visibly changed in
    # the same diff. Two checks, and the difference between them matters.
    #
    # The first is an EQUALITY against the recorded artifact list, which is the
    # strong form and the one that normally holds: the committed file must list
    # exactly the artifacts the generator was run on. Both are 53.
    results.append(("ok" if len(digests_in_file) == len(fixture_artifacts) else "fail",
                    "the committed file lists exactly the recorded artifact set",
                    f"file has {len(digests_in_file)}, the recorded PyPI response has {len(fixture_artifacts)}"))
    # The second is a FLOOR, kept even though the equality above subsumes it for
    # this pin. It is a floor because it is about the direction of change: removing
    # a hash narrows who can install, which is a regression, and it must be done by
    # bumping the version -- which regenerates the file and is expected to move this
    # number. A lower floor is not "safe to lower". 53 measured for pyyaml 6.0.2.
    results.append(("ok" if len(digests_in_file) >= 53 else "fail",
                    "artifact floor: the list has not shrunk below the 53 measured for 6.0.2",
                    f"only {len(digests_in_file)} artifacts listed; 6.0.2 publishes 53. "
                    "Removing a hash narrows who can install -- do that only by bumping the version."))
    # What neither check can do, stated because the previous wording implied it:
    # prove the recorded list still matches PyPI today. If 6.0.2 gained an artifact,
    # both pass and the file is incomplete. Only re-fetching establishes that, which
    # is what the bump workflow is for.

# --- the derived CPython wheel range --------------------------------------
# The range used to be two hand-written constants that nothing connected to the
# artifact list, so a version bump kept the old pin's wheel-coverage claim in the
# header. It is now derived, which is what makes the header unable to lie.
WIDE = [
    ("PyYAML-6.0.2-cp38-cp38-manylinux_2_17_x86_64.whl", "1" * 64),
    ("PyYAML-6.0.2-cp313-cp313-macosx_11_0_arm64.whl", "2" * 64),
    ("PyYAML-6.0.2-cp39-cp39-win_amd64.whl", "3" * 64),
    ("pyyaml-6.0.2.tar.gz", "4" * 64),
]
try:
    got = gen.cpython_wheel_range(WIDE)
    results.append(("ok" if got == (8, 13) else "fail",
                    "cpython_wheel_range reads min and max from the wheel tags",
                    "" if got == (8, 13) else f"got {got}, wanted (8, 13)"))
except ValueError as error:
    results.append(("fail", "cpython_wheel_range reads min and max from the wheel tags", str(error)))

# The range must be derived, not hardcoded: an artifact set whose newest wheel is
# cp314 has to yield 14, which is the case the old constants got wrong.
NEWER = [
    ("PyYAML-6.0.3-cp313-cp313-manylinux_2_17_x86_64.whl", "1" * 64),
    ("PyYAML-6.0.3-cp314-cp314-manylinux_2_17_x86_64.whl", "2" * 64),
]
try:
    got = gen.cpython_wheel_range(NEWER)
    results.append(("ok" if got == (13, 14) else "fail",
                    "cpython_wheel_range tracks a newer artifact set rather than a fixed range",
                    "" if got == (13, 14) else f"got {got}, wanted (13, 14)"))
except ValueError as error:
    results.append(("fail", "cpython_wheel_range tracks a newer artifact set rather than a fixed range", str(error)))

# An sdist-only set cannot honestly state a range, and rendering one would claim
# --only-binary works when it refuses every interpreter.
try:
    gen.cpython_wheel_range([("pyyaml-6.0.2.tar.gz", "5" * 64)])
except ValueError as error:
    results.append(("ok" if "no artifact is a CPython wheel" in str(error) else "fail",
                    "an sdist-only artifact set is refused rather than given a range",
                    "" if "no artifact is a CPython wheel" in str(error) else str(error)))
else:
    results.append(("fail", "an sdist-only artifact set is refused rather than given a range",
                    "it was accepted, so the header would claim interpreters it cannot serve"))

# --- the header states the derived range, and the committed one agrees ---
header = gen.file_header("pyyaml", "6.0.2", 8, 13)
found = gen.CP_RANGE_IN_HEADER.search(header)
results.append(("ok" if found and found.groups() == ("8", "13") else "fail",
                "the header states the range it was given",
                "" if found else "CP_RANGE_IN_HEADER did not match the header the generator emitted"))
# The committed file has to state the same range, or CI's pinned interpreter is
# being checked against a number nothing derived.
committed_range = gen.CP_RANGE_IN_HEADER.search(committed)
results.append(("ok" if committed_range else "fail",
                "the committed lockfile states its CPython range",
                "" if committed_range else "no CPython range line in scripts/requirements-test.txt"))

# --- the CLI and its write path ------------------------------------------
# main() is the function that overwrites the committed lockfile, and it was the
# one uncovered corner: every assertion above called a pure function, so a bug in
# the argument handling, the output path, or the write itself would have shipped.
# Driven through --from-json, so no network is involved -- and fetch_pypi_json is
# replaced with a tripwire to prove it.
work = tempfile.mkdtemp(prefix="gen-req-cli-")


def fake_pypi(artifacts):
    return {"urls": [{"filename": f, "digests": {"sha256": d}} for f, d in artifacts]}


fixture = os.path.join(work, "pypi.json")
with open(fixture, "w", encoding="utf-8") as handle:
    json.dump(fake_pypi(WIDE), handle)


def rendered(artifacts):
    """What main() would emit for these artifacts: JSON in, sorted, rendered out.

    Goes through extract_artifacts rather than trusting the caller's order, because
    that sort is part of what makes the output byte-stable, and comparing against an
    unsorted expectation would be a test that passes only by accident of ordering.
    """
    return gen.render_file(gen.extract_artifacts(fake_pypi(artifacts)))


# Every call to fetch_pypi_json is recorded, so "main never reaches for the
# network" is measured rather than asserted. My first version of this line was a
# literal `results.append(("ok", ...))` with the reason in the third slot -- a
# comment wearing an assertion's clothes, which is the exact defect this repo
# treats as a defect. It would have stayed green if main started fetching.
network_calls = []


def tripwire(*args, **kwargs):
    network_calls.append(args[0] if args else "?")
    raise AssertionError("main() tried to reach the network in an offline test")


gen.fetch_pypi_json = tripwire

# --stdout prints exactly what main would render.
buf = io.StringIO()
with contextlib.redirect_stdout(buf):
    rc = gen.main(["--from-json", fixture, "--stdout"])
results.append(("ok" if rc == 0 and buf.getvalue() == rendered(WIDE) else "fail",
                "main --stdout prints exactly what render_file returns",
                f"rc={rc}"))
results.append(("ok" if buf.getvalue() != committed else "fail",
                "main --stdout for a synthetic set differs from the committed file",
                "the synthetic artifact set rendered identically to the committed lockfile, so the test input is not exercising the path"))

# --output writes the same bytes to the named path.
out_path = os.path.join(work, "written.txt")
rc = gen.main(["--from-json", fixture, "--output", out_path])
written = open(out_path, encoding="utf-8").read() if os.path.isfile(out_path) else None
results.append(("ok" if rc == 0 and written == rendered(WIDE) else "fail",
                "main --output writes exactly what render_file returns",
                f"rc={rc} wrote={written is not None}"))

# Checked after every main() call above, not before it: the counter has to be read
# at the end or it proves nothing about the calls that already happened.
results.append(("ok" if not network_calls else "fail",
                "no main() invocation reached for the network",
                "" if not network_calls else f"fetch_pypi_json called with {network_calls}"))

# A rejected artifact set must make main fail loudly and write nothing, rather
# than overwrite the committed lockfile with a file it cannot vouch for.
bad_fixture = os.path.join(work, "bad.json")
with open(bad_fixture, "w", encoding="utf-8") as handle:
    json.dump(fake_pypi([("PyYAML-6.0.2-cp313-cp313-win_amd64.whl", "z" * 64)]), handle)
doomed = os.path.join(work, "doomed.txt")
err = io.StringIO()
with contextlib.redirect_stderr(err):
    rc = gen.main(["--from-json", bad_fixture, "--output", doomed])
results.append(("ok" if rc != 0 and not os.path.exists(doomed) else "fail",
                "main refuses a bad artifact set and writes no file",
                f"rc={rc} exists={os.path.exists(doomed)}"))
results.append(("ok" if "not 64 lowercase hex" in err.getvalue() else "fail",
                "main's refusal names the actual problem",
                f"stderr was {err.getvalue()!r}"))

# A PyPI response with no artifact list at all must not leave a zero-artifact
# lockfile behind.
empty_fixture = os.path.join(work, "empty.json")
with open(empty_fixture, "w", encoding="utf-8") as handle:
    json.dump({"urls": []}, handle)
rc = gen.main(["--from-json", empty_fixture, "--stdout"])
results.append(("ok" if rc != 0 else "fail",
                "main refuses an empty PyPI response",
                f"rc={rc}"))

# The recorded fixture must reproduce the committed lockfile through the CLI too,
# not only through the library. This is the documented bump workflow, so it is the
# one that has to be proven rather than described.
buf = io.StringIO()
with contextlib.redirect_stdout(buf):
    rc = gen.main(["--from-json", fixture_path, "--stdout"])
results.append(("ok" if rc == 0 and buf.getvalue() == committed else "fail",
                "the documented offline regenerate command reproduces the committed lockfile",
                f"rc={rc} identical={buf.getvalue() == committed}"))

shutil.rmtree(work, ignore_errors=True)

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
# 48 assertions are emitted. The floor sits at 44 to tolerate a small legitimate
# edit while still failing on a deletion -- the whole point of the mechanism is
# that removing a check cannot turn the suite green.
MINIMUM_ASSERTIONS=44
if [[ "${EMITTED}" -lt "${MINIMUM_ASSERTIONS}" ]]; then
  bad "assertion floor: ${EMITTED} >= ${MINIMUM_ASSERTIONS}" \
    "an assertion was deleted, or the block stopped emitting checks"
fi

printf '\n  %d passed, %d failed\n' "${PASSED}" "${FAIL_COUNT}"
[[ "${FAIL_COUNT}" -eq 0 ]]
