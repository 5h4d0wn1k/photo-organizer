#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXIT_CODE=0

echo "Smoke release check starting..."

# Run cargo test on native_core
if command -v cargo >/dev/null 2>&1; then
  echo "Running cargo test in native_core..."
  if cargo test --manifest-path "${ROOT_DIR}/native_core/Cargo.toml" --quiet; then
    echo "PASS: cargo test (native_core)"
  else
    echo "FAIL: cargo test (native_core)"
    EXIT_CODE=1
  fi
else
  echo "SKIP: cargo not installed"
fi

# flutter analyze in app (skip if not installed)
if command -v flutter >/dev/null 2>&1; then
  echo "Running flutter analyze in app..."
  if (cd "${ROOT_DIR}/app" && flutter analyze --no-pub); then
    echo "PASS: flutter analyze (app)"
  else
    echo "FAIL: flutter analyze (app)"
    EXIT_CODE=1
  fi
else
  echo "SKIP: flutter not installed"
fi

echo "Smoke release check complete (exit=${EXIT_CODE})"
exit "${EXIT_CODE}"
