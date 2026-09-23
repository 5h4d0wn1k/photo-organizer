#!/usr/bin/env python3
"""Move audio files from Ok into Ok/Audio with verified moves.

Default mode is dry-run. Execute mode hashes the source, copies to a temporary
destination under Ok/Audio, verifies the destination hash, then removes the
source. Matching JSON sidecars are moved beside the audio file when present.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import os
import shutil
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path


DEFAULT_OK_ROOT = Path("/mnt/windows/transfer/Ok")
DEFAULT_AUDIO_ROOT = Path("/mnt/windows/transfer/Ok/Audio")
HASH_BUFFER_BYTES = 1024 * 1024

AUDIO_EXTENSIONS = {
    ".aac",
    ".aif",
    ".aiff",
    ".alac",
    ".amr",
    ".ape",
    ".au",
    ".caf",
    ".flac",
    ".m4a",
    ".m4b",
    ".mka",
    ".mid",
    ".midi",
    ".mp3",
    ".oga",
    ".ogg",
    ".opus",
    ".ra",
    ".wav",
    ".weba",
    ".wma",
}


@dataclass
class AudioMoveDecision:
    source_path: str
    destination_path: str
    action: str
    status: str
    sha256: str = ""
    byte_size: int = 0
    sidecar_paths: str = ""
    move_result: str = ""
    move_error: str = ""


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


def iter_audio_files(ok_root: Path, audio_root: Path) -> list[Path]:
    audio_files: list[Path] = []
    for current, dirnames, filenames in os.walk(ok_root):
        current_path = Path(current)
        kept_dirs = []
        for dirname in dirnames:
            candidate = current_path / dirname
            if is_under(candidate, audio_root):
                continue
            kept_dirs.append(dirname)
        dirnames[:] = kept_dirs
        for filename in filenames:
            path = current_path / filename
            if path.suffix.lower() in AUDIO_EXTENSIONS:
                audio_files.append(path)
    return audio_files


def relative_destination(ok_root: Path, source: Path) -> Path:
    try:
        return source.relative_to(ok_root)
    except ValueError:
        return Path(source.name)


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


def sidecars_for(path: Path) -> list[Path]:
    candidates = [path.with_name(f"{path.name}.json"), path.with_suffix(".json")]
    seen: set[Path] = set()
    result: list[Path] = []
    for candidate in candidates:
        if candidate in seen:
            continue
        seen.add(candidate)
        if candidate.exists() and candidate.is_file():
            result.append(candidate)
    return result


def decide(ok_root: Path, audio_root: Path) -> list[AudioMoveDecision]:
    decisions: list[AudioMoveDecision] = []
    for source in iter_audio_files(ok_root, audio_root):
        try:
            digest = sha256_file(source)
        except OSError as exc:
            decisions.append(
                AudioMoveDecision(
                    source_path=str(source),
                    destination_path="",
                    action="keep_source",
                    status="hash_failed",
                    byte_size=file_size(source),
                    move_error=str(exc),
                )
            )
            continue

        destination = unique_destination(audio_root / relative_destination(ok_root, source), digest)
        decisions.append(
            AudioMoveDecision(
                source_path=str(source),
                destination_path=str(destination),
                action="move_to_audio",
                status="ready",
                sha256=digest,
                byte_size=file_size(source),
                sidecar_paths=json.dumps([str(item) for item in sidecars_for(source)], ensure_ascii=False),
            )
        )
    return decisions


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
        if sha256_file(temp_destination) != expected_hash:
            temp_destination.unlink(missing_ok=True)
            raise RuntimeError("Destination hash verification failed; source left in place.")
        temp_destination.replace(destination)
        source.unlink()
        return "moved_verified"
    finally:
        temp_destination.unlink(missing_ok=True)


def move_sidecars(decision: AudioMoveDecision) -> list[dict[str, str]]:
    moved: list[dict[str, str]] = []
    source_audio = Path(decision.source_path)
    destination_audio = Path(decision.destination_path)
    for raw_path in json.loads(decision.sidecar_paths or "[]"):
        source = Path(raw_path)
        if not source.exists():
            continue
        if source.name == f"{source_audio.name}.json":
            destination = destination_audio.with_name(f"{destination_audio.name}.json")
        else:
            destination = destination_audio.with_suffix(".json")
        try:
            result = move_verified(source, destination, sha256_file(source))
            moved.append({"source": str(source), "destination": str(destination), "result": result})
        except Exception as exc:  # noqa: BLE001 - keep cleanup failure in manifest.
            moved.append({"source": str(source), "destination": str(destination), "result": "failed", "error": str(exc)})
    return moved


def execute(decisions: list[AudioMoveDecision]) -> dict:
    counts = {"moved_verified": 0, "sidecars_moved": 0, "failed": 0}
    failures: list[dict[str, str]] = []
    sidecars: list[dict[str, str]] = []

    for decision in decisions:
        if decision.action != "move_to_audio":
            continue
        try:
            decision.move_result = move_verified(Path(decision.source_path), Path(decision.destination_path), decision.sha256)
            counts["moved_verified"] += 1
            for item in move_sidecars(decision):
                sidecars.append(item)
                if item.get("result") in {"moved_verified", "destination_already_verified_source_removed"}:
                    counts["sidecars_moved"] += 1
        except Exception as exc:  # noqa: BLE001 - per-file audit should continue.
            decision.move_result = "failed"
            decision.move_error = str(exc)
            counts["failed"] += 1
            failures.append({"source_path": decision.source_path, "destination_path": decision.destination_path, "error": str(exc)})

    return {"counts": counts, "failures": failures[:200], "sidecars": sidecars[:200]}


def summarize(decisions: list[AudioMoveDecision], *, mode: str, ok_root: Path, audio_root: Path, execution: dict | None = None) -> dict:
    summary: dict[str, object] = {
        "mode": mode,
        "ok_root": str(ok_root),
        "audio_root": str(audio_root),
        "candidate_count": len(decisions),
        "candidate_bytes": sum(decision.byte_size for decision in decisions),
        "by_status": {},
        "by_action": {},
    }
    for decision in decisions:
        for key, value in (("by_status", decision.status), ("by_action", decision.action)):
            bucket = summary[key]
            assert isinstance(bucket, dict)
            bucket[value] = int(bucket.get(value, 0)) + 1
    if execution is not None:
        summary["execution"] = execution
    return summary


def write_outputs(decisions: list[AudioMoveDecision], summary: dict, audio_root: Path, stamp: str) -> tuple[Path, Path]:
    manifest_dir = audio_root / "_manifests"
    manifest_dir.mkdir(parents=True, exist_ok=True)
    csv_path = manifest_dir / f"move-ok-audio-{stamp}.csv"
    json_path = manifest_dir / f"move-ok-audio-{stamp}.summary.json"
    field_names = list(asdict(AudioMoveDecision("", "", "", "")).keys())

    with csv_path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=field_names)
        writer.writeheader()
        for decision in decisions:
            writer.writerow(asdict(decision))

    with json_path.open("w", encoding="utf-8") as handle:
        json.dump(summary, handle, indent=2, sort_keys=True)
        handle.write("\n")

    return csv_path, json_path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ok-root", type=Path, default=DEFAULT_OK_ROOT)
    parser.add_argument("--audio-root", type=Path, default=DEFAULT_AUDIO_ROOT)
    parser.add_argument("--execute", action="store_true", help="Perform verified moves.")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    ok_root: Path = args.ok_root
    audio_root: Path = args.audio_root
    if not ok_root.is_dir():
        print(f"Ok root does not exist: {ok_root}")
        return 2
    audio_root.mkdir(parents=True, exist_ok=True)

    decisions = decide(ok_root, audio_root)
    execution = execute(decisions) if args.execute else None
    summary = summarize(
        decisions,
        mode="execute-verified-move" if args.execute else "dry-run",
        ok_root=ok_root,
        audio_root=audio_root,
        execution=execution,
    )
    csv_path, json_path = write_outputs(decisions, summary, audio_root, utc_stamp())
    print(json.dumps(summary, indent=2, sort_keys=True))
    print(f"CSV manifest: {csv_path}")
    print(f"Summary JSON: {json_path}")
    if execution and execution["counts"]["failed"]:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
