#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/photo-organizer-secret-service.XXXXXX")"
cargo_home="${CARGO_HOME:-$HOME/.cargo}"
rustup_home="${RUSTUP_HOME:-$HOME/.rustup}"
trap 'rm -rf "$temporary_root"' EXIT

for command_name in dbus-run-session gnome-keyring-daemon; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    printf 'required command is missing: %s\n' "$command_name" >&2
    exit 1
  fi
done

export PHOTO_ORGANIZER_SECRET_SERVICE_TEST_ROOT="$temporary_root"
export PHOTO_ORGANIZER_SECRET_SERVICE_TEST_REPO="$repo_root"
export CARGO_HOME="$cargo_home"
export RUSTUP_HOME="$rustup_home"
export TMPDIR="$temporary_root/tmp"
mkdir -p "$TMPDIR"

dbus-run-session -- bash -euo pipefail <<'SESSION'
  isolated_home="$PHOTO_ORGANIZER_SECRET_SERVICE_TEST_ROOT/home"
  mkdir -p "$isolated_home/data" "$PHOTO_ORGANIZER_SECRET_SERVICE_TEST_ROOT/run" "$PHOTO_ORGANIZER_SECRET_SERVICE_TEST_ROOT/control"
  chmod 700 "$PHOTO_ORGANIZER_SECRET_SERVICE_TEST_ROOT/run" "$PHOTO_ORGANIZER_SECRET_SERVICE_TEST_ROOT/control"
  export XDG_RUNTIME_DIR="$PHOTO_ORGANIZER_SECRET_SERVICE_TEST_ROOT/run"
  unset GNOME_KEYRING_CONTROL
  export HOME="$isolated_home"
  export XDG_DATA_HOME="$isolated_home/data"

  # Unlock a new temporary keyring with an empty passphrase. This keyring lives
  # only under the per-run temporary HOME and is removed when the session ends.
  eval "$(printf "\\n" | gnome-keyring-daemon --unlock --components=secrets --control-directory="$PHOTO_ORGANIZER_SECRET_SERVICE_TEST_ROOT/control")"
  cd "$PHOTO_ORGANIZER_SECRET_SERVICE_TEST_REPO/native_core"
  cargo test --locked --test vault_key_production \
    production_keyring_provisions_and_reopens_vault_key -- --exact --ignored
SESSION

printf 'Production keyring Secret Service round-trip passed in an isolated session.\n'
