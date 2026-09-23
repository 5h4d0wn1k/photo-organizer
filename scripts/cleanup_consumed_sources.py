#!/usr/bin/env python3
"""Clean source folders after their useful data has been staged into Unfiltered.

Default mode is dry-run. Execute mode deletes only files whose exact SHA-256 is
already present under Unfiltered. Unique leftovers are moved into
Unfiltered/_source_audit with copy/hash verification before source removal.
Empty directories are removed with rmdir, never rm -rf.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import os
import shutil
from dataclasses import asdict, dataclass, fields
from datetime import datetime, timezone
from pathlib import Path


DEFAULT_UNFILTERED_ROOT = Path("/mnt/windows/transfer/Ok/Photos/Unfiltered")
DEFAULT_SOURCES = [
    Path("/mnt/windows/transfer/Ok/Takeout"),
    Path("/mnt/windows/transfer/Ok/jsonmerged data"),
]
SOURCE_AUDIT_DIR_NAME = "_source_audit"
HASH_BUFFER_BYTES = 1024 * 1024


@dataclass
class CleanupDecision:
    source_root: str
    source_path: str
    action: str
    status: str
    byte_size: int = 0
    sha256: str = ""
    preserved_at: str = ""
    audit_destination: str = ""
    result: str = ""
    error: str = ""


def utc_stamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while True:
            chunk = handle.read(HASH_BUFFER_BYTES)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()


def file_size(path: Path) -> int:
    try:
        return path.stat().st_size
    except OSError:
        return 0


def is_under(path: Path, root: Path) -> bool:
    try:
        path.resolve().relative_to(root.resolve())
        return True
    except (OSError, ValueError):
        return False


def iter_files(root: Path) -> list[Path]:
    if not root.exists():
        return []
    return [path for path in root.rglob("*") if path.is_file()]


def build_preserved_index(unfiltered_root: Path, source_files: list[Path]) -> dict[tuple[int, str], Path]:
    sizes = {file_size(path) for path in source_files}
    index: dict[tuple[int, str], Path] = {}
    if not sizes:
        return index

    for path in unfiltered_root.rglob("*"):
        if not path.is_file():
            continue
        if is_under(path, unfiltered_root / SOURCE_AUDIT_DIR_NAME):
            continue
        size = file_size(path)
        if size not in sizes:
            continue
        try:
            index.setdefault((size, sha256_file(path)), path)
        except OSError:
            continue
    return index


def audit_destination(unfiltered_root: Path, source_root: Path, source_file: Path) -> Path:
    try:
        relative = source_file.relative_to(source_root)
    except ValueError:
        relative = Path(source_file.name)
    return unfiltered_root / SOURCE_AUDIT_DIR_NAME / source_root.name / relative


def unique_destination(path: Path, digest: str) -> Path:
    if not path.exists():
        return path
    try:
        if sha256_file(path) == digest:
            return path
    except OSError:
        # Unreadable/missing file: content cannot be verified against this digest.
        pass

    suffix = path.suffix
    stem = path.name[: -len(suffix)] if suffix else path.name
    for index in range(1, 10000):
        candidate = path.with_name(f"{stem}.{digest[:12]}.{index}{suffix}")
        if not candidate.exists():
            return candidate
        try:
            if sha256_file(candidate) == digest:
                return candidate
        except OSError:
            continue
    raise RuntimeError(f"Could not find collision-free destination for {path}")


def copy_verified_then_unlink(source: Path, destination: Path, expected_hash: str) -> str:
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists():
        if sha256_file(destination) == expected_hash:
            source.unlink()
            return "already_preserved_source_removed"
        raise RuntimeError(f"Destination exists with different content: {destination}")

    temp_destination = destination.with_name(f".{destination.name}.tmp-{os.getpid()}")
    try:
        shutil.copy2(source, temp_destination)
        if sha256_file(temp_destination) != expected_hash:
            temp_destination.unlink(missing_ok=True)
            raise RuntimeError("Audit copy hash verification failed; source left in place.")
        temp_destination.replace(destination)
        source.unlink()
        return "moved_to_audit_verified"
    finally:
        temp_destination.unlink(missing_ok=True)


def decide(sources: list[Path], unfiltered_root: Path) -> list[CleanupDecision]:
    all_source_files: list[Path] = []
    for source in sources:
        all_source_files.extend(iter_files(source))
    preserved = build_preserved_index(unfiltered_root, all_source_files)

    decisions: list[CleanupDecision] = []
    for source_root in sources:
        for source_file in iter_files(source_root):
            size = file_size(source_file)
            try:
                digest = sha256_file(source_file)
            except OSError as exc:
                decisions.append(
                    CleanupDecision(
                        source_root=str(source_root),
                        source_path=str(source_file),
                        action="keep_source",
                        status="read_failed",
                        byte_size=size,
                        error=str(exc),
                    )
                )
                continue

            existing = preserved.get((size, digest))
            if existing:
                decisions.append(
                    CleanupDecision(
                        source_root=str(source_root),
                        source_path=str(source_file),
                        action="delete_preserved_duplicate",
                        status="preserved",
                        byte_size=size,
                        sha256=digest,
                        preserved_at=str(existing),
                    )
                )
            else:
                destination = unique_destination(audit_destination(unfiltered_root, source_root, source_file), digest)
                decisions.append(
                    CleanupDecision(
                        source_root=str(source_root),
                        source_path=str(source_file),
                        action="move_unique_to_source_audit",
                        status="unique",
                        byte_size=size,
                        sha256=digest,
                        audit_destination=str(destination),
                    )
                )

    return decisions


def execute(decisions: list[CleanupDecision], sources: list[Path]) -> dict:
    counts = {"deleted_preserved_duplicates": 0, "moved_unique_to_audit": 0, "kept": 0, "failed": 0, "removed_empty_dirs": 0}
    failures: list[dict[str, str]] = []

    for decision in decisions:
        source = Path(decision.source_path)
        try:
            if decision.action == "delete_preserved_duplicate":
                if not source.exists():
                    decision.result = "already_absent"
                elif sha256_file(source) == decision.sha256:
                    source.unlink()
                    decision.result = "deleted_preserved_duplicate"
                    counts["deleted_preserved_duplicates"] += 1
                else:
                    raise RuntimeError("Source hash changed since audit; source left in place.")
            elif decision.action == "move_unique_to_source_audit":
                decision.result = copy_verified_then_unlink(source, Path(decision.audit_destination), decision.sha256)
                counts["moved_unique_to_audit"] += 1
            else:
                decision.result = "kept"
                counts["kept"] += 1
        except Exception as exc:  # noqa: BLE001 - per-file cleanup manifest must capture failures.
            decision.result = "failed"
            decision.error = str(exc)
            counts["failed"] += 1
            failures.append({"source_path": decision.source_path, "error": str(exc)})

    for source in sources:
        if not source.exists():
            continue
        dirs = sorted([path for path in source.rglob("*") if path.is_dir()], key=lambda path: len(path.parts), reverse=True)
        dirs.append(source)
        for directory in dirs:
            try:
                directory.rmdir()
                counts["removed_empty_dirs"] += 1
            except OSError:
                continue

    return {"counts": counts, "failures": failures[:200]}


def write_outputs(decisions: list[CleanupDecision], summary: dict, manifest_dir: Path, stamp: str) -> tuple[Path, Path]:
    manifest_dir.mkdir(parents=True, exist_ok=True)
    csv_path = manifest_dir / f"cleanup-consumed-sources-{stamp}.csv"
    json_path = manifest_dir / f"cleanup-consumed-sources-{stamp}.summary.json"
    field_names = [item.name for item in fields(CleanupDecision)]

    with csv_path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=field_names)
        writer.writeheader()
        for decision in decisions:
            writer.writerow(asdict(decision))

    with json_path.open("w", encoding="utf-8") as handle:
        json.dump(summary, handle, indent=2, sort_keys=True)
        handle.write("\n")

    return csv_path, json_path


def summarize(decisions: list[CleanupDecision], *, mode: str, sources: list[Path], unfiltered_root: Path, execution: dict | None = None) -> dict:
    summary: dict[str, object] = {
        "mode": mode,
        "sources": [str(source) for source in sources],
        "unfiltered_root": str(unfiltered_root),
        "source_audit_root": str(unfiltered_root / SOURCE_AUDIT_DIR_NAME),
        "file_count": len(decisions),
        "byte_count": sum(decision.byte_size for decision in decisions),
        "by_action": {},
        "by_status": {},
    }
    for decision in decisions:
        for key, value in (("by_action", decision.action), ("by_status", decision.status)):
            bucket = summary[key]
            assert isinstance(bucket, dict)
            bucket[value] = int(bucket.get(value, 0)) + 1
    if execution is not None:
        summary["execution"] = execution
    return summary


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--unfiltered-root", type=Path, default=DEFAULT_UNFILTERED_ROOT)
    parser.add_argument("--source", action="append", type=Path, help="Source folder to clean. Can be repeated.")
    parser.add_argument("--execute", action="store_true", help="Delete preserved duplicates and move unique leftovers into _source_audit.")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    unfiltered_root: Path = args.unfiltered_root
    sources: list[Path] = args.source or DEFAULT_SOURCES

    if not unfiltered_root.is_dir():
        print(f"Unfiltered root does not exist: {unfiltered_root}")
        return 2

    decisions = decide(sources, unfiltered_root)
    execution = execute(decisions, sources) if args.execute else None
    summary = summarize(
        decisions,
        mode="execute-cleanup" if args.execute else "dry-run",
        sources=sources,
        unfiltered_root=unfiltered_root,
        execution=execution,
    )
    csv_path, json_path = write_outputs(decisions, summary, unfiltered_root / SOURCE_AUDIT_DIR_NAME / "manifests", utc_stamp())
    print(json.dumps(summary, indent=2, sort_keys=True))
    print(f"CSV manifest: {csv_path}")
    print(f"Summary JSON: {json_path}")
    if execution and execution["counts"]["failed"]:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
