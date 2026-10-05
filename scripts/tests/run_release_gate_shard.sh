#!/usr/bin/env bash
set -uo pipefail

if (($# != 5)); then
  printf 'usage: run_release_gate_shard.sh SHARD_COUNT SHARD_INDEX SUITE LOG STATUS\n' >&2
  exit 2
fi

shard_count="$1"
shard_index="$2"
suite="$3"
log_path="$4"
status_path="$5"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

set -o pipefail
MUTATION_SHARDS="${shard_count}" MUTATION_SHARD="${shard_index}" \
  SHARD_WRAPPER_PID="$$" bash "${suite}" 2>&1 \
  | tee "${log_path}" \
  | python3 -u "${script_dir}/prefix_shard_output.py" "${shard_index}"
suite_rc=$?

status_tmp="${status_path}.tmp.$$"
if ! printf '%s\n' "${suite_rc}" >"${status_tmp}"; then
  printf 'FATAL: cannot write shard status marker: %s\n' "${status_tmp}" >&2
  exit 1
fi
if ! mv "${status_tmp}" "${status_path}"; then
  printf 'FATAL: cannot publish shard status marker: %s\n' "${status_path}" >&2
  exit 1
fi
