#!/usr/bin/env python3
"""Index the cleaned local archive into the gallery daemon by reference.

This does not move, copy, upload, or delete media. It asks the local daemon to
scan organized folders, then commits all selected non-duplicate candidates in
reference mode so the app can build timeline/place/event/search views.
"""

from __future__ import annotations

import argparse
import json
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


DEFAULT_API_BASE = "http://127.0.0.1:4821"
DEFAULT_MANIFEST_DIR = Path("/mnt/windows/transfer/Ok/Photos/PrivateGalleryLibrary/import_manifests")
DEFAULT_SOURCES = [
    {
        "label": "organized_photos",
        "source_path": "/mnt/windows/transfer/Ok/Photos/Unfiltered",
        "place_hint": "Local organized photos",
        "add_as_watch_folder": True,
    },
    {
        "label": "organized_videos",
        "source_path": "/mnt/windows/transfer/Ok/video",
        "place_hint": "Local organized videos",
        "add_as_watch_folder": True,
    },
]


def utc_stamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def post_json(api_base: str, path: str, body: dict[str, Any]) -> dict[str, Any]:
    request = urllib.request.Request(
        f"{api_base}{path}",
        data=json.dumps(body).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=None) as response:
            return json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as error:
        detail = error.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"POST {path} failed with {error.code}: {detail}") from error


def get_json(api_base: str, path: str) -> dict[str, Any]:
    with urllib.request.urlopen(f"{api_base}{path}", timeout=30) as response:
        return json.loads(response.read().decode("utf-8"))


def compact_session(session: dict[str, Any]) -> dict[str, Any]:
    candidates = session.get("candidates") or []
    return {
        "id": session.get("id"),
        "source_path": session.get("source_path"),
        "import_mode": session.get("import_mode"),
        "status": session.get("status"),
        "created_at": session.get("created_at"),
        "completed_at": session.get("completed_at"),
        "candidate_count": len(candidates),
        "selected_candidate_count": session.get("selected_candidate_count", 0),
        "selected_bytes": session.get("selected_bytes", 0),
        "duplicate_count": session.get("duplicate_count", 0),
        "unsupported_count": session.get("unsupported_count", 0),
        "sidecar_count": session.get("sidecar_count", 0),
        "imported_asset_count": len(session.get("imported_asset_ids") or []),
        "moved_asset_count": len(session.get("moved_asset_ids") or []),
        "skipped_duplicate_count": len(session.get("skipped_duplicate_ids") or []),
        "failed_candidate_count": len(session.get("failed_candidate_ids") or []),
        "sidecars_moved": session.get("sidecars_moved", 0),
        "source_contains_managed_library": session.get("source_contains_managed_library", False),
    }


def index_source(api_base: str, source: dict[str, Any]) -> dict[str, Any]:
    scan = post_json(
        api_base,
        "/imports/scan",
        {
            "source_path": source["source_path"],
            "source_kind": "folder",
            "import_mode": "reference",
            "add_as_watch_folder": source["add_as_watch_folder"],
            "place_hint": source["place_hint"],
            "recursive": True,
        },
    )
    committed = post_json(
        api_base,
        "/imports/commit",
        {
            "session_id": scan["id"],
            "selected_candidate_ids": [],
            "import_mode": "reference",
            "add_as_watch_folder": source["add_as_watch_folder"],
        },
    )
    return {
        "label": source["label"],
        "scan": compact_session(scan),
        "commit": compact_session(committed),
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--api-base", default=DEFAULT_API_BASE)
    parser.add_argument("--manifest-dir", type=Path, default=DEFAULT_MANIFEST_DIR)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    health = get_json(args.api_base, "/health")
    if health.get("status") != "ok":
        raise RuntimeError(f"Daemon health check failed: {health}")

    args.manifest_dir.mkdir(parents=True, exist_ok=True)
    results = []
    for source in DEFAULT_SOURCES:
        print(f"Indexing {source['label']}: {source['source_path']}", flush=True)
        results.append(index_source(args.api_base, source))

    diagnostics = get_json(args.api_base, "/diagnostics")
    status = get_json(args.api_base, "/library/status")
    summary = {
        "mode": "reference_index",
        "created_at": datetime.now(timezone.utc).isoformat(),
        "results": results,
        "diagnostics": diagnostics,
        "library_status": status,
    }
    output = args.manifest_dir / f"index-organized-library-{utc_stamp()}.summary.json"
    output.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps(summary, indent=2, sort_keys=True))
    print(f"Summary JSON: {output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
