#!/usr/bin/env python3
"""Candidate isolation mutations and real artifact-receipt verification."""

import copy
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = yaml.safe_load((ROOT / ".github/workflows/release.yml").read_text())


def validate(workflow):
    jobs = workflow["jobs"]
    release = jobs["release"]
    candidate = jobs.get("candidate-validation", {})
    auth = jobs.get("tag-release-authorization", {})
    failures = []

    def require(condition, name):
        if not condition:
            failures.append(name)

    require("workflow_dispatch" in workflow.get("on", workflow.get(True, {})), "manual trigger")
    require(auth.get("if") == "github.event_name == 'push' && startsWith(github.ref, 'refs/tags/v')", "tag authorization")
    require("tag-release-authorization" in release["needs"], "publication dependency")
    require(not release.get("if") and not release.get("continue-on-error"), "publisher success gate")
    require(candidate.get("if") == "github.event_name == 'workflow_dispatch'", "candidate event")
    require(set(candidate.get("needs", [])) == set(release["needs"]) - {"tag-release-authorization"}, "candidate gates")
    require(candidate.get("permissions", {}).get("contents") == "read", "candidate read only")
    require(not candidate.get("continue-on-error"), "candidate fail closed")

    def downloads(job):
        return [dict(step["with"], path=str(Path(step["with"]["path"])))
                for step in job["steps"] if "download-artifact" in step.get("uses", "")]

    def staging(job):
        if any(step.get("run") == "bash scripts/stage_release_candidate.sh" for step in job["steps"]):
            return ["\n".join((ROOT / "scripts/stage_release_candidate.sh").read_text().splitlines()[2:]) + "\n"]
        return [step["run"] for step in job["steps"] if "refusing to publish a partial release" in step.get("run", "")]

    require(downloads(candidate) == downloads(release), "same artifact downloads")
    require(staging(candidate) == staging(release) and len(staging(release)) == 1, "same artifact staging")
    for name, job in (("candidate", candidate), ("release", release)):
        steps = job["steps"]
        receipt = [i for i, step in enumerate(steps) if step.get("run") == "python3 scripts/release_artifact_receipt.py dist"]
        require(len(receipt) == 1 and receipt[0] == len(steps) - 2, name + " receipt before delivery")
        require(not any(step.get("if") or step.get("continue-on-error") for step in steps), name + " steps fail closed")
    upload = candidate["steps"][-1]
    require("upload-artifact" in upload.get("uses", "") and upload.get("with", {}).get("path") == "dist/*" and upload.get("with", {}).get("if-no-files-found") == "error", "candidate evidence")
    require("release-candidate-evidence" in upload.get("with", {}).get("name", ""), "candidate evidence name")
    require(workflow.get("env", {}).get("RELEASE_LABEL") == "${{ github.event_name == 'push' && github.ref_name || format('v0.0.0-candidate.{0}', github.run_id) }}", "candidate package version")
    return failures


class CandidateTests(unittest.TestCase):
    def test_publisher_mutation_scope_with_duplicate_candidate(self):
        harness = (ROOT / "scripts/tests/release_atomic_publish_mutation_test.sh").read_text()
        helper = harness[harness.index("apply() {"):harness.index("# preflight <file>")]
        fixture = """jobs:
  candidate-validation:
    needs:
      - linux
  release:
    needs:
      - linux
  following:
    needs:
      - linux
"""
        old, new = "      - linux", "      - windows"
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "workflow.yml"
            path.write_text(fixture)

            def apply(scope):
                return subprocess.run(
                    ["bash", "-c", helper + '\napply "$1" "$2" "$3" "$4"',
                     "scope-probe", str(path), old, new, scope], capture_output=True
                )

            self.assertNotEqual(apply("").returncode, 0)
            self.assertEqual(path.read_text(), fixture)
            self.assertEqual(apply("release").returncode, 0)
            jobs = yaml.safe_load(path.read_text())["jobs"]
            self.assertEqual(jobs["candidate-validation"]["needs"], ["linux"])
            self.assertEqual(jobs["release"]["needs"], ["windows"])
            self.assertEqual(jobs["following"]["needs"], ["linux"])
            changed = path.read_text()
            self.assertNotEqual(apply("missing").returncode, 0)
            self.assertEqual(path.read_text(), changed)
            path.write_text(fixture.replace("  release:\n    needs:\n      - linux", "  release:\n    needs:\n      - linux\n      - linux"))
            ambiguous = path.read_text()
            self.assertNotEqual(apply("release").returncode, 0)
            self.assertEqual(path.read_text(), ambiguous)

    def test_committed_workflow(self):
        self.assertEqual(validate(WORKFLOW), [])

    def test_mutations_bite_by_name(self):
        mutations = [
            ("tag authorization", lambda w: w["jobs"]["tag-release-authorization"].update({"if": "always()"})),
            ("publication dependency", lambda w: w["jobs"]["release"]["needs"].remove("tag-release-authorization")),
            ("same artifact staging", lambda w: w["jobs"]["candidate-validation"]["steps"][-3].update({"run": "true"})),
            ("candidate gates", lambda w: w["jobs"]["candidate-validation"]["needs"].remove("ios")),
            ("candidate read only", lambda w: w["jobs"]["candidate-validation"]["permissions"].update({"contents": "write"})),
            ("candidate fail closed", lambda w: w["jobs"]["candidate-validation"].update({"continue-on-error": True})),
            ("candidate receipt before delivery", lambda w: w["jobs"]["candidate-validation"]["steps"].pop(-2)),
            ("release receipt before delivery", lambda w: w["jobs"]["release"]["steps"].pop(-2)),
            ("candidate evidence", lambda w: w["jobs"]["candidate-validation"]["steps"][-1]["with"].update({"if-no-files-found": "warn"})),
            ("candidate package version", lambda w: w["env"].update({"RELEASE_LABEL": "${{ github.ref_name }}"})),
        ]
        for name, mutate in mutations:
            with self.subTest(mutation=name):
                changed = copy.deepcopy(WORKFLOW)
                mutate(changed)
                self.assertIn(name, validate(changed))

    def test_receipt_and_manifest_bytes(self):
        for event, ref in (("workflow_dispatch", "refs/heads/main"), ("push", "refs/tags/v1.0.0")):
            with self.subTest(event=event), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                for platform in ("linux", "windows", "macos", "android", "ios"):
                    (root / (platform + ".zip")).write_bytes(platform.encode())
                env = dict(os.environ, GITHUB_SHA="a" * 40, GITHUB_EVENT_NAME=event, GITHUB_REF=ref,
                           GITHUB_RUN_ID="123", GITHUB_RUN_ATTEMPT="2", GITHUB_REPOSITORY="test/repo")
                env.pop("GITHUB_STEP_SUMMARY", None)
                result = subprocess.run(["python3", str(ROOT / "scripts/release_artifact_receipt.py"), temp], env=env, capture_output=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                receipt = json.loads((root / "release-receipt.json").read_text())
                self.assertEqual(receipt["source_commit"], "a" * 40)
                self.assertEqual(receipt["publication_eligible"], event == "push")
                self.assertEqual(len(receipt["artifacts"]), 5)
                manifest = (root / "SHA256SUMS").read_text().splitlines()
                self.assertEqual({line.split("  ")[1] for line in manifest}, {p.name for p in root.iterdir()} - {"SHA256SUMS"})
                for line in manifest:
                    digest, name = line.split("  ")
                    self.assertEqual(digest, hashlib.sha256((root / name).read_bytes()).hexdigest())
                checked = subprocess.run(["sha256sum", "-c", "SHA256SUMS"], cwd=root, capture_output=True)
                self.assertEqual(checked.returncode, 0, checked.stderr)
                (root / "ios.zip").write_bytes(b"tampered")
                checked = subprocess.run(["sha256sum", "-c", "SHA256SUMS"], cwd=root, capture_output=True)
                self.assertNotEqual(checked.returncode, 0)

    def test_receipt_refuses_invalid_inputs(self):
        for kind in ("empty", "zero", "directory", "symlink", "reserved", "newline", "missing-sha", "branch-push"):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                env = dict(os.environ, GITHUB_SHA="a" * 40, GITHUB_EVENT_NAME="workflow_dispatch", GITHUB_REF="refs/heads/main", GITHUB_RUN_ID="1", GITHUB_RUN_ATTEMPT="1", GITHUB_REPOSITORY="test/repo")
                env.pop("GITHUB_STEP_SUMMARY", None)
                if kind != "empty":
                    (root / "valid.zip").write_bytes(b"payload")
                if kind == "zero":
                    (root / "zero.zip").touch()
                elif kind == "directory":
                    (root / "nested").mkdir()
                elif kind == "symlink":
                    (root / "link.zip").symlink_to(root / "valid.zip")
                elif kind == "reserved":
                    (root / "SHA256SUMS").write_bytes(b"collision")
                elif kind == "newline":
                    (root / "bad\nname").write_bytes(b"payload")
                elif kind == "missing-sha":
                    env.pop("GITHUB_SHA")
                elif kind == "branch-push":
                    env["GITHUB_EVENT_NAME"] = "push"
                result = subprocess.run(["python3", str(ROOT / "scripts/release_artifact_receipt.py"), temp], env=env, capture_output=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((root / "release-receipt.json").exists())


if __name__ == "__main__":
    unittest.main()
