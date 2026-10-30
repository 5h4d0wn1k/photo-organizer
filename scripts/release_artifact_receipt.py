#!/usr/bin/env python3
"""Record the exact flat, staged release set without reading signing material."""

import hashlib
import json
import os
from pathlib import Path
import re
import sys


def main():
    root = Path(sys.argv[1])
    sha = os.environ.get("GITHUB_SHA", "")
    event = os.environ.get("GITHUB_EVENT_NAME", "")
    ref = os.environ.get("GITHUB_REF", "")
    if not re.fullmatch(r"[0-9a-f]{40}", sha):
        raise ValueError("receipt requires the exact source commit")
    if event not in {"push", "workflow_dispatch"}:
        raise ValueError("unsupported release event")
    if event == "push" and not ref.startswith("refs/tags/v"):
        raise ValueError("publication receipt requires a version tag")
    files = sorted(root.iterdir())
    if not files:
        raise ValueError("refusing an empty artifact set")
    digests = {}
    for path in files:
        if (
            path.name in {"SHA256SUMS", "release-receipt.json"}
            or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._+-]*", path.name)
            or path.is_symlink()
            or not path.is_file()
            or path.stat().st_size == 0
        ):
            raise ValueError("invalid or reserved artifact: " + path.name)
        digest = hashlib.sha256()
        with path.open("rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
        digests[path.name] = {"sha256": digest.hexdigest(), "bytes": path.stat().st_size}
    receipt = {
        "source_commit": sha,
        "ref": ref,
        "event": event,
        "run_id": os.environ["GITHUB_RUN_ID"],
        "run_attempt": os.environ["GITHUB_RUN_ATTEMPT"],
        "repository": os.environ["GITHUB_REPOSITORY"],
        "publication_eligible": event == "push",
        "artifacts": digests,
    }
    receipt_path = root / "release-receipt.json"
    receipt_path.write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n")
    receipt_digest = hashlib.sha256(receipt_path.read_bytes()).hexdigest()
    lines = [f"{value['sha256']}  {name}\n" for name, value in digests.items()]
    lines.append(f"{receipt_digest}  release-receipt.json\n")
    (root / "SHA256SUMS").write_text("".join(lines))
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as handle:
            handle.write(
                f"### Validated {'tag' if event == 'push' else 'nonpublishing candidate'}\n\n"
                f"Source: `{sha}`; run `{receipt['run_id']}` attempt `{receipt['run_attempt']}`.\n\n"
                "All five platform build/smoke dependencies passed. "
                "`SHA256SUMS` covers every staged file and the source receipt. "
                "Hardware, feature, signing continuity and recovery acceptance remain separate.\n"
            )
    print(f"Recorded {len(digests)} artifacts from source {sha}; SHA256SUMS includes receipt")


if __name__ == "__main__":
    main()
