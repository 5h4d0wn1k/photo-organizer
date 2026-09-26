#!/usr/bin/env bash
#
# Hard gate for the Android release APK: the exact file we are about to publish
# must be signed, and signed with the signature schemes we claim in the release
# notes.
#
# Why this is a script and not a few lines of YAML: the assertions below are the
# only thing standing between an unsigned (or weakly signed) artifact and users.
# Logic that protects users should be executable, testable and reviewable on its
# own, not buried in a workflow. scripts/tests/apksigner_gate_test.sh builds real
# APKs and runs *this* code against them.
#
# Why we assert the schemes explicitly instead of trusting the exit status:
# `apksigner verify` returns 0 for a v2-only APK, so an exit-status-only check
# would happily publish an artifact whose v3 signature is missing -- and the
# release notes would then claim v3. Conversely, v1/JAR signing is deliberately
# OFF because minSdk is 24; the Gradle signing config turns it on automatically
# if minSdk ever drops below 24, and this gate would then correctly reject the
# build for lacking v2.
#
# Usage:
#   android_release_verify_signature.sh <apk> [evidence-out] [checksum-out]
#
# Exit status is 0 only when every assertion holds.

set -euo pipefail

die() {
  printf 'android_release_verify_signature: %s\n' "$*" >&2
  exit 1
}

usage() {
  printf 'usage: %s <apk> [evidence-out] [checksum-out]\n' "${0##*/}" >&2
}

[[ $# -ge 1 && $# -le 3 ]] || {
  usage
  exit 2
}

APK="$1"
EVIDENCE="${2:-apksigner-verify.txt}"
CHECKSUM="${3:-${APK}.sha256}"

[[ -n "${APK}" ]] || {
  usage
  exit 2
}
[[ -f "${APK}" ]] || die "APK not found: ${APK}"
[[ -s "${APK}" ]] || die "APK is empty: ${APK}"

# ---------------------------------------------------------------------------
# Locate apksigner. Prefer the newest build-tools in the SDK (matching what
# Gradle itself used to sign), and fall back to PATH for unusual setups.
# ---------------------------------------------------------------------------
resolve_apksigner() {
  local candidate
  if [[ -n "${ANDROID_HOME:-}" ]]; then
    candidate="$(ls -1 "${ANDROID_HOME}"/build-tools/*/apksigner 2>/dev/null | sort -V | tail -n 1 || true)"
    if [[ -n "${candidate}" && -x "${candidate}" ]]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  fi
  if command -v apksigner >/dev/null 2>&1; then
    command -v apksigner
    return 0
  fi
  return 1
}

if ! APKSIGNER="$(resolve_apksigner)"; then
  die "apksigner not found. Set ANDROID_HOME to an Android SDK with build-tools installed (GitHub runners do this), or put apksigner on PATH. Refusing to publish an unverified artifact."
fi

printf 'Verifying %s with %s\n' "${APK}" "${APKSIGNER}"

# Always keep the full transcript: it is the release evidence, and when this
# gate fails it is the only thing that explains why.
verify_rc=0
"${APKSIGNER}" verify --verbose --print-certs "${APK}" >"${EVIDENCE}" 2>&1 || verify_rc=$?

if ((verify_rc != 0)); then
  # apksigner prints "DOES NOT VERIFY" followed by a reason (for example
  # "Target SDK version 36 requires a minimum of signature scheme v2").
  # Note that this failure text does NOT contain the token "Verifies", so the
  # assertion below is unambiguous in both directions.
  printf '::error::APK signature verification failed (apksigner exit %s). Transcript:\n' "${verify_rc}"
  cat "${EVIDENCE}" >&2
  exit 1
fi

assert_scheme() {
  local pattern="$1" message="$2"
  if ! grep -Eq "${pattern}" "${EVIDENCE}"; then
    printf '::error::%s\n' "${message}"
    printf 'apksigner reported:\n' >&2
    grep -E '^Verified using' "${EVIDENCE}" >&2 || cat "${EVIDENCE}" >&2
    exit 1
  fi
}

# "Verifies" is the first line apksigner prints on success. The failure text is
# "DOES NOT VERIFY" (upper case), so an anchored match is unambiguous.
if ! grep -qx "Verifies" "${EVIDENCE}"; then
  printf '::error::apksigner did not report a successful verification\n'
  cat "${EVIDENCE}" >&2
  exit 1
fi

assert_scheme '^Verified using v2 scheme.*: true$' \
  'APK is missing a v2 (APK Signature Scheme v2) signature'
assert_scheme '^Verified using v3 scheme.*: true$' \
  'APK is missing a v3 (APK Signature Scheme v3) signature'

# Record the certificate fingerprint in the log so a release can be traced to a
# signing key without exposing the key itself.
cert_digest="$(grep -E '^V3\.0 Signer: certificate SHA-256 digest: ' "${EVIDENCE}" | head -n 1 | sed 's/^.*: //' || true)"
[[ -n "${cert_digest}" ]] || cert_digest='(no v3 signer digest reported)'

# Publish a checksum that verifies with `sha256sum -c` after a user downloads
# the APK and the .sha256 sidecar. Deliberately records the bare filename, not
# the CI build path, so the pair is verifiable outside the runner.
checksum_dir="$(dirname "${CHECKSUM}")"
mkdir -p "${checksum_dir}"
checksum_path="$(cd "${checksum_dir}" && pwd)/${CHECKSUM##*/}"
apk_dir="$(cd "$(dirname "${APK}")" && pwd)"
(
  cd "${apk_dir}"
  sha256sum "${APK##*/}"
) >"${checksum_path}"

cat "${EVIDENCE}"
printf 'Signing certificate SHA-256: %s\n' "${cert_digest}"
printf 'Checksum written to %s\n' "${CHECKSUM}"
printf 'signature gate PASSED\n'
