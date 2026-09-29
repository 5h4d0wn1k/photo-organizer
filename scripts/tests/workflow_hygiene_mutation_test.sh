#!/usr/bin/env bash
#
# Mutation pass for the pin-version / pin-major / dependabot-grouping
# assertions added to scripts/tests/workflow_hygiene_test.sh (issue #130).
#
# Those three assertions exist because Dependabot moved
# actions/download-artifact from 4.1.8 to 8.0.1 inside a grouped PR while
# leaving the trailing `# v4` comment in place, and nothing in CI noticed. An
# assertion that cannot be made to fail is a comment, so each one is broken
# here and the suite is required to go red.
#
# Leaves the working tree untouched.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SUITE="${ROOT_DIR}/scripts/tests/workflow_hygiene_test.sh"
WORK="$(mktemp -d)"
trap 'restore; rm -rf "${WORK}"' EXIT

PINNED_FILES=(
  "${ROOT_DIR}/.github/workflows/ci.yml"
  "${ROOT_DIR}/.github/workflows/release.yml"
  "${ROOT_DIR}/.github/workflows/scorecard.yml"
  "${ROOT_DIR}/.github/workflows/codeql-analysis.yml"
  "${ROOT_DIR}/.github/workflows/canary.yml"
  "${ROOT_DIR}/.github/workflows/dependency-review.yml"
  "${ROOT_DIR}/.github/workflows/stale.yml"
  "${ROOT_DIR}/.github/workflows/labeler.yml"
  "${ROOT_DIR}/.github/workflows/project.yml"
)
DEPENDABOT="${ROOT_DIR}/.github/dependabot.yml"

for f in "${PINNED_FILES[@]}"; do
  if [[ -f "$f" ]]; then
    cp "$f" "${WORK}/$(basename "$f").orig"
  fi
done
cp "${DEPENDABOT}" "${WORK}/dependabot.yml.orig"

restore() {
  for f in "${PINNED_FILES[@]}"; do
    base="$(basename "$f")"
    [[ -f "${WORK}/${base}.orig" ]] && cp "${WORK}/${base}.orig" "$f"
  done
  cp "${WORK}/dependabot.yml.orig" "${DEPENDABOT}"
}

MUTATIONS_RUN=0
MUTATIONS_BITING=0
mismatches=()

# apply <file> <old|||new>
apply() {
  python3 - "$1" "$2" <<'PYTHON'
import sys

path, expr = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as handle:
    text = handle.read()
old, new = expr.split("|||")
old = old.replace("\\n", "\n")
new = new.replace("\\n", "\n")
if old not in text:
    print(f"MUTATION TARGET NOT FOUND: {old!r}", file=sys.stderr)
    sys.exit(3)
with open(path, "w", encoding="utf-8") as handle:
    handle.write(text.replace(old, new, 1))
PYTHON
}

# mutate <name> <file> <old|||new> <expected-needle>
# The needle matters: "the suite went red" is not the same as "the suite went
# red on the assertion this mutation is about". A wrong-red is reported as a
# failure, not counted.
mutate() {
  local name="$1" file="$2" expr="$3" needle="$4"
  MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
  restore
  if ! apply "$file" "$expr"; then
    mismatches+=("${name}: could not apply the mutation")
    restore
    return
  fi
  local out rc
  out="$(bash "${SUITE}" 2>&1)"
  rc=$?
  if [[ ${rc} -eq 0 ]]; then
    mismatches+=("${name}: SUITE STILL PASSED (assertion does not bite)")
  elif ! grep -qF "${needle}" <<<"${out}"; then
    mismatches+=("${name}: went red but not on '${needle}'")
    mismatches+=("        saw: $(grep -E '^( +ok|  FAIL)' <<<"${out}" | grep -iF "$(cut -d: -f1 <<<"${needle}" | head -1)" | head -2 | tr '\n' ' ')")
  else
    MUTATIONS_BITING=$((MUTATIONS_BITING + 1))
    printf '  bites  %s\n' "${name}"
  fi
  restore
}

echo "== the mislabelled-pin regression (the reason these assertions exist) =="

# 1. The exact defect from #128: SHA moves to a new major, comment stays.
mutate "download-artifact pin moves but the comment is left stale" \
  "${ROOT_DIR}/.github/workflows/release.yml" \
  'actions/download-artifact@fa0a91b85d4f404e444e00e005971372dc801d16 # v4|||actions/download-artifact@fa0a91b85d4f404e444e00e005971372dc801d16 # v8' \
  "pin-version"

# 2. A pin with no version comment at all -- the reviewer has nothing to read.
mutate "a pin loses its version comment entirely" \
  "${ROOT_DIR}/.github/workflows/ci.yml" \
  'actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a # v7|||actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a' \
  "no parseable '# vN' version comment"

# 3. A garbage comment that looks like a version but is not one.
mutate "a pin's version comment is unparseable" \
  "${ROOT_DIR}/.github/workflows/ci.yml" \
  'gitleaks/gitleaks-action@e0c47f4f8be36e29cdc102c57e68cb5cbf0e8d1e # v3|||gitleaks/gitleaks-action@e0c47f4f8be36e29cdc102c57e68cb5cbf0e8d1e # latest' \
  "no parseable '# vN' version comment"

# 4. A minor-version comment is still a parseable major claim, and must pass.
#    (This one is expected NOT to bite; it guards against an over-strict
#    regex that would reject `# v2.1.3` and force someone to delete the comment.)
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
restore
if apply "${ROOT_DIR}/.github/workflows/ci.yml" \
  'actions-rust-lang/setup-rust-toolchain@ecabd13d1c56bd1345c230e542e9144811ad706f # v2|||actions-rust-lang/setup-rust-toolchain@ecabd13d1c56bd1345c230e542e9144811ad706f # v2.1.3' \
  && bash "${SUITE}" >/dev/null 2>&1; then
  MUTATIONS_BITING=$((MUTATIONS_BITING + 1))
  printf '  bites  a full version comment (# v2.1.3) is accepted (over-strict regex guard)\n'
else
  mismatches+=("over-strict regex: a full version comment was rejected; the regex must accept # vN.M.P")
fi
restore

# 5. The cross-file major check: same action, two declared majors.
mutate "one action declared at two different majors" \
  "${ROOT_DIR}/.github/workflows/scorecard.yml" \
  'github/codeql-action/upload-sarif@2892aa5e19bbd11bc0cff5427e3b750a04d9e3c2 # v4|||github/codeql-action/upload-sarif@2892aa5e19bbd11bc0cff5427e3b750a04d9e3c2 # v5' \
  "declared at more than one major"

echo "== the dependabot bundling root cause =="

# 6. The exact fix being reverted: drop update-types so majors ride along again.
mutate "dependabot github-actions group loses update-types" \
  "${DEPENDABOT}" \
  '        update-types: ["minor", "patch"]\n        patterns: ["*"]|||        patterns: ["*"]' \
  "no update-types"

# 7. Re-group, but include 'major' -- the subtler version of the same mistake.
mutate "dependabot group re-adds 'major' to update-types" \
  "${DEPENDABOT}" \
  '        update-types: ["minor", "patch"]|||        update-types: ["minor", "patch", "major"]' \
  "includes 'major'"

# 8. The group keeps update-types but loses `patterns`, which is what an
#    ungrouped-by-accident config looks like. An earlier version of this
#    assertion treated a pattern-less group as the safe "scoped" case and passed
#    it; the mutation is what showed that.
mutate "dependabot group loses its patterns" "${DEPENDABOT}" \
  '      github-actions-minor-patch:\n        update-types: ["minor", "patch"]\n        patterns: ["*"]|||      github-actions-minor-patch:\n        update-types: ["minor", "patch"]' \
  "no patterns"

# 9. `groups:` removed entirely -- one PR per bump. Safe, but stated rather than
#    passing silently, because "deliberately ungrouped" and "accidentally
#    ungrouped" are indistinguishable from the file alone. Done as a line-range
#    edit rather than an exact-text match: the block carries a long comment, and
#    an exact match on a comment is exactly the kind of assertion that rots.
MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
restore
if python3 - "${DEPENDABOT}" <<'PYTHON2'
import re
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    text = handle.read()
# Drop the `groups:` block of the github-actions update only.
pattern = re.compile(
    r"(package-ecosystem: \"github-actions\".*?)\n    groups:\n(?:.*\n)*?(?=  - package-ecosystem)",
    re.DOTALL,
)
if not pattern.search(text):
    print("MUTATION TARGET NOT FOUND: github-actions groups block", file=sys.stderr)
    sys.exit(3)
with open(path, "w", encoding="utf-8") as handle:
    handle.write(pattern.sub(lambda m: m.group(1) + "\n", text, count=1))
PYTHON2
then
  # Captured rather than piped: `set -o pipefail` is on, so
  # `bash suite | grep` returns the suite's non-zero exit even when grep matched,
  # which reports a biting assertion as non-biting. The exit status of interest
  # is the suite's, so it is kept separate from the text search.
  no_groups_out="$(bash "${SUITE}" 2>&1)"
  if grep -qF "no groups" <<<"${no_groups_out}"; then
    MUTATIONS_BITING=$((MUTATIONS_BITING + 1))
    printf '  bites  dependabot with no groups at all is reported, not silently accepted\n'
  else
    mismatches+=("no groups: the suite did not report an absent groups block")
  fi
else
  mismatches+=("no groups: could not apply the mutation")
fi
restore

restore
final_out="$(bash "${SUITE}" 2>&1)"
final_rc=$?
echo
if [[ ${final_rc} -ne 0 ]]; then
  mismatches+=("restoring the originals did not return the suite to green")
fi

printf 'mutations: %d run, %d bit, suite after restore: %s\n' \
  "${MUTATIONS_RUN}" "${MUTATIONS_BITING}" \
  "$(grep -E '^[0-9]+ passed' <<<"${final_out}" || echo 'no summary')"

if ((${#mismatches[@]} > 0)); then
  printf '\nNON-BITING MUTATIONS (%d):\n' "${#mismatches[@]}" >&2
  printf '  - %s\n' "${mismatches[@]}" >&2
  exit 1
fi
printf 'all %d mutations bit\n' "${MUTATIONS_RUN}"
