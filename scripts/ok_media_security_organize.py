#!/usr/bin/env python3
"""Security-audit and safely move Ok media into Photos/Unfiltered.

The default mode is dry-run. Execute mode uses verified copy-then-unlink moves:
hash source, copy to a temporary destination, verify destination hash, then
remove the source. Destination collisions never overwrite existing content.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import mimetypes
import os
import shutil
import subprocess
import sys
from dataclasses import asdict, dataclass, fields
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable


DEFAULT_OK_ROOT = Path("/mnt/windows/transfer/Ok")
DEFAULT_UNFILTERED_ROOT = Path("/mnt/windows/transfer/Ok/Photos/Unfiltered")
ORGANIZED_DIR_NAME = "_organized_from_ok"
SECURITY_REVIEW_DIR_NAME = "_security_review"
MANIFEST_DIR_NAME = "manifests"
HASH_BUFFER_BYTES = 1024 * 1024
PROBE_TIMEOUT_SECONDS = 20

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
    ".jxl",
    ".jxr",
    ".m4v",
    ".mkv",
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

SCRIPTABLE_IMAGE_EXTENSIONS = {".svg"}
AUDIO_EXTENSIONS = {".aac", ".aiff", ".alac", ".flac", ".m4a", ".mp3", ".oga", ".ogg", ".opus", ".wav", ".wma"}

IMAGE_EXTENSIONS = {
    ".bmp",
    ".dng",
    ".gif",
    ".heic",
    ".heif",
    ".jfif",
    ".jpeg",
    ".jpg",
    ".jxl",
    ".jxr",
    ".png",
    ".tif",
    ".tiff",
    ".webp",
}

VIDEO_EXTENSIONS = MEDIA_EXTENSIONS - IMAGE_EXTENSIONS

EXECUTABLE_MIMES = {
    "application/x-dosexec",
    "application/x-executable",
    "application/x-pie-executable",
    "application/x-sharedlib",
    "application/x-msdownload",
    "application/x-mach-binary",
    "application/vnd.microsoft.portable-executable",
}

SCRIPT_OR_MARKUP_MIMES = {
    "application/javascript",
    "application/x-javascript",
    "application/x-shellscript",
    "application/x-perl",
    "application/x-python",
    "application/xhtml+xml",
    "text/html",
    "text/javascript",
    "text/x-python",
    "text/x-shellscript",
}

ALLOWED_MEDIA_MIME_PREFIXES = ("image/", "video/")
KNOWN_MEDIA_MIMES = {
    "application/octet-stream",  # Some camera/raw formats are reported this way.
    "application/x-iso9660-image",  # Not clean by itself; parser check decides.
}


@dataclass
class ProbeResult:
    tool: str
    status: str
    detail: str = ""


@dataclass
class MediaDecision:
    source_path: str
    destination_path: str
    classification: str
    action: str
    sha256: str = ""
    byte_size: int = 0
    extension: str = ""
    mime_type: str = ""
    file_description: str = ""
    duplicate_of: str = ""
    sidecar_paths: str = ""
    reasons: str = ""
    probes: str = ""
    move_result: str = ""
    move_error: str = ""


def utc_stamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def is_media_extension(path: Path) -> bool:
    return path.suffix.lower() in MEDIA_EXTENSIONS


def is_under(path: Path, root: Path) -> bool:
    try:
        path.resolve().relative_to(root.resolve())
        return True
    except (OSError, ValueError):
        return False


def iter_files(root: Path, excluded_roots: list[Path]) -> Iterable[Path]:
    excluded = [path.resolve() for path in excluded_roots if path.exists()]
    for current, dirnames, filenames in os.walk(root):
        current_path = Path(current)
        kept_dirs = []
        for dirname in dirnames:
            candidate = current_path / dirname
            try:
                resolved = candidate.resolve()
            except OSError:
                continue
            if any(resolved == excluded_root or is_under(resolved, excluded_root) for excluded_root in excluded):
                continue
            kept_dirs.append(dirname)
        dirnames[:] = kept_dirs
        for filename in filenames:
            yield current_path / filename


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


def read_head(path: Path, size: int = 512) -> bytes:
    try:
        with path.open("rb") as handle:
            return handle.read(size)
    except OSError:
        return b""


def run_tool(args: list[str], timeout: int = PROBE_TIMEOUT_SECONDS) -> ProbeResult:
    tool = Path(args[0]).name
    try:
        completed = subprocess.run(
            args,
            check=False,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except FileNotFoundError:
        return ProbeResult(tool, "unavailable", "tool not found")
    except subprocess.TimeoutExpired:
        return ProbeResult(tool, "timeout", f"timed out after {timeout}s")

    output = (completed.stdout or completed.stderr or "").strip().replace("\n", " ")[:500]
    if completed.returncode == 0:
        return ProbeResult(tool, "ok", output)
    return ProbeResult(tool, "failed", output or f"exit code {completed.returncode}")


def file_probe(path: Path) -> tuple[str, str]:
    mime = run_tool(["file", "--brief", "--mime-type", str(path)], timeout=10)
    desc = run_tool(["file", "--brief", str(path)], timeout=10)
    mime_value = mime.detail.strip() if mime.status == "ok" else ""
    desc_value = desc.detail.strip() if desc.status == "ok" else ""
    return mime_value, desc_value


def parser_probes(path: Path, mime_type: str) -> list[ProbeResult]:
    ext = path.suffix.lower()
    probes: list[ProbeResult] = []

    if ext in IMAGE_EXTENSIONS or mime_type.startswith("image/"):
        probes.append(run_tool(["identify", "-quiet", "-ping", str(path)]))
        probes.append(run_tool(["exiftool", "-fast2", "-warning", "-error", "-s3", str(path)], timeout=15))
    elif ext in VIDEO_EXTENSIONS or mime_type.startswith("video/"):
        probes.append(run_tool(["ffprobe", "-v", "error", "-show_format", "-show_streams", "-of", "json", str(path)]))
        probes.append(run_tool(["exiftool", "-fast2", "-warning", "-error", "-s3", str(path)], timeout=15))

    return probes


def clamscan_probe(path: Path) -> ProbeResult:
    return run_tool(["clamscan", "--no-summary", str(path)], timeout=60)


def sidecars_for(path: Path) -> list[Path]:
    candidates = [
        path.with_name(f"{path.name}.json"),
        path.with_suffix(".json"),
    ]
    seen: set[Path] = set()
    existing = []
    for candidate in candidates:
        if candidate in seen:
            continue
        seen.add(candidate)
        if candidate.exists() and candidate.is_file():
            existing.append(candidate)
    return existing


def relative_destination(root: Path, source_root: Path, source: Path, bucket: str) -> Path:
    try:
        rel = source.relative_to(source_root)
    except ValueError:
        rel = Path(source.name)
    return root / bucket / rel


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


def build_existing_hash_index(unfiltered_root: Path, candidate_sizes: set[int]) -> dict[tuple[int, str], Path]:
    existing: dict[tuple[int, str], Path] = {}
    if not candidate_sizes:
        return existing

    excluded_names = {ORGANIZED_DIR_NAME, SECURITY_REVIEW_DIR_NAME, "_takeout_review", "json"}
    for current, dirnames, filenames in os.walk(unfiltered_root):
        dirnames[:] = [name for name in dirnames if name not in excluded_names]
        current_path = Path(current)
        for filename in filenames:
            path = current_path / filename
            if not is_media_extension(path):
                continue
            size = file_size(path)
            if size not in candidate_sizes:
                continue
            try:
                digest = sha256_file(path)
            except OSError:
                continue
            existing.setdefault((size, digest), path)
    return existing


def mime_says_media(path: Path) -> bool:
    if path.suffix.lower() in AUDIO_EXTENSIONS:
        return False
    mime = run_tool(["file", "--brief", "--mime-type", str(path)], timeout=10)
    return mime.status == "ok" and mime.detail.startswith(ALLOWED_MEDIA_MIME_PREFIXES)


def candidate_paths(ok_root: Path, unfiltered_root: Path, *, extension_only: bool = False) -> list[Path]:
    private_library = ok_root / "Photos" / "PrivateGalleryLibrary"
    excluded = [unfiltered_root, private_library]
    candidates: list[Path] = []
    for path in iter_files(ok_root, excluded):
        if is_media_extension(path) or (not extension_only and mime_says_media(path)):
            candidates.append(path)
    return candidates


def decide(
    path: Path,
    *,
    ok_root: Path,
    unfiltered_root: Path,
    existing_hashes: dict[tuple[int, str], Path],
    clamscan_available: bool,
) -> MediaDecision:
    reasons: list[str] = []
    probes: list[ProbeResult] = []
    size = file_size(path)
    extension = path.suffix.lower()
    sidecars = sidecars_for(path)
    mime_type, file_description = file_probe(path)

    digest = ""
    try:
        digest = sha256_file(path)
    except OSError as exc:
        destination = relative_destination(unfiltered_root, ok_root, path, f"{SECURITY_REVIEW_DIR_NAME}/suspicious")
        return MediaDecision(
            source_path=str(path),
            destination_path=str(destination),
            classification="suspicious",
            action="move_to_suspicious",
            byte_size=size,
            extension=extension,
            mime_type=mime_type,
            file_description=file_description,
            sidecar_paths=json.dumps([str(item) for item in sidecars]),
            reasons=f"Cannot read/hash file: {exc}",
        )

    head = read_head(path)
    classification = "clean"
    action = "move_to_unfiltered"

    if size == 0:
        classification = "suspicious"
        action = "move_to_suspicious"
        reasons.append("Zero-byte media candidate.")

    if path.is_symlink():
        classification = "suspicious"
        action = "move_to_suspicious"
        reasons.append("Symlink candidate; not following links during archive organization.")

    if mime_type in EXECUTABLE_MIMES or head.startswith((b"MZ", b"\x7fELF")):
        classification = "malicious_like"
        action = "move_to_malicious"
        reasons.append("Executable binary signature or MIME detected on a media-extension file.")

    if mime_type in SCRIPT_OR_MARKUP_MIMES or head.lstrip().startswith((b"#!", b"<html", b"<!DOCTYPE html", b"<script")):
        classification = "malicious_like"
        action = "move_to_malicious"
        reasons.append("Script/HTML content detected on a media-extension file.")

    if classification == "clean" and (extension in SCRIPTABLE_IMAGE_EXTENSIONS or mime_type == "image/svg+xml"):
        classification = "suspicious"
        action = "move_to_suspicious"
        reasons.append("Scriptable SVG image should be reviewed before mixing into the photo library.")

    duplicate_of = ""
    existing = existing_hashes.get((size, digest))
    if existing and classification == "clean":
        classification = "duplicate"
        action = "move_to_duplicates_review"
        duplicate_of = str(existing)
        reasons.append("Checksum already exists in Unfiltered; moving source into duplicate review.")

    if classification == "clean":
        if not (mime_type.startswith(ALLOWED_MEDIA_MIME_PREFIXES) or mime_type in KNOWN_MEDIA_MIMES):
            guessed = mimetypes.guess_type(path.name)[0] or ""
            if not guessed.startswith(ALLOWED_MEDIA_MIME_PREFIXES):
                classification = "suspicious"
                action = "move_to_suspicious"
                reasons.append(f"file(1) MIME is not image/video: {mime_type or 'unknown'}.")

    if classification == "clean":
        probes.extend(parser_probes(path, mime_type))
        failed_probes = [probe for probe in probes if probe.status not in {"ok", "unavailable"}]
        ok_probes = [probe for probe in probes if probe.status == "ok"]
        if failed_probes and not ok_probes:
            classification = "suspicious"
            action = "move_to_suspicious"
            reasons.append("Local parser validation failed.")
        elif failed_probes:
            reasons.append("Some local parser checks failed, but another parser accepted the file.")

    if clamscan_available:
        av_probe = clamscan_probe(path)
        probes.append(av_probe)
        detail = av_probe.detail.lower()
        if av_probe.status == "failed" and "found" in detail:
            classification = "malicious"
            action = "move_to_malicious"
            reasons.append(f"ClamAV reported malware: {av_probe.detail}")
        elif av_probe.status not in {"ok", "unavailable"}:
            if classification == "clean":
                classification = "suspicious"
                action = "move_to_suspicious"
            reasons.append(f"ClamAV scan did not complete cleanly: {av_probe.status} {av_probe.detail}")
    else:
        probes.append(ProbeResult("clamscan", "unavailable", "ClamAV is not installed on this machine."))

    if not reasons:
        reasons.append("Passed available local media safety checks.")

    if action == "move_to_unfiltered":
        destination = relative_destination(unfiltered_root, ok_root, path, ORGANIZED_DIR_NAME)
    elif action == "move_to_duplicates_review":
        destination = relative_destination(unfiltered_root, ok_root, path, f"{SECURITY_REVIEW_DIR_NAME}/duplicates")
    elif action == "move_to_malicious":
        destination = relative_destination(unfiltered_root, ok_root, path, f"{SECURITY_REVIEW_DIR_NAME}/malicious")
    else:
        destination = relative_destination(unfiltered_root, ok_root, path, f"{SECURITY_REVIEW_DIR_NAME}/suspicious")
    destination = unique_destination(destination, digest)

    return MediaDecision(
        source_path=str(path),
        destination_path=str(destination),
        classification=classification,
        action=action,
        sha256=digest,
        byte_size=size,
        extension=extension,
        mime_type=mime_type,
        file_description=file_description,
        duplicate_of=duplicate_of,
        sidecar_paths=json.dumps([str(item) for item in sidecars], ensure_ascii=False),
        reasons=" | ".join(reasons),
        probes=json.dumps([asdict(probe) for probe in probes], ensure_ascii=False),
    )


def move_verified(source: Path, destination: Path, expected_hash: str) -> str:
    destination.parent.mkdir(parents=True, exist_ok=True)

    if destination.exists():
        if sha256_file(destination) == expected_hash:
            source.unlink()
            return "destination_already_verified_source_removed"
        raise RuntimeError(f"Destination exists with different content: {destination}")

    temp_destination = destination.with_name(f".{destination.name}.tmp-{os.getpid()}")
    try:
        shutil.copy2(source, temp_destination)
        copied_hash = sha256_file(temp_destination)
        if copied_hash != expected_hash:
            temp_destination.unlink(missing_ok=True)
            raise RuntimeError("Destination hash verification failed; source left in place.")
        temp_destination.replace(destination)
        source.unlink()
        return "moved_verified"
    finally:
        temp_destination.unlink(missing_ok=True)


def move_sidecars(decision: MediaDecision) -> list[dict[str, str]]:
    moved: list[dict[str, str]] = []
    sidecars = json.loads(decision.sidecar_paths or "[]")
    destination = Path(decision.destination_path)
    for sidecar in sidecars:
        source = Path(sidecar)
        if not source.exists():
            continue
        target = destination.with_name(f"{destination.name}.json") if source.name == f"{Path(decision.source_path).name}.json" else destination.with_suffix(".json")
        try:
            digest = sha256_file(source)
            result = move_verified(source, target, digest)
            moved.append({"source": str(source), "destination": str(target), "result": result})
        except Exception as exc:  # noqa: BLE001 - per-file audit must preserve failure details.
            moved.append({"source": str(source), "destination": str(target), "result": "failed", "error": str(exc)})
    return moved


def execute_decisions(decisions: list[MediaDecision]) -> dict:
    counts = {"moved_verified": 0, "sidecars_moved": 0, "failed": 0}
    failures: list[dict[str, str]] = []
    sidecar_results: list[dict[str, str]] = []

    for decision in decisions:
        try:
            result = move_verified(Path(decision.source_path), Path(decision.destination_path), decision.sha256)
            decision.move_result = result
            counts["moved_verified"] += 1
            for sidecar_result in move_sidecars(decision):
                sidecar_results.append(sidecar_result)
                if sidecar_result.get("result") in {"moved_verified", "destination_already_verified_source_removed"}:
                    counts["sidecars_moved"] += 1
        except Exception as exc:  # noqa: BLE001 - per-file audit must preserve failure details.
            decision.move_result = "failed"
            decision.move_error = str(exc)
            counts["failed"] += 1
            failures.append({"source_path": decision.source_path, "destination_path": decision.destination_path, "error": str(exc)})

    return {"counts": counts, "failures": failures[:200], "sidecars": sidecar_results[:500]}


def write_outputs(decisions: list[MediaDecision], manifest_dir: Path, stamp: str, summary: dict) -> tuple[Path, Path]:
    manifest_dir.mkdir(parents=True, exist_ok=True)
    csv_path = manifest_dir / f"ok-media-security-organize-{stamp}.csv"
    json_path = manifest_dir / f"ok-media-security-organize-{stamp}.summary.json"

    fields = list(asdict(MediaDecision("", "", "", "")).keys())
    with csv_path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        for decision in decisions:
            writer.writerow(asdict(decision))

    with json_path.open("w", encoding="utf-8") as handle:
        json.dump(summary, handle, indent=2, sort_keys=True)
        handle.write("\n")

    return csv_path, json_path


def load_manifest(path: Path) -> list[MediaDecision]:
    field_names = {item.name for item in fields(MediaDecision)}
    decisions: list[MediaDecision] = []
    with path.open("r", encoding="utf-8", newline="") as handle:
        for row in csv.DictReader(handle):
            values = {name: row.get(name, "") for name in field_names}
            values["byte_size"] = int(values.get("byte_size") or 0)
            decisions.append(MediaDecision(**values))
    return decisions


def summarize(
    decisions: list[MediaDecision],
    *,
    mode: str,
    ok_root: Path,
    unfiltered_root: Path,
    clamscan_available: bool,
    execution: dict | None = None,
) -> dict:
    summary: dict[str, object] = {
        "mode": mode,
        "ok_root": str(ok_root),
        "unfiltered_root": str(unfiltered_root),
        "organized_root": str(unfiltered_root / ORGANIZED_DIR_NAME),
        "security_review_root": str(unfiltered_root / SECURITY_REVIEW_DIR_NAME),
        "clamscan_available": clamscan_available,
        "candidate_count": len(decisions),
        "candidate_bytes": sum(decision.byte_size for decision in decisions),
        "by_classification": {},
        "by_action": {},
        "by_extension": {},
    }
    for decision in decisions:
        for key, value in (
            ("by_classification", decision.classification),
            ("by_action", decision.action),
            ("by_extension", decision.extension or "<none>"),
        ):
            bucket = summary[key]
            assert isinstance(bucket, dict)
            bucket[value] = int(bucket.get(value, 0)) + 1
    if execution is not None:
        summary["execution"] = execution
    return summary


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ok-root", type=Path, default=DEFAULT_OK_ROOT)
    parser.add_argument("--unfiltered-root", type=Path, default=DEFAULT_UNFILTERED_ROOT)
    parser.add_argument("--execute", action="store_true", help="Perform verified moves after writing the audit decisions.")
    parser.add_argument(
        "--extension-only",
        action="store_true",
        help="Only discover media by extension. By default, extensionless image/video MIME files are included too.",
    )
    parser.add_argument(
        "--execute-manifest",
        type=Path,
        help="Execute verified moves from an existing dry-run CSV manifest instead of re-probing files.",
    )
    parser.add_argument("--limit", type=int, default=0, help="Process only the first N candidates, for testing.")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    ok_root: Path = args.ok_root
    unfiltered_root: Path = args.unfiltered_root

    if not ok_root.is_dir():
        print(f"Ok root does not exist: {ok_root}", file=sys.stderr)
        return 2
    if not unfiltered_root.is_dir():
        print(f"Unfiltered root does not exist: {unfiltered_root}", file=sys.stderr)
        return 2

    clamscan_available = shutil.which("clamscan") is not None
    if args.execute_manifest:
        decisions = load_manifest(args.execute_manifest)
        execution = execute_decisions(decisions)
        summary = summarize(
            decisions,
            mode="execute-manifest-verified-move",
            ok_root=ok_root,
            unfiltered_root=unfiltered_root,
            clamscan_available=clamscan_available,
            execution=execution,
        )
        csv_path, json_path = write_outputs(
            decisions,
            unfiltered_root / SECURITY_REVIEW_DIR_NAME / MANIFEST_DIR_NAME,
            utc_stamp(),
            summary,
        )

        print(json.dumps(summary, indent=2, sort_keys=True))
        print(f"CSV manifest: {csv_path}")
        print(f"Summary JSON: {json_path}")
        return 1 if execution["counts"]["failed"] else 0

    paths = candidate_paths(ok_root, unfiltered_root, extension_only=args.extension_only)
    if args.limit:
        paths = paths[: args.limit]

    candidate_sizes = {file_size(path) for path in paths}
    existing_hashes = build_existing_hash_index(unfiltered_root, candidate_sizes)
    decisions = [
        decide(
            path,
            ok_root=ok_root,
            unfiltered_root=unfiltered_root,
            existing_hashes=existing_hashes,
            clamscan_available=clamscan_available,
        )
        for path in paths
    ]

    execution = execute_decisions(decisions) if args.execute else None
    summary = summarize(
        decisions,
        mode="execute-verified-move" if args.execute else "dry-run",
        ok_root=ok_root,
        unfiltered_root=unfiltered_root,
        clamscan_available=clamscan_available,
        execution=execution,
    )
    csv_path, json_path = write_outputs(
        decisions,
        unfiltered_root / SECURITY_REVIEW_DIR_NAME / MANIFEST_DIR_NAME,
        utc_stamp(),
        summary,
    )

    print(json.dumps(summary, indent=2, sort_keys=True))
    print(f"CSV manifest: {csv_path}")
    print(f"Summary JSON: {json_path}")
    if execution and execution["counts"]["failed"]:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
