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
    # A second writer does not have to use the action. `gh release create` -- or a
    # call to the releases API -- in any job's `run:` block creates or updates a
    # release too, and a scan that only matches `action-gh-release` in `uses:`
    # cannot see it. Without this, "exactly one job may publish" is a claim about
    # one spelling of publishing rather than about publishing: an independent
    # review added a job that ran `gh release create` in a `run:` block and the
    # suite stayed green.
    if "action-gh-release" in str(step.get("uses", "")):
        return True
    run = str(step.get("run", ""))
    return bool(
        re.search(r"\bgh\s+release\s+(create|edit|upload)\b", run)
        or (re.search(r"\bgh\s+api\b", run) and "releases" in run)
    )

publishers = {
    job for job, spec in jobs.items() if any(is_publish_step(s) for s in spec.get("steps", []) or [])
}

failures = []

checks = 0


def expect(condition, message):
    global checks
    checks += 1
    if not condition:
        failures.append(message)

# --- the core #97 guarantee -------------------------------------------------
expect("android" not in publishers, "the `android` build job must not publish; the `release` job owns publication")
expect(
    sorted(needs_of("android-verify")) == ["android", "android-smoke"],
    "`android-verify` must need both `android` and `android-smoke`",
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

# --- atomic publication ------------------------------------------------------
# Before this, five jobs held `contents: write`, none had a `needs:`, and each
# published itself. The release action creates the release when it does not
# exist, so a tag where any subset of those jobs failed still produced a live,
# public, non-draft release carrying whatever the successful jobs had uploaded,
# and it became "Latest". The tag was consumed. Nothing asserted against that
# shape, which is why `release_workflow_test.sh` had to be read to find it.
#
# v0.1.7 is the observed instance: run 35839417899 had Android, Windows and
# macOS green, Linux and iOS red, and published exactly those three assets --
# three assets, not four, and the APK was one of them.
#
# The invariant is therefore not "the Android publish job needs the smoke gate".
# It is: exactly one job may publish, and everything that produces release
# material must gate it.
expect(
    publishers == {"release"},
    f"exactly one job may publish, and it must be `release` (found {sorted(publishers)})",
)
expect(
    "release" in jobs,
    "release.yml must define a single `release` job that owns publication",
)

# --- one publish *step*, not one publish job ----------------------------------
# `publishers` is a set of job NAMES, so every property below it was satisfied by
# `any(...)`/join over whichever steps a job happened to have. A second publish
# step inside `release` was therefore invisible: the job name is still `release`,
# the real step still sets `fail_on_unmatched_files`, and the joins still contain
# `dist/*`. The suite stayed green while a second publish call sat *before*
# staging -- and the pinned action creates the release as a draft, uploads, then
# flips `draft: false`, so it leaves a live, Latest release carrying only what it
# named, with every staging refusal afterwards arriving too late. That is the
# v0.1.7 incident, reproduced inside the job that exists to prevent it.
#
# So count publish steps workflow-wide, pin the single one's position, and derive
# every publish property from that one step rather than from a join over many.
publish_steps_everywhere = [
    (job, step)
    for job, spec in jobs.items()
    for step in (spec.get("steps") or [])
    if is_publish_step(step)
]
expect(
    len(publish_steps_everywhere) == 1,
    f"exactly one publish step may exist anywhere in the workflow (found "
    f"{len(publish_steps_everywhere)}: {[(job, str(step.get('name') or step.get('uses') or '(run block)')) for job, step in publish_steps_everywhere]})",
)
release_publish_steps = [step for step in steps_of("release") if is_publish_step(step)]
expect(
    len(release_publish_steps) == 1,
    f"exactly one publish step may exist in `release` (found {len(release_publish_steps)})",
)
expect(
    release_publish_steps == steps_of("release")[-1:],
    "the publish step must be the last step of `release`, so nothing runs after the release "
    "goes live; a publish step placed earlier publishes whatever it named regardless of staging",
)
# The single publish step, for the property assertions below. When the count is
# wrong these are deliberately vacuous rather than raising: the count assertion is
# already red and named, and a traceback would replace a readable failure with a
# crash and hide the other findings.
publish_step = release_publish_steps[0] if len(release_publish_steps) == 1 else {}
publish_with = publish_step.get("with") or {}
for upstream in (
    "release-signing-preflight",
    "linux",
    "linux-smoke",
    "windows",
    "windows-smoke",
    "macos",
    "macos-smoke",
    "ios",
    "android-verify",
):
    expect(
        upstream in needs_of("release"),
        f"`release` must need `{upstream}`, or a failure there still publishes a partial release",
    )
expect(
    len(needs_of("release")) == len(set(needs_of("release"))),
    "`release` lists a dependency twice",
)

# --- every artifact with a smoke gate must actually be gated ------------------
# The Linux and Windows gate jobs below were added without listing them in
# `release.needs`, so they *ran* and reported failure while `release` still
# published. A gate that does not gate publication is a comment. Each smoke job
# must (a) depend only on the build job whose bytes it consumes, and (b) invoke
# its committed gate script, and (c) block `release`.
for smoke_job, build_job, gate_script in (
    ("linux-smoke", "linux", "scripts/linux_release_artifact_smoke.sh"),
    ("windows-smoke", "windows", "scripts/windows_release_artifact_smoke.sh"),
    ("macos-smoke", "macos", "scripts/macos_release_artifact_smoke.sh"),
):
    expect(
        sorted(needs_of(smoke_job)) == [build_job],
        f"`{smoke_job}` must need only `{build_job}`",
    )
    expect(
        gate_script in runs_of(smoke_job),
        f"`{smoke_job}` must run `{gate_script}`",
    )
# iOS is install/launch-gated in the release path, with a real backend.
#
# `scripts/ios_release_artifact_smoke.sh` is fail-closed on
# `IOS_SMOKE_BACKEND_PROBE`: it refuses to report success unless the launched app
# can be shown to reach a backend. iOS forbids an app from spawning galleryd, so
# the `ios` job supplies a host daemon, injects the session into the debug build
# through `IOS_SMOKE_LAUNCH_ARGUMENTS`, and proves the app reached it. If any
# piece is dropped the gate fails closed and blocks the release, which is the
# point: an ungated iOS artifact must not ship as "verified".
ios_runs = runs_of("ios")
expect(
    "ios_release_artifact_smoke.sh" in ios_runs,
    "the `ios` job must invoke `scripts/ios_release_artifact_smoke.sh`; an iOS "
    "artifact is otherwise shipped ungated",
)
expect(
    "IOS_SMOKE_BACKEND_PROBE" in ios_runs,
    "the `ios` job must set IOS_SMOKE_BACKEND_PROBE; the gate is fail-closed on it "
    "and would block every release",
)
expect(
    "IOS_SMOKE_LAUNCH_ARGUMENTS" in ios_runs,
    "the `ios` job must set IOS_SMOKE_LAUNCH_ARGUMENTS so the debug build is "
    "pointed at the host daemon the probe checks",
)
expect(
    "flutter build ios --simulator" in ios_runs,
    "the `ios` job must build the simulator slice `simctl` can install "
    "(`flutter build ios --simulator`); the device .app cannot be installed",
)
expect(
    "target/release/galleryd" in ios_runs and "/mobile/workspace" in ios_runs,
    "the `ios` job must start a host galleryd and prove the app reached it "
    "(the probe reads GET /mobile/workspace from the daemon log)",
)
# `if:` on a job runs it even when its dependencies failed, which is exactly the
# mechanism by which a four-platform release escapes while Android is red.
# #82 proposed `always()`; it is the opposite of atomic publication.
#
# The first version of this check compared the raw string to the literal
# `always()`. That was not a check at all: an independent review added
# `if: ${{ always() }}` -- the form GitHub's own documentation uses, semantically
# identical -- and the suite stayed green.
#
# The second version normalised `${{ }}` and whitespace and searched for
# `always()` anywhere in the expression. Still too narrow. Per GitHub's
# `jobs.<job_id>.needs` documentation, ANY job-level conditional drops the
# implicit `success()`, including `if: ${{ !cancelled() }}`, which reads like the
# opposite of `always()` and is the form someone reaches for when told "the
# publish job must run even when...".
#
# So the correct assertion is the one the workflow comment actually claims: the
# publisher has no conditional, and therefore runs only when every entry in
# `needs` succeeded. Absence of `if` is the whole guarantee; any value at all
# weakens it, so any value at all fails. A step-level `if` is checked separately
# below, because a step-level scan cannot see a job-level key.
expect(
    not jobs["release"].get("if"),
    "`release` must carry no job-level `if:` at all -- any conditional drops the implicit "
    "`success()` on `needs`, so `if: ${{ !cancelled() }}` or `if: ${{ success() || failure() }}` "
    "publishes a partial release just as `always()` does. The guarantee is the ABSENCE of a "
    "conditional, so only absence passes",
)
# And the same for its steps, which is a different key on a different object: a
# job-level scan cannot see a step-level `if`. This matters independently of the
# job-level rule, because the staging step *refuses* by exiting non-zero -- a
# publish step carrying `if: always()` would run anyway and create a release whose
# `dist/*` glob matches nothing. Nothing in `release` needs a conditional; the two
# legitimate `if: always()` steps in this file are cleanup and evidence upload, in
# the `android` and `android-smoke` jobs.
release_step_conditions = [
    (step.get("name") or "<unnamed>")
    for step in steps_of("release")
    if isinstance(step, dict) and step.get("if")
]
expect(
    not release_step_conditions,
    "no step in `release` may carry an `if:` -- a step-level `if: always()` on the publish "
    "step runs it even when the staging step refused, creating exactly the empty release "
    "this change exists to prevent. Offending step(s): " + ", ".join(release_step_conditions),
)
expect(
    not any("release" in needs_of(job) for job in jobs),
    "no job may need `release` itself -- `release` is the terminal publisher, and a job "
    "that depends on it would deadlock on the artifact it waits for",
)

# Artifact-level completeness. Asserting the `needs:` list alone is not enough: a
# new platform can be added to `needs` and still never be downloaded, which
# publishes a release that silently omits it. So every artifact any job uploads
# is checked against every artifact `release` downloads.
def upload_names(job):
    found = []
    for step in steps_of(job):
        if not isinstance(step, dict) or "upload-artifact" not in str(step.get("uses", "")):
            continue
        name = str((step.get("with") or {}).get("name") or "")
        if name:
            found.append(name)
    return found

def download_names(job):
    found = []
    for step in steps_of(job):
        if not isinstance(step, dict) or "download-artifact" not in str(step.get("uses", "")):
            continue
        name = str((step.get("with") or {}).get("name") or "")
        if name:
            found.append(name)
    return found

def download_platforms(job):
    # The platform directory each download-artifact step writes into. This is the
    # set of platforms `release` actually has on disk, derived from the workflow
    # rather than restated, so it cannot drift from what is fetched.
    found = set()
    for step in steps_of(job):
        if not isinstance(step, dict) or "download-artifact" not in str(step.get("uses", "")):
            continue
        path = str((step.get("with") or {}).get("path") or "")
        found.add(path.rstrip("/").rsplit("/", 1)[-1] if path else "")
    return found

def staged_platforms(job):
    # The `platforms=(...)` array in the staging step -- the list that decides what
    # is copied into `dist` and therefore what the release actually attaches.
    found = None
    for step in steps_of(job):
        if not isinstance(step, dict):
            continue
        match = re.search(r"^\s*platforms=\(([^)]*)\)", str(step.get("run", "")), re.M)
        if match:
            found = set(match.group(1).split())
    return found or set()

# The published asset set is decided by `platforms=(...)`, and nothing else. An
# independent review built a composite `freebsd` job that was wired up correctly in
# every way this file checks -- job created, added to `needs`, artifact uploaded,
# artifact downloaded into `incoming/freebsd` -- and the suite stayed at 52 passed,
# because the download landed in a directory the staging loop never visits. The
# artifact was then attached to nothing. That is precisely the "silently omits a
# platform" outcome the workflow comment claims to prevent, and the earlier
# assertion could not see it: it required the literal
# `find "incoming/${platform}" -type f -size +0c` inside the run block, which is
# still true no matter which platforms the array holds.
#
# So the array is now compared against the download destinations. They must be the
# same set. A rename of a download path fails here too, instead of failing closed
# at publish time as a confusing refusal.
expect(
    staged_platforms("release") == download_platforms("release")
    and len(download_platforms("release")) >= 1,
    "the staging `platforms=(...)` array must be exactly the set of directories the "
    "download-artifact steps write into -- an artifact fetched into `incoming/<p>` that the "
    "staging loop never visits is downloaded, verified, and then attached to nothing. "
    "Add a platform to the array and the suite fails here, not silently at release time",
)

# `continue-on-error: true` turns a step's refusal into a green job. The staging
# step's whole purpose is to exit non-zero on an incomplete platform set; with this
# key the job succeeds anyway, `dist` is never created, and the publish step's glob
# matches nothing. The review demonstrated the suite stayed green while this was
# added. The comment at release.yml:802-804 claims the release "is either complete
# or it does not exist", and a swallowed refusal is the one thing that breaks that.
continue_on_error = [
    (step.get("name") or "<unnamed>")
    for step in steps_of("release")
    if isinstance(step, dict) and "continue-on-error" in step
]
expect(
    not continue_on_error,
    "no step in `release` may set `continue-on-error` -- it swallows the staging step's "
    "refusal and turns the whole job green with nothing staged. Offending step(s): "
    + ", ".join(continue_on_error),
)

# The same hole one level up. A job-level key marks the entire `release` job
# green even when the staging step exits non-zero, so the publish step then runs
# against a `dist/` the refusal prevented from being created. The review that
# found the step-level hole did not cover this one.
expect(
    "continue-on-error" not in (jobs.get("release") or {}),
    "no job-level `continue-on-error` may be set on `release` -- it turns the staging "
    "step's refusal into a green job with nothing staged",
)

# The action's default is `fail_on_unmatched_files: false`, which CREATES a release
# with zero assets when the glob matches nothing -- the v0.1.7 shape, live and
# public. Asserted separately from `continue-on-error` so that even if a future
# edit swallows the staging refusal, the publish step itself still refuses to make
# an empty release.
expect(
    "action-gh-release" in str(publish_step.get("uses", ""))
    and publish_with.get("fail_on_unmatched_files") is True,
    "the publish step must set `fail_on_unmatched_files: true` -- the action's default is "
    "`false`, which creates a live release with zero attached assets when `dist/*` matches "
    "nothing, which is exactly the v0.1.7 partial-release outcome",
)

def reachable_from(start):
    # Transitive, not direct. `android` is what produces the APK, but `release`
    # does not name it: `android-verify` sits between them, and a failing `android`
    # blocks `android-verify` which blocks `release`. Asserting a *direct* edge
    # from `release` to every producer would be wrong twice over -- it would fail a
    # correct workflow, and the "fix" would be a redundant direct dependency that
    # hides whether the real chain is intact.
    seen = set()
    stack = [start]
    while stack:
        current = stack.pop()
        if current not in jobs:
            continue
        for dep in needs_of(current):
            if dep not in seen:
                seen.add(dep)
                stack.append(dep)
    return seen

release_reaches = reachable_from("release")
produced = {}
for job in jobs:
    for name in upload_names(job):
        produced.setdefault(name, set()).add(job)
release_downloads = set(download_names("release"))

# `*-evidence-*` artifacts are CI evidence, not release assets, so they are
# deliberately not downloaded. Everything else is release material.
for name, producers in sorted(produced.items()):
    if "evidence" in name:
        continue
    for producer in sorted(producers):
        expect(
            producer in release_reaches,
            f"`{producer}` uploads `{name}` but `release` does not depend on it (directly "
            f"or transitively), so its failure would not block the release",
        )
    expect(
        name in release_downloads,
        f"`release` must download `{name}` (uploaded by {sorted(producers)}), or the "
        f"release silently omits it",
    )
expect(
    release_downloads <= set(produced),
    f"`release` downloads artifacts no job uploads: {sorted(release_downloads - set(produced))}",
)
expect(
    len(release_downloads) == len([n for n in produced if "evidence" not in n]),
    "`release` must download every release-material artifact exactly once",
)

# The staging step is what makes "complete or nothing" true at the byte level:
# without it, a glob that matched nothing would still publish a release.
staging_runs = "\n".join(
    str(step.get("run", ""))
    for step in steps_of("release")
    if isinstance(step, dict) and "refusing to publish a partial release" in str(step.get("run", ""))
)
staging_code = "\n".join(
    line for line in staging_runs.splitlines()
    if line.strip() and not line.lstrip().startswith("#")
)
expect(bool(staging_code), "`release` must have a staging step that refuses a partial release")
if staging_code:
    expect("-type f -size +0c" in staging_code,
           "the staging step must count non-empty files, or an empty artifact counts as produced")
    expect("exit 1" in staging_code,
           "the staging step must exit non-zero when a platform contributed nothing")
    expect("overwrite the other" in staging_code,
           "the staging step must refuse two artifacts sharing a basename, or one silently "
           "overwrites the other in the release")
    expect(
    "cp " in staging_code,
    "the staging step must copy each artifact into the published directory",
)

# --- the signing preflight cannot be bypassed -------------------------------
# Its only job is to be fast and to be the same policy everything else uses. A
# preflight that re-implements the rule, or that tolerates an unexpected mode, is
# worse than none: it looks like a gate and is not one.
preflight_steps = steps_of("release-signing-preflight")
preflight_raw = "\n".join(
    str(step.get("run", "")) for step in preflight_steps if isinstance(step, dict)
)
# Comments are stripped: the preflight's own comments quote the command and the
# error text it is checking for, so a substring search over the raw block would be
# satisfied by the explanation alone.
preflight_code = "\n".join(
    line
    for line in preflight_raw.splitlines()
    if line.strip() and not line.lstrip().startswith("#")
)
expect(bool(preflight_steps),
       "release.yml must define a `release-signing-preflight` job")
if preflight_steps:
    expect("android_release_signing.sh mode" in preflight_code,
           "the preflight must resolve signing through the shared policy script, so it cannot "
           "drift from the workflow, the local readiness check and the tests")
    expect("keytool" not in preflight_code,
           "the preflight must not invoke keytool; it resolves a mode, it does not materialise a key")
    expect("*)" in preflight_code,
           "the preflight must have a default branch, so an unexpected mode is not accepted silently")
    expect(re.search(r"\*\)\s*(?:echo[^\n]*\n)*\s*exit 1", preflight_code) is not None,
           "the preflight must exit non-zero on an unexpected signing mode")
    expect(len(preflight_steps) == 2,
           f"the preflight must be checkout plus the policy call and nothing else, or a missing "
           f"secret is no longer a fast fail (found {len(preflight_steps)} steps)")
    expect((jobs["release-signing-preflight"].get("permissions") or {}).get("contents") == "read",
           "the preflight must not hold contents: write")
    expect(jobs["release-signing-preflight"].get("timeout-minutes", 999) <= 10,
           "the preflight must have a short timeout, or it is not a fast fail")
expect(
    not needs_of("release-signing-preflight"),
    "the preflight must need no other job, or a missing secret stops being a fast fail",
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
# The inverse, which is the property that makes the previous one mean something:
# every job that CANNOT publish must also not hold the token that publishes. Four
# build jobs holding `contents: write` is not itself a bug -- it is a fact about
# who can create a release, and it is the reason the partial publish was possible.
for job in sorted(set(jobs) - publishers):
    expect(
        (jobs[job].get("permissions") or {}).get("contents") != "write",
        f"`{job}` does not publish, so it must not hold contents: write",
    )
expect(
    workflow.get("permissions", {}).get("contents") == "read",
    "the workflow's top-level default must stay contents: read, so a new job does not "
    "inherit write",
)

# `linux` holds `id-token: write` and `attestations: write`. Those mint an SBOM-backed
# provenance attestation; neither can create a release, a tag, or an asset, which is
# why the invariant above is scoped to `contents` and not to "any write". That
# carve-out is asserted rather than left to a reader's judgement: deleting either key
# looks like harmless least-privilege cleanup, and it silently stops every future
# Linux artifact from carrying provenance. The loop above already proves `linux`
# holds `contents: read`.
_linux_perms = jobs["linux"].get("permissions") or {}
expect(
    any("attest-build-provenance" in str(step.get("uses", ""))
        for step in jobs["linux"].get("steps", []) or []),
    "the `linux` job is expected to attest its build provenance",
)
expect(
    _linux_perms.get("id-token") == "write"
    and _linux_perms.get("attestations") == "write",
    "the `linux` attestation step needs id-token: write and attestations: write",
)

# --- the signing disclosure must be driven by the preflight, not hardcoded ----
# This is the one place the release tells users something they will act on: whether
# a future version installs over this one, or requires an uninstall that discards
# their paired identity. An independent review replaced the whole `${{ ... }}`
# expression with the optimistic literal and this suite still reported 51 passed --
# so an ephemeral-key release could have published a body promising clean upgrades.
# Nothing below was asserted, and no mutation covered it.
_publish_body = ""
for _step in jobs["release"].get("steps", []) or []:
    if "softprops/action-gh-release" in str(_step.get("uses", "")):
        _publish_body = str((_step.get("with") or {}).get("body", ""))
expect(
    "needs.release-signing-preflight.outputs.signing_mode" in _publish_body,
    "the release body must branch on the preflight's signing_mode, or it is a hardcoded "
    "claim that a future version installs over this one",
)
# Both branches must survive. Keeping only the optimistic one is the same defect as
# hardcoding it, just spelled as an `if`.
expect(
    "project release key" in _publish_body,
    "the release body must describe the real-release-key outcome, so an ephemeral-key "
    "build does not leave the reader with no guidance",
)
expect(
    "ephemeral per-run CI key" in _publish_body,
    "the release body must describe the ephemeral-key outcome, which is the case that "
    "tells users an uninstall is coming and their paired identity will be discarded",
)
# The preflight has to publish that value, or the expression above resolves empty and
# GitHub substitutes "" -- silently deleting the entire sentence rather than failing.
expect(
    jobs["release-signing-preflight"].get("outputs", {}).get("signing_mode")
    == "${{ steps.signing.outputs.mode }}",
    "the preflight must expose signing_mode from the step that computes it, or the "
    "release body's expression resolves to an empty string",
)
# And the mode must actually come from the shared policy script, not a literal, so
# the body and the gate that refuses unsigned releases cannot disagree.
_preflight_run = "".join(
    str(step.get("run", ""))
    for step in jobs["release-signing-preflight"].get("steps", []) or []
)
expect(
    "android_release_signing.sh mode" in _preflight_run,
    "the preflight must read the mode from scripts/android_release_signing.sh, the "
    "single source of truth the android job's gate also uses",
)

# --- the fast-fail preflight is only fast if the builds wait for it -----------
# The preflight comment claims "fail in seconds, and before any job holds
# `contents: write`" and "every job that builds a platform `needs:` this one, so a
# tag with no signing material fails here instead of after two and a half hours of
# builds". An independent review found the second sentence was false: linux/windows/
# macos/ios had no `needs:` at all, so they ran to completion regardless. The
# `needs:` was added to make the claim true -- and it is asserted here so a later
# edit cannot make the comment false again without going red. The job count and the
# timeouts are asserted below too, because "two and a half hours" is a claim about
# specific values.
for _builder in ("linux", "windows", "macos", "ios", "android"):
    expect(
        "release-signing-preflight" in needs_of(_builder),
        f"the `{_builder}` job must need the signing preflight, or the preflight does "
        f"not actually fail fast -- the long platform builds run to completion "
        f"whatever the preflight says",
    )

# --- release assets: the SBOM must actually ship -----------------------------
# Consolidating publication dropped this. `docs/RELEASE_CHECKLIST.md` still requires "an
# SBOM artifact from CI", the `linux` job still generates one, and nothing uploaded it --
# so the release silently lost an asset it had published on origin/main. No assertion
# mentioned the SBOM, which is why an independent review had to find it.
_linux_upload = ""
for _step in jobs["linux"].get("steps", []) or []:
    if "upload-artifact" in str(_step.get("uses", "")):
        _linux_upload = str((_step.get("with") or {}).get("path", ""))
expect(
    "sbom.spdx.json" in _linux_upload,
    "the Linux artifact upload must include sbom.spdx.json, or the release no longer "
    "ships the SBOM that docs/RELEASE_CHECKLIST.md requires",
)
_linux_generates_sbom = any(
    "sbom-action" in str(step.get("uses", ""))
    for step in jobs["linux"].get("steps", []) or []
    if isinstance(step, dict)
)
expect(
    _linux_generates_sbom,
    "the `linux` job must still generate the SBOM it uploads; deleting the step leaves "
    "the checklist requiring an artifact that nothing produces",
)
# Order matters and is easy to lose: `upload-artifact` snapshots the workspace when it
# runs, so a SBOM generated *after* the upload is a file nothing will ever publish. That
# is exactly the state this PR was found in.
_linux_step_names = [
    str(step.get("name", "")) for step in jobs["linux"].get("steps", []) or []
    if isinstance(step, dict)
]
_sbom_at = next(
    (n for n, name in enumerate(_linux_step_names) if name == "Generate SBOM"), None
)
_upload_at = next(
    (n for n, name in enumerate(_linux_step_names) if name == "Upload Linux artifacts"),
    None,
)
expect(
    _sbom_at is not None and _upload_at is not None and _sbom_at < _upload_at,
    "the SBOM must be generated BEFORE the upload, or `upload-artifact` snapshots the "
    "workspace before the file exists and the SBOM is silently discarded",
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
# keystore error after a long NDK cross-compile" -- and a tag cut before the
# signing secrets exist must fail in seconds, not after burning the three-target
# cargo-ndk release build. Order is load-bearing here, so it is asserted, not
# assumed.
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

# --- release body integrity --------------------------------------------------
# With one publish call there is no "last job to finish wins the body" race left
# to guard against: the body is written exactly once. What still has to hold is
# that every platform's signing warning survives into it, because that text is
# the only place a reader learns a platform is unsigned. Losing it is a security
# disclosure regression, not cosmetics.
release_body = str(publish_with.get("body", ""))
for platform in ("Android", "Linux", "Windows", "macOS", "iOS"):
    # The signing status has to be on the same line as the platform name.
    # Checking that the name merely appears somewhere was measurably weaker:
    # rewriting "* **macOS** - unsigned. No notarization." to
    # "* **macOS** - see notes." left that assertion green, which is precisely the
    # regression the assertion exists to catch -- a reader can no longer tell
    # whether the platform is signed.
    lines = [line for line in release_body.splitlines() if platform in line]
    expect(
        any(re.search(r"unsigned|signed|codesign|notariz|authenticode|gpg", line, re.IGNORECASE)
            for line in lines),
        f"the release body must state {platform}'s signing status on the same line as its "
        f"name; it is the only place a reader learns the platform is unsigned",
    )
notes_owners = [
    job for job, step in publish_steps_everywhere
    if (step.get("with") or {}).get("generate_release_notes")
]
expect(
    len(notes_owners) == 1,
    f"exactly one publish step may set generate_release_notes (found {len(notes_owners)}: {notes_owners})",
)
# The publish step must attach the staged directory, and the staging step must be
# the only thing deciding what is in it. Compared for equality, not containment:
# `dist/*` joined with `incoming/android/*` contains `dist/*` while attaching a
# second, unvetted glob.
release_files = str(publish_with.get("files", ""))
expect(
    release_files == "dist/*",
    f"the publish step must attach exactly the staged directory and nothing else, so the file "
    f"list is decided by the staging step's assertions rather than by a glob "
    f"(got: {release_files!r})",
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
# The shell wraps this entire block in one `check`, so its own tally cannot see
# these assertions. Print the count on the way out, or a failure reads as an
# unexplained red with no way to tell how much of the file had run.
if failures:
    print(f'{len(failures)} of {checks} embedded assertions failed')
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

  # And the runner must actually fail when a suite fails, or CI reports a red
  # suite as a green build. Neutering its failure handling used to go unnoticed,
  # because nothing exercised it.
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

  # The driver shards its long mutation pass: it runs N concurrent copies of one
  # suite and folds them into a single PASS/FAIL/DEGRADED result. Nothing else
  # runs that branch, so a shard that silently stops being spawned, or a failing
  # shard that stops failing the pass, would go unnoticed. This probe narrows
  # SUITES to the sharded suite and swaps in a fake that records which shard it
  # was handed, so both the union and the aggregation are checked.
  #
  # The expected shard set is pinned to what the committed driver declares. If
  # someone un-shards the pass (count 1) or drops a shard, the union assertion
  # fails rather than quietly accepting a subset of the mutations.
  shard_root="$(mktemp -d)"
  mkdir -p "${shard_root}/scripts/tests"
  cp "${runner}" "${shard_root}/scripts/tests/run_release_gate_tests.sh"
  if python3 - "${shard_root}/scripts/tests/run_release_gate_tests.sh" <<'PYTHON'
import re
import sys

path = sys.argv[1]
with open(path) as handle:
    source = handle.read()
narrowed, count = re.subn(
    r"SUITES=\(\n(?:  \S+\n)+\)",
    "SUITES=(\n  ios_release_artifact_mutation_test.sh\n)",
    source,
)
if count != 1:
    sys.exit("could not narrow the SUITES list; the runner's shape changed")
with open(path, "w") as handle:
    handle.write(narrowed)
PYTHON
  then
    shard_runner="${shard_root}/scripts/tests/run_release_gate_tests.sh"
    shard_suite="${shard_root}/scripts/tests/ios_release_artifact_mutation_test.sh"
    shard_log="$(mktemp)"

    # Each shard must be handed its own index, and every index must run.
    # The literal below is the committed shard count; a drop is a hard failure.
    cat >"${shard_suite}" <<SHARD_SUITE
#!/usr/bin/env bash
printf '%s\n' "\${MUTATION_SHARD}" >>"${shard_log}"
exit 0
SHARD_SUITE
    if bash "${shard_runner}" >/dev/null 2>&1; then
      ok "the committed runner exits 0 when every shard of a sharded suite passes"
    else
      bad "the committed runner exits 0 when every shard of a sharded suite passes" \
        "the sharded path failed on a clean probe"
    fi
    shards_seen="$(sort -n -u "${shard_log}" | tr '\n' ' ')"
    if [[ "${shards_seen}" == "0 1 2 3 4 5 6 7 " ]]; then
      ok "every shard of the sharded suite runs (the union is the full set)"
    else
      bad "every shard of the sharded suite runs (the union is the full set)" \
        "shards seen: ${shards_seen:-<none>}"
    fi

    # A failure in any one shard must fail the whole pass, not be averaged away.
    cat >"${shard_suite}" <<'SHARD_SUITE'
#!/usr/bin/env bash
if [[ "${MUTATION_SHARD}" == "3" ]]; then
  exit 1
fi
exit 0
SHARD_SUITE
    if bash "${shard_runner}" >/dev/null 2>&1; then
      bad "the committed runner fails the pass when one shard fails" \
        "a failing shard was reported as a clean pass"
    else
      ok "the committed runner fails the pass when one shard fails"
    fi

    # A shard that skipped its assertions must degrade the pass exactly as a whole
    # suite does, or a shard missing a prerequisite hides behind a green pass.
    cat >"${shard_suite}" <<'SHARD_SUITE'
#!/usr/bin/env bash
if [[ "${MUTATION_SHARD}" == "5" ]]; then
  printf 'RELEASE_GATE_SUITE_DEGRADED: probe shard\n'
fi
exit 0
SHARD_SUITE
    if bash "${shard_runner}" >/dev/null 2>&1; then
      bad "the committed runner degrades the pass when one shard is degraded" \
        "a skipped shard was reported as a clean pass"
    else
      ok "the committed runner degrades the pass when one shard is degraded"
    fi

    rm -f "${shard_log}"
    rm -rf "${shard_root}"
  else
    bad "the runner's SUITES list can be narrowed to the sharded suite" \
      "the probe could not rewrite the SUITES list; the assertions above did not run"
  fi
else
  bad "run_release_gate_tests.sh exists" "${runner} not found"
fi

# The release gate is fanned out over one job per suite and aggregated by the
# single required check. That shape is what makes one required context mean
# "every suite passed": a matrix leg is its own check name, so requiring each
# leg on its own would mean a ruleset edit per new suite -- and a required
# context that is missing never blocks. The aggregate closes that gap, but only
# if it genuinely gates on the legs. Nothing else in this file reads the matrix
# or the aggregate, so the whole wiring can be deleted while every other
# assertion stays green (issue #97 / #104). These assertions bind the two jobs
# to the driver's own suite list and to each other.
#
# The gate's own step is executed here, not pattern-matched: a substring check
# for `exit 1` is satisfied by a step that exits 0, which is exactly the false
# pass the aggregate exists to prevent.
echo " the release gate is fanned out and the aggregate actually gates"
if ! ci_matrix_checks="$(
  python3 - "${ROOT_DIR}/.github/workflows/ci.yml" "${runner}" "${WORK_DIR}" <<'PYTHON'
import os
import re
import sys

import yaml

ci_path, driver_path, work_dir = sys.argv[1], sys.argv[2], sys.argv[3]
with open(ci_path, encoding="utf-8") as handle:
    ci = yaml.safe_load(handle)
with open(driver_path, encoding="utf-8") as handle:
    driver_source = handle.read()

jobs = ci.get("jobs") or {}


def emit(condition, message, detail=""):
    # One assertion per line, \x1f-separated so the shell can read the message
    # and its detail without splitting on anything a message might contain.
    detail = str(detail).replace("\n", " ")
    print(("ok" if condition else "fail") + "\x1f" + message + "\x1f" + detail)


# The driver's SUITES list, parsed exactly the way the shard probes above parse
# it, so the matrix cannot be declared equal to a stale, hand-copied list.
driver_match = re.search(r"SUITES=\(\n(?:  \S+\n)+\)", driver_source)
driver_suites = []
if driver_match:
    driver_suites = [
        line.strip() for line in driver_match.group(0).splitlines()[1:-1] if line.strip()
    ]
emit(
    bool(driver_suites),
    "run_release_gate_tests.sh declares a parseable, non-empty SUITES list",
    f"parsed {driver_suites}",
)

# The one job whose strategy.matrix carries the suite dimension.
matrix_jobs = {}
for name, spec in jobs.items():
    matrix = ((spec or {}).get("strategy") or {}).get("matrix") or {}
    if isinstance(matrix.get("suite"), list):
        matrix_jobs[name] = spec
emit(
    len(matrix_jobs) == 1,
    "ci.yml has exactly one job whose strategy.matrix fans out suites",
    f"found {sorted(matrix_jobs)}",
)

matrix_name = next(iter(matrix_jobs)) if len(matrix_jobs) == 1 else None
matrix_spec = matrix_jobs.get(matrix_name, {}) if matrix_name else {}
ci_suites = (((matrix_spec.get("strategy") or {}).get("matrix") or {}).get("suite")) or []

emit(
    bool(ci_suites) and sorted(ci_suites) == sorted(driver_suites),
    "the suite matrix lists exactly the driver's SUITES (nothing missing, nothing extra)",
    f"driver={driver_suites} ci={ci_suites}",
)
emit(
    len(ci_suites) == len(set(ci_suites)),
    "the suite matrix lists no suite twice",
    f"ci={ci_suites}",
)

matrix_steps = matrix_spec.get("steps") or []
driver_steps = [
    step for step in matrix_steps if "run_release_gate_tests.sh" in str(step.get("run", ""))
]
emit(
    len(driver_steps) == 1,
    "exactly one matrix step invokes the release-gate driver",
    f"found {len(driver_steps)}",
)
driver_run = str(driver_steps[0].get("run", "")) if len(driver_steps) == 1 else ""
emit(
    re.search(r"--only-suite\s+[\"']?\$\{\{\s*matrix\.suite\s*\}\}", driver_run) is not None,
    'each matrix leg runs exactly its own suite (--only-suite "${{ matrix.suite }}")',
    driver_run,
)
emit(
    ((matrix_spec.get("strategy") or {}).get("fail-fast")) is False,
    "the suite matrix sets fail-fast: false so one red leg still reports the rest",
    f"fail-fast={((matrix_spec.get('strategy') or {}).get('fail-fast'))!r}",
)


def needs_of(spec):
    raw = (spec or {}).get("needs") or []
    if isinstance(raw, str):
        return [raw]
    return list(raw)


aggregators = [
    name
    for name, spec in jobs.items()
    if matrix_name and name != matrix_name and matrix_name in needs_of(spec)
]
emit(
    len(aggregators) == 1,
    "exactly one job aggregates the suite matrix through needs:",
    f"found {aggregators}",
)

agg_name = aggregators[0] if len(aggregators) == 1 else None
agg_spec = jobs.get(agg_name, {}) if agg_name else {}
agg_if = str(agg_spec.get("if", ""))
# The aggregate must run even when a leg fails, and for that reason alone: it is
# the single REQUIRED check, and GitHub reports a skipped required job as
# Success. A substring test for `!cancelled()` is satisfied by
# `!cancelled() || true` and by
# `!cancelled() && github.event_name != 'pull_request'`, both of which can skip
# the required job while still containing the token. So the expression is
# normalised -- whitespace removed, an optional `${{ }}` wrapper stripped -- and
# compared against the one safe value instead of being searched for the token.
normalized_agg_if = re.sub(r"\s+", "", agg_if)
if normalized_agg_if.startswith("${{") and normalized_agg_if.endswith("}}"):
    normalized_agg_if = normalized_agg_if[3:-2]
emit(
    normalized_agg_if == "!cancelled()",
    "the aggregate runs even when a leg fails (its job-if is exactly !cancelled())",
    f"if={agg_if!r}",
)

result_expr = f"needs.{matrix_name}.result" if matrix_name else ""
result_steps = []
for step in agg_spec.get("steps") or []:
    env = step.get("env") or {}
    if result_expr and any(result_expr in str(value) for value in env.values()):
        result_steps.append(step)
emit(
    bool(result_steps),
    "the aggregate binds needs.<matrix>.result so it can check the legs",
    f"found {len(result_steps)} step(s)",
)

result_run = str(result_steps[0].get("run", "")) if result_steps else ""
emit(
    "exit 1" in result_run and "success" in result_run,
    "the aggregate's result step fails unless every leg reported success",
    result_run,
)

# Hand the extracted run and its env var to the shell so it can be EXECUTED, not
# merely inspected.
if result_steps:
    env = result_steps[0].get("env") or {}
    var = next((k for k, v in env.items() if result_expr and result_expr in str(v)), "")
    with open(os.path.join(work_dir, "agg_result_gate.sh"), "w", encoding="utf-8") as handle:
        handle.write(result_run)
    with open(os.path.join(work_dir, "agg_result_var"), "w", encoding="utf-8") as handle:
        handle.write(var)

# Job-level `continue-on-error` is the same hole one level up: it marks the
# whole gate job green even when one of its steps failed, so the single REQUIRED
# check reports Success with a failed leg behind it. Only the step-level keys
# were checked until now.
gate_offenders = []
for gate_job in [name for name in (matrix_name, agg_name) if name]:
    gate_spec = jobs.get(gate_job, {}) or {}
    if gate_spec.get("continue-on-error"):
        gate_offenders.append(f"{gate_job}: (job-level)")
    for step in gate_spec.get("steps") or []:
        if step.get("continue-on-error"):
            gate_offenders.append(f"{gate_job}: {step.get('name') or step.get('uses') or '(run)'}")
emit(
    not gate_offenders,
    "no release-gate job hides a failure behind continue-on-error",
    f"offenders={gate_offenders}",
)
PYTHON
)"; then
  bad "the release-gate matrix checker ran to completion" \
    "the embedded python exited non-zero; the structural assertions are incomplete"
fi
while IFS=$'\x1f' read -r verdict message detail; do
  [[ -n "${verdict}" ]] || continue
  if [[ "${verdict}" == "ok" ]]; then
    ok "${message}"
  else
    bad "${message}" "${detail}"
  fi
done <<<"${ci_matrix_checks}"

# Execute the aggregate's result gate with a failed and a clean outcome. The
# structural check above is satisfied by a step that runs `exit 1` inside a
# branch that can never be taken; running it is what proves a failed leg is
# actually refused.
agg_gate="${WORK_DIR}/agg_result_gate.sh"
agg_var_file="${WORK_DIR}/agg_result_var"
if [[ -s "${agg_gate}" && -s "${agg_var_file}" ]]; then
  agg_var="$(cat "${agg_var_file}")"
  if env "${agg_var}=failure" bash "${agg_gate}" >/dev/null 2>&1; then
    bad "the aggregate result gate fails a leg that failed" \
      "the committed step exited 0 for result=failure"
  else
    ok "the aggregate result gate fails a leg that failed"
  fi
  if env "${agg_var}=success" bash "${agg_gate}" >/dev/null 2>&1; then
    ok "the same result gate passes when every leg succeeded (not vacuous)"
  else
    bad "the same result gate passes when every leg succeeded (not vacuous)" \
      "the committed step exited non-zero for result=success"
  fi
else
  bad "the aggregate result gate can be executed" \
    "no env-bound result step was extracted from the aggregate"
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
# The verification job holds the re-verification; the publish job holds the file
# list. They are different jobs now, and the `release` -> `android-verify` edge is
# what keeps "verified" and "attached" referring to the same bytes. Both are read
# here so the chain is checked end to end rather than one half at a time.
verify_steps = workflow["jobs"]["android-verify"].get("steps", []) or []
publish_steps = workflow["jobs"]["release"].get("steps", []) or []
runs = [
    str(step.get("run", ""))
    for step in verify_steps
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
  ok "the verify job re-verifies the APK from the artifact root"
else
  bad "the verify job re-verifies the APK from the artifact root" \
    "the verify job does not verify apk/app-release.apk"
fi

echo " the job that publishes re-verifies what it publishes"
# The build job runs the signature gate and the smoke job installs the APK, so
# publication is already downstream of two checks. This asserts the third,
# independent one: a job on its own runner, with its own checkout of the gate
# script, re-derives the checksum and the signature from the exact artifact that
# is about to become a download. Without it, a mismatch between what was verified
# and what is published would be invisible until a user hit "App not installed"
# again.
#
# The invariant changed shape when publication moved to one job. It used to be
# "the re-verify step comes before the publish step", which is an in-step
# ordering inside a single job. It is now a cross-job chain, and all three links
# have to hold or the guarantee is gone:
#
#   1. `android-verify` re-derives the checksum and signature (the same code as
#      before, unchanged);
#   2. `release` needs `android-verify`, so it cannot attach those bytes until the
#      re-derivation is green;
#   3. what `release` attaches is what `android-verify` verified -- which is no
#      longer a literal path list, because the artifacts are staged into `dist/`.
#      It is now the staging step that decides, so that is what is asserted.
#
# Link 3 is the one that needed care. The old check listed
# `apk/app-release.apk` and friends as full lines in `files:` and was found by
# mutation: dropping the APK from the list left every check green. Staging
# replaced that list, so the equivalent assertion is that the staging step copies
# every file from every platform directory without filtering, and that the publish
# step attaches exactly the staged directory.
publish_checks="$(python3 - "${WORKFLOW}" <<'PYTHON'
import sys

import yaml

with open(sys.argv[1], encoding="utf-8") as handle:
    workflow = yaml.safe_load(handle)
jobs = workflow["jobs"]
steps = jobs["android-verify"].get("steps", []) or []


def as_list(raw):
    return [raw] if isinstance(raw, str) else list(raw or [])


results = {}
for step in steps:
    if not isinstance(step, dict):
        continue
    name = str(step.get("name", ""))
    run = str(step.get("run", ""))
    if "Re-verify" in name:
        results["present"] = True
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
        results["empty-input"] = "::error::refusing to release" in code
    # All three files, not just the APK: the checksum is what the user verifies
    # with, and the signature transcript is the certificate audit trail. A
    # release missing any of them degrades what "verified" means in practice.
    if "android_release_verify_signature.sh" in run:
        # Comments are stripped first, for the reason spelled out above: the only
        # occurrence of `apksigner-verify.txt` in this block was a comment quoting it,
        # so a naive search passed on the explanation and failed on the code. Verified
        # by deleting just that comment line -- the assertion went red.
        #
        # Note what this does and does not claim. The job does NOT read
        # `apksigner-verify.txt`; it writes its own transcript into a scratch dir from
        # a fresh `mktemp -d` and greps that for a certificate digest. So the assertion
        # is that the APK and its checksum are both consumed, and that a digest is
        # demanded from the re-derivation -- not that a shipped file is re-read.
        results["all-three-present"] = all(
            quoted in code
            for quoted in (
                'APK="apk/app-release.apk"',
                "apk/app-release.apk.sha256",
            )
        )
        results["fresh-transcript"] = (
            "mktemp -d" in code and "certificate SHA-256 digest" in code
        )

results.setdefault("present", False)
for key in ("checksum", "signature", "empty-input", "all-three-present", "fresh-transcript"):
    results.setdefault(key, False)

# Link 2: the ordering, now expressed as the dependency edge.
results["gated"] = "android-verify" in as_list(jobs["release"].get("needs"))

# Link 3: what is published is what was verified.
release_steps = jobs["release"].get("steps", []) or []
publish_files = " ".join(
    str(step.get("with", {}).get("files", ""))
    for step in release_steps
    if isinstance(step, dict) and "action-gh-release" in str(step.get("uses", ""))
)
results["attaches"] = "dist/*" in publish_files
results["stages-everything"] = any(
    "refusing to publish a partial release" in str(step.get("run", ""))
    and "find \"incoming/${platform}\" -type f -size +0c" in str(step.get("run", ""))
    for step in release_steps
    if isinstance(step, dict)
)
results["downloads-android"] = any(
    str((step.get("with") or {}).get("name", "")) == "android-artifact"
    for step in release_steps
    if isinstance(step, dict) and "download-artifact" in str(step.get("uses", ""))
)
for key, value in results.items():
    print(f"{key}\t{'yes' if value else 'no'}")
PYTHON
)"
for required in present checksum signature empty-input all-three-present fresh-transcript gated attaches stages-everything downloads-android; do
  value="$(printf '%s\n' "${publish_checks}" | grep "^${required}	" | cut -f2 | head -n 1)"
  case "${required}" in
    gated)
      if [[ "${value}" == "yes" ]]; then
        ok "the release cannot attach the APK before the verify job re-verifies it"
      else
        bad "the release cannot attach the APK before the verify job re-verifies it" \
          "\`release\` does not need \`android-verify\`, so the re-verified bytes are not what gate the publication"
      fi
      ;;
    stages-everything)
      if [[ "${value}" == "yes" ]]; then
        ok "the staging step copies every file from every platform directory"
      else
        bad "the staging step copies every file from every platform directory" \
          "the staging step does not enumerate all files per platform, so an artifact can be verified and never published"
      fi
      ;;
    downloads-android)
      if [[ "${value}" == "yes" ]]; then
        ok "the release downloads the android artifact the verify job checked"
      else
        bad "the release downloads the android artifact the verify job checked" \
          "\`release\` does not download \`android-artifact\`"
      fi
      ;;
    attaches)
      if [[ "${value}" == "yes" ]]; then
        ok "the release attaches the same APK the verify job re-verified"
      else
        bad "the release attaches the same APK the verify job re-verified" \
          "the publish step does not attach the staged directory, so the verified bytes are not necessarily the published bytes"
      fi
      ;;
    all-three-present)
      if [[ "${value}" == "yes" ]]; then
        ok "the verify job consumes both the APK and its checksum, from live code"
      else
        bad "the verify job consumes both the APK and its checksum, from live code" \
          "the APK or its checksum is not checked before publication (and the previous check could be satisfied by a comment quoting the filename)"
      fi
      ;;
    fresh-transcript)
      if [[ "${value}" == "yes" ]]; then
        ok "the verify job demands a certificate digest from its own fresh transcript"
      else
        bad "the verify job demands a certificate digest from its own fresh transcript" \
          "the re-verification does not write a transcript to a scratch dir, or does not require a certificate digest from it -- so the signature check could pass having proved nothing"
      fi
      ;;
    present)
      if [[ "${value}" == "yes" ]]; then
        ok "the publish job has a re-verification step"
      else
        bad "the publish job has a re-verification step" "no step named 'Re-verify' in android-verify"
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

echo " the staging step is run, not grepped"
# String presence is not evidence that a guard is live. The staging step's two
# refusals are printed by branches; replacing the collision guard with `if false`
# leaves every one of those strings in place, so a suite that greps for them
# reports a guarantee that does not exist. The step body is extracted and executed
# instead, against synthetic artifact trees.
#
# This is the same discipline the key-cleanup check above uses, and for the same
# reason: a `set -e`-free step with a wrong path would otherwise exit 0 while
# doing nothing.
staging_probe="$(python3 - "${WORKFLOW}" <<'PYTHON'
import sys

import yaml

with open(sys.argv[1], encoding="utf-8") as handle:
    workflow = yaml.safe_load(handle)
for step in workflow["jobs"]["release"].get("steps", []) or []:
    if not isinstance(step, dict):
        continue
    if "refusing to publish a partial release" in str(step.get("run", "")):
        sys.stdout.write("---SCRIPT---\n")
        sys.stdout.write(str(step.get("run", "")))
        sys.stdout.write("\n")
        break
else:
    print("MISSING")
PYTHON
)"
if [[ "$(tail -n 1 <<<"${staging_probe}")" == "MISSING" ]]; then
  bad "the release stages every platform artifact before publishing" \
    "the release job has no staging step that refuses a partial release"
else
  ok "the release stages every platform artifact before publishing"
  staging_script="${WORK_DIR}/staging.sh"
  printf '%s\n' "${staging_probe}" | sed -n '/^---SCRIPT---$/,$p' | tail -n +2 >"${staging_script}"

  # Seed a complete tree. Every probe below mutates one copy of it.
  seed_complete() {
    local root="$1"
    rm -rf "${root}"
    local platform
    for platform in android linux windows macos ios; do
      mkdir -p "${root}/incoming/${platform}"
      printf 'payload-%s\n' "${platform}" >"${root}/incoming/${platform}/${platform}.bin"
    done
  }

  seed_complete "${WORK_DIR}/stage-complete"
  if ( cd "${WORK_DIR}/stage-complete" && bash "${staging_script}" ) \
      >"${WORK_DIR}/stage-complete.log" 2>&1 &&
    [[ "$(find "${WORK_DIR}/stage-complete/dist" -type f 2>/dev/null | wc -l)" -eq 5 ]]; then
    ok "a complete artifact set is staged"
  else
    bad "a complete artifact set is staged" \
      "$(tr '\n' '|' <"${WORK_DIR}/stage-complete.log" 2>/dev/null)"
  fi

  # A platform directory that is absent entirely: the case an artifact rename or a
  # failed upload produces.
  seed_complete "${WORK_DIR}/stage-missing"
  rm -rf "${WORK_DIR}/stage-missing/incoming/macos"
  if ( cd "${WORK_DIR}/stage-missing" && bash "${staging_script}" ) \
      >"${WORK_DIR}/stage-missing.log" 2>&1; then
    bad "a missing platform directory refuses the release" \
      "the step exited 0 with incoming/macos absent"
  elif ! grep -qF 'refusing to publish a partial release' "${WORK_DIR}/stage-missing.log"; then
    bad "a missing platform directory refuses the release" \
      "the step failed but not with the partial-release refusal: $(tr '\n' '|' <"${WORK_DIR}/stage-missing.log")"
  else
    ok "a missing platform directory refuses the release"
  fi

  # A platform whose every file is zero bytes. This is the assertion the
  # `-size +0c` exists for, and a plain `-type f` would sail past it.
  seed_complete "${WORK_DIR}/stage-zero"
  rm -f "${WORK_DIR}/stage-zero/incoming/windows/windows.bin"
  : >"${WORK_DIR}/stage-zero/incoming/windows/truncated.zip"
  if ( cd "${WORK_DIR}/stage-zero" && bash "${staging_script}" ) \
      >"${WORK_DIR}/stage-zero.log" 2>&1; then
    bad "a platform whose only file is empty refuses the release" \
      "the step exited 0 with windows contributing nothing but a zero-byte file"
  else
    ok "a platform whose only file is empty refuses the release"
  fi

  # Two platforms producing the same basename. The release action uploads by
  # basename, so without this guard one platform's artifact silently replaces the
  # other's and the release carries the wrong bytes under a plausible name.
  #
  # The clash has to be *two files with one name in two directories*. Copying one
  # file to a second directory just produces a single file, which stages fine --
  # and that is the mistake the first version of this probe made, so it is called
  # out here rather than left to be rediscovered.
  seed_complete "${WORK_DIR}/stage-clash"
  printf 'android-payload\n' >"${WORK_DIR}/stage-clash/incoming/android/shared.bin"
  printf 'ios-payload\n' >"${WORK_DIR}/stage-clash/incoming/ios/shared.bin"
  if ( cd "${WORK_DIR}/stage-clash" && bash "${staging_script}" ) \
      >"${WORK_DIR}/stage-clash.log" 2>&1; then
    bad "two artifacts sharing a basename refuse the release" \
      "the step exited 0 and would have published one platform's file as another's"
  elif ! grep -qF 'overwrite the other' "${WORK_DIR}/stage-clash.log"; then
    bad "two artifacts sharing a basename refuse the release" \
      "the step failed but not with the collision refusal: $(tr '\n' '|' <"${WORK_DIR}/stage-clash.log")"
  else
    ok "two artifacts sharing a basename refuse the release"
  fi

  # Deliberate behaviour, pinned: a zero-byte file travelling *beside* a real one is
  # dropped from the release rather than published. Shipping a 0-byte artifact is
  # worse than shipping none, and the release is already refused outright when a
  # platform contributes nothing at all, so nothing is silently lost.
  seed_complete "${WORK_DIR}/stage-mixed"
  : >"${WORK_DIR}/stage-mixed/incoming/macos/empty.dmg"
  if ( cd "${WORK_DIR}/stage-mixed" && bash "${staging_script}" ) \
      >"${WORK_DIR}/stage-mixed.log" 2>&1 &&
    [[ ! -e "${WORK_DIR}/stage-mixed/dist/empty.dmg" ]] &&
    [[ -e "${WORK_DIR}/stage-mixed/dist/macos.bin" ]]; then
    ok "a zero-byte file is dropped from the release, not published"
  else
    bad "a zero-byte file is dropped from the release, not published" \
      "$(tr '\n' '|' <"${WORK_DIR}/stage-mixed.log" 2>/dev/null)"
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
