#!/usr/bin/env bash
#
# Single source of truth for "how is the Android release APK signed?".
#
# The published APK used to be completely unsigned (issue #97): Gradle only ever
# read signing material from a local, git-ignored properties file that does not
# exist on a CI runner, so `signingConfig` was null and stock Android rejected the
# package with "App not installed".
#
# This script encodes the release signing policy so the workflow, the local
# readiness check and the tests all agree on it:
#
#   * all four secrets present  -> mode "release"   (upgrade-stable artifact)
#   * none present              -> mode "ephemeral" (ONLY when the repository
#                                  variable PRIVATE_GALLERY_RELEASE_ALLOW_EPHEMERAL_SIGNING
#                                  is explicitly enabled; otherwise a hard failure
#                                  with setup instructions)
#   * some but not all present  -> hard failure, always. A half-configured
#                                  keystore is a mistake, never a fallback.
#
# An ephemeral key is deliberately opt-in rather than the default: because the
# key is regenerated on every run, consecutive releases are signed by different
# keys, so Android refuses the upgrade (INSTALL_FAILED_UPDATE_INCOMPATIBLE) and
# the user has to uninstall. Uninstalling wipes flutter_secure_storage, which
# holds the mobile bearer token and cloud group/device identity, forcing a full
# re-pair with the desktop daemon. "Always installable but never upgradeable" is
# a worse user outcome than a release that refuses to publish, and a silent
# downgrade is not acceptable at all.
#
# Usage:
#   android_release_signing.sh mode         # prints "release" or "ephemeral"
#   android_release_signing.sh materialize  # writes the keystore, exports env
#
# Inputs (env):  ANDROID_KEYSTORE_BASE64, ANDROID_KEYSTORE_PASSWORD,
#                ANDROID_KEY_ALIAS, ANDROID_KEY_PASSWORD
#                PRIVATE_GALLERY_RELEASE_ALLOW_EPHEMERAL_SIGNING ("true" to allow)
# Outputs (env): ANDROID_KEYSTORE_FILE, ANDROID_KEYSTORE_PASSWORD,
#                ANDROID_KEY_ALIAS, ANDROID_KEY_PASSWORD  (written to $GITHUB_ENV)

set -euo pipefail

EPHEMERAL_KEY_ALIAS="ci-ephemeral-key"
EPHEMERAL_KEY_PASSWORD="ephemeral-ci-only-not-a-secret"
EPHEMERAL_KEY_DNAME="CN=Photo Organizer CI Ephemeral, OU=CI, O=Photo Organizer, C=NA"
EPHEMERAL_KEY_VALIDITY_DAYS=10000
# A JKS/PKCS12 keystore is binary; anything smaller means the secret was
# truncated, base64-corrupted, or the wrong secret entirely.
MIN_KEYSTORE_BYTES=512

is_true() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    true | 1 | yes | on) return 0 ;;
    *) return 1 ;;
  esac
}

count_present_signing_secrets() {
  local present=0 name
  for name in ANDROID_KEYSTORE_BASE64 ANDROID_KEYSTORE_PASSWORD ANDROID_KEY_ALIAS ANDROID_KEY_PASSWORD; do
    if [[ -n "${!name:-}" ]]; then
      present=$((present + 1))
    fi
  done
  printf '%s' "${present}"
}

missing_signing_secret_names() {
  local name missing=""
  for name in ANDROID_KEYSTORE_BASE64 ANDROID_KEYSTORE_PASSWORD ANDROID_KEY_ALIAS ANDROID_KEY_PASSWORD; do
    if [[ -z "${!name:-}" ]]; then
      missing="${missing}${missing:+, }${name}"
    fi
  done
  printf '%s' "${missing}"
}

fail_missing_keystore_setup() {
  cat >&2 <<'EOF'
ERROR: no Android release signing material is configured, so the release APK
would be unsigned and Android would refuse to install it ("App not installed").

Publishing is blocked on purpose. Configure the four release secrets once:

  keytool -genkeypair -v -keystore release.jks -storetype PKCS12 \
    -keyalg RSA -keysize 4096 -validity 10000 -alias photo-organizer \
    -storepass '<store password>' -keypass '<key password>' \
    -dname "CN=Photo Organizer, O=Photo Organizer, C=NA"

  gh secret set ANDROID_KEYSTORE_BASE64   < <(base64 -w0 release.jks)
  gh secret set ANDROID_KEYSTORE_PASSWORD -- '<store password>'
  gh secret set ANDROID_KEY_ALIAS         -- 'photo-organizer'
  gh secret set ANDROID_KEY_PASSWORD      -- '<key password>'

Keep release.jks and both passwords somewhere safe and private: the signing key
is the artifact's identity, and losing it means users can never install an
upgrade over an already-installed copy.

If you deliberately want a throwaway, non-upgradeable artifact (for example a
local smoke-test tag), set the repository variable
PRIVATE_GALLERY_RELEASE_ALLOW_EPHEMERAL_SIGNING=true. That signs with a key
generated for that single run; the release notes say so explicitly, and the
next release will require users to uninstall first.
EOF
  exit 1
}

resolve_mode() {
  local present
  present="$(count_present_signing_secrets)"
  case "${present}" in
    4) printf 'release' ;;
    0)
      if is_true "${PRIVATE_GALLERY_RELEASE_ALLOW_EPHEMERAL_SIGNING:-}"; then
        printf 'ephemeral'
      else
        fail_missing_keystore_setup
      fi
      ;;
    *)
      echo "ERROR: Android release signing is only partially configured." >&2
      echo "Missing: $(missing_signing_secret_names)" >&2
      echo "Set all four of ANDROID_KEYSTORE_BASE64, ANDROID_KEYSTORE_PASSWORD," >&2
      echo "ANDROID_KEY_ALIAS and ANDROID_KEY_PASSWORD, or remove all four." >&2
      echo "A partially configured keystore is never silently ignored." >&2
      exit 1
      ;;
  esac
}

keystore_destination() {
  local temp_dir="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
  mkdir -p "${temp_dir}"
  printf '%s' "${temp_dir}/private-gallery-release.jks"
}

assert_outside_workspace() {
  local destination="$1"
  if [[ -n "${GITHUB_WORKSPACE:-}" && "${destination}" == "${GITHUB_WORKSPACE}"* ]]; then
    echo "ERROR: refusing to write signing material inside the repository working tree (${destination})." >&2
    exit 1
  fi
}

materialize_release_keystore() {
  local destination="$1"
  assert_outside_workspace "${destination}"
  # Secrets pasted through a web UI or a Windows editor routinely carry CRLF
  # line endings; GNU base64 rejects those, so strip all whitespace first.
  printf '%s' "${ANDROID_KEYSTORE_BASE64}" | tr -d '[:space:]' | base64 --decode >"${destination}" 2>/dev/null || {
    echo "ERROR: ANDROID_KEYSTORE_BASE64 is not valid base64. Re-create it with: base64 -w0 release.jks" >&2
    rm -f "${destination}"
    exit 1
  }
  if [[ ! -s "${destination}" || "$(stat -c %s "${destination}")" -lt "${MIN_KEYSTORE_BYTES}" ]]; then
    echo "ERROR: the decoded keystore is empty or implausibly small; the secret is truncated or corrupt." >&2
    rm -f "${destination}"
    exit 1
  fi
  # Fail fast, with a readable message, instead of letting Gradle report an
  # opaque keystore error after a long NDK cross-compile.
  if ! keytool -list -keystore "${destination}" -storepass "${ANDROID_KEYSTORE_PASSWORD}" >/dev/null 2>&1; then
    echo "ERROR: the decoded keystore could not be opened with ANDROID_KEYSTORE_PASSWORD." >&2
    echo "Check that the base64 blob and the store password belong to the same keystore." >&2
    rm -f "${destination}"
    exit 1
  fi
}

materialize_ephemeral_keystore() {
  local destination="$1"
  assert_outside_workspace "${destination}"
  rm -f "${destination}"
  keytool -genkeypair \
    -keystore "${destination}" \
    -storetype PKCS12 \
    -storepass "${EPHEMERAL_KEY_PASSWORD}" \
    -keypass "${EPHEMERAL_KEY_PASSWORD}" \
    -alias "${EPHEMERAL_KEY_ALIAS}" \
    -keyalg RSA \
    -keysize 2048 \
    -validity "${EPHEMERAL_KEY_VALIDITY_DAYS}" \
    -dname "${EPHEMERAL_KEY_DNAME}" >/dev/null 2>&1
}

export_to_github_env() {
  local destination="$1" store_password="$2" alias_name="$3" key_password="$4"
  if [[ -z "${GITHUB_ENV:-}" ]]; then
    echo "GITHUB_ENV is not set; run this inside GitHub Actions or export the variables yourself." >&2
    return 0
  fi
  {
    echo "ANDROID_KEYSTORE_FILE=${destination}"
    echo "ANDROID_KEYSTORE_PASSWORD=${store_password}"
    echo "ANDROID_KEY_ALIAS=${alias_name}"
    echo "ANDROID_KEY_PASSWORD=${key_password}"
  } >>"${GITHUB_ENV}"
}

require_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required tool: $1" >&2
    exit 1
  fi
}

main() {
  local subcommand="${1:-}"
  case "${subcommand}" in
    mode)
      resolve_mode
      printf '\n'
      ;;
    materialize)
      require_tool keytool
      require_tool base64
      local mode destination
      mode="$(resolve_mode)"
      destination="$(keystore_destination)"
      if [[ "${mode}" == "release" ]]; then
        materialize_release_keystore "${destination}"
        export_to_github_env "${destination}" "${ANDROID_KEYSTORE_PASSWORD}" "${ANDROID_KEY_ALIAS}" "${ANDROID_KEY_PASSWORD}"
      else
        materialize_ephemeral_keystore "${destination}"
        export_to_github_env "${destination}" "${EPHEMERAL_KEY_PASSWORD}" "${EPHEMERAL_KEY_ALIAS}" "${EPHEMERAL_KEY_PASSWORD}"
      fi
      printf '%s\n' "${mode}"
      ;;
    *)
      echo "usage: $(basename "$0") {mode|materialize}" >&2
      exit 2
      ;;
  esac
}

main "$@"
