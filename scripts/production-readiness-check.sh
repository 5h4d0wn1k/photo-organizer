#!/usr/bin/env bash

set -u

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CARGO_BIN="${CARGO_BIN:-cargo}"
FLUTTER_BIN="${FLUTTER_BIN:-flutter}"
GIT_BIN="${GIT_BIN:-git}"
REQUIRE_RELEASE_SIGNING="${PRIVATE_GALLERY_READINESS_REQUIRE_RELEASE_SIGNING:-0}"

pass_count=0
fail_count=0
skip_count=0
warn_count=0

pass() {
  printf 'PASS: %s\n' "$1"
  pass_count=$((pass_count + 1))
}

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  fail_count=$((fail_count + 1))
}

skip() {
  printf 'SKIP: %s\n' "$1"
  skip_count=$((skip_count + 1))
}

warn() {
  printf 'WARN: %s\n' "$1" >&2
  warn_count=$((warn_count + 1))
}

is_enabled() {
  case "${1:-}" in
    1 | true | TRUE | yes | YES) return 0 ;;
    *) return 1 ;;
  esac
}

run_check() {
  local label="$1"
  shift

  printf '\n==> %s\n' "$label"
  if "$@"; then
    pass "$label"
  else
    local status=$?
    fail "${label} exited ${status}"
  fi
}

have_command() {
  command -v "$1" >/dev/null 2>&1
}

is_enabled() {
  case "${1:-}" in
    1 | true | TRUE | yes | YES | on | ON)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

read_shell_scripts() {
  mapfile -d '' SHELL_SCRIPTS < <(find "${ROOT_DIR}/scripts" -maxdepth 1 -type f -name '*.sh' -print0 | sort -z)
}

check_bash_syntax() {
  local script
  for script in "${SHELL_SCRIPTS[@]}"; do
    bash -n "$script" || return $?
  done
}

check_git_state() {
  local status
  if ! status="$("${GIT_BIN}" -C "${ROOT_DIR}" status --short)"; then
    warn "git status failed; release evidence should be captured from a valid checkout"
    return 1
  fi

  if [[ -n "$status" ]]; then
    warn "worktree has uncommitted changes; release artifacts should come from a reviewed tag or clean release commit"
    if is_enabled "${PRIVATE_GALLERY_READINESS_REQUIRE_CLEAN_GIT:-0}"; then
      return 1
    fi
  else
    pass "git worktree has no uncommitted changes"
  fi
}

check_android_release_signing_config() {
  local gradle_file="${ROOT_DIR}/app/android/app/build.gradle.kts"
  local ignore_file="${ROOT_DIR}/app/android/.gitignore"
  local properties_file="${ROOT_DIR}/app/android/private-gallery-release.properties"
  local store_file

  if [[ ! -f "${gradle_file}" ]]; then
    warn "Android Gradle file not found; Android release signing evidence is unavailable"
    return 1
  fi
  if grep -n 'signingConfigs\.getByName("debug")' "${gradle_file}"; then
    warn "Android release build must not use the debug signing config"
    return 1
  fi
  if ! grep -qx 'private-gallery-release\.properties' "${ignore_file}"; then
    warn "Android release signing properties file must be git-ignored"
    return 1
  fi
  if ! is_enabled "${REQUIRE_RELEASE_SIGNING}"; then
    warn "Android release signing material was not required for this local check; set PRIVATE_GALLERY_READINESS_REQUIRE_RELEASE_SIGNING=1 for release evidence"
    return 0
  fi
  if [[ ! -f "${properties_file}" ]]; then
    warn "Android release signing properties are required but app/android/private-gallery-release.properties is missing"
    return 1
  fi
  for key in storeFile storePassword keyAlias keyPassword; do
    if ! grep -Eq "^${key}=.+" "${properties_file}"; then
      warn "Android release signing properties are missing ${key}"
      return 1
    fi
  done
  store_file="$(sed -n 's/^storeFile=//p' "${properties_file}" | tail -1)"
  if [[ ! -f "${ROOT_DIR}/app/android/${store_file}" && ! -f "${store_file}" ]]; then
    warn "Android release signing keystore file referenced by storeFile was not found"
    return 1
  fi
}

run_cargo_fmt() {
  "${CARGO_BIN}" fmt --manifest-path "${ROOT_DIR}/native_core/Cargo.toml" --all -- --check
}

run_cargo_test() {
  "${CARGO_BIN}" test --manifest-path "${ROOT_DIR}/native_core/Cargo.toml"
}

run_cargo_clippy() {
  "${CARGO_BIN}" clippy --manifest-path "${ROOT_DIR}/native_core/Cargo.toml" --all-targets --all-features -- -D warnings
}

run_cargo_audit() {
  "${CARGO_BIN}" audit --manifest-path "${ROOT_DIR}/native_core/Cargo.toml"
}

run_flutter_analyze() {
  (cd "${ROOT_DIR}/app" && "${FLUTTER_BIN}" analyze)
}

run_flutter_test() {
  (cd "${ROOT_DIR}/app" && "${FLUTTER_BIN}" test)
}

run_flutter_outdated_report() {
  (cd "${ROOT_DIR}/app" && "${FLUTTER_BIN}" pub outdated)
}

run_android_api_smoke() {
  "${ROOT_DIR}/scripts/android_mobile_smoke.sh"
}

run_android_app_smoke() {
  "${ROOT_DIR}/scripts/android_mobile_app_smoke.sh"
}

run_remote_boundary_check() {
  local base="${PRIVATE_GALLERY_READINESS_REMOTE_BASE_URL%/}"
  local library_status
  local pairing_status

  curl -fsS "${base}/health" >/dev/null
  library_status="$(curl -sS -o /dev/null -w '%{http_code}' "${base}/library/status")"
  pairing_status="$(curl -sS -o /dev/null -w '%{http_code}' "${base}/pairing/sessions")"
  printf 'Remote desktop route statuses: /library/status=%s /pairing/sessions=%s\n' \
    "${library_status}" "${pairing_status}"
  [[ "$library_status" == "403" && "$pairing_status" == "403" ]]
}

printf 'Private Gallery production readiness checks\n'
printf 'Root: %s\n' "${ROOT_DIR}"
printf 'Mode: non-destructive local checks; device and remote probes require explicit environment variables.\n'

read_shell_scripts

if ((${#SHELL_SCRIPTS[@]} > 0)); then
  run_check "bash syntax for scripts/*.sh" check_bash_syntax
  if have_command shellcheck; then
    run_check "shellcheck scripts/*.sh" shellcheck "${SHELL_SCRIPTS[@]}"
  else
    skip "shellcheck scripts/*.sh (shellcheck not installed)"
  fi
else
  skip "bash syntax for scripts/*.sh (no shell scripts found)"
  skip "shellcheck scripts/*.sh (no shell scripts found)"
fi

if have_command "${GIT_BIN}"; then
  printf '\n==> git worktree state\n'
  if check_git_state; then
    :
  else
    fail "git worktree state is not clean and PRIVATE_GALLERY_READINESS_REQUIRE_CLEAN_GIT is enabled"
  fi
else
  skip "git worktree state (${GIT_BIN} not installed)"
fi

run_check "Android release signing does not use debug keys" check_android_release_signing_config

if have_command "${CARGO_BIN}"; then
  run_check "cargo fmt --check" run_cargo_fmt
  run_check "cargo test" run_cargo_test
  if "${CARGO_BIN}" clippy --version >/dev/null 2>&1; then
    run_check "cargo clippy --all-targets --all-features" run_cargo_clippy
  else
    skip "cargo clippy --all-targets --all-features (cargo clippy not installed)"
  fi
  if "${CARGO_BIN}" audit --version >/dev/null 2>&1; then
    run_check "cargo audit" run_cargo_audit
  else
    skip "cargo audit (cargo-audit not installed)"
  fi
else
  skip "cargo fmt --check (${CARGO_BIN} not installed)"
  skip "cargo test (${CARGO_BIN} not installed)"
  skip "cargo clippy --all-targets --all-features (${CARGO_BIN} not installed)"
  skip "cargo audit (${CARGO_BIN} not installed)"
fi

if have_command "${FLUTTER_BIN}"; then
  run_check "flutter analyze" run_flutter_analyze
  run_check "flutter test" run_flutter_test
  run_check "flutter pub outdated report" run_flutter_outdated_report
else
  skip "flutter analyze (${FLUTTER_BIN} not installed)"
  skip "flutter test (${FLUTTER_BIN} not installed)"
  skip "flutter pub outdated report (${FLUTTER_BIN} not installed)"
fi

if is_enabled "${PRIVATE_GALLERY_READINESS_RUN_ANDROID_SMOKE:-0}"; then
  if [[ -x "${ROOT_DIR}/scripts/android_mobile_smoke.sh" ]] && have_command adb; then
    run_check "Android two-phone API smoke" run_android_api_smoke
  elif [[ ! -x "${ROOT_DIR}/scripts/android_mobile_smoke.sh" ]]; then
    skip "Android two-phone API smoke (script is not executable)"
  else
    skip "Android two-phone API smoke (adb not installed)"
  fi
else
  skip "Android two-phone API smoke (set PRIVATE_GALLERY_READINESS_RUN_ANDROID_SMOKE=1)"
fi

if is_enabled "${PRIVATE_GALLERY_READINESS_RUN_ANDROID_APP_SMOKE:-0}"; then
  if [[ -x "${ROOT_DIR}/scripts/android_mobile_app_smoke.sh" ]] && have_command adb && have_command "${FLUTTER_BIN}"; then
    run_check "Android Flutter app smoke" run_android_app_smoke
  elif [[ ! -x "${ROOT_DIR}/scripts/android_mobile_app_smoke.sh" ]]; then
    skip "Android Flutter app smoke (script is not executable)"
  elif ! have_command adb; then
    skip "Android Flutter app smoke (adb not installed)"
  else
    skip "Android Flutter app smoke (${FLUTTER_BIN} not installed)"
  fi
else
  skip "Android Flutter app smoke (set PRIVATE_GALLERY_READINESS_RUN_ANDROID_APP_SMOKE=1)"
fi

if [[ -n "${PRIVATE_GALLERY_READINESS_REMOTE_BASE_URL:-}" ]]; then
  if have_command curl; then
    run_check "remote /health allowed and desktop route forbidden" run_remote_boundary_check
  else
    skip "remote /health allowed and desktop route forbidden (curl not installed)"
  fi
else
  skip "remote boundary probe (set PRIVATE_GALLERY_READINESS_REMOTE_BASE_URL)"
fi

if is_enabled "${PRIVATE_GALLERY_READINESS_RUN_SECRET_SCAN:-0}"; then
  if have_command gitleaks; then
    run_check "gitleaks secret scan" gitleaks detect --source "${ROOT_DIR}" --no-banner --redact
  else
    skip "gitleaks secret scan (gitleaks not installed)"
  fi
else
  skip "gitleaks secret scan (set PRIVATE_GALLERY_READINESS_RUN_SECRET_SCAN=1)"
fi

if is_enabled "${PRIVATE_GALLERY_READINESS_RUN_SBOM:-0}"; then
  if have_command syft; then
    run_check "SBOM generation dry output" syft dir:"${ROOT_DIR}" -o table
  else
    skip "SBOM generation dry output (syft not installed)"
  fi
else
  skip "SBOM generation dry output (set PRIVATE_GALLERY_READINESS_RUN_SBOM=1)"
fi

printf '\nReadiness summary: %d passed, %d failed, %d skipped, %d warnings.\n' \
  "${pass_count}" "${fail_count}" "${skip_count}" "${warn_count}"

if ((fail_count > 0)); then
  exit 1
fi
