#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/photo-organizer-portable.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT
for command_name in dbus-run-session gnome-keyring-daemon; do
  command -v "$command_name" >/dev/null 2>&1 || { printf 'required command missing: %s\n' "$command_name" >&2; exit 1; }
done
export PHOTO_ORGANIZER_RECOVERY_TEST_ROOT="$test_root"
export PHOTO_ORGANIZER_RECOVERY_TEST_REPO="$repo_root"
export CARGO_HOME="${CARGO_HOME:-$HOME/.cargo}"
export RUSTUP_HOME="${RUSTUP_HOME:-$HOME/.rustup}"
printf 'photo-organizer-portable-test' > "$test_root/harness.marker"
for phase in export restore; do
  export PHOTO_ORGANIZER_RECOVERY_TEST_PHASE="$phase"
  dbus-run-session -- bash -euo pipefail <<'SESSION'
phase_root="$PHOTO_ORGANIZER_RECOVERY_TEST_ROOT/keyring-$PHOTO_ORGANIZER_RECOVERY_TEST_PHASE"
mkdir -p "$phase_root/home/data" "$phase_root/run" "$phase_root/control" "$phase_root/tmp"
chmod 700 "$phase_root/run" "$phase_root/control"
export HOME="$phase_root/home"
export XDG_DATA_HOME="$HOME/data"
export XDG_RUNTIME_DIR="$phase_root/run"
export TMPDIR="$phase_root/tmp"
unset GNOME_KEYRING_CONTROL
eval "$(printf '\n' | gnome-keyring-daemon --unlock --components=secrets --control-directory="$phase_root/control")"
cd "$PHOTO_ORGANIZER_RECOVERY_TEST_REPO/native_core"
cargo test --locked --test portable_recovery_production "portable_${PHOTO_ORGANIZER_RECOVERY_TEST_PHASE}_phase" -- --exact --ignored
SESSION
done
printf 'Production portable recovery passed across independent Secret Service sessions.\n'
