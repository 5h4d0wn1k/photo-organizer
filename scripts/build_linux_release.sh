#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CARGO_BIN="${CARGO_BIN:-cargo}"
FLUTTER_BIN="${FLUTTER_BIN:-flutter}"
APP_BUNDLE_DIR="${ROOT_DIR}/app/build/linux/x64/release/bundle"
DAEMON_BIN="${ROOT_DIR}/target/release/galleryd"

echo "Building Rust daemon..."
"${CARGO_BIN}" build --manifest-path "${ROOT_DIR}/native_core/Cargo.toml" --bin galleryd --release

echo "Building Flutter Linux app..."
(cd "${ROOT_DIR}/app" && "${FLUTTER_BIN}" build linux)

if [[ ! -x "${DAEMON_BIN}" ]]; then
  echo "Expected daemon binary not found: ${DAEMON_BIN}" >&2
  exit 1
fi

echo "Bundling galleryd beside the Flutter app..."
cp "${DAEMON_BIN}" "${APP_BUNDLE_DIR}/galleryd"
chmod +x "${APP_BUNDLE_DIR}/galleryd"
rm -rf "${APP_BUNDLE_DIR}/ml_sidecar"
cp -R "${ROOT_DIR}/ml_sidecar" "${APP_BUNDLE_DIR}/ml_sidecar"
chmod +x "${APP_BUNDLE_DIR}/ml_sidecar/private_gallery_ml_sidecar.py"
chmod +x "${ROOT_DIR}/scripts/private_gallery_linux_launcher.sh"

echo "Linux release bundle is ready:"
echo "${APP_BUNDLE_DIR}/private_gallery_app"
echo
echo "Recommended launcher:"
echo "${ROOT_DIR}/scripts/private_gallery_linux_launcher.sh"
