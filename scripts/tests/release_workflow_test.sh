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
  python3 -m pip install --quiet pyyaml >/dev/null 2>&1 || true
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
if grep -q 'apksigner_gate_test.sh' "${ROOT_DIR}/scripts/tests/run_release_gate_tests.sh"; then
  ok "the runner includes apksigner_gate_test.sh, so the signature gate is covered"
else
  bad "the runner includes apksigner_gate_test.sh, so the signature gate is covered"
fi

echo " the emulator-runner script stays a single line in the committed script too"
# The committed script is invoked as `bash <file>`, so multi-line control flow is
# safe there. The only thing that must not leak back into the workflow is a
# multi-line inline `script:`.
if grep -q 'script: |' "${WORKFLOW}"; then
  bad 'no multi-line inline emulator script: block may reappear'
else
  ok 'no multi-line inline emulator script: block may reappear'
fi

printf '\n%s passed, %s failed\n' "${PASS_COUNT}" "${FAIL_COUNT}"
if ((FAIL_COUNT > 0)); then
  exit 1
fi
