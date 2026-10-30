#!/usr/bin/env bash
# Keep byte-for-byte stage behavior aligned with the publisher; tested in release_candidate_validation_test.py.
set -euo pipefail
platforms=(android linux windows macos ios)
missing=()
for platform in "${platforms[@]}"; do
  dir="incoming/${platform}"
  if [[ ! -d "${dir}" ]]; then
    missing+=("${platform}: no directory")
    continue
  fi
  count="$(find "${dir}" -type f -size +0c | wc -l)"
  if [[ "${count}" -eq 0 ]]; then
    missing+=("${platform}: no non-empty file")
  fi
done
if [[ "${#missing[@]}" -ne 0 ]]; then
  echo "::error::refusing to publish a partial release:" >&2
  printf '  %s\n' "${missing[@]}" >&2
  exit 1
fi

rm -rf dist
mkdir -p dist
for platform in "${platforms[@]}"; do
  while IFS= read -r file; do
    base="$(basename "${file}")"
    if [[ -e "dist/${base}" ]]; then
      echo "::error::refusing to publish: ${base} is produced by more than one platform and would overwrite the other" >&2
      exit 1
    fi
    cp "${file}" "dist/${base}"
  done < <(find "incoming/${platform}" -type f -size +0c)
done

echo "staged $(find dist -type f | wc -l) files from ${#platforms[@]} platforms:"
ls -l dist
