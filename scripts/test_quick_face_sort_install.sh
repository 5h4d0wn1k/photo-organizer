#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python_bin="${1:-python3}"
venv_dir="$(mktemp -d "${TMPDIR:-/tmp}/photo-organizer-face-sort.XXXXXX")"
trap 'rm -rf "$venv_dir"' EXIT

"$python_bin" -m venv "$venv_dir/venv"
venv_python="$venv_dir/venv/bin/python"

"$venv_python" -m pip install -r "$repo_root/tools/quick-face-sort/requirements.txt"
"$venv_python" -m pip check
PYTHONPATH="$repo_root/tools/quick-face-sort" "$venv_python" -c \
  'import cv2; import face_recognition; import main; import tkinter'

printf 'Fresh virtualenv install and import smoke passed with %s\n' "$python_bin"
