#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
# Frozen main immediately before the Iroh major upgrade. Its application code,
# manifest and lockfile are built unchanged; only the setup/inspection example
# is added. It must not be silently updated to a modern Iroh implementation.
historical_ref=663c67c5a5650e923f20474963ae8df2bf884592
for required in cargo git python3 unshare ip dbus-daemon gnome-keyring-daemon secret-tool; do
  command -v "$required" >/dev/null || { echo "required command missing: $required" >&2; exit 1; }
done
export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-2}"
export CARGO_HOME="${CARGO_HOME:-$HOME/.cargo}"
export RUSTUP_HOME="${RUSTUP_HOME:-$HOME/.rustup}"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/photo-organizer-iroh-app.XXXXXX")"
# Retain only test daemon diagnostics and public verdicts, never keyrings,
# runtime identity files, databases or encrypted media.
evidence_root="${IROH_APP_EVIDENCE_DIR:-${CARGO_TARGET_DIR:-$repo_root/target}/iroh-app-evidence}"
keyring_bus_pids=()
network_pid=''
cancel() {
  local status="$1"
  trap '' INT TERM
  if [[ -n "$network_pid" ]]; then
    kill -TERM "$network_pid" 2>/dev/null || true
    wait "$network_pid" 2>/dev/null || true
    network_pid=''
  else
    # A signal may arrive after the background launch but before $! has been
    # assigned. The shell job table already owns that child at this point.
    local child_pid
    for child_pid in $(jobs -pr); do
      kill -TERM "$child_pid" 2>/dev/null || true
      wait "$child_pid" 2>/dev/null || true
    done
  fi
  exit "$status"
}
trap 'cancel 130' INT
trap 'cancel 143' TERM
cleanup() {
  local result=$?
  local diagnostics_result=0
  local removal_result=0
  local keyring_result=0
  # Capturing public diagnostics is useful, but it must never prevent removal
  # of the temporary keyrings, identity files, databases, and media below.
  if ! python3 - "$test_root" "$evidence_root" <<'PY'
import pathlib, shutil, sys
source, destination = map(pathlib.Path, sys.argv[1:])
destination = destination / source.name
for path in [*source.rglob('daemon.log'), source / 'evidence.jsonl']:
    if path.is_file():
        target = destination / path.relative_to(source)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path, target)
print(f'Iroh application test diagnostics: {destination}')
PY
  then
    diagnostics_result=1
    echo 'failed to preserve Iroh application test diagnostics' >&2
  fi
  # The D-Bus session owns its temporary Secret Service process. Stop every
  # session before deleting its socket/keyring tree; a failed stop is reported
  # but never lets a previous test failure disappear.
  for bus_pid in "${keyring_bus_pids[@]}"; do
    if ! kill "$bus_pid" 2>/dev/null; then
      keyring_result=1
      echo "failed to stop isolated Iroh test D-Bus session: $bus_pid" >&2
    fi
  done
  if ! rm -rf -- "$test_root"; then
    removal_result=1
    echo "failed to remove isolated Iroh application test directory: $test_root" >&2
  fi
  # Do not turn a test failure into a cleanup failure: the original error is
  # the actionable result. Successful runs, however, fail closed if either
  # diagnostics or sensitive-data cleanup could not complete.
  if (( result != 0 )); then
    return "$result"
  fi
  if (( removal_result != 0 || diagnostics_result != 0 || keyring_result != 0 )); then
    return 1
  fi
  return 0
}
trap cleanup EXIT
export PHOTO_ORGANIZER_IROH_APP_TEST_ROOT="$test_root"
mkdir "$test_root/historical"
git -C "$repo_root" archive "$historical_ref" | tar -x -C "$test_root/historical"
python3 - "$test_root/historical/native_core/Cargo.toml" <<'PY'
import pathlib, sys, tomllib
manifest = tomllib.loads(pathlib.Path(sys.argv[1]).read_text())
assert manifest['dependencies']['iroh'] == '0.98.2', 'frozen source must use historical Iroh'
PY
mkdir -p "$test_root/historical/native_core/examples"
cp "$repo_root/native_core/examples/iroh_app_fixture.rs" "$test_root/historical/native_core/examples/"
# Build sequentially in the one shared target tree. Copy finished executables
# before the historical package overwrites their same-named target paths.
base_target="${CARGO_TARGET_DIR:-$repo_root/target}"
base_target="$(realpath -m "$base_target")"
mkdir -p "$test_root/bin/current" "$test_root/bin/historical"
cargo build --locked --manifest-path "$repo_root/Cargo.toml" --target-dir "$base_target" -p native_core --bin galleryd --example iroh_app_fixture
cp "$base_target/debug/galleryd" "$test_root/bin/current/galleryd"
cp "$base_target/debug/examples/iroh_app_fixture" "$test_root/bin/current/iroh_app_fixture"
cargo build --locked --manifest-path "$test_root/historical/Cargo.toml" --target-dir "$base_target" -p native_core --bin galleryd --example iroh_app_fixture
cp "$base_target/debug/galleryd" "$test_root/bin/historical/galleryd"
cp "$base_target/debug/examples/iroh_app_fixture" "$test_root/bin/historical/iroh_app_fixture"
export IROH_APP_CURRENT_BIN="$test_root/bin/current/galleryd"
export IROH_APP_HISTORICAL_BIN="$test_root/bin/historical/galleryd"
export IROH_APP_CURRENT_FIXTURE_BIN="$test_root/bin/current/iroh_app_fixture"
export IROH_APP_HISTORICAL_FIXTURE_BIN="$test_root/bin/historical/iroh_app_fixture"
export IROH_APP_REPO="$repo_root"
start_keyring_session() {
  local name="$1"
  local output_variable="$2"
  local session_root="$test_root/keyrings/$name"
  local session_info session_address session_pid
  mkdir -p "$session_root/home/data" "$session_root/run" "$session_root/control"
  chmod 700 "$session_root/run" "$session_root/control"
  session_info="$(dbus-daemon --session --fork \
    --address="unix:path=$session_root/run/bus" --print-address=1 --print-pid=1)"
  session_address="$(printf '%s\n' "$session_info" | sed -n '1p')"
  session_pid="$(printf '%s\n' "$session_info" | sed -n '2p')"
  case "$session_address" in
    "unix:path=$session_root/"*) ;;
    *) echo "isolated D-Bus address escaped test root: $session_address" >&2; return 1 ;;
  esac
  if ! printf '\n' | env \
    HOME="$session_root/home" \
    XDG_DATA_HOME="$session_root/home/data" \
    XDG_RUNTIME_DIR="$session_root/run" \
    DBUS_SESSION_BUS_ADDRESS="$session_address" \
    gnome-keyring-daemon --unlock --components=secrets \
      --control-directory="$session_root/control" >/dev/null; then
    echo "failed to start isolated Secret Service session: $name" >&2
    kill "$session_pid" 2>/dev/null || true
    return 1
  fi
  # Fail before building if this session is not usable from the same kind of
  # root-mapped user namespace as the daemons. The probe is an exact
  # test-only entry and is removed immediately; no host keyring is touched.
  local probe_attribute="photo-organizer-iroh-$name-$$"
  if ! printf '%s' "$name" | env \
    HOME="$session_root/home" \
    XDG_DATA_HOME="$session_root/home/data" \
    XDG_RUNTIME_DIR="$session_root/run" \
    DBUS_SESSION_BUS_ADDRESS="$session_address" \
    secret-tool store --label='Photo Organizer Iroh harness probe' app "$probe_attribute"; then
    echo "isolated Secret Service cannot store a probe: $name" >&2
    kill "$session_pid" 2>/dev/null || true
    return 1
  fi
  if ! unshare --user --map-root-user --net -- env \
    DBUS_SESSION_BUS_ADDRESS="$session_address" \
    secret-tool lookup app "$probe_attribute" | grep -Fxq "$name"; then
    echo "isolated Secret Service is unavailable to a network-isolated node: $name" >&2
    env DBUS_SESSION_BUS_ADDRESS="$session_address" secret-tool clear app "$probe_attribute" || true
    kill "$session_pid" 2>/dev/null || true
    return 1
  fi
  if ! env DBUS_SESSION_BUS_ADDRESS="$session_address" secret-tool clear app "$probe_attribute"; then
    echo "failed to remove isolated Secret Service probe: $name" >&2
    kill "$session_pid" 2>/dev/null || true
    return 1
  fi
  keyring_bus_pids+=("$session_pid")
  printf -v "$output_variable" '%s' "$session_address"
}
# The project processes run in a shared user+network namespace so historical
# and current daemons can exchange direct packets but have no route to the
# Internet. GNOME Keyring cannot drop capabilities while mapped to namespace
# root, so create one temporary, per-node Secret Service in the parent user
# namespace first. Its only transport is a Unix socket under test_root; the
# daemon retains both the network isolation and independent keyring identity.
start_keyring_session source IROH_APP_SOURCE_DBUS_ADDRESS
start_keyring_session receiver IROH_APP_RECEIVER_DBUS_ADDRESS
export IROH_APP_SOURCE_DBUS_ADDRESS IROH_APP_RECEIVER_DBUS_ADDRESS
IROH_APP_HOST_UID="$(id -u)"
IROH_APP_HOST_GID="$(id -g)"
export IROH_APP_HOST_UID IROH_APP_HOST_GID
# Historical code still enables N0 lookup when relays are disabled. A private
# network namespace has no external interfaces/routes, so even that unchanged
# binary cannot publish test endpoint information. There is no permissive fallback.
unshare --user --map-root-user --net -- bash -euo pipefail <<'NETWORK' &
ip link set lo up
# Iroh excludes loopback during interface discovery. A private veth advertises
# an address without providing a gateway or any route to hosted infrastructure.
ip link add interop0 type veth peer name interop1
ip address add 192.0.2.1/24 dev interop0
ip link set interop0 up
ip link set interop1 up
# libdbus authenticates using the process UID. Restore the caller's numerical
# UID in a nested user namespace after configuring the isolated network, so
# both D-Bus EXTERNAL authentication and socket peer credentials agree.
exec unshare --user --map-user="$IROH_APP_HOST_UID" --map-group="$IROH_APP_HOST_GID" -- \
  python3 "$IROH_APP_REPO/scripts/tests/iroh_historical_app_test.py"
NETWORK
network_pid=$!
wait "$network_pid"
network_pid=''
printf 'Historical/current application Push/evict/Pull and identity acceptance passed.\n'
