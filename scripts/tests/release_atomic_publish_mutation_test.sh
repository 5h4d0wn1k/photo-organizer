#!/usr/bin/env bash
#
# Mutation pass for the atomic-publication assertions in
# scripts/tests/release_workflow_test.sh.
#
# These assertions are the ones that stopped a live, public, non-draft release
# from shipping four platforms with no Android APK. A green run of them is worth
# very little on its own: every one of them is a substring or a shape check over
# a YAML file, which is exactly the kind of check that reads as proof while
# measuring nothing. So each is mutated here and has to be caught BY NAME.
#
# "The suite exited non-zero" is not a result; a specific assertion going red is.
# Two guards exist because both failure modes below were hit while writing the
# sibling harness:
#
#   * `preflight` rejects a mutation that leaves release.yml unparseable. Such a
#     mutation measures nothing and reads as a legitimate red.
#   * `needle_matches` requires the named assertion. A red suite with the wrong
#     assertion red is a false pass wearing a failure's clothes.
#
# `grep -c` rather than `grep -q` in `needle_matches`, deliberately: `grep -q`
# exits on its first match, SIGPIPEs the upstream `grep -v`, and under
# `set -o pipefail` that turns a successful match into a non-zero pipeline
# depending on whether the writer finished first. It is a race, and it made two
# mutations in the sibling harness report as non-biting when the assertion they
# targeted had in fact gone red.
set -uo pipefail

ROOT_DIR="${PO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SUITE="${ROOT_DIR}/scripts/tests/release_workflow_test.sh"
WORKFLOW="${ROOT_DIR}/.github/workflows/release.yml"

WORK="$(mktemp -d)"
trap 'restore; rm -rf "${WORK}"' EXIT

cp "${WORKFLOW}" "${WORK}/workflow.orig"
cp "${SUITE}" "${WORK}/suite.orig"

restore() {
  cp "${WORK}/workflow.orig" "${WORKFLOW}"
  cp "${WORK}/suite.orig" "${SUITE}"
}

# apply <file> <old> <new> -- replace exactly one occurrence, then read the file
# back and confirm it now says what was intended. Writing a file is not evidence
# that the file contains the intended text.
apply() {
  python3 - "$1" "$2" "$3" <<'PYTHON'
import sys

path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, encoding="utf-8") as handle:
    text = handle.read()
count = text.count(old)
if count != 1:
    print(
        f"ANCHOR IS NOT UNIQUE ({count} occurrences): {old[:90]!r}", file=sys.stderr
    )
    sys.exit(4 if count else 3)
with open(path, "w", encoding="utf-8") as handle:
    handle.write(text.replace(old, new, 1))
with open(path, encoding="utf-8") as handle:
    after = handle.read()
if new and new not in after:
    print("MUTATION DID NOT LAND: replacement text absent", file=sys.stderr)
    sys.exit(5)
if old and old in after and old not in new:
    print("MUTATION DID NOT LAND: original text still present", file=sys.stderr)
    sys.exit(6)
print(text[: text.index(old)].count("\n") + 1)
PYTHON
}

# preflight <file> -- refuse a mutation that leaves the file unparseable.
preflight() {
  local out
  case "$1" in
  *.yml | *.yaml)
    if ! out="$(python3 -c '
import sys
import yaml
yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
' "$1" 2>&1)"; then
      printf 'the workflow no longer parses: %s\n' "${out}" >&2
      return 1
    fi
    ;;
  *)
    if ! out="$(bash -n "$1" 2>&1)"; then
      printf 'the shell script no longer parses: %s\n' "${out}" >&2
      return 1
    fi
    ;;
  esac
  return 0
}

# Everything the suite said except its passing verdicts. A FAIL line is a symptom;
# the assertion's own detail line is the cause, and it is the more precise
# evidence.
needle_matches() {
  grep -vE '^[[:space:]]*ok ' <<<"$1" | grep -cF -- "$2" >/dev/null
}

# mutate <name> <old> <new> <needle> [target]
#
# `target` defaults to the workflow. Mutating the *suite* is legitimate and needed:
# some assertions are load-bearing for the suite's own correctness rather than for
# catching a workflow defect, and the only way to show those is to break them and
# watch a correct workflow start failing.
mutate() {
  local name="$1" old="$2" new="$3" needle="$4"
  local target="${5:-${WORKFLOW}}"
  MUTATIONS_RUN=$((MUTATIONS_RUN + 1))
  restore
  local line
  if ! line="$(apply "${target}" "${old}" "${new}" 2>&1)"; then
    mismatches+=("${name}: could not apply the mutation (${line})")
    restore
    return
  fi
  if ! preflight "${target}"; then
    mismatches+=("${name}: INVALID MUTATION -- it breaks the file under test, so a red suite would prove nothing")
    restore
    return
  fi
  local out rc
  out="$(PYTHONDONTWRITEBYTECODE=1 bash "${SUITE}" 2>&1)"
  rc=$?
  if [[ ${rc} -eq 0 ]]; then
    mismatches+=("${name}: SUITE STILL PASSED (the assertion does not bite)")
  elif ! needle_matches "${out}" "${needle}"; then
    mismatches+=("${name}: went red but not on '${needle}'")
    mismatches+=("        line ${line}; saw: $(grep -E '^[[:space:]]*FAIL ' <<<"${out}" | head -3 | tr '\n' ' ')")
  else
    MUTATIONS_BITING=$((MUTATIONS_BITING + 1))
    printf '  bites  %s\n' "${name}"
  fi
  restore
}

MUTATIONS_RUN=0
MUTATIONS_BITING=0
mismatches=()

echo "== one publisher, and it is the only one that can write =="

echo "== nothing reaches the release that was never downloaded =="

# The original defect: `linux` publishing itself again, with no `needs:` and no
# relation to the other platforms. This is the shape that produced a four-platform
# "stable" release with no APK.
mutate "a platform job publishes again, independently" \
  '          path: |
            photo-organizer-linux-x86_64-*.AppImage
            photo-organizer_*_amd64.deb' \
  '          path: |
            photo-organizer-linux-x86_64-*.AppImage
            photo-organizer_*_amd64.deb

      - name: Release Linux
        uses: softprops/action-gh-release@efb35369e0ad2afab669f228072c1b0d510eae64 # v3
        with:
          files: photo-organizer-linux-x86_64-*.AppImage
          append_body: true
          body: |
            Linux build.' \
  "exactly one job may publish"

# The token, not the publish step. A job that cannot publish but holds the token
# can still create a release the moment someone adds a step to it, so the
# assertion is about the permission, not about the current step list.
mutate "a build job that cannot publish holds contents: write" \
  '  macos:
    name: macOS (DMG)
    # Fail fast: a missing keystore must not cost five long platform builds.
    needs:
      - release-signing-preflight
    runs-on: macos-latest
    timeout-minutes: 150
    permissions:
      contents: read' \
  '  macos:
    name: macOS (DMG)
    # Fail fast: a missing keystore must not cost five long platform builds.
    needs:
      - release-signing-preflight
    runs-on: macos-latest
    timeout-minutes: 150
    permissions:
      contents: write' \
  "so it must not hold contents: write"

mutate "the workflow's default permission becomes contents: write" \
  'permissions:
  contents: read

concurrency:' \
  'permissions:
  contents: write

concurrency:' \
  "top-level default must stay contents: read"

# The carve-out, which is the one place a non-`contents` write survives. `id-token` and
# `attestations` are required by `actions/attest-build-provenance` and neither can
# publish. A reviewer applying least-privilege reflexively would delete them, and the
# only thing that would notice is these two mutations going green-by-deletion.
mutate "the Linux provenance attestation loses its id-token" \
  '    permissions:
      contents: read
      id-token: write
      attestations: write' \
  '    permissions:
      contents: read
      attestations: write' \
  "the \`linux\` attestation step needs id-token: write and attestations: write"

mutate "the Linux provenance attestation loses its attestations scope" \
  '    permissions:
      contents: read
      id-token: write
      attestations: write' \
  '    permissions:
      contents: read
      id-token: write' \
  "the \`linux\` attestation step needs id-token: write and attestations: write"

mutate "the Linux attestation step is silently replaced by a checkout, so a step named [Attest build provenance] attests nothing" \
  '      - name: Attest build provenance
        uses: actions/attest-build-provenance@4d101475d8b20a2381f78447822ac1eab6504dd8 # v4.2.2' \
  '      - name: Attest build provenance
        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7' \
  "the \`linux\` job is expected to attest its build provenance"

# Both `always()` guards previously compared the raw string to the literal
# "always()". GitHub also accepts `${{ always() }}` and any expression containing the
# call, so neither check could see the form its own documentation uses. Found by an
# independent review, which added `if: ${{ always() }}` and got 51 passed -- the exact
# escape the workflow comment claims is structurally closed.
# The job-level check is "no `if:` at all", because per GitHub's
# `jobs.<job_id>.needs` documentation ANY job-level conditional drops the implicit
# `success()`. The three mutations below are the three spellings that matter: the
# literal `always()`, the `${{ }}` form GitHub's own docs use, and `!cancelled()`
# -- which reads like the opposite of `always()` and which an independent review
# used to keep the suite fully green while re-opening the partial-release escape.
mutate "the publish job runs even when a dependency failed (job level, literal form)" \
  '  release:
    name: Publish release
    runs-on: ubuntu-latest' \
  '  release:
    name: Publish release
    runs-on: ubuntu-latest
    if: always()' \
  "must carry no job-level"

mutate "the publish job runs even when a dependency failed (job level, expression form)" \
  '  release:
    name: Publish release
    runs-on: ubuntu-latest' \
  '  release:
    name: Publish release
    runs-on: ubuntu-latest
    if: ${{ always() }}' \
  "must carry no job-level"

# The escape the review found: not `always()` at all, and still an override.
mutate "the publish job runs when a dependency failed via !cancelled(), which is not the string always()" \
  '  release:
    name: Publish release
    runs-on: ubuntu-latest' \
  '  release:
    name: Publish release
    runs-on: ubuntu-latest
    if: ${{ !cancelled() }}' \
  "must carry no job-level"

mutate "always() is hidden inside a compound condition" \
  '  release:
    name: Publish release
    runs-on: ubuntu-latest' \
  '  release:
    name: Publish release
    runs-on: ubuntu-latest
    if: "${{ success() || failure() }}"' \
  "must carry no job-level"

# Step-level is a different key on a different object, and it is the one that
# matters most here: the staging step refuses by exiting non-zero, so a publish
# step carrying `if: always()` runs anyway with a glob that matches nothing.
mutate "the publish step runs even when the staging step refused (step level)" \
  '      - name: Publish the release
        uses: softprops/action-gh-release' \
  '      - name: Publish the release
        if: ${{ always() }}
        uses: softprops/action-gh-release' \
  "on the publish step runs it even when the staging step refused"

# This one searched a blob built as "job: [needs]" for the token `needs:`, which that
# string can never contain -- so it could not fail. Adding a job that genuinely depends
# on `release` left the suite green.
mutate "a job depends on \`release\`, the terminal publisher" \
  '  release-signing-preflight:' \
  '  debug-consumer:
    runs-on: ubuntu-latest
    needs:
      - release
    steps:
      - run: "true"

  release-signing-preflight:' \
  "no job may need \`release\` itself"

# The release body's signing disclosure. An independent review replaced the whole
# `${{ ... }}` expression with the optimistic literal and got 51 passed, so an
# ephemeral-key release could have told users their next version installs cleanly over
# this one -- and that is the disclosure this PR exists to stop.
#
# The needle is the whole expression, not a key next to it. A first attempt at this
# mutation added a harmless `body_prefix_hardcoded: true` key and the suite correctly
# stayed green: the mutation did not remove anything the assertion protects, so "passed"
# was the right answer and the mutation was worthless. Found because the harness
# reports non-biting mutations loudly instead of counting them.
# The needle must cover the expression itself. Anchoring on `body: |` + the heading
# and appending a line does NOT remove the expression, so the suite correctly stayed
# green -- the mutation was worthless and the harness said so rather than counting it.
mutate "the release body drops the signing-mode expression and keeps the optimistic claim" \
  "$(python3 - <<'PYEXPR'
import pathlib
import re

text = pathlib.Path(".github/workflows/release.yml").read_text()
match = re.search(r"\$\{\{ needs\.release-signing-preflight\.outputs\.signing_mode[^\n]*\}\}", text)
print(match.group(0) if match else "NO-EXPRESSION-FOUND")
PYEXPR
)" \
  'THIS ARTIFACT IS SIGNED WITH THE PROJECT RELEASE KEY SO UPGRADES JUST WORK.' \
  "the release body must branch on the preflight's signing_mode"

mutate "the release body drops the ephemeral-key warning" \
  "This artifact is signed with an ephemeral per-run CI key, so it installs once but a future version will require uninstalling it first" \
  "Signed." \
  "the release body must describe the ephemeral-key outcome"

# Anchored on the job header, not on the step name: `outputs:` sits on the job and the
# step that computes the mode is named differently. An earlier version of this needle
# used the step name and matched zero times.
mutate "the preflight stops publishing signing_mode to the release body" \
  '    name: Android release signing preflight
    runs-on: ubuntu-latest
    timeout-minutes: 5
    permissions:
      contents: read
    outputs:
      signing_mode: ${{ steps.signing.outputs.mode }}' \
  '    name: Android release signing preflight
    runs-on: ubuntu-latest
    timeout-minutes: 5
    permissions:
      contents: read
    outputs:
      unrelated: ${{ steps.signing.outputs.mode }}' \
  "the preflight must expose signing_mode"

# An independent review found that consolidating publication silently dropped a release
# asset: on origin/main the Linux job attached `sbom.spdx.json`, and here the SBOM is
# generated but uploaded under a file list that omits it. No test mentioned the SBOM, so
# `docs/RELEASE_CHECKLIST.md` kept requiring an SBOM that no longer shipped. Both
# mutations below were confirmed to leave the suite at 52 passed before this block
# existed.
mutate "the SBOM is generated but no longer uploaded as a release asset" \
  '            photo-organizer_*_amd64.deb
            sbom.spdx.json' \
  '            photo-organizer_*_amd64.deb' \
  "the Linux artifact upload must include sbom.spdx.json"

mutate "the SBOM step is deleted entirely" \
  '      - name: Generate SBOM
        uses: anchore/sbom-action@3ad7283483fc7af8ff2b4ea19663c2d5ca935e26 # v0.24.2' \
  '      - name: Generate SBOM
        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7' \
  "job must still generate the SBOM it uploads"

# The preflight was described as failing "in seconds, not after two and a half hours of
# builds", but the platform jobs had no `needs:` at all, so the claim was false. The
# `needs:` was added to make it true; these two keep it true.
mutate "a long platform build stops waiting for the fast-fail preflight" \
  '  macos:
    name: macOS (DMG)
    # Fail fast: a missing keystore must not cost five long platform builds.
    needs:
      - release-signing-preflight' \
  '  macos:
    name: macOS (DMG)' \
  "job must need the signing preflight"

echo "== every upstream gates the publication =="

for upstream in release-signing-preflight linux windows macos ios android-verify; do
  mutate "\`release\` stops needing \`${upstream}\`" \
    "    needs:
      - release-signing-preflight
      - linux
      - windows
      - macos
      - ios
      - android-verify" \
    "$(python3 - "${upstream}" <<'PYTHON'
import sys

drop = sys.argv[1]
entries = [
    "release-signing-preflight",
    "linux",
    "windows",
    "macos",
    "ios",
    "android-verify",
]
remaining = [entry for entry in entries if entry != drop]
print("    needs:\n" + "\n".join(f"      - {entry}" for entry in remaining))
PYTHON
)" \
    "\`release\` must need \`${upstream}\`"
done

# `if: always()` is what #82 proposed and is the exact opposite of atomic
# publication: it runs the publish job even when a dependency failed.
mutate "the publish job runs even when a dependency failed" \
  '    needs:
      - release-signing-preflight
      - linux
      - windows
      - macos
      - ios
      - android-verify
    permissions:
      contents: write' \
  '    needs:
      - release-signing-preflight
      - linux
      - windows
      - macos
      - ios
      - android-verify
    if: always()
    permissions:
      contents: write' \
  "must carry no job-level"

# Reachability has to be transitive: `android` produces the APK but `release`
# names `android-verify`, so a direct-only walk would report the correct workflow
# as broken. The mutation below proves the walk is real by breaking it and
# watching a correct workflow go red -- the inverse shape from every other case
# here, and the reason it is called out separately.
mutate "reachability stops being transitive" \
  'release_reaches = reachable_from("release")' \
  'release_reaches = set(needs_of("release"))' \
  'does not depend on it (directly or transitively)' \
  "${SUITE}"

echo "== nothing reaches the release, and the checksum is not re-derived =="

mutate "the macOS artifact is never downloaded" \
  '      - name: Download macOS artifact
        uses: actions/download-artifact@fa0a91b85d4f404e444e00e005971372dc801d16 # v4
        with:
          name: macos-artifact
          path: incoming/macos

' \
  '' \
  'must download `macos-artifact`'

mutate "the Linux artifact is downloaded under a name no job uploads" \
  '          name: linux-artifacts
          path: incoming/linux' \
  '          name: linux-artifacts-final
          path: incoming/linux' \
  'downloads artifacts no job uploads'

# The staging step is what makes "complete or nothing" true at the byte level.
# Inverting its guard is the interesting mutation: a complete set is then refused
# and an incomplete one sails through to publish whatever arrived.
#
# The anchor is the one-line condition rather than the whole block, because the
# block contains a `printf '  %s\n'` whose literal backslash-n has to be carried
# through the shell quoting intact, and getting that wrong produces a mutation
# that quietly fails to apply.
mutate "the partial-release refusal is inverted" \
  '          if [[ "${#missing[@]}" -ne 0 ]]; then' \
  '          if [[ "${#missing[@]}" -eq 0 ]]; then' \
  "a missing platform directory refuses the release"

mutate "the staging step counts zero-byte files as produced" \
  '            count="$(find "${dir}" -type f -size +0c | wc -l)"' \
  '            count="$(find "${dir}" -type f | wc -l)"' \
  "a platform whose only file is empty refuses the release"

# This is the one that matters for the string-presence assertions. Replacing the
# guard with `if false` leaves the message, the comment and the `exit 1` all in
# place -- a suite that greps for them reports a guard that does not exist. Only
# executing the step catches it.
mutate "the basename-collision guard is present but dead" \
  '              if [[ -e "dist/${base}" ]]; then' \
  '              if false; then' \
  "two artifacts sharing a basename refuse the release"

echo "== what is published is what was verified =="

mutate "the publish step attaches a different tree than the staged one" \
  '          files: dist/*' \
  '          files: incoming/*/*' \
  "must attach exactly the staged directory and nothing else"

mutate "a platform's signing status is dropped from the release body" \
  '            * **macOS** — unsigned. No notarization.' \
  '            * **macOS** — see the notes above.' \
  "must state macOS's signing status"

mutate "the Android verify job stops re-checking the checksum" \
  '          ( cd apk && sha256sum -c app-release.apk.sha256 )' \
  '          ( cd apk && sha256sum app-release.apk.sha256 )' \
  "re-verifies the checksum"

mutate "the Android re-verification step is renamed so it is not found" \
  '      - name: Re-verify the artifact about to be published' \
  '      - name: Look at the artifact again' \
  "the publish job has a re-verification step"

echo "== the preflight cannot be bypassed =="

# If the preflight stops asserting the resolved mode, an unexpected value passes.
mutate "the preflight accepts any signing mode" \
  '            *)
              echo "::error::android_release_signing.sh returned an unexpected mode: '"'"'${mode}'"'"'" >&2
              exit 1
              ;;' \
  '            *)
              ;;' \
  "the preflight must exit non-zero on an unexpected signing mode"

# ...and it has to be the shared policy script, not a local re-implementation,
# or the workflow and the local readiness check can drift apart silently.
# `continue-on-error: true` on the staging step is the one-key version of the
# v0.1.7 failure: the refusal exits 1, GitHub marks the step failed-but-continued,
# the job succeeds, `dist` was never created (the `rm -rf dist` follows the
# refusal), and `dist/*` matches nothing. An independent review added this key and
# the suite stayed fully green.
mutate "the staging step swallows its own refusal with continue-on-error" \
  '      - name: Stage every platform artifact, refusing an incomplete set
        run: |' \
  '      - name: Stage every platform artifact, refusing an incomplete set
        continue-on-error: true
        run: |' \
  "no step in \`release\` may set \`continue-on-error\`"

# The action's default creates a release with zero assets when the glob matches
# nothing, which is a live public release missing every platform.
mutate "the publish step loses fail_on_unmatched_files and can create an empty release" \
  '          fail_on_unmatched_files: true
' \
  '' \
  "must set \`fail_on_unmatched_files: true\`"

# A second publish step *inside* `release`. Every publish property was asserted
# with `any(...)`/join over whichever steps a job happened to have, and
# `publishers` is a set of job NAMES, so a second publish call in the single
# publishing job was invisible: the name was still `release`, the real step still
# set `fail_on_unmatched_files`, and the join still contained `dist/*`. An
# independent review inserted this and the suite stayed green. The pinned action
# drafts the release, uploads, then flips `draft: false`, so the sneaker leaves a
# live Latest release carrying only what it named -- with every staging refusal
# running afterwards, too late. That is the v0.1.7 incident inside the job built
# to prevent it.
mutate "a second publish step is added inside \`release\`, before staging" \
  '      - name: Stage every platform artifact, refusing an incomplete set' \
  '      - name: Sneak publish before staging
        uses: softprops/action-gh-release@efb35369e0ad2afab669f228072c1b0d510eae64 # v3
        with:
          files: incoming/android/*
      - name: Stage every platform artifact, refusing an incomplete set' \
  "exactly one publish step may exist anywhere in the workflow"

# Same shape, but placed after the real publish step, so only the ordering
# assertion can catch it: the count is 2 and the last step is not a publish step,
# but `fail_on_unmatched_files` and `dist/*` are both still present on the real
# step. Without a position assertion this ordering defect would survive.
mutate "a publish step is appended after the real one, so something runs post-publish" \
  '          fail_on_unmatched_files: true' \
  '          fail_on_unmatched_files: true

      - name: Late publish after the release is live
        uses: softprops/action-gh-release@efb35369e0ad2afab669f228072c1b0d510eae64 # v3
        with:
          files: incoming/macos/*' \
  "must be the last step of \`release\`"

# The real step keeps `fail_on_unmatched_files`, and the join over all publish
# steps still contains `dist/*` -- but the step now also attaches an unvetted
# glob, which is what actually gets uploaded. Containment cannot see this.
mutate "the publish step attaches an extra unvetted glob alongside the staged tree" \
  '          files: dist/*' \
  '          files: dist/*
            incoming/*' \
  "must attach exactly the staged directory and nothing else"

# The `platforms=(...)` array is what decides the published asset set. An
# independent review built a composite `freebsd` job -- created, added to `needs`,
# artifact uploaded, artifact downloaded into `incoming/freebsd` -- and the suite
# stayed at 52 passed, because the download landed in a directory the staging loop
# never visits. The artifact was fetched, verified, and attached to nothing.
mutate "the staging array drops a platform that every other check still knows about" \
  'platforms=(android linux windows macos ios)' \
  'platforms=(android linux windows macos)' \
  "must be exactly the set of directories the download-artifact steps write into"

# A second writer does not have to use the action.
mutate "a second job publishes through the gh CLI instead of the release action" \
  '  release-signing-preflight:' \
  '  sneaky-publish:
    name: Sneaky publish
    runs-on: ubuntu-latest
    permissions:
      contents: read
    steps:
      - name: Sneak
        run: gh release create "${GITHUB_REF_NAME}" --repo "${GITHUB_REPOSITORY}"

  release-signing-preflight:' \
  "exactly one job may publish"

# A download path rename is the same defect spelled differently: the artifact is
# fetched into a directory the staging loop never reads.
mutate "the ios artifact is downloaded into a directory the staging loop never visits" \
  '          path: incoming/ios' \
  '          path: incoming/ios-app' \
  "must be exactly the set of directories the download-artifact steps write into"

mutate "the preflight stops using the shared signing policy script" \
  '          mode="$(bash scripts/android_release_signing.sh mode | tail -n 1)"' \
  '          mode="release"' \
  "the preflight must resolve signing through the shared policy script"

restore
final_out="$(PYTHONDONTWRITEBYTECODE=1 bash "${SUITE}" 2>&1)"
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
  printf '\nNON-BITING / WRONG-RED / INVALID MUTATIONS (%d):\n' "${#mismatches[@]}" >&2
  printf '  - %s\n' "${mismatches[@]}" >&2
  exit 1
fi
printf 'all %d mutations bit\n' "${MUTATIONS_RUN}"