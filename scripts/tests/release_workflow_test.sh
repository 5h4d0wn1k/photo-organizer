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

# PyYAML is a declared, hash-pinned test dependency (scripts/requirements-test.txt).
# This suite does NOT install it -- see workflow_hygiene_test.sh for why, and
# issue #136. `actions/setup-python` puts the pinned interpreter first on PATH.
if ! python3 -c "import yaml" >/dev/null 2>&1; then
  echo "PyYAML is required to run these tests." >&2
  echo "Install the hash-pinned test dependencies with: make deps" >&2
  echo "That needs CPython 3.8-3.13 on a FRESH environment: PyYAML 6.0.2 publishes" >&2
  echo "no 3.14 wheel and the install is --only-binary, so it refuses rather than" >&2
  echo "compiling the sdist. If PyYAML is already installed pip short-circuits and" >&2
  echo "neither flag is exercised -- use a new venv to check." >&2
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

# ...and pinned to the *same* SHA every other workflow uses, which is a
# different and much stronger property than the shape check above.
#
# release.yml is where this went wrong. Two of its checkout pins read
# `actions/checkout@3d3d42e5...` against `3d3c42e5...` everywhere else: one
# character apart, both valid 40-hex strings, so the shape check passed and so
# did every mutation harness in the repository. The `android` job owns one of
# them, declares no `needs:`, and therefore runs on every `v*` tag -- where it
# could not resolve its own checkout and failed before executing a step. The
# entire Android release path, blocking install+launch gate included, was dead
# on a real tag and nothing here could see it. Since this file is the suite
# that owns the release path, the release path gets its own copy of the check
# rather than relying on the repo-wide one in workflow_hygiene_test.sh.
#
# Scanned textually and across files on purpose: the claim is about every
# `uses:` line in the repository agreeing, which is a fact about the files
# rather than about this workflow's parsed step graph.
import glob as _glob

_repo_refs: dict[str, dict[str, list[str]]] = {}
for _path in sorted(_glob.glob(str(ROOT_DIR / ".github/workflows/*.yml"))):
    _name = Path(_path).name
    for _ref in re.findall(r"uses:\s*(\S+)", Path(_path).read_text(encoding="utf-8")):
        if _ref.startswith("./") or _ref.startswith("docker://") or "@" not in _ref:
            continue
        _repo, _, _sha = _ref.partition("@")
        if re.fullmatch(r"[0-9a-f]{40}", _sha):
            _repo_refs.setdefault(_repo, {}).setdefault(_sha, []).append(_name)

for _repo, _by_sha in sorted(_repo_refs.items()):
    expect(
        len(_by_sha) == 1,
        f"every workflow must pin `{_repo}` to one reviewed SHA, found {len(_by_sha)}: "
        + "; ".join(f"{s} in {', '.join(sorted(set(v)))}" for s, v in sorted(_by_sha.items())),
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
# Signing resolution must run BEFORE the NDK cross-compile. The signing script's
# stated purpose is to "fail fast ... instead of letting Gradle report an opaque
# keystore error after a long NDK cross-compile" -- and a tag cut before the four
# secrets exist must fail in seconds, not after burning the three-target cargo-ndk
# release build. Order is load-bearing here, so it is asserted, not assumed.
android_steps = steps_of("android")
signing_index = next((i for i, s in enumerate(android_steps)
                      if "android_release_signing.sh materialize" in str(s.get("run", ""))), None)
ndk_index = next((i for i, s in enumerate(android_steps)
                  if "cargo ndk" in str(s.get("run", ""))), None)
expect(signing_index is not None and ndk_index is not None and signing_index < ndk_index,
       "signing material must resolve before the NDK cross-compile, so a missing secret fails fast")
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
# An unsigned release build must be an explicit, recorded decision, not the
# default when the properties file is missing. Without this a developer who
# builds before populating private-gallery-release.properties gets a green build
# and an uninstallable APK -- the #97 symptom, reproduced locally.
expect("allowUnsignedRelease" in gradle,
       "build.gradle.kts must require an explicit opt-out for unsigned release builds")
expect("signingConfig = if (hasReleaseSigning)" in gradle,
       "the release build type must select its signing config from hasReleaseSigning")

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

# The runner is what CI actually executes -- and CI must actually execute the
# runner. Deleting the entire `release-gate` job from ci.yml used to leave every
# assertion here green, because this file asserted the runner's contents but
# nothing bound the runner to CI. Found by mutation.
ci_gate="$(python3 - "${ROOT_DIR}/.github/workflows/ci.yml" <<'PYTHON'
import sys

import yaml

with open(sys.argv[1], encoding="utf-8") as handle:
    ci = yaml.safe_load(handle)

found = False
for job in (ci.get("jobs") or {}).values():
    for step in job.get("steps", []) or []:
        if not isinstance(step, dict):
            continue
        if "scripts/tests/run_release_gate_tests.sh" in str(step.get("run", "")):
            found = True
print("yes" if found else "no")
PYTHON
)"
if [[ "${ci_gate}" == "yes" ]]; then
  ok "ci.yml runs the release gate test runner"
else
  bad "ci.yml runs the release gate test runner" \
    "no ci.yml step runs scripts/tests/run_release_gate_tests.sh; the gate would not run in CI"
fi

# The runner is what CI actually executes, so its suite list is parsed rather than
# grepped. A text grep cannot tell an active entry from a commented-out one, so
# commenting a suite out used to leave this test green.
runner="${ROOT_DIR}/scripts/tests/run_release_gate_tests.sh"
if [[ -f "${runner}" ]]; then
  ok "run_release_gate_tests.sh exists"
  runner_suites="$(sed -n '/^SUITES=(/,/^)/p' "${runner}" |
    sed 's/#.*//' | grep -oE '[A-Za-z0-9_]+_test\.sh' | sort -u)"
  # The runner's own self-list is the load-bearing entry: every other suite is
  # asserted by release_workflow_test itself, so removing it from SUITES is the
  # one removal this file could never notice -- found by mutation, and the enabler
  # for a green run with the python3 guard removed.
  for suite in android_release_signing_test.sh apksigner_gate_test.sh android_release_artifact_smoke_test.sh release_workflow_test.sh; do
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
  # `dist`, exactly. A bare `-d` passes for any directory that happens to exist on
  # disk -- found by mutation: `path: public/seed-media/demo` (untracked, zero APKs)
  # went green while the LCA comment in the workflow claims the opposite. The
  # staging step creates `dist` and nothing else writes it, so the check is the
  # literal name plus "the staging step creates it", not "it exists".
  if [[ "${upload_path}" == "dist" ]] && grep -qE "^[[:space:]]*mkdir -p dist\$" "${WORKFLOW}"; then
    ok "the Android artifact is uploaded as the staged dist/ directory"
  else
    bad "the Android artifact is uploaded as the staged dist/ directory" \
      "'${upload_path}' is not the directory the staging step creates; the artifact root would not match what the consumers read"
  fi
fi

# The staging step must copy every file the consumers reference, so the artifact
# cannot silently lose its checksum or its signature evidence. Parsed from the
# staging step's own `run:` script, not grepped from the raw file: a comment
# quoting `"apksigner-verify.txt:apksigner-verify.txt"` satisfies a raw grep and
# would let a staging entry be replaced with `"":""` while every check stays
# green -- both found by mutation.
staged_pairs="$(python3 - "${WORKFLOW}" <<'PYTHON'
import re
import sys

import yaml

with open(sys.argv[1], encoding="utf-8") as handle:
    workflow = yaml.safe_load(handle)

steps = workflow["jobs"]["android"].get("steps", []) or []
code = "\n".join(
    str(step.get("run", "")) for step in steps if isinstance(step, dict)
)
code = "\n".join(
    line
    for line in code.splitlines()
    if line.strip() and not line.lstrip().startswith("#")
)
for pair in re.findall(r'"([^"]+:[^"]+)"', code):
    print(pair)
PYTHON
)"
for required in app-release.apk app-release.apk.sha256 apksigner-verify.txt; do
  # Assign from a command substitution, not a `while read` loop over a process
  # substitution: the loop would run in a subshell and the variable it set would be
  # lost, silently reporting every name as unstaged. The pairs were extracted above
  # from the staging step's own comment-stripped `run:` script, so a comment or
  # an unrelated step quoting "x:y" cannot satisfy this.
  staged_destination=no
  for pair in ${staged_pairs}; do
    destination="${pair##*:}"
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
# Parsed from the YAML, not grepped from the raw file. A comment explaining the
# staging layout quotes `apk/app-release.apk` (it has to, to explain what it is
# not), so a raw grep is satisfied by the explanation alone -- found by mutation:
# repointing the emulator runner's `script:` at a nested path left the check green
# because the comment at the staging step still named the right path.
apk_consumers="$(python3 - "${WORKFLOW}" <<'PYTHON'
import sys

import yaml

with open(sys.argv[1], encoding="utf-8") as handle:
    workflow = yaml.safe_load(handle)

smoke_steps = workflow["jobs"]["android-smoke"].get("steps", []) or []
scripts = [
    str(step.get("with", {}).get("script", ""))
    for step in smoke_steps
    if isinstance(step, dict)
    and "android-emulator-runner" in str(step.get("uses", ""))
]
publish_steps = workflow["jobs"]["android-publish"].get("steps", []) or []
runs = [
    str(step.get("run", ""))
    for step in publish_steps
    if isinstance(step, dict)
]
attached = " ".join(
    str(step.get("with", {}).get("files", ""))
    for step in publish_steps
    if isinstance(step, dict) and "action-gh-release" in str(step.get("uses", ""))
)
print("SMOKE_SCRIPT:" + "\n".join(scripts))
print("PUBLISH_RUN:" + "\n".join(runs))
print("ATTACHED:" + attached)
PYTHON
)"
if grep -qF '$GITHUB_WORKSPACE/apk/app-release.apk' <<<"${apk_consumers}"; then
  ok "the smoke gate reads the APK from the artifact root"
else
  bad "the smoke gate reads the APK from the artifact root" \
    "the emulator runner script does not reference apk/app-release.apk"
fi
if grep -qF 'APK="apk/app-release.apk"' <<<"${apk_consumers}" \
  && grep -qF 'apk/app-release.apk' <<<"${apk_consumers}" \
  && grep -qF 'apk/app-release.apk.sha256' <<<"${apk_consumers}"; then
  ok "the publish step re-verifies and attaches the APK from the artifact root"
else
  bad "the publish step re-verifies and attaches the APK from the artifact root" \
    "the publish job does not verify and attach apk/app-release.apk"
fi

echo " the job that publishes re-verifies what it publishes"
# The build job runs the signature gate and the smoke job installs the APK, so
# publication is already downstream of two checks. This asserts the third,
# independent one: the publish job -- the last thing that runs before the bytes
# become a download, on its own runner, with its own checkout of the gate script --
# re-derives the checksum and the signature from the artifact it is about to
# attach. Without it, a mismatch between what was verified and what is published
# would be invisible until a user hit "App not installed" again.
publish_checks="$(python3 - "${WORKFLOW}" <<'PYTHON'
import sys

import yaml

with open(sys.argv[1], encoding="utf-8") as handle:
    workflow = yaml.safe_load(handle)
steps = workflow["jobs"]["android-publish"].get("steps", []) or []

reverify_index = None
release_index = None
results = {}
for index, step in enumerate(steps):
    if not isinstance(step, dict):
        continue
    name = str(step.get("name", ""))
    run = str(step.get("run", ""))
    if "action-gh-release" in str(step.get("uses", "")):
        release_index = index
        # The whole point of re-verifying is that the *published* bytes are the
        # verified ones. If the release attached a different path, the gate would
        # be checking a file nobody downloads. Found by mutation: dropping the APK
        # from `files:` left every check green.
        attached = str(step.get("with", {}).get("files", ""))
        # All three, not just the APK: the checksum is what the user verifies
        # with, and the signature transcript is the certificate audit trail. A
        # release missing any of them degrades what "verified" means in practice.
        # Matched as full lines so `apk/app-release.apk` cannot be satisfied by
        # `apk/app-release.apk.sha256`.
        attached_lines = f"{attached}\n".splitlines()
        results["attaches"] = all(
            name in attached_lines
            for name in (
                "apk/app-release.apk",
                "apk/app-release.apk.sha256",
                "apk/apksigner-verify.txt",
            )
        )
    if "Re-verify" in name:
        reverify_index = index
        # Comments are stripped before matching. A comment explaining *why* a
        # command runs usually quotes the command, so a naive substring search
        # over the raw block is satisfied by the explanation alone -- the same
        # string that was just deleted from the script. This was found by
        # mutation: replacing the `sha256sum -c` line with `echo` left the check
        # green.
        code = "\n".join(
            line
            for line in run.splitlines()
            if line.strip() and not line.lstrip().startswith("#")
        )
        results["checksum"] = "sha256sum -c" in code
        results["signature"] = "android_release_verify_signature.sh" in code
        results["empty-input"] = "::error::refusing to publish" in code

results["present"] = reverify_index is not None
# The guarantee, stated once: the re-verification has to come before the step that
# makes the bytes downloadable. `False` when either step is missing, because an
# absent step cannot be ordered correctly.
results["ordered"] = (
    reverify_index is not None
    and release_index is not None
    and reverify_index < release_index
)
for key, value in results.items():
    print(f"{key}\t{'yes' if value else 'no'}")
PYTHON
)"
for required in present checksum signature empty-input ordered attaches; do
  value="$(printf '%s\n' "${publish_checks}" | grep "^${required}	" | cut -f2 | head -n 1)"
  case "${required}" in
    ordered)
      if [[ "${value}" == "yes" ]]; then
        ok "the publish job re-verifies before it publishes"
      else
        bad "the publish job re-verifies before it publishes" \
          "the release step runs before any re-verification, so nothing checks the bytes that get attached"
      fi
      ;;
    attaches)
      if [[ "${value}" == "yes" ]]; then
        ok "the release attaches the same APK the publish job re-verified"
      else
        bad "the release attaches the same APK the publish job re-verified" \
          "apk/app-release.apk is verified but not in the release file list, so the check covers a file nobody downloads"
      fi
      ;;
    present)
      if [[ "${value}" == "yes" ]]; then
        ok "the publish job has a re-verification step"
      else
        bad "the publish job has a re-verification step" "no step named 'Re-verify' in android-publish"
      fi
      ;;
    *)
      if [[ "${value}" == "yes" ]]; then
        ok "the publish job re-verifies the ${required} of the artifact it attaches"
      else
        bad "the publish job re-verifies the ${required} of the artifact it attaches" \
          "the re-verification step does not check the ${required}"
      fi
      ;;
  esac
done

echo " the materialized signing key is removed from the runner"
# `materialize` has to leave the keystore on disk -- the Gradle build is a later
# process and reads it through GITHUB_ENV -- so the key outlives the script that
# wrote it. The removal therefore has to live in the build job, and it has to be
# guarded by `if: always()`, or it is skipped in precisely the cases that matter: a
# failed or cancelled build.
key_cleanup="$(python3 - "${WORKFLOW}" <<'PYTHON'
import sys

import yaml

with open(sys.argv[1], encoding="utf-8") as handle:
    workflow = yaml.safe_load(handle)
steps = workflow["jobs"]["android"].get("steps", []) or []
for step in steps:
    if not isinstance(step, dict):
        continue
    if "Remove the materialized signing key" not in str(step.get("name", "")):
        continue
    print(f"condition\t{str(step.get('if', '')).strip()}")
    print(f"present\tyes")
    # The step body is written to stdout so the test can *run* it rather than
    # grep it. Grepping the text only proves the string `rm -f` appears somewhere,
    # which is satisfied by a branch that is never taken -- caught by mutation.
    sys.stdout.write("---SCRIPT---\n")
    sys.stdout.write(str(step.get("run", "")))
    sys.stdout.write("\n")
    break
else:
    print("present\tno")
PYTHON
)"
if [[ "$(printf '%s\n' "${key_cleanup}" | grep '^present	')" != "present	yes" ]]; then
  bad "the signing key is removed from the runner after the build" \
    "no step in the android job removes the materialized keystore"
else
  ok "the signing key is removed from the runner after the build"
  condition="$(printf '%s\n' "${key_cleanup}" | grep '^condition	' | cut -f2)"
  # `always()` and `success() || failure()` are equivalent; only the first is
  # spelled the way this workflow spells conditions, and requiring it keeps the
  # assertion about the *guarantee* rather than about one spelling of it.
  if [[ "${condition}" == "always()" ]]; then
    ok "the key removal runs even when the build fails (if: always())"
  else
    bad "the key removal runs even when the build fails (if: always())" \
      "if: was '${condition}', so a failed build skips the cleanup"
  fi

  # Run the step for real against a throwaway keystore.
  cleanup_script="${WORK_DIR}/key-cleanup.sh"
  printf '%s\n' "${key_cleanup}" | sed -n '/^---SCRIPT---$/,$p' | tail -n +2 >"${cleanup_script}"
  probe="${WORK_DIR}/fake-keystore.jks"
  : >"${probe}"
  if ANDROID_KEYSTORE_FILE="${probe}" bash "${cleanup_script}" >"${WORK_DIR}/cleanup.log" 2>&1 &&
    [[ ! -e "${probe}" ]]; then
    ok "the key removal step, executed, actually deletes the keystore"
  else
    bad "the key removal step, executed, actually deletes the keystore" \
      "the file survived: $(tr '\n' '|' <"${WORK_DIR}/cleanup.log")"
  fi
  # ...and it must not fail when there is nothing to remove, or `if: always()`
  # would turn every failed build into a second failure that masks the first.
  if env -u ANDROID_KEYSTORE_FILE bash "${cleanup_script}" >"${WORK_DIR}/cleanup-none.log" 2>&1; then
    ok "the key removal step is a no-op when no key was materialized"
  else
    bad "the key removal step is a no-op when no key was materialized" \
      "$(tr '\n' '|' <"${WORK_DIR}/cleanup-none.log")"
  fi
  # ...and it must not report success while leaving the key in place, which is the
  # failure mode a `set -e`-free step with a wrong path would have.
  : >"${probe}"
  if ANDROID_KEYSTORE_FILE="${probe}" bash "${cleanup_script}" >/dev/null 2>&1 &&
    [[ -e "${probe}" ]]; then
    bad "the key removal step does not report success while leaving the key" \
      "the step exited 0 with the keystore still on disk"
  else
    ok "the key removal step does not report success while leaving the key"
  fi
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
