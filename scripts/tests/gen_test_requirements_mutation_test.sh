#!/usr/bin/env bash
#
# Mutation pass for scripts/tests/gen_test_requirements_test.sh (issue #136).
#
# The workflow-hygiene mutation harness proves that suite's assertions bite. This
# does the same for the generator suite, which is the one that decides whether the
# committed lockfile can be trusted. It had no mutation pass at all, and that is a
# gap rather than a formality: the round-trip and CLI assertions in it are the only
# thing standing between a hand-edited requirements file and a required check that
# reports it as generated.
#
# Four rules this harness obeys, each learned by getting it wrong first:
#
#  1. Every anchor must be UNIQUE. `apply` replaces the first occurrence, and an
#     anchor that appears twice silently mutates the wrong site -- during #136 a
#     mutation of `python -m pip install ...` hit the workflow's ShellCheck
#     argument list instead of the command, and the assertion correctly stayed
#     green, which is indistinguishable from a missing assertion unless you read
#     which line changed. `apply` therefore refuses any count other than 1.
#
#  2. A mutation must go red for the RIGHT reason. "The suite exited non-zero" is
#     not a result; a named assertion going red is. `needle_matches` scopes to
#     FAIL lines and their detail lines, and a wrong-red is reported as a failure.
#
#  3. A mutation must be ON DISK before the suite is believed. One run of this
#     harness reported a mutation as non-biting; a rerun with an unrelated `grep`
#     added in front of the suite reported it as biting. The root cause was never
#     confirmed, so rather than guess, `apply` now re-reads the file and refuses to
#     return success unless the replacement is present and the original text is
#     gone, and the suite runs with bytecode writing disabled so a cached `.pyc`
#     cannot be the thing under test. A mutation that is not on disk now fails the
#     harness loudly instead of looking like a green assertion.
#
#  4. Anchors are read from the files, never invented. Digests and filenames taken
#     from memory do not exist, and the first draft of this harness had four
#     mutations that could not apply for exactly that reason.
#
# Leaves the working tree untouched: restores from file copies, never from git.
set -uo pipefail

ROOT_DIR="${PO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SUITE="${ROOT_DIR}/scripts/tests/gen_test_requirements_test.sh"
GENERATOR="${ROOT_DIR}/scripts/gen_test_requirements.py"
REQUIREMENTS="${ROOT_DIR}/scripts/requirements-test.txt"
FIXTURE="${ROOT_DIR}/scripts/tests/fixtures/pyyaml-6.0.2-pypi.json"

WORK="$(mktemp -d)"
trap 'restore; rm -rf "${WORK}"' EXIT

cp "${GENERATOR}" "${WORK}/generator.orig"
cp "${REQUIREMENTS}" "${WORK}/requirements.orig"
cp "${FIXTURE}" "${WORK}/fixture.orig"
cp "${SUITE}" "${WORK}/suite.orig"

restore() {
  cp "${WORK}/generator.orig" "${GENERATOR}"
  cp "${WORK}/requirements.orig" "${REQUIREMENTS}"
  cp "${WORK}/fixture.orig" "${FIXTURE}"
  cp "${WORK}/suite.orig" "${SUITE}"
}

MUTATIONS_RUN=0
MUTATIONS_BITING=0
mismatches=()

# apply <file> <old|||new>  -- exactly one occurrence, verified on disk; prints the
# line it changed. Literal `\n` in either half becomes a real newline.
#
# The post-write re-read is the point of rule 3: writing the file is not evidence
# that the file now says what the mutation intended.
apply() {
  python3 - "$1" "$2" <<'PYTHON'
import sys

path, expr = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as handle:
    text = handle.read()
old, new = expr.split("|||")
old = old.replace("\\n", "\n")
new = new.replace("\\n", "\n")
count = text.count(old)
if count != 1:
    print(f"ANCHOR IS NOT UNIQUE ({count} occurrences): {old[:90]!r}", file=sys.stderr)
    sys.exit(4 if count else 3)
with open(path, "w", encoding="utf-8") as handle:
    handle.write(text.replace(old, new, 1))
with open(path, encoding="utf-8") as handle:
    after = handle.read()
if new and new not in after:
    print("MUTATION DID NOT LAND: replacement text is not in the file", file=sys.stderr)
    sys.exit(5)
if old and old in after and old not in new:
    print("MUTATION DID NOT LAND: original text is still in the file", file=sys.stderr)
    sys.exit(6)
print(text[: text.index(old)].count("\n") + 1)
PYTHON
}

# FAIL lines and their indented detail lines only. `ok` lines share substrings with
# FAIL lines, so matching the whole output would let a passing assertion satisfy
# the needle.
needle_matches() {
  grep -E '^  FAIL |^        ' <<<"$1" | grep -qF "$2"
}

# Runs the suite with bytecode writing off (rule 3).
run_suite() {
  PYTHONDONTWRITEBYTECODE=1 bash "${SUITE}" 2>&1
}

mutate() {
  local name="$1" file="$2" expr="$3" needle="$4"
  MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
  restore
  local line
  if ! line="$(apply "$file" "$expr" 2>&1)"; then
    mismatches+=("${name}: could not apply the mutation (${line})")
    restore
    return
  fi
  local out rc
  out="$(run_suite)"
  rc=$?
  if [[ ${rc} -eq 0 ]]; then
    mismatches+=("${name}: SUITE STILL PASSED (assertion does not bite)")
  elif ! needle_matches "${out}" "${needle}"; then
    mismatches+=("${name}: went red but not on '${needle}'")
    mismatches+=("        line ${line}; saw: $(grep -E '^  FAIL ' <<<"${out}" | head -3 | tr '\n' ' ')")
  else
    MUTATIONS_BITING=$((MUTATIONS_BITING + 1))
    printf '  bites  %s\n' "${name}"
  fi
  restore
}

# A real digest from the committed file, so the anchors below are ones the file
# actually contains (rule 4). $'...' is used where a literal backslash has to
# survive: "…" \\n" would lose the backslash to `apply`'s newline unescaping.
FIRST_DIGEST="0a9a2848a5b7feac301353437eb7d5957887edbf81d56e903999a75a3d743086"
# A digest line in this file ends with a pip continuation backslash, and the
# anchor has to include it: an anchor that omits it deletes a line's continuation
# rather than the line, which is a different mutation wearing the same name.
# printf '\\\\' is one backslash and the appended newline is real. This used to be
# written with ANSI-C quoting, whose handling of a trailing backslash-plus-n turned
# out to depend on the surrounding context -- not a property to build a harness on.
HASH_LINE="$(printf '    --hash=sha256:%s \\' "${FIRST_DIGEST}")"$'\n'
PIN_LINE="$(printf 'pyyaml==6.0.2 \\')"$'\n'
COMMENT_LINE="$(printf '# PyYAML-6.0.2-cp313-cp313-macosx_10_13_x86_64.whl')"$'\n'

echo "== the committed lockfile stops being what the generator emits =="

# Each of these is a hand edit to the committed file. Round-trip equality is what
# catches all three; the suite's header says so, and these are the mutations that
# keep the header honest.
mutate "a digest is edited in place" \
  "${REQUIREMENTS}" \
  "--hash=sha256:${FIRST_DIGEST}|||--hash=sha256:0000000000000000000000000000000000000000000000000000000000000000" \
  "exactly what the generator emits"

mutate "a hash line is deleted, narrowing who can install" \
  "${REQUIREMENTS}" \
  "${HASH_LINE}|||" \
  "artifact floor"

mutate "the version pin is changed by hand" \
  "${REQUIREMENTS}" \
  "${PIN_LINE}|||$(printf 'pyyaml==6.0.3 \\')"$'\n' \
  "exactly what the generator emits"

  # The committed file is not the synthetic input the parser-shape assertion above
  # uses, so the named failure here is the guarded parse of the real file -- not
  # "a comment inside the hash block is rejected on parse", which never sees it.
mutate "a comment is put inside the hash block" \
  "${REQUIREMENTS}" \
  "${HASH_LINE}|||${COMMENT_LINE}" \
  "the committed requirements file parses"

# The derived CPython range. The header states the range it was given and the
# generator derives that range from the recorded artifact filenames, so editing
# either side has to be caught, and neither may become a constant again.
mutate "the header's CPython range is widened by hand" \
  "${REQUIREMENTS}" \
  '# CPython 3.8 through 3.13 for this pin.|||# CPython 3.8 through 3.14 for this pin.' \
  "exactly what the generator emits"

mutate "the recorded artifact set gains a newer interpreter" \
  "${FIXTURE}" \
  'PyYAML-6.0.2-cp313-cp313-macosx_10_13_x86_64.whl|||PyYAML-6.0.2-cp314-cp314-macosx_10_13_x86_64.whl' \
  "exactly what the generator emits"

mutate "a digest in the recorded response is altered" \
  "${FIXTURE}" \
  "\"sha256\": \"${FIRST_DIGEST}\"|||\"sha256\": \"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff\"" \
  "exactly what the generator emits"

echo "== the generator stops refusing what it must =="

# Each refusal shape has a named assertion, so breaking a guard has to go red on
# that assertion rather than anywhere.
mutate "validate_artifacts stops checking the digest shape" \
  "${GENERATOR}" \
  '_SHA256 = re.compile(r"^[0-9a-f]{64}$")|||_SHA256 = re.compile(r"^[0-9a-f]{1,}$")' \
  "a truncated digest is refused"

mutate "validate_artifacts stops rejecting a duplicate digest" \
  "${GENERATOR}" \
  'if digest in seen_digests:|||if False:' \
  "one digest claimed by two filenames is refused"

mutate "validate_artifacts stops rejecting an empty artifact list" \
  "${GENERATOR}" \
  'if not artifacts:|||if False:' \
  "an empty artifact list is refused"

mutate "validate_artifacts stops rejecting a repeated filename" \
  "${GENERATOR}" \
  'if filename in seen_filenames:|||if False:' \
  "a repeated filename is refused"

mutate "validate_artifacts stops checking the version" \
  "${GENERATOR}" \
  'if dist_version != version:|||if False:' \
  "an artifact at another version is refused"

mutate "validate_artifacts stops checking the distribution name" \
  "${GENERATOR}" \
  'if normalise_name(dist) != expected:|||if False:' \
  "an artifact for another project is refused"

mutate "validate_artifacts stops rejecting a malformed wheel filename" \
  "${GENERATOR}" \
  'if len(parts) < 5:|||if False:' \
  "a malformed wheel filename is refused"

echo "== the generator stops deriving, and the CLI stops vetting =="

# The range must come from the artifact list. A constant is the regression the
# recorded fixture exists to make impossible, so it gets its own mutation.
mutate "cpython_wheel_range returns a constant instead of deriving" \
  "${GENERATOR}" \
  'return min(minors), max(minors)|||return 8, 13' \
  "tracks a newer artifact set"

mutate "cpython_wheel_range accepts an sdist-only set" \
  "${GENERATOR}" \
  'if not minors:|||if False:' \
  "an sdist-only artifact set is refused"

# main() is the function that overwrites the committed lockfile. Rendering without
# validating is the failure worth catching: a bad artifact set would be written out
# as though it had been vetted.
mutate "main renders without validating the artifact set" \
  "${GENERATOR}" \
  'rendered = render_file(artifacts, package=args.package, version=args.version)|||rendered = file_header(args.package, args.version, 8, 13) + render_requirements(artifacts, args.package, args.version)' \
  "main refuses a bad artifact set and writes no file"

echo "== the count regex's anchor, which is load-bearing and was quietly lost once =="

# Part A. An over-long digest with the anchor in place: this assertion must catch
# it, because that is the only reason the anchor exists.
mutate "an over-long digest meets the anchored count regex" \
  "${REQUIREMENTS}" \
  "--hash=sha256:${FIRST_DIGEST}|||--hash=sha256:${FIRST_DIGEST}f" \
  "every hash in the file is 64 hex chars and is counted once"

# Part B. The same over-long digest with the anchor REMOVED. This one must NOT go
# red on the count assertion: the unanchored regex truncates the digest to its
# first 64 characters, the count still matches, and the assertion goes silent. A
# green result here is the point, so it is checked in the opposite direction.
#
# The lookahead was dropped from this suite's own line by an unrelated edit while
# its comment still claimed it was there, and nothing went red: the comment
# described a property of the code that no longer existed. That is the specific
# failure this pair of mutations exists to make impossible.
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
restore
unanchored="an over-long digest meets an UNANCHORED count regex"
if ! apply "${REQUIREMENTS}" \
  "--hash=sha256:${FIRST_DIGEST}|||--hash=sha256:${FIRST_DIGEST}f" >/dev/null 2>&1; then
  mismatches+=("${unanchored}: could not apply the digest half")
elif ! apply "${SUITE}" \
  'r"--hash=sha256:([0-9a-f]{64})(?![0-9A-Za-z])"|||r"--hash=sha256:([0-9a-f]{64})"' >/dev/null 2>&1; then
  mismatches+=("${unanchored}: could not apply the regex half")
else
  # The suite is expected to be red here: the committed file really does carry an
  # over-long digest, so the round-trip assertions are right to fire. The only thing
  # under test is whether the COUNT assertion joins them, and an unanchored regex
  # makes it not. So the suite exit status is deliberately not consulted: a
  # whole-suite-green expectation here would be satisfied by the very defect this
  # check exists to catch.
  out="$(run_suite)"
  if needle_matches "${out}" "every hash in the file is 64 hex chars and is counted once"; then
    mismatches+=("${unanchored}: the count assertion fired anyway, so the anchor is not what makes it fire")
  else
    MUTATIONS_BITING=$((MUTATIONS_BITING + 1))
    printf '  bites  %s\n' "${unanchored} (goes silent, as it must)"
  fi
fi
restore

echo "== documented blind spot, asserted so the header cannot drift =="

# A lockfile that is wrong CONSISTENTLY: the recorded response and the committed
# file change together, so they still agree with each other while both disagree
# with PyPI. Round-trip equality cannot see this, and neither can counting. It is
# `pip install --require-hashes` in the required `Security gates` job that closes
# it, and that is the whole reason the network is not in a required check here.
#
# So the expected result is GREEN, and the harness fails if it is not. The suite's
# header states this boundary in words; this is the same statement in an assertion,
# so the two cannot drift apart unnoticed.
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
restore
blindspot="a consistently wrong lockfile (fixture and lockfile agree, PyPI does not)"
if ! apply "${FIXTURE}" \
  "\"sha256\": \"${FIRST_DIGEST}\"|||\"sha256\": \"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff\"" >/dev/null 2>&1; then
  mismatches+=("${blindspot}: could not apply the fixture half")
elif ! apply "${REQUIREMENTS}" \
  "--hash=sha256:${FIRST_DIGEST}|||--hash=sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" >/dev/null 2>&1; then
  mismatches+=("${blindspot}: could not apply the lockfile half")
else
  out="$(run_suite)"
  if [[ $? -ne 0 ]]; then
    mismatches+=("${blindspot}: the suite went red, so the header's stated boundary is wrong")
    mismatches+=("        saw: $(grep -E '^  FAIL ' <<<"${out}" | head -3 | tr '\n' ' ')")
  else
    MUTATIONS_BITING=$((MUTATIONS_BITING + 1))
    printf '  bites  %s (green, as the header states)\n' "${blindspot}"
  fi
fi
restore

restore
final_out="$(run_suite)"
final_rc=$?
echo
if [[ ${final_rc} -ne 0 ]]; then
  mismatches+=("restoring the originals did not return the suite to green")
  printf '%s\n' "${final_out}" | tail -5 | sed 's/^/        /' >&2
fi

printf 'mutations: %d run, %d bit, suite after restore: %s\n' \
  "${MUTATIONS_RUN}" "${MUTATIONS_BITING}" \
  "$(grep -E '^[[:space:]]*[0-9]+ passed' <<<"${final_out}" || echo 'no summary')"

if ((${#mismatches[@]} > 0)); then
  printf '\nNON-BITING / WRONG-RED MUTATIONS (%d):\n' "${#mismatches[@]}" >&2
  printf '  - %s\n' "${mismatches[@]}" >&2
  exit 1
fi
printf 'all %d mutations bit\n' "${MUTATIONS_RUN}"
