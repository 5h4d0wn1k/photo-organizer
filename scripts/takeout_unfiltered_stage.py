#!/usr/bin/env python3
"""Safely stage Google Takeout Photos files into the Unfiltered folder.

Default mode is a dry-run: it writes manifests only and never moves/deletes
source media. Execute mode copies files with hash verification so the original
Takeout export remains recoverable.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import os
import shutil
import sys
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable


DEFAULT_TAKEOUT_ROOT = Path("/mnt/windows/transfer/Ok/Takeout/Google Photos")
DEFAULT_UNFILTERED_ROOT = Path("/mnt/windows/transfer/Ok/Photos/Unfiltered")
REVIEW_DIR_NAME = "_takeout_review"
HASH_BUFFER_BYTES = 1024 * 1024

MEDIA_EXTENSIONS = {
    ".3gp",
    ".avi",
    ".bmp",
    ".dng",
    ".gif",
    ".heic",
    ".heif",
    ".jfif",
    ".jpeg",
    ".jpg",
    ".jxr",
    ".m4v",
    ".mov",
    ".mp4",
    ".mpeg",
    ".mpg",
    ".png",
    ".tif",
    ".tiff",
    ".webp",
    ".wmv",
}


@dataclass
class ManifestRow:
    record_type: str
    status: str
    action: str
    source_path: str
    destination_path: str = ""
    matched_media_path: str = ""
    match_method: str = ""
    sha256: str = ""
    byte_size: int = 0
    reason: str = ""


def utc_stamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def is_media(path: Path) -> bool:
    return path.suffix.lower() in MEDIA_EXTENSIONS


def iter_files(root: Path, *, skip_review: bool = False) -> Iterable[Path]:
    for current, dirnames, filenames in os.walk(root):
        if skip_review:
            dirnames[:] = [name for name in dirnames if name != REVIEW_DIR_NAME]
        for filename in filenames:
            yield Path(current) / filename


def file_size(path: Path) -> int:
    try:
        return path.stat().st_size
    except OSError:
        return 0


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while True:
            chunk = handle.read(HASH_BUFFER_BYTES)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()


def read_takeout_json(path: Path) -> dict:
    try:
        with path.open("r", encoding="utf-8") as handle:
            value = json.load(handle)
        return value if isinstance(value, dict) else {}
    except (OSError, json.JSONDecodeError, UnicodeDecodeError):
        return {}


def title_from_json(path: Path) -> str:
    value = read_takeout_json(path)
    title = value.get("title")
    return title if isinstance(title, str) else ""


def photo_sidecar_like(path: Path) -> bool:
    if path.name.lower() == "metadata.json":
        return False
    value = read_takeout_json(path)
    if not isinstance(value.get("title"), str):
        return False
    photo_keys = {
        "photoTakenTime",
        "geoData",
        "geoDataExif",
        "url",
        "googlePhotosOrigin",
        "creationTime",
        "description",
    }
    return any(key in value for key in photo_keys)


def unique_index(paths: Iterable[Path], key_fn) -> tuple[dict[str, Path], set[str]]:
    buckets: dict[str, list[Path]] = {}
    for path in paths:
        key = key_fn(path)
        if key:
            buckets.setdefault(key, []).append(path)
    unique: dict[str, Path] = {}
    ambiguous: set[str] = set()
    for key, matches in buckets.items():
        if len(matches) == 1:
            unique[key] = matches[0]
        else:
            ambiguous.add(key)
    return unique, ambiguous


def remove_json_suffix(name: str) -> str:
    return name[:-5] if name.lower().endswith(".json") else name


def destination_for_review_file(unfiltered_root: Path, bucket: str, source_root: Path, source: Path) -> Path:
    try:
        rel = source.relative_to(source_root)
    except ValueError:
        rel = Path(source.name)
    return unfiltered_root / REVIEW_DIR_NAME / bucket / rel


def classify_json_sidecars(takeout_root: Path, unfiltered_root: Path, media_paths: list[Path]) -> list[ManifestRow]:
    by_name, ambiguous_names = unique_index(media_paths, lambda path: path.name.casefold())
    by_stem, ambiguous_stems = unique_index(media_paths, lambda path: path.stem.casefold())
    rows: list[ManifestRow] = []

    for path in iter_files(takeout_root):
        if path.suffix.lower() != ".json":
            continue

        if path.name.lower() == "metadata.json":
            rows.append(
                ManifestRow(
                    record_type="json",
                    status="album_metadata",
                    action="copy_to_review",
                    source_path=str(path),
                    destination_path=str(destination_for_review_file(unfiltered_root, "album_metadata", takeout_root, path)),
                    byte_size=file_size(path),
                    reason="Album-level metadata is preserved for review but is not attached to one media file.",
                )
            )
            continue

        if not photo_sidecar_like(path):
            rows.append(
                ManifestRow(
                    record_type="json",
                    status="non_photo_json",
                    action="copy_to_review",
                    source_path=str(path),
                    destination_path=str(destination_for_review_file(unfiltered_root, "non_photo_json", takeout_root, path)),
                    byte_size=file_size(path),
                    reason="JSON did not look like a Google Photos item sidecar.",
                )
            )
            continue

        token = remove_json_suffix(path.name)
        title = title_from_json(path)
        match: Path | None = None
        match_method = ""
        ambiguous_reason = ""

        for candidate, method in ((token, "json_filename"), (title, "json_title")):
            key = candidate.casefold()
            if not key:
                continue
            if key in by_name:
                match = by_name[key]
                match_method = method
                break
            if key in ambiguous_names:
                ambiguous_reason = f"{method} matched multiple media files named {candidate!r}."

        if match is None and Path(token).suffix == "":
            key = token.casefold()
            if key in by_stem:
                match = by_stem[key]
                match_method = "json_stem"
            elif key in ambiguous_stems:
                ambiguous_reason = f"JSON stem {token!r} matched multiple media stems."

        if match is None:
            bucket = "ambiguous_json" if ambiguous_reason else "unmatched_json"
            rows.append(
                ManifestRow(
                    record_type="json",
                    status="ambiguous" if ambiguous_reason else "unmatched",
                    action="copy_to_review",
                    source_path=str(path),
                    destination_path=str(destination_for_review_file(unfiltered_root, bucket, takeout_root, path)),
                    byte_size=file_size(path),
                    reason=ambiguous_reason or "No unique Unfiltered media file matched this Takeout sidecar.",
                )
            )
            continue

        destination = unfiltered_root / "json" / f"{match.name}.json"
        if destination.exists():
            try:
                same_content = sha256_file(path) == sha256_file(destination)
            except OSError:
                same_content = False
            if same_content:
                rows.append(
                    ManifestRow(
                        record_type="json",
                        status="already_present",
                        action="skip",
                        source_path=str(path),
                        destination_path=str(destination),
                        matched_media_path=str(match),
                        match_method=match_method,
                        byte_size=file_size(path),
                        reason="Matching sidecar already exists with identical content.",
                    )
                )
            else:
                rows.append(
                    ManifestRow(
                        record_type="json",
                        status="destination_collision",
                        action="copy_to_review",
                        source_path=str(path),
                        destination_path=str(destination_for_review_file(unfiltered_root, "sidecar_collisions", takeout_root, path)),
                        matched_media_path=str(match),
                        match_method=match_method,
                        byte_size=file_size(path),
                        reason="A sidecar already exists for the matched media, but content differs.",
                    )
                )
            continue

        rows.append(
            ManifestRow(
                record_type="json",
                status="matched",
                action="copy",
                source_path=str(path),
                destination_path=str(destination),
                matched_media_path=str(match),
                match_method=match_method,
                byte_size=file_size(path),
                reason="Sidecar can be attached under Unfiltered/json without modifying media.",
            )
        )

    return rows


def media_hash_index(unfiltered_root: Path, takeout_media: list[Path]) -> dict[str, Path]:
    sizes = {file_size(path) for path in takeout_media}
    by_hash: dict[str, Path] = {}
    if not sizes:
        return by_hash

    for path in iter_files(unfiltered_root, skip_review=True):
        if not is_media(path):
            continue
        if file_size(path) not in sizes:
            continue
        try:
            digest = sha256_file(path)
        except OSError:
            continue
        by_hash.setdefault(digest, path)
    return by_hash


def classify_takeout_media(takeout_root: Path, unfiltered_root: Path, takeout_media: list[Path]) -> list[ManifestRow]:
    rows: list[ManifestRow] = []
    existing_hashes = media_hash_index(unfiltered_root, takeout_media)

    for path in takeout_media:
        try:
            digest = sha256_file(path)
        except OSError as exc:
            rows.append(
                ManifestRow(
                    record_type="media",
                    status="read_failed",
                    action="skip",
                    source_path=str(path),
                    byte_size=file_size(path),
                    reason=str(exc),
                )
            )
            continue

        duplicate = existing_hashes.get(digest)
        if duplicate:
            destination = destination_for_review_file(unfiltered_root, "duplicate_media", takeout_root, path)
            rows.append(
                ManifestRow(
                    record_type="media",
                    status="duplicate",
                    action="copy_to_review",
                    source_path=str(path),
                    destination_path=str(destination),
                    matched_media_path=str(duplicate),
                    match_method="sha256",
                    sha256=digest,
                    byte_size=file_size(path),
                    reason="Takeout media content already exists in Unfiltered; stage separately for review.",
                )
            )
        else:
            destination = destination_for_review_file(unfiltered_root, "new_media", takeout_root, path)
            rows.append(
                ManifestRow(
                    record_type="media",
                    status="new",
                    action="copy",
                    source_path=str(path),
                    destination_path=str(destination),
                    match_method="sha256",
                    sha256=digest,
                    byte_size=file_size(path),
                    reason="Takeout media was not found by checksum in Unfiltered.",
                )
            )

    return rows


def route_planned_destination_collisions(rows: list[ManifestRow], takeout_root: Path, unfiltered_root: Path) -> None:
    planned: dict[str, list[ManifestRow]] = {}
    for row in rows:
        if row.action != "copy" or not row.destination_path:
            continue
        planned.setdefault(row.destination_path, []).append(row)

    for destination, bucket in planned.items():
        if len(bucket) < 2:
            continue

        first = bucket[0]
        first.reason = f"{first.reason} Other Takeout records also targeted this destination; first planned copy kept."
        seen_hashes: dict[str, ManifestRow] = {}

        try:
            first_hash = sha256_file(Path(first.source_path))
            seen_hashes[first_hash] = first
        except OSError:
            first_hash = ""

        for row in bucket[1:]:
            try:
                row_hash = sha256_file(Path(row.source_path))
            except OSError:
                row_hash = ""

            if row_hash and row_hash in seen_hashes:
                row.status = "planned_duplicate_same_content"
                row.action = "skip"
                row.sha256 = row_hash
                row.reason = f"Another source with identical content already targets {destination}."
                continue

            if row_hash:
                seen_hashes[row_hash] = row
            row.status = "planned_destination_collision"
            row.action = "copy_to_review"
            row.destination_path = str(
                destination_for_review_file(unfiltered_root, "planned_sidecar_collisions", takeout_root, Path(row.source_path))
            )
            row.sha256 = row_hash
            row.reason = "Multiple Takeout records targeted the same Unfiltered sidecar name with different content."


def copy_verified(source: Path, destination: Path, *, expected_hash: str = "") -> str:
    destination.parent.mkdir(parents=True, exist_ok=True)
    source_hash = expected_hash or sha256_file(source)

    if destination.exists():
        if sha256_file(destination) == source_hash:
            return "existing_same"
        raise RuntimeError(f"Destination exists with different content: {destination}")

    temp_destination = destination.with_name(f".{destination.name}.tmp-{os.getpid()}")
    try:
        shutil.copy2(source, temp_destination)
        copied_hash = sha256_file(temp_destination)
        if copied_hash != source_hash:
            temp_destination.unlink(missing_ok=True)
            raise RuntimeError(f"Hash verification failed for {source}")
        temp_destination.replace(destination)
        return "copied"
    finally:
        temp_destination.unlink(missing_ok=True)


def write_manifests(rows: list[ManifestRow], manifest_dir: Path, stamp: str, summary: dict) -> tuple[Path, Path]:
    manifest_dir.mkdir(parents=True, exist_ok=True)
    csv_path = manifest_dir / f"takeout-unfiltered-stage-{stamp}.csv"
    json_path = manifest_dir / f"takeout-unfiltered-stage-{stamp}.summary.json"

    with csv_path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(asdict(rows[0]).keys()) if rows else list(ManifestRow("", "", "", "").__dict__.keys()))
        writer.writeheader()
        for row in rows:
            writer.writerow(asdict(row))

    with json_path.open("w", encoding="utf-8") as handle:
        json.dump(summary, handle, indent=2, sort_keys=True)
        handle.write("\n")

    return csv_path, json_path


def summarize(rows: list[ManifestRow], *, mode: str, takeout_root: Path, unfiltered_root: Path, execution: dict | None = None) -> dict:
    summary: dict[str, object] = {
        "mode": mode,
        "takeout_root": str(takeout_root),
        "unfiltered_root": str(unfiltered_root),
        "review_root": str(unfiltered_root / REVIEW_DIR_NAME),
        "total_records": len(rows),
        "total_bytes_referenced": sum(row.byte_size for row in rows),
        "by_type": {},
        "by_status": {},
        "by_action": {},
    }
    for row in rows:
        for key, value in (("by_type", row.record_type), ("by_status", row.status), ("by_action", row.action)):
            bucket = summary[key]
            assert isinstance(bucket, dict)
            bucket[value] = int(bucket.get(value, 0)) + 1
    if execution is not None:
        summary["execution"] = execution
    return summary


def execute_rows(rows: list[ManifestRow]) -> dict:
    copied = 0
    existing_same = 0
    failed = 0
    errors: list[dict[str, str]] = []

    for row in rows:
        if row.action not in {"copy", "copy_to_review"}:
            continue
        if not row.destination_path:
            continue
        try:
            result = copy_verified(Path(row.source_path), Path(row.destination_path), expected_hash=row.sha256)
            if result == "copied":
                copied += 1
            elif result == "existing_same":
                existing_same += 1
        except Exception as exc:  # noqa: BLE001 - manifest should capture all per-file failures.
            failed += 1
            errors.append({"source_path": row.source_path, "destination_path": row.destination_path, "error": str(exc)})

    return {"copied": copied, "existing_same": existing_same, "failed": failed, "errors": errors[:100]}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--takeout-root", type=Path, default=DEFAULT_TAKEOUT_ROOT)
    parser.add_argument("--unfiltered-root", type=Path, default=DEFAULT_UNFILTERED_ROOT)
    parser.add_argument("--execute", action="store_true", help="Copy staged files after classification. Never deletes source files.")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    takeout_root: Path = args.takeout_root
    unfiltered_root: Path = args.unfiltered_root

    if not takeout_root.is_dir():
        print(f"Takeout root does not exist: {takeout_root}", file=sys.stderr)
        return 2
    if not unfiltered_root.is_dir():
        print(f"Unfiltered root does not exist: {unfiltered_root}", file=sys.stderr)
        return 2

    media_paths = [path for path in iter_files(unfiltered_root, skip_review=True) if is_media(path)]
    takeout_media = [path for path in iter_files(takeout_root) if is_media(path)]

    rows = classify_takeout_media(takeout_root, unfiltered_root, takeout_media)
    rows.extend(classify_json_sidecars(takeout_root, unfiltered_root, media_paths))
    route_planned_destination_collisions(rows, takeout_root, unfiltered_root)

    execution = execute_rows(rows) if args.execute else None
    mode = "execute-copy" if args.execute else "dry-run"
    summary = summarize(rows, mode=mode, takeout_root=takeout_root, unfiltered_root=unfiltered_root, execution=execution)
    csv_path, json_path = write_manifests(rows, unfiltered_root / REVIEW_DIR_NAME / "manifests", utc_stamp(), summary)

    print(json.dumps(summary, indent=2, sort_keys=True))
    print(f"CSV manifest: {csv_path}")
    print(f"Summary JSON: {json_path}")
    return 1 if execution and execution["failed"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
