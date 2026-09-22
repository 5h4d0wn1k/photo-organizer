#!/usr/bin/env python3
"""Local ML sidecar for Private Gallery.

This sidecar is intentionally a command-line process, not a server. It reads
local files, writes JSON to stdout, and never opens a network listener.
"""

from __future__ import annotations

import importlib.util
import importlib.metadata
import hashlib
import json
import os
import platform
import sys


OFFLINE_ENV_KEYS = {
    "HF_HUB_OFFLINE": "1",
    "TRANSFORMERS_OFFLINE": "1",
    "HF_DATASETS_OFFLINE": "1",
    "WANDB_DISABLED": "true",
    "DO_NOT_TRACK": "1",
}


def _dependency_status(name: str) -> dict[str, object]:
    available = importlib.util.find_spec(name) is not None
    version = None
    if available:
        package_name = {
            "cv2": "opencv-python",
            "PIL": "Pillow",
        }.get(name, name)
        try:
            version = importlib.metadata.version(package_name)
        except importlib.metadata.PackageNotFoundError:
            version = None
    return {
        "name": name,
        "available": available,
        "version": version,
    }


def probe() -> dict[str, object]:
    offline_env = {
        key: os.environ.get(key)
        for key in sorted(OFFLINE_ENV_KEYS)
    }
    offline_ready = all(
        str(offline_env.get(key)).lower() == expected
        for key, expected in OFFLINE_ENV_KEYS.items()
    )
    dependencies = [
        _dependency_status("PIL"),
        _dependency_status("numpy"),
        _dependency_status("onnxruntime"),
        _dependency_status("cv2"),
    ]
    return {
        "ok": True,
        "runtime": "python-sidecar",
        "python_version": platform.python_version(),
        "executable": sys.executable,
        "offline_ready": offline_ready,
        "offline_env": offline_env,
        "dependencies": dependencies,
        "detail": (
            "Python sidecar is callable. Inference remains disabled until "
            "approved local models and provider commands are implemented."
        ),
    }


def _sidecar_hash() -> str | None:
    try:
        with open(__file__, "rb") as handle:
            return hashlib.sha256(handle.read()).hexdigest()
    except OSError:
        return None


def _add_tag(tags: list[dict[str, object]], label: str, confidence: float) -> None:
    if confidence <= 0:
        return
    confidence = max(0.01, min(0.99, confidence))
    existing = next((tag for tag in tags if tag["label"] == label), None)
    if existing is not None:
        existing["confidence"] = max(float(existing["confidence"]), confidence)
        return
    tags.append({"label": label, "confidence": round(confidence, 3)})


def scene_tags(image_path: str) -> dict[str, object]:
    try:
        from PIL import Image, ImageStat
    except ImportError as error:
        return {
            "ok": False,
            "runtime": "python-sidecar",
            "detail": f"local scene provider missing Pillow/PIL: {error}",
        }

    try:
        with Image.open(image_path) as image:
            width, height = image.size
            thumb = image.convert("RGB")
            thumb.thumbnail((96, 96))
            stat = ImageStat.Stat(thumb)
            mean_r, mean_g, mean_b = [value / 255.0 for value in stat.mean]
            gray = thumb.convert("L")
            gray_stat = ImageStat.Stat(gray)
            brightness = gray_stat.mean[0] / 255.0
            contrast = gray_stat.stddev[0] / 255.0
    except Exception as error:  # Pillow raises several image-specific errors.
        return {
            "ok": False,
            "runtime": "python-sidecar",
            "detail": f"local scene analysis failed: {error}",
        }

    max_channel = max(mean_r, mean_g, mean_b)
    min_channel = min(mean_r, mean_g, mean_b)
    saturation = 0.0 if max_channel <= 0 else (max_channel - min_channel) / max_channel
    aspect = width / max(1, height)

    tags: list[dict[str, object]] = []
    _add_tag(tags, "photo", 0.52)

    if aspect >= 1.25:
        _add_tag(tags, "landscape_orientation", min(0.95, 0.55 + (aspect - 1.25) / 3.0))
    elif aspect <= 0.8:
        _add_tag(tags, "portrait_orientation", min(0.95, 0.55 + (0.8 - aspect) / 2.0))
    else:
        _add_tag(tags, "square_or_balanced_frame", 0.55)

    if brightness < 0.24:
        _add_tag(tags, "dark_or_low_light", 0.7 + (0.24 - brightness))
    elif brightness > 0.78:
        _add_tag(tags, "bright_image", 0.65 + min(0.25, brightness - 0.78))

    if saturation < 0.08:
        _add_tag(tags, "black_and_white_or_low_color", 0.7)
    elif saturation > 0.38:
        _add_tag(tags, "colorful", min(0.95, 0.55 + saturation))

    if contrast > 0.24:
        _add_tag(tags, "high_contrast", min(0.95, 0.55 + contrast))
    elif contrast < 0.08:
        _add_tag(tags, "low_contrast", 0.65)

    if mean_g > mean_r * 1.08 and mean_g > mean_b * 1.04 and saturation > 0.15:
        _add_tag(tags, "greenery_or_nature_hint", min(0.92, 0.52 + (mean_g - max(mean_r, mean_b)) * 2.2))

    if mean_b > mean_r * 1.12 and mean_b >= mean_g * 0.95 and brightness > 0.42:
        _add_tag(tags, "sky_or_blue_tone_hint", min(0.9, 0.5 + (mean_b - mean_r) * 1.8))

    if mean_r > mean_b * 1.12 and saturation > 0.12:
        _add_tag(tags, "warm_tone", min(0.9, 0.5 + (mean_r - mean_b) * 1.8))
    elif mean_b > mean_r * 1.12 and saturation > 0.12:
        _add_tag(tags, "cool_tone", min(0.9, 0.5 + (mean_b - mean_r) * 1.8))

    if brightness > 0.68 and saturation < 0.18 and contrast > 0.11:
        _add_tag(tags, "document_or_screenshot_hint", min(0.86, 0.52 + contrast))

    tags = sorted(tags, key=lambda item: float(item["confidence"]), reverse=True)[:8]
    return {
        "ok": True,
        "runtime": "python-sidecar",
        "model_name": "local-heuristic-scene-tagger",
        "model_version": "v1",
        "model_hash": _sidecar_hash(),
        "tags": tags,
        "detail": "Local heuristic scene analysis completed without network or model downloads.",
    }


def main(argv: list[str]) -> int:
    if len(argv) >= 2 and argv[1] == "probe":
        print(json.dumps(probe(), sort_keys=True))
        return 0

    if len(argv) >= 3 and argv[1] == "scene-tags":
        print(json.dumps(scene_tags(argv[2]), sort_keys=True))
        return 0

    if len(argv) < 2:
        detail = "unsupported command; expected 'probe' or 'scene-tags <image_path>'"
    else:
        detail = f"unsupported command '{argv[1]}'; expected 'probe' or 'scene-tags <image_path>'"

    print(
        json.dumps(
            {
                "ok": False,
                "runtime": "python-sidecar",
                "detail": detail,
            }
        )
    )
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
