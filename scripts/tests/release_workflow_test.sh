#!/usr/bin/env bash
#
# Structural regression tests for .github/workflows/release.yml.
#
# The "no un-installable APK ever ships" guarantee in issue #97 is a property of
# the workflow's *shape*, not of any single step. Shape is easy to break by
# accident during an unrelated edit (re-adding a release step, dropping a `needs`,
# flipping a permission), and a broken guarantee here is invisible until a user
# cannot install the app. These assertions make it fail loudly in CI instead.
#
# Everything here is checked against the parsed workflow, not against grep
# patterns, so reformatting or reordering steps cannot silently pass.

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORKFLOW="${ROOT_DIR}/.github/workflows/release.yml"
GRADLE_FILE="${ROOT_DIR}/app/android/app/build.gradle.kts"
SIGNING_SCRIPT="${ROOT_DIR}/scripts/android_release_signing.sh"
SMOKE_SCRIPT="${ROOT_DIR}/scripts/android_release_artifact_smoke.sh"
SIGNATURE_SCRIPT="${ROOT_DIR}/scripts/android_release_verify_signature.sh"
WORK_DIR="$(mktemp -d)"
PASS_COUNT=0
FAIL_COUNT=0

cleanup() {
  rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

ok() {
  PASS_COUNT=$((PASS_COUNT + 1))
  printf '  ok   %s\n' "$1"
}

bad() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  printf '  FAIL %s\n' "$1" >&2
  if [[ -n "${2:-}" ]]; then
    printf '%s\n' "$2" | sed 's/^/        /' >&2
  fi
}

if ! python3 -c "import yaml" >/dev/null 2>&1; then
  # Pinned so a future PyYAML release cannot change the assertions' behaviour,
  # and best-effort: the next check fails loudly if it did not work.
  python3 -m pip install --quiet "pyyaml==6.0.2" >/dev/null 2>&1 || true
fi
if ! python3 -c "import yaml" >/dev/null 2>&1; then
  echo "PyYAML is required to run these tests" >&2
  exit 1
fi

# Run the python assertion block; every failure it reports becomes one FAIL line.
check() {
  local name="$1"
  # Quoted heredoc: the assertions below contain GitHub Actions expressions like
  # ${{ github.workspace }}, which the shell would otherwise try to expand.
  if python3 - "${WORKFLOW}" "${GRADLE_FILE}" "${ROOT_DIR}" <<'PY' >"${WORK_DIR}/out" 2>&1
import re
import sys
from pathlib import Path

import yaml

workflow_path, gradle_path = sys.argv[1], sys.argv[2]
ROOT_DIR = Path(sys.argv[3])
with open(workflow_path, encoding="utf-8") as handle:
    workflow = yaml.safe_load(handle)
with open(gradle_path, encoding="utf-8") as handle:
    gradle = handle.read()

jobs = workflow["jobs"]

def steps_of(job):
    return jobs[job].get("steps", []) or []

def uses_of(job):
    return [str(step.get("uses", "")) for step in steps_of(job)]

def runs_of(job):
    return "\n".join(str(step.get("run", "")) for step in steps_of(job))

def needs_of(job):
    # YAML allows `needs: android` (scalar) as well as a list; normalise both.
    raw = jobs[job].get("needs") or []
    if isinstance(raw, str):
        return [raw]
    return list(raw)

def is_publish_step(step):
    return "action-gh-release" in str(step.get("uses", ""))

publishers = {
    job for job, spec in jobs.items() if any(is_publish_step(s) for s in spec.get("steps", []) or [])
}

failures = []

def expect(condition, message):
    if not condition:
        failures.append(message)

# --- the core #97 guarantee -------------------------------------------------
expect("android" not in publishers, "the `android` build job must not publish; `android-publish` owns publication")
expect(
    sorted(needs_of("android-publish")) == ["android", "android-smoke"],
    "`android-publish` must need both `android` and `android-smoke`",
)
expect(
    sorted(needs_of("android-smoke")) == ["android"],
    "`android-smoke` must need `android`",
)
expect(
    jobs["android-smoke"]["strategy"]["fail-fast"] is False,
    "`android-smoke` must set fail-fast: false so a failing API level still reports the other",
)
expect(
    sorted(jobs["android-smoke"]["strategy"]["matrix"]["api-level"]) == [30, 35],
    "the smoke matrix must cover API 30 (legacy) and API 35 (modern, near targetSdk 36)",
)

# --- least privilege --------------------------------------------------------
expect(
    jobs["android"]["permissions"] == {"contents": "read"},
    "the `android` build job must not hold contents: write",
)
for job in publishers:
    expect(
        jobs[job].get("permissions", {}).get("contents") == "write",
        f"the publishing job `{job}` needs contents: write",
    )

# --- supply chain: every action pinned to a full commit SHA -----------------
for job, spec in jobs.items():
    for step in spec.get("steps", []) or []:
        ref = str(step.get("uses", ""))
        if not ref or ref.startswith("./") or ref.startswith("docker://"):
            continue
        pinned = ref.rsplit("@", 1)[-1]
        expect(
            len(pinned) == 40 and all(c in "0123456789abcdef" for c in pinned),
            f"`{job}` step `{step.get('name', ref)}` must pin a full 40-char commit SHA, got: {ref}",
        )

# --- the emulator action's execution model ---------------------------------
# reactivecircus/android-emulator-runner splits `script` on newlines and runs
# each line as an independent `sh -c`. Any multi-line script silently destroys
# control flow and cannot use `set -o pipefail` (dash has no pipefail).
smoke_steps = [s for s in steps_of("android-smoke") if "android-emulator-runner" in str(s.get("uses", ""))]
expect(len(smoke_steps) == 1, "expected exactly one android-emulator-runner step")
if smoke_steps:
    script = str(smoke_steps[0].get("with", {}).get("script", ""))
    expect(
        len([line for line in script.splitlines() if line.strip()]) == 1,
        f"the emulator-runner `script` must be a SINGLE line, got {len(script.splitlines())} lines",
    )
    expect("android_release_artifact_smoke.sh" in script, "the single line must delegate to the committed smoke script")
    expect(
        smoke_steps[0].get("with", {}).get("target") == "google_apis",
        "the emulator must use google_apis (the app ships mobile_scanner, which needs Play services)",
    )
    expect(
        smoke_steps[0].get("with", {}).get("working-directory") == "${{ github.workspace }}",
        "the emulator step must pin working-directory so the committed script is found",
    )

# --- signing is not optional, and is not faked ------------------------------
expect("android_release_signing.sh materialize" in runs_of("android"),
       "the android job must resolve signing through scripts/android_release_signing.sh")
expect("keytool -genkeypair" not in runs_of("android"),
       "the android job must not inline its own throwaway key generation; the policy script owns that decision")
expect("secrets.ANDROID_KEYSTORE" not in runs_of("android"),
       "the android job must not reference signing secrets directly in a run block")
expect("generate_release_notes" not in runs_of("android"),
       "generated release notes are owned by a single job to avoid duplicating the changelog")
verify_steps = [s for s in steps_of("android") if "android_release_verify_signature.sh" in str(s.get("run", ""))]
expect(len(verify_steps) == 1,
       "the android job must run exactly one signature gate, via scripts/android_release_verify_signature.sh")
if verify_steps:
    verify_run = str(verify_steps[0].get("run", ""))
    # The scheme assertions themselves live in the gate script, where they can be
    # tested against real APKs. Assert both halves: the workflow must delegate to
    # the tested script, and that script must still assert the schemes.
    gate = ROOT_DIR / "scripts" / "android_release_verify_signature.sh"
    expect(gate.is_file(),
           "scripts/android_release_verify_signature.sh must exist; the workflow delegates to it")
    if gate.is_file():
        gate_src = gate.read_text()
        for scheme in ("v2 scheme", "v3 scheme"):
            expect(scheme in gate_src,
                   f"the signature gate must assert the {scheme} signature explicitly")
        expect("app-release.apk.sha256" in verify_run,
               "the signature gate must still publish the checksum next to the APK")
    # No inline apksigner logic: that is exactly how the guarantee gets weakened
    # without anyone noticing.
    expect(not re.search(r"apksigner\s+verify", verify_run),
           "the workflow must not re-inline apksigner logic; the tested gate script owns it")

# --- release body integrity across platforms --------------------------------
# Every platform publishes into the same release. Without append_body, the last
# job to finish silently deletes every other platform's signing warning.
for job in publishers:
    for step in steps_of(job):
        if not is_publish_step(step):
            continue
        params = step.get("with", {}) or {}
        expect(
            params.get("append_body") is True,
            f"`{job}` publish step must set append_body: true or it will clobber other platforms' notes",
        )
notes_owners = [
    job
    for job in publishers
    for step in steps_of(job)
    if is_publish_step(step) and (step.get("with", {}) or {}).get("generate_release_notes")
]
expect(
    len(notes_owners) == 1,
    f"exactly one job may set generate_release_notes (found {len(notes_owners)}: {notes_owners})",
)

# --- the Gradle signing config ---------------------------------------------
for token in ("ANDROID_KEYSTORE_FILE", "ANDROID_KEYSTORE_PASSWORD", "ANDROID_KEY_ALIAS", "ANDROID_KEY_PASSWORD"):
    expect(token in gradle, f"build.gradle.kts must resolve {token} from the environment")
expect("enableV1Signing = flutter.minSdkVersion < 24" in gradle,
       "v1 signing must be conditional on minSdk, not unconditionally enabled (minSdk is 24)")
expect("enableV2Signing = true" in gradle, "v2 signing must be enabled")
expect("enableV3Signing = true" in gradle, "v3 signing must be enabled")
expect("only partially configured" in gradle,
       "build.gradle.kts must reject a half-configured keystore instead of silently dropping it")
expect("signingConfigs.getByName(\"debug\")" not in gradle,
       "the release build must never use the debug signing config")

for message in failures:
    print(message)
sys.exit(1 if failures else 0)
PY
  then
    ok "${name}"
  else
    bad "${name}" "$(cat "${WORK_DIR}/out")"
  fi
}

echo "release workflow + Gradle signing structure"

check "the workflow parses and every structural guarantee holds"

echo " committed gate scripts"
for script in "${SIGNING_SCRIPT}" "${SMOKE_SCRIPT}" "${SIGNATURE_SCRIPT}"; do
  if bash -n "${script}" 2>/dev/null; then
    ok "$(basename "${script}") is valid bash"
  else
    bad "$(basename "${script}") is valid bash"
  fi
  if [[ -x "${script}" ]]; then
    ok "$(basename "${script}") is executable"
  else
    bad "$(basename "${script}") is executable"
  fi
done

echo " the gate scripts that decide what ships are actually tested"
for suite in android_release_signing_test.sh apksigner_gate_test.sh android_release_artifact_smoke_test.sh; do
  if [[ -f "${ROOT_DIR}/scripts/tests/${suite}" ]]; then
    ok "${suite} exists"
  else
    bad "${suite} exists"
  fi
done

# The runner is what CI actually executes, so its suite list is parsed rather than
# grepped. A text grep cannot tell an active entry from a commented-out one, so
# commenting a suite out used to leave this test green.
runner="${ROOT_DIR}/scripts/tests/run_release_gate_tests.sh"
if [[ -f "${runner}" ]]; then
  ok "run_release_gate_tests.sh exists"
  runner_suites="$(sed -n '/^SUITES=(/,/^)/p' "${runner}" |
    sed 's/#.*//' | grep -oE '[A-Za-z0-9_]+_test\.sh' | sort -u)"
  for suite in android_release_signing_test.sh apksigner_gate_test.sh android_release_artifact_smoke_test.sh; do
    if printf '%s\n' "${runner_suites}" | grep -qx "${suite}"; then
      ok "the runner actively lists ${suite} (not just mentions it)"
    else
      bad "the runner actively lists ${suite} (not just mentions it)" \
        "parsed suite list: $(printf '%s' "${runner_suites}" | tr '\n' ' ')"
    fi
  done

  # And the runner must actually fail when a suite fails. Neutering its failure
  # handling used to go unnoticed, because nothing exercised it.
  probe_root="$(mktemp -d)"
  mkdir -p "${probe_root}/tests"
  printf '#!/usr/bin/env bash\necho "boom"\nexit 1\n' >"${probe_root}/tests/deliberately_failing_test.sh"
  chmod +x "${probe_root}/tests/deliberately_failing_test.sh"
  # The runner must actually fail when a suite fails, or CI reports a red suite
  # as a green build.
  #
  # This runs the REAL runner rather than a reimplementation of it. A hand-rolled
  # mini-runner would only prove that the pattern works in general, which says
  # nothing about the committed file. The copy differs from the real runner in
  # exactly one way: its SUITES list is narrowed to the probe suite, so the
  # assertion is not masked by the other three. Every line that decides the exit
  # status is the committed code, verbatim.
  probe_root="$(mktemp -d)"
  mkdir -p "${probe_root}/scripts/tests"
  cp "${runner}" "${probe_root}/scripts/tests/run_release_gate_tests.sh"
  if python3 - "${probe_root}/scripts/tests/run_release_gate_tests.sh" <<'PYTHON'
import re
import sys

path = sys.argv[1]
with open(path) as handle:
    source = handle.read()
narrowed, count = re.subn(
    r"SUITES=\(\n(?:  \S+\n)+\)",
    "SUITES=(\n  probe_suite_test.sh\n)",
    source,
)
if count != 1:
    sys.exit("could not narrow the SUITES list; the runner's shape changed")
with open(path, "w") as handle:
    handle.write(narrowed)
PYTHON
  then
    probe_runner="${probe_root}/scripts/tests/run_release_gate_tests.sh"
    printf '#!/usr/bin/env bash\nprintf "%%s failed, 0 passed\n" probe\nexit 1\n' \
      >"${probe_root}/scripts/tests/probe_suite_test.sh"
    chmod +x "${probe_root}/scripts/tests/probe_suite_test.sh"
    if bash "${probe_runner}" >/dev/null 2>&1; then
      bad "the committed runner propagates a suite failure as a non-zero exit" \
        "the real runner exited 0 despite a failing suite"
    else
      ok "the committed runner propagates a suite failure as a non-zero exit"
    fi

    # The DEGRADED path must do the same. A suite that could not run its
    # assertions still exits 0, and reporting that as a plain PASS would let a
    # real coverage gap hide behind a green build.
    printf '#!/usr/bin/env bash\nprintf "RELEASE_GATE_SUITE_DEGRADED: no Android SDK\n0 passed, 0 failed\n"\n' \
      >"${probe_root}/scripts/tests/probe_suite_test.sh"
    if bash "${probe_runner}" >/dev/null 2>&1; then
      bad "the committed runner exits non-zero when a suite reports itself degraded" \
        "a skipped suite was reported as a clean pass"
    else
      ok "the committed runner exits non-zero when a suite reports itself degraded"
    fi

    # Both assertions above are only meaningful if the harness can also go green.
    #
    # The green case deliberately mentions the word in prose, because a suite that
    # merely *talks about* being degraded has not degraded. Detecting the marker by
    # grepping the log for the bare word would call this a skip, fail the entire
    # run, and so train people to ignore a real degraded report. This is a bug that
    # actually occurred here: an assertion whose name read "... when a suite is
    # DEGRADED" made a fully passing run report itself as degraded.
    printf '#!/usr/bin/env bash\nprintf "1 passed, 0 failed\\nok   a suite that merely mentions DEGRADED in prose is not degraded\\n"\nexit 0\n' \
      >"${probe_root}/scripts/tests/probe_suite_test.sh"
    if bash "${probe_runner}" >/dev/null 2>&1; then
      ok "the same runner copy exits 0 for a clean suite (assertions are not vacuous)"
    else
      bad "the same runner copy exits 0 for a clean suite (assertions are not vacuous)" \
        "the probe harness fails on its own"
    fi
  else
    bad "the runner's SUITES list can be narrowed for probing" \
      "the probe could not rewrite the SUITES list; the assertions above did not run"
  fi
  rm -rf "${probe_root}"
else
  bad "run_release_gate_tests.sh exists" "${runner} not found"
fi

echo " the signing key cannot be committed by accident"
# The release runbook tells the maintainer to create release.jks in the working
# directory. If git does not ignore it, a routine `git add .` publishes the
# signing key to a public repository -- irreversibly, since it stays in history
# after deletion, and it destroys the artifact's upgrade path. Verified with
# `git check-ignore` rather than by grepping the ignore file, so a rule that
# exists but does not actually work still fails here.
for name in release.jks upload.keystore keystore.p12 server.pem; do
  if (cd "${ROOT_DIR}" && git check-ignore -q "${name}"); then
    ok "${name} is ignored at the repository root"
  else
    bad "${name} is ignored at the repository root" "git would track ${name}; 'git add .' would commit the signing key"
  fi
done
if (cd "${ROOT_DIR}" && git ls-files --error-unmatch release.jks >/dev/null 2>&1); then
  bad 'no keystore is tracked in git' 'a keystore is tracked; see git ls-files'
else
  ok 'no keystore is tracked in git'
fi

echo " the Android artifact reaches the smoke gate and the release at the path they look for"
# This is a real bug that shipped in review: the upload listed three separate
# paths, and actions/upload-artifact documents that with multiple paths "the least
# common ancestor of all the search paths will be used as the root directory of
# the artifact". The LCA of a deep build path and two filenames at the workspace
# root is the workspace root, so the APK was archived as
# `apk/app/build/app/outputs/flutter-apk/app-release.apk` while both consumers
# read `apk/app-release.apk`. Every release would have failed on a missing file.
#
# The structural property that prevents a recurrence: exactly one file is
# uploaded, and it is a directory, so the artifact root is unambiguous. A
# multi-path list is rejected outright rather than reasoned about, because the
# resulting layout depends on the action's undocumented-for-our-case hierarchy
# rules.
upload_path="$(python3 - "${WORKFLOW}" <<'PYTHON'
import sys
import yaml

with open(sys.argv[1]) as handle:
    workflow = yaml.safe_load(handle)
paths = []
for job in workflow["jobs"].values():
    for step in job.get("steps", []) or []:
        if not isinstance(step, dict):
            continue
        if "upload-artifact" not in str(step.get("uses", "")):
            continue
        # Match the artifact by its exact name. A substring test for "android" also
        # matches `android-smoke-evidence`, which is a different artifact with a
        # different layout, so asserting against that one would prove nothing.
        if str(step.get("with", {}).get("name", "")) != "android-artifact":
            continue
        raw = step["with"].get("path", "")
        paths = [p.strip() for p in str(raw).splitlines() if p.strip()]
if len(paths) == 1:
    print(paths[0])
PYTHON
)"
if [[ -z "${upload_path}" ]]; then
  bad "the Android artifact is uploaded as a single path" \
    "no android-artifact upload step, or it lists several paths (see the LCA note in the workflow)"
else
  # A single path that is a directory makes the artifact root that directory, so
  # the layout is exactly what the staging step produced. A single *file* would
  # work too, but a directory is what we stage, and the two are not equivalent if
  # the staged set ever grows.
  if [[ -d "${ROOT_DIR}/${upload_path}" ]] || grep -qE "^[[:space:]]*mkdir -p ${upload_path}\$" "${WORKFLOW}"; then
    ok "the Android artifact is uploaded as a directory, so its root is unambiguous (${upload_path})"
  else
    bad "the Android artifact is uploaded as a directory, so its root is unambiguous" \
      "'${upload_path}' is neither a tracked directory nor a directory the staging step creates"
  fi
fi

# The staging step must copy every file the consumers reference, so the artifact
# cannot silently lose its checksum or its signature evidence. Matched on the
# *destination* of each "source:destination" pair rather than on a whole line, so
# the assertion does not depend on which entry happens to be last in the list (the
# last one carries no line-continuation backslash) or on how it is indented.
for required in app-release.apk app-release.apk.sha256 apksigner-verify.txt; do
  # Assign from a command substitution, not a `while read` loop over a process
  # substitution: the loop would run in a subshell and the variable it set would be
  # lost, silently reporting every name as unstaged.
  staged_destination=no
  staged_pairs="$(grep -oE '"[^"]+:[^"]+"' "${WORKFLOW}" 2>/dev/null || true)"
  for pair in ${staged_pairs}; do
    # Strip the surrounding quotes grep kept: the match is a quoted YAML/shell
    # token, so "${pair##*:}" alone would end in a literal `"` and never equal the
    # bare filename.
    destination="${pair##*:}"
    destination="${destination%\"}"
    destination="${destination#\"}"
    if [[ "${destination}" == "${required}" ]]; then
      staged_destination=yes
      break
    fi
  done
  if [[ "${staged_destination}" == "yes" ]]; then
    ok "the staging step copies ${required} into the uploaded directory"
  else
    bad "the staging step copies ${required} into the uploaded directory" \
      "not staged; it would be missing from the artifact"
  fi
done

# ...and the consumers must all look for the APK at the artifact root.
if grep -qF 'apk/app-release.apk' "${WORKFLOW}"; then
  ok "the smoke gate and the publish step read the APK from the artifact root"
else
  bad "the smoke gate and the publish step read the APK from the artifact root" \
    "nothing references apk/app-release.apk; the consumers and the upload disagree"
fi

echo " the emulator-runner script stays a single line in the committed script too"
# The committed script is invoked as `bash <file>`, so multi-line control flow is
# safe there. The only thing that must not leak back into the workflow is a
# multi-line inline `script:`.
# A folded block scalar (">") is just as multi-line as a literal ("|") and breaks
# the emulator-runner action identically, so match both.
if grep -qE '^[[:space:]]*script:[[:space:]]*[>|]' "${WORKFLOW}"; then
  bad 'no multi-line inline emulator script: block may reappear'
else
  ok 'no multi-line inline emulator script: block may reappear'
fi

printf '\n%s passed, %s failed\n' "${PASS_COUNT}" "${FAIL_COUNT}"
if ((FAIL_COUNT > 0)); then
  exit 1
fi
