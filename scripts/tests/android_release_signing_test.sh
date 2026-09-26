#!/usr/bin/env bash
#
# Tests for scripts/android_release_signing.sh — the Android release signing
# policy.
#
# The policy is the part of issue #97 that is easy to get subtly wrong and
# impossible to notice until a user cannot install the app:
#
#   * no signing material and no opt-in  -> refuse to release (never publish an
#     unsigned APK, and never silently downgrade the guarantee)
#   * partial signing material          -> always refuse; a half-configured
#     keystore is a mistake, not a fallback
#   * all four secrets                  -> "release" (upgrade-stable)
#   * no secrets + explicit opt-in      -> "ephemeral" (opt-in only, documented)
#
# It also proves the keystore handling is safe: CRLF-wrapped base64 still
# decodes, corrupt or truncated secrets fail with an actionable message instead
# of an opaque Gradle error hours later, and signing material is never written
# inside the repository working tree.

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="${ROOT_DIR}/scripts/android_release_signing.sh"
WORK_DIR="$(mktemp -d)"
PASS_COUNT=0
FAIL_COUNT=0

cleanup() {
  rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

ok() {
  PASS_COUNT=$((PASS_COUNT + 1))
  printf '  ok   %s\n' "$1"
}

bad() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  printf '  FAIL %s\n' "$1" >&2
  if [[ -n "${2:-}" ]]; then
    printf '%s\n' "$2" | sed 's/^/        /' >&2
  fi
}

OUT="${WORK_DIR}/out"
GITHUB_ENV_FILE="${WORK_DIR}/github_env"

expect_out() {
  # expect_out <name> <expected-stdout> <cmd...>
  local name="$1" expected="$2"
  shift 2
  if "$@" >"${OUT}" 2>&1 && [[ "$(cat "${OUT}")" == "${expected}" ]]; then
    ok "${name}"
  else
    bad "${name}" "expected '${expected}', got: $(cat "${OUT}")"
  fi
}

expect_fail() {
  # expect_fail <name> <needle> <cmd...>
  local name="$1" needle="$2"
  shift 2
  if "$@" >"${OUT}" 2>&1; then
    bad "${name}" "expected a non-zero exit, got success: $(cat "${OUT}")"
    return
  fi
  if ! grep -Fq "${needle}" "${OUT}"; then
    bad "${name}" "expected the failure to mention '${needle}'; got: $(cat "${OUT}")"
    return
  fi
  ok "${name}"
}

# --- fixtures ----------------------------------------------------------------

STORE_PASSWORD="test-store-pass"
KEY_PASSWORD="test-key-pass"
ALIAS="photo-organizer-test"
KEYSTORE="${WORK_DIR}/release.jks"

if ! command -v keytool >/dev/null 2>&1; then
  echo "keytool is required to run these tests" >&2
  exit 1
fi

keytool -genkeypair \
  -keystore "${KEYSTORE}" \
  -storetype PKCS12 \
  -storepass "${STORE_PASSWORD}" \
  -keypass "${KEY_PASSWORD}" \
  -alias "${ALIAS}" \
  -keyalg RSA \
  -keysize 2048 \
  -validity 3650 \
  -dname "CN=Photo Organizer Test, O=Test, C=NA" >/dev/null 2>&1 || {
  echo "failed to create the test keystore" >&2
  exit 1
}

KEYSTORE_B64="$(base64 -w0 "${KEYSTORE}")"
# GitHub web-UI secrets and Windows editors routinely introduce CRLF wrapping.
KEYSTORE_B64_CRLF="$(printf '%s\n' "${KEYSTORE_B64}" | fold -w 64 | sed 's/$/\r/')"

run_mode() {
  env -u ANDROID_KEYSTORE_BASE64 -u ANDROID_KEYSTORE_PASSWORD \
    -u ANDROID_KEY_ALIAS -u ANDROID_KEY_PASSWORD \
    -u PRIVATE_GALLERY_RELEASE_ALLOW_EPHEMERAL_SIGNING \
    "$@" bash "${SCRIPT}" mode
}

run_materialize() {
  env -u ANDROID_KEYSTORE_BASE64 -u ANDROID_KEYSTORE_PASSWORD \
    -u ANDROID_KEY_ALIAS -u ANDROID_KEY_PASSWORD \
    -u PRIVATE_GALLERY_RELEASE_ALLOW_EPHEMERAL_SIGNING \
    RUNNER_TEMP="${WORK_DIR}/runner" \
    GITHUB_WORKSPACE="${WORK_DIR}/workspace" \
    GITHUB_ENV="${GITHUB_ENV_FILE}" \
    "$@" bash "${SCRIPT}" materialize
}

# `env` cannot take a multi-line VAR=value built from a variable, so the secret
# values are exported through a wrapper that sets them directly.
secrets_env() {
  printf '%s\n' \
    "export ANDROID_KEYSTORE_BASE64='${KEYSTORE_B64}'" \
    "export ANDROID_KEYSTORE_PASSWORD='${STORE_PASSWORD}'" \
    "export ANDROID_KEY_ALIAS='${ALIAS}'" \
    "export ANDROID_KEY_PASSWORD='${KEY_PASSWORD}'"
}

with_secrets_run_mode() {
  bash -c "$(secrets_env)
    export RUNNER_TEMP='${WORK_DIR}/runner' GITHUB_WORKSPACE='${WORK_DIR}/workspace' GITHUB_ENV='${GITHUB_ENV_FILE}'
    bash '${SCRIPT}' $*"
}

with_secrets_run_materialize() {
  bash -c "$(secrets_env)
    export RUNNER_TEMP='${WORK_DIR}/runner' GITHUB_WORKSPACE='${WORK_DIR}/workspace' GITHUB_ENV='${GITHUB_ENV_FILE}'
    bash '${SCRIPT}' $*"
}

echo "android_release_signing.sh"

echo " mode resolution"
expect_fail "no secrets and no opt-in blocks the release" "gh secret set ANDROID_KEYSTORE_BASE64" \
  run_mode
expect_out "no secrets with the explicit opt-in yields ephemeral" "ephemeral" \
  run_mode PRIVATE_GALLERY_RELEASE_ALLOW_EPHEMERAL_SIGNING=true
expect_fail "a misspelled opt-in value is not honoured" "gh secret set" \
  run_mode PRIVATE_GALLERY_RELEASE_ALLOW_EPHEMERAL_SIGNING=yes-please

expect_out "all four secrets yield release" "release" with_secrets_run_mode mode

echo " partial configuration is never a silent fallback"
for missing in ANDROID_KEYSTORE_BASE64 ANDROID_KEYSTORE_PASSWORD ANDROID_KEY_ALIAS ANDROID_KEY_PASSWORD; do
  partial="$(printf '%s\n' \
    "export ANDROID_KEYSTORE_BASE64='${KEYSTORE_B64}'" \
    "export ANDROID_KEYSTORE_PASSWORD='${STORE_PASSWORD}'" \
    "export ANDROID_KEY_ALIAS='${ALIAS}'" \
    "export ANDROID_KEY_PASSWORD='${KEY_PASSWORD}'" |
    grep -v "^export ${missing}=")"
  expect_fail "missing ${missing} is refused" "only partially configured" \
    bash -c "${partial}; bash '${SCRIPT}' mode"
  expect_fail "missing ${missing} is refused even with the opt-in" "only partially configured" \
    bash -c "${partial}; export PRIVATE_GALLERY_RELEASE_ALLOW_EPHEMERAL_SIGNING=true; bash '${SCRIPT}' mode"
done

echo " materializing the release keystore"
: >"${GITHUB_ENV_FILE}"
expect_out "materialize reports release mode" "release" with_secrets_run_materialize materialize
if [[ -f "${WORK_DIR}/runner/private-gallery-release.jks" ]]; then
  ok "the keystore is written under RUNNER_TEMP"
else
  bad "the keystore is written under RUNNER_TEMP"
fi
for variable in ANDROID_KEYSTORE_FILE ANDROID_KEYSTORE_PASSWORD ANDROID_KEY_ALIAS ANDROID_KEY_PASSWORD; do
  if grep -q "^${variable}=" "${GITHUB_ENV_FILE}"; then
    ok "GITHUB_ENV carries ${variable}"
  else
    bad "GITHUB_ENV carries ${variable}"
  fi
done
if keytool -list -keystore "${WORK_DIR}/runner/private-gallery-release.jks" \
  -storepass "${STORE_PASSWORD}" -alias "${ALIAS}" >/dev/null 2>&1; then
  ok "the materialized keystore opens with the configured alias and password"
else
  bad "the materialized keystore opens with the configured alias and password"
fi
if [[ "${WORK_DIR}/runner/private-gallery-release.jks" == "${WORK_DIR}/workspace"* ]]; then
  bad "signing material is kept out of the working tree"
else
  ok "signing material is kept out of the working tree"
fi

echo " materializing the ephemeral keystore"
: >"${GITHUB_ENV_FILE}"
expect_out "materialize reports ephemeral mode when opted in" "ephemeral" \
  run_materialize PRIVATE_GALLERY_RELEASE_ALLOW_EPHEMERAL_SIGNING=true
if [[ -f "${WORK_DIR}/runner/private-gallery-release.jks" ]]; then
  ok "the ephemeral keystore is created"
else
  bad "the ephemeral keystore is created"
fi
if keytool -list -keystore "${WORK_DIR}/runner/private-gallery-release.jks" \
  -storepass "ephemeral-ci-only-not-a-secret" >/dev/null 2>&1; then
  ok "the ephemeral keystore is a real, openable keystore"
else
  bad "the ephemeral keystore is a real, openable keystore"
fi

echo " corrupt secret handling"
expect_fail "invalid base64 is rejected with a fix" "not valid base64" \
  bash -c "export ANDROID_KEYSTORE_BASE64='not!valid!base64' ANDROID_KEYSTORE_PASSWORD='p' ANDROID_KEY_ALIAS='a' ANDROID_KEY_PASSWORD='k'
    export RUNNER_TEMP='${WORK_DIR}/runner' GITHUB_WORKSPACE='${WORK_DIR}/workspace' GITHUB_ENV='${GITHUB_ENV_FILE}'
    bash '${SCRIPT}' materialize"
expect_fail "a truncated keystore is rejected" "truncated or corrupt" \
  bash -c "export ANDROID_KEYSTORE_BASE64='$(printf '%s' "${KEYSTORE_B64}" | cut -c1-40)' ANDROID_KEYSTORE_PASSWORD='${STORE_PASSWORD}' ANDROID_KEY_ALIAS='${ALIAS}' ANDROID_KEY_PASSWORD='${KEY_PASSWORD}'
    export RUNNER_TEMP='${WORK_DIR}/runner' GITHUB_WORKSPACE='${WORK_DIR}/workspace' GITHUB_ENV='${GITHUB_ENV_FILE}'
    bash '${SCRIPT}' materialize"
expect_fail "a wrong store password is rejected before Gradle sees it" "could not be opened" \
  bash -c "export ANDROID_KEYSTORE_BASE64='${KEYSTORE_B64}' ANDROID_KEYSTORE_PASSWORD='wrong-password' ANDROID_KEY_ALIAS='${ALIAS}' ANDROID_KEY_PASSWORD='${KEY_PASSWORD}'
    export RUNNER_TEMP='${WORK_DIR}/runner' GITHUB_WORKSPACE='${WORK_DIR}/workspace' GITHUB_ENV='${GITHUB_ENV_FILE}'
    bash '${SCRIPT}' materialize"

echo " base64 with CRLF wrapping still decodes"
: >"${GITHUB_ENV_FILE}"
expect_out "CRLF-wrapped base64 materializes cleanly" "release" \
  bash -c "export ANDROID_KEYSTORE_BASE64=\"\$(printf '%s' '${KEYSTORE_B64_CRLF}')\" ANDROID_KEYSTORE_PASSWORD='${STORE_PASSWORD}' ANDROID_KEY_ALIAS='${ALIAS}' ANDROID_KEY_PASSWORD='${KEY_PASSWORD}'
    export RUNNER_TEMP='${WORK_DIR}/runner' GITHUB_WORKSPACE='${WORK_DIR}/workspace' GITHUB_ENV='${GITHUB_ENV_FILE}'
    bash '${SCRIPT}' materialize"
if keytool -list -keystore "${WORK_DIR}/runner/private-gallery-release.jks" \
  -storepass "${STORE_PASSWORD}" >/dev/null 2>&1; then
  ok "the CRLF-decoded keystore is intact"
else
  bad "the CRLF-decoded keystore is intact"
fi

echo " refuses to write secrets into the repository"
mkdir -p "${WORK_DIR}/workspace"
expect_fail "writing signing material into the working tree is refused" "refusing to write signing material" \
  bash -c "export ANDROID_KEYSTORE_BASE64='${KEYSTORE_B64}' ANDROID_KEYSTORE_PASSWORD='${STORE_PASSWORD}' ANDROID_KEY_ALIAS='${ALIAS}' ANDROID_KEY_PASSWORD='${KEY_PASSWORD}'
    export RUNNER_TEMP='${WORK_DIR}/workspace/nested' GITHUB_WORKSPACE='${WORK_DIR}/workspace' GITHUB_ENV='${GITHUB_ENV_FILE}'
    bash '${SCRIPT}' materialize"

echo " usage"
expect_fail "an unknown subcommand is a usage error" "usage" bash "${SCRIPT}" nonsense

printf '\n%s passed, %s failed\n' "${PASS_COUNT}" "${FAIL_COUNT}"
if ((FAIL_COUNT > 0)); then
  exit 1
fi
