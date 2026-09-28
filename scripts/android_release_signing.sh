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
# a worse user outcome than a release that refuses to publish.
#
# What is actually enforced here: ephemeral signing requires the explicit opt-in
# variable, and the release notes say so on every release that uses it, so the
# downgrade is never silent. What is NOT yet enforced: that a release is signed
# with the same key as the previous one. A repository variable that is switched
# on and then left on would make the *second* consecutive ephemeral release look
# like the first. Closing that needs a cross-release fingerprint check (the
# certificate digest is already extracted by android_release_verify_signature.sh)
# and is tracked as issue #101 rather than claimed here.
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

# Signing material and the environment file that carries its passwords are
# created 0600 rather than the default 0644. On a single-tenant ephemeral CI
# runner this is defence in depth, but the same script is used on a developer's
# machine and on a release host, where a keystore readable by other local users
# is a real problem.
umask 077

EPHEMERAL_KEY_ALIAS="ci-ephemeral-key"
EPHEMERAL_KEY_DNAME="CN=Photo Organizer CI Ephemeral, OU=CI, O=Photo Organizer, C=NA"
EPHEMERAL_KEY_VALIDITY_DAYS=10000
EPHEMERAL_KEY_PASSWORD_BYTES=32
# A JKS/PKCS12 keystore is binary; anything smaller means the secret was
# truncated, base64-corrupted, or the wrong secret entirely.
MIN_KEYSTORE_BYTES=512

# The throwaway key's password is generated per run instead of being written
# down here. A committed literal is a value every clone of this repository
# already has, which makes it a published secret by definition and fails secret
# scanning on the very commit that adds no real credential.
#
# Memoised so the store password, the key password and the value exported to
# GITHUB_ENV are the same string within a run: they are consumed by different
# processes, and a keystore that cannot be reopened is worse than no keystore.
#
# 32 bytes from the kernel CSPRNG, hex-encoded, gives 128 bits of entropy in a
# form that cannot inject a second entry into GITHUB_ENV, cannot confuse keytool
# with a metacharacter, and needs no extra tool beyond coreutils.
ephemeral_key_password() {
  if [[ -z "${EPHEMERAL_KEY_PASSWORD:-}" ]]; then
    EPHEMERAL_KEY_PASSWORD="$(
      od -An -tx1 -N"${EPHEMERAL_KEY_PASSWORD_BYTES}" /dev/urandom | tr -d ' \n'
    )"
  fi
  printf '%s' "${EPHEMERAL_KEY_PASSWORD}"
}

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
    -storepass '<store password>' \
    -dname "CN=Photo Organizer, O=Photo Organizer, C=NA"

  A PKCS12 keystore cannot hold two different passwords: keytool prints
  "Different store and key passwords not supported for PKCS12 KeyStores.
  Ignoring user-specified -keypass value." and discards -keypass. The key
  password IS the store password, so set both secrets to the same value. Use
  -storetype JKS if you need them to differ.

  gh secret set ANDROID_KEYSTORE_BASE64   < <(base64 -w0 release.jks)
  gh secret set ANDROID_KEYSTORE_PASSWORD -- '<store password>'
  gh secret set ANDROID_KEY_ALIAS         -- 'photo-organizer'
  gh secret set ANDROID_KEY_PASSWORD      -- '<the same password>'

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
  # Refuse before creating anything: a rejected run must not have already made a
  # directory inside the tree it just declared off-limits. The directory is what
  # gets checked here because the keystore file does not exist yet.
  assert_outside_workspace "${temp_dir}"
  mkdir -p "${temp_dir}"
  # mktemp rather than $RANDOM: the name is then both unpredictable enough not to
  # be a known target for anything running in the Gradle JVM, and collision-free,
  # so a rerun can never silently overwrite a previous keystore.
  #
  # The path reaches Gradle through ANDROID_KEYSTORE_FILE, so nothing depends on
  # what it happens to be.
  mktemp "${temp_dir}/private-gallery-release-XXXXXXXXXXXXXXXX.jks"
}

# Refuse to write signing material into the repository working tree.
#
# The comparison is done on canonical paths, not on string prefixes. A prefix
# test alone is wrong in both directions: a path such as
# "${GITHUB_WORKSPACE}/./sub/keystore.jks" does not textually start with the
# workspace string yet is inside it (under-refusal: the write is allowed), and a
# sibling directory such as "${GITHUB_WORKSPACE}-backup" is not inside it
# (over-refusal: safe, but wrong). realpath -m canonicalises without requiring
# the path to exist yet.
assert_outside_workspace() {
  local destination="$1"
  [[ -n "${GITHUB_WORKSPACE:-}" ]] || return 0
  local canonical_destination canonical_workspace
  canonical_workspace="$(realpath -m "${GITHUB_WORKSPACE}" 2>/dev/null || printf '%s' "${GITHUB_WORKSPACE}")"
  canonical_destination="$(realpath -m "${destination}" 2>/dev/null || printf '%s' "${destination}")"
  if [[ "${canonical_destination}" == "${canonical_workspace}" ||
    "${canonical_destination}" == "${canonical_workspace}/"* ]]; then
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
  # Explicit, not relying on mktemp's 0600 or on the process umask: if either ever
  # changes, the keystore must still be owner-only. This is the mechanism the
  # signing suite asserts, not a side effect it happens to observe.
  chmod 600 "${destination}"
  # `wc -c` rather than `stat -c %s`: the `-c` form is GNU coreutils and does not
  # exist on BSD/macOS, where this script is also used to prepare a local release.
  # `wc -c` is POSIX and prints the same byte count on both.
  if [[ ! -s "${destination}" || "$(wc -c <"${destination}" | tr -d '[:space:]')" -lt "${MIN_KEYSTORE_BYTES}" ]]; then
    echo "ERROR: the decoded keystore is empty or implausibly small; the secret is truncated or corrupt." >&2
    rm -f "${destination}"
    exit 1
  fi
  # Fail fast, with a readable message, instead of letting Gradle report an
  # opaque keystore error after a long NDK cross-compile.
  #
  # -storepass:env keeps the store password out of keytool's argv, where any
  # other process on the machine could read it from /proc/<pid>/cmdline. On a
  # single-tenant ephemeral runner that is not a practical exposure, but it is
  # free to avoid and there is no reason to hand the value out.
  if ! keytool -list -keystore "${destination}" -storepass:env ANDROID_KEYSTORE_PASSWORD >/dev/null 2>&1; then
    echo "ERROR: the decoded keystore could not be opened with ANDROID_KEYSTORE_PASSWORD." >&2
    echo "Check that the base64 blob and the store password belong to the same keystore." >&2
    rm -f "${destination}"
    exit 1
  fi
}

materialize_ephemeral_keystore() {
  local destination="$1" password="$2"
  assert_outside_workspace "${destination}"
  rm -f "${destination}"
  keytool -genkeypair \
    -keystore "${destination}" \
    -storetype PKCS12 \
    -storepass "${password}" \
    -keypass "${password}" \
    -alias "${EPHEMERAL_KEY_ALIAS}" \
    -keyalg RSA \
    -keysize 2048 \
    -validity "${EPHEMERAL_KEY_VALIDITY_DAYS}" \
    -dname "${EPHEMERAL_KEY_DNAME}" >/dev/null 2>&1
}

# Refuse a signing value that would corrupt $GITHUB_ENV.
#
# GitHub parses $GITHUB_ENV one line at a time, so a value containing a newline
# does not stay one variable: every line after the embedded break becomes a
# brand-new environment variable for every later step in the job. A pasted alias
# or password carrying a stray newline would therefore silently inject e.g.
# GITHUB_TOKEN_LEAK=... into the build, with no error and a zero exit status.
# Rejecting newlines (and CR) is the whole defence; there is no escaping
# mechanism in this file format.
assert_single_line_value() {
  local name="$1" value="$2"
  if [[ "${value}" == *$'\n'* || "${value}" == *$'\r'* ]]; then
    echo "ERROR: ${name} must not contain a newline." >&2
    echo "It would be parsed as extra variables in \$GITHUB_ENV, not as one value." >&2
    echo "Re-create the secret without embedded line breaks." >&2
    exit 1
  fi
}

export_to_github_env() {
  local destination="$1" store_password="$2" alias_name="$3" key_password="$4"
  if [[ -z "${GITHUB_ENV:-}" ]]; then
    # Outside GitHub Actions there is no environment file to receive the
    # variables, so the keystore this just wrote would be orphaned: valid, on
    # disk, at a path nobody was told. In release mode that orphan is the
    # production signing key. Print the path (never the passwords) so the caller
    # can export or delete it, instead of succeeding silently with a key nobody
    # can find to clean up.
    printf 'GITHUB_ENV is not set; the keystore was written to %s\n' "${destination}" >&2
    printf 'ANDROID_KEYSTORE_FILE=%s\n' "${destination}"
    return 0
  fi
  assert_single_line_value ANDROID_KEYSTORE_FILE "${destination}"
  assert_single_line_value ANDROID_KEYSTORE_PASSWORD "${store_password}"
  assert_single_line_value ANDROID_KEY_ALIAS "${alias_name}"
  assert_single_line_value ANDROID_KEY_PASSWORD "${key_password}"
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
      local mode destination ephemeral_password
      mode="$(resolve_mode)"
      destination="$(keystore_destination)"
      # The key deliberately outlives this process: `materialize` writes the path to
      # GITHUB_ENV and a *later* process -- the Gradle build -- is what reads it. An
      # EXIT trap that removed the file would delete the signing key between
      # materialize and the build, so cleanup belongs to the build job, after the
      # build, where it is guarded by `if: always()`.
      if [[ "${mode}" == "release" ]]; then
        materialize_release_keystore "${destination}"
        export_to_github_env "${destination}" "${ANDROID_KEYSTORE_PASSWORD}" "${ANDROID_KEY_ALIAS}" "${ANDROID_KEY_PASSWORD}"
      else
        # Generated once, here, so the keystore and the exported value are
        # guaranteed to agree without either side re-deriving it.
        ephemeral_password="$(ephemeral_key_password)"
        materialize_ephemeral_keystore "${destination}" "${ephemeral_password}"
        export_to_github_env "${destination}" "${ephemeral_password}" "${EPHEMERAL_KEY_ALIAS}" "${ephemeral_password}"
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
