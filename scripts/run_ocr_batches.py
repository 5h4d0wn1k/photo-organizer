#!/usr/bin/env python3
"""Run safe local OCR indexing batches against the gallery daemon.

This script never moves, deletes, uploads, or downloads media. It only calls the
loopback daemon's `/ocr/rebuild` endpoint with a small explicit batch size, then
prints OCR coverage before and after each batch.
"""

from __future__ import annotations

import argparse
import json
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


DEFAULT_API_BASE = "http://127.0.0.1:4821"
DEFAULT_MANIFEST_DIR = Path(
    "/mnt/windows/transfer/Ok/Photos/PrivateGalleryLibrary/ocr_manifests"
)


def utc_stamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def get_json(api_base: str, path: str, timeout: int = 30) -> dict[str, Any]:
    try:
        with urllib.request.urlopen(f"{api_base}{path}", timeout=timeout) as response:
            return json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as error:
        detail = error.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"GET {path} failed with {error.code}: {detail}") from error


def post_json(
    api_base: str, path: str, body: dict[str, Any], timeout: int
) -> dict[str, Any]:
    request = urllib.request.Request(
        f"{api_base}{path}",
        data=json.dumps(body).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as error:
        detail = error.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"POST {path} failed with {error.code}: {detail}") from error


def validate_privacy_status(api_base: str) -> dict[str, Any]:
    privacy = get_json(api_base, "/privacy/status")
    encryption = privacy.get("encryption") or {}
    problems = []
    if not privacy.get("loopback_only"):
        problems.append("daemon is not loopback-only")
    if privacy.get("photo_processing_network_allowed"):
        problems.append("photo processing network access is enabled")
    if privacy.get("cloud_ai_enabled"):
        problems.append("cloud AI is enabled")
    if not encryption.get("sensitive_indexing_allowed"):
        problems.append("encrypted sensitive indexing is not allowed")
    if problems:
        raise RuntimeError("Refusing OCR batch: " + "; ".join(problems))
    return privacy


def compact_status(status: dict[str, Any]) -> dict[str, Any]:
    return {
        "ocr_ready": status.get("ocr_ready", False),
        "ocr_text_block_count": status.get("ocr_text_block_count", 0),
        "ocr_indexed_asset_count": status.get("ocr_indexed_asset_count", 0),
        "ocr_total_photo_count": status.get("ocr_total_photo_count", 0),
        "ocr_remaining_photo_count": status.get("ocr_remaining_photo_count", 0),
        "detail": status.get("detail", ""),
    }


def print_status(label: str, status: dict[str, Any]) -> None:
    compact = compact_status(status)
    print(
        "{label}: {indexed}/{total} photo assets OCR-processed, "
        "{text} searchable text blocks, {remaining} remaining".format(
            label=label,
            indexed=compact["ocr_indexed_asset_count"],
            total=compact["ocr_total_photo_count"],
            text=compact["ocr_text_block_count"],
            remaining=compact["ocr_remaining_photo_count"],
        ),
        flush=True,
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--api-base", default=DEFAULT_API_BASE)
    parser.add_argument("--batch-size", type=int, default=10)
    parser.add_argument("--max-batches", type=int, default=1)
    parser.add_argument("--sleep-seconds", type=float, default=0)
    parser.add_argument("--request-timeout", type=int, default=900)
    parser.add_argument("--manifest-dir", type=Path, default=DEFAULT_MANIFEST_DIR)
    parser.add_argument(
        "--status-only",
        action="store_true",
        help="Print OCR coverage and exit without starting OCR.",
    )
    parser.add_argument(
        "--yes",
        action="store_true",
        help="Confirm larger OCR runs. Required for batch-size > 10 or max-batches > 1.",
    )
    return parser.parse_args()


def validate_args(args: argparse.Namespace) -> None:
    if args.batch_size < 1:
        raise RuntimeError("--batch-size must be at least 1")
    if args.max_batches < 1:
        raise RuntimeError("--max-batches must be at least 1")
    if not args.status_only and (args.batch_size > 10 or args.max_batches > 1) and not args.yes:
        raise RuntimeError(
            "Refusing larger OCR run without --yes. Start with the default one "
            "batch of 10, or pass --yes after reviewing CPU/runtime impact."
        )


def main() -> int:
    args = parse_args()
    validate_args(args)

    health = get_json(args.api_base, "/health")
    if health.get("status") != "ok":
        raise RuntimeError(f"Daemon health check failed: {health}")
    privacy = validate_privacy_status(args.api_base)

    before = get_json(args.api_base, "/search/status")
    print_status("Before", before)
    if args.status_only:
        print(json.dumps({"privacy": privacy, "search_status": before}, indent=2))
        return 0

    args.manifest_dir.mkdir(parents=True, exist_ok=True)
    batches = []
    previous_indexed = int(before.get("ocr_indexed_asset_count") or 0)
    current_status = before

    for batch_number in range(1, args.max_batches + 1):
        remaining = int(current_status.get("ocr_remaining_photo_count") or 0)
        if remaining <= 0:
            print("OCR coverage is complete; no more batches needed.", flush=True)
            break

        print(
            f"Running OCR batch {batch_number}/{args.max_batches} "
            f"with limit {args.batch_size}...",
            flush=True,
        )
        job = post_json(
            args.api_base,
            "/ocr/rebuild",
            {"force": False, "limit": args.batch_size},
            timeout=args.request_timeout,
        )
        current_status = get_json(args.api_base, "/search/status")
        print(f"Job {job.get('id')}: {job.get('status')} - {job.get('detail')}")
        print_status("After", current_status)

        indexed = int(current_status.get("ocr_indexed_asset_count") or 0)
        batches.append(
            {
                "batch_number": batch_number,
                "job": job,
                "status_after": compact_status(current_status),
            }
        )

        if job.get("status") != "completed":
            print("Stopping because OCR job did not complete.", flush=True)
            break
        if indexed <= previous_indexed:
            print(
                "Stopping because OCR processed count did not increase. "
                "This prevents looping on missing or repeatedly failing assets.",
                flush=True,
            )
            break
        previous_indexed = indexed
        if batch_number < args.max_batches and args.sleep_seconds > 0:
            time.sleep(args.sleep_seconds)

    summary = {
        "mode": "safe_ocr_batches",
        "created_at": datetime.now(timezone.utc).isoformat(),
        "api_base": args.api_base,
        "batch_size": args.batch_size,
        "max_batches": args.max_batches,
        "privacy": {
            "loopback_only": privacy.get("loopback_only"),
            "photo_processing_network_allowed": privacy.get(
                "photo_processing_network_allowed"
            ),
            "cloud_ai_enabled": privacy.get("cloud_ai_enabled"),
            "encryption": privacy.get("encryption"),
        },
        "status_before": compact_status(before),
        "status_after": compact_status(current_status),
        "batches": batches,
    }
    output = args.manifest_dir / f"ocr-batches-{utc_stamp()}.summary.json"
    output.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"Summary JSON: {output}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"ERROR: {error}", file=sys.stderr)
        raise SystemExit(1)
