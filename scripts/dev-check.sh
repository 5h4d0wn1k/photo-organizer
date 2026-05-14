#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "Running lightweight checks from: ${ROOT_DIR}"

if command -v cargo >/dev/null 2>&1; then
  echo
  echo "[cargo] fmt --check"
  cargo fmt --manifest-path "${ROOT_DIR}/native_core/Cargo.toml" --all -- --check

  echo
  echo "[cargo] test"
  cargo test --manifest-path "${ROOT_DIR}/native_core/Cargo.toml"
else
  echo "cargo not available; skipping Rust validation."
fi

if command -v flutter >/dev/null 2>&1; then
  echo
  echo "[flutter] analyze"
  flutter analyze "${ROOT_DIR}/app"
else
  echo "flutter not available; skipping Flutter validation."
fi
