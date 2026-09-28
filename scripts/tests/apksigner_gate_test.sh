#!/usr/bin/env bash
#
# Tests the real signature gate (scripts/android_release_verify_signature.sh)
# against real, signed APKs.
#
# This is the check that would have caught issue #97. It is deliberately not a
# mock: it links a minimal APK with aapt2, signs it with a throwaway key in a
# temp directory, and runs the actual gate script over the result. That is the
# only way to prove the assertions match what apksigner really prints.
#
# Coverage:
#   * a v2+v3 signed APK           -> accepted
#   * an unsigned APK (the #97 bug)-> rejected
#   * a v2-only signed APK         -> rejected, even though apksigner alone
#                                     accepts it (exit 0). This is the case
#                                     that justifies asserting the schemes
#                                     explicitly instead of trusting the exit
#                                     status.
#   * a v1-only signed APK         -> rejected
#   * a malformed file             -> rejected
#   * a missing file               -> rejected
#   * the published checksum       -> verifiable with `sha256sum -c`
#   * certificate digest evidence  -> recorded, so a release is traceable to a key
#
# If the Android SDK is not available the suite reports a loud, explicit skip
# with the reason. It never passes silently pretending to have tested something
# it could not test.

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GATE="${ROOT_DIR}/scripts/android_release_verify_signature.sh"

pass_count=0
fail_count=0
skip_count=0

# The runner detects a degraded suite by looking for this exact marker. It has to
# be a distinct token rather than the bare word "DEGRADED": the runner greps the
# whole log, so any assertion whose *name* merely mentions the word (as one of
# these does) would otherwise be reported as a skipped suite.
DEGRADED_MARKER='RELEASE_GATE_SUITE_DEGRADED:'

ok() {
  pass_count=$((pass_count + 1))
  printf '  ok   %s\n' "$1"
}

fail() {
  fail_count=$((fail_count + 1))
  printf '  FAIL %s\n' "$1"
  if [[ $# -ge 2 ]]; then
    printf '       %s\n' "$2"
  fi
}

skip_all() {
  skip_count=$((skip_count + 1))
  printf '  SKIP %s\n' "$1"
  printf '\n  !! %s this suite could not run: %s\n' "${DEGRADED_MARKER}" "$1"
  printf '  !! The signature gate was NOT exercised here. On a GitHub runner the\n'
  printf '  !! Android SDK is preinstalled, so the release job still enforces it;\n'
  printf '  !! do not read this skip as a pass.\n'
  exit 0
}

# One assertion that cannot be exercised in this environment, while the rest of
# the suite still runs. The DEGRADED marker is what matters: the suite runner
# fails on it, so a partial skip cannot be mistaken for full coverage. A skip
# that only printed SKIP would leave a green build with a hole in it.
skip_one() {
  skip_count=$((skip_count + 1))
  printf '  SKIP %s\n' "$1"
  printf '       %s\n' "$2"
  printf '  !! %s %s\n' "${DEGRADED_MARKER}" "$1"
  printf '  !! That assertion did NOT run; do not read this suite as a pass.\n'
}

# ---------------------------------------------------------------------------
# Toolchain discovery
# ---------------------------------------------------------------------------
sdk_root="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
[[ -n "${sdk_root}" && -d "${sdk_root}" ]] || skip_all "no Android SDK (set ANDROID_HOME)"

build_tools_dir="$(ls -1d "${sdk_root}"/build-tools/* 2>/dev/null | sort -V | tail -n 1 || true)"
[[ -n "${build_tools_dir}" && -x "${build_tools_dir}/apksigner" && -x "${build_tools_dir}/aapt2" ]] ||
  skip_all "no usable build-tools (apksigner/aapt2) under ${sdk_root}"

android_jar="$(ls -1 "${sdk_root}"/platforms/*/android.jar 2>/dev/null | sort -V | tail -n 1 || true)"
[[ -n "${android_jar}" && -f "${android_jar}" ]] ||
  skip_all "no android.jar under ${sdk_root}/platforms"

command -v keytool >/dev/null 2>&1 || skip_all "keytool not on PATH"

WORK="$(mktemp -d)"
cleanup() { rm -rf "${WORK}"; }
trap cleanup EXIT

cd "${WORK}" || skip_all "could not create a temp working directory"

cat >AndroidManifest.xml <<'MANIFEST'
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    package="com.example.signaturegate"
    android:versionCode="1"
    android:versionName="1.0">
  <uses-sdk android:minSdkVersion="24" android:targetSdkVersion="36" />
  <application android:label="signature gate fixture" />
</manifest>
MANIFEST

"${build_tools_dir}/aapt2" link -o base.apk \
  -I "${android_jar}" \
  --manifest AndroidManifest.xml \
  --min-sdk-version 24 --target-sdk-version 36 >/dev/null 2>&1 ||
  skip_all "aapt2 could not link the fixture APK"
[[ -s base.apk ]] || skip_all "aapt2 produced an empty fixture APK"

keytool -genkeypair -v -keystore fixture.jks -storetype PKCS12 \
  -keyalg RSA -keysize 2048 -validity 30 \
  -alias fixture -storepass fixturepass -keypass fixturepass \
  -dname "CN=Signature Gate Fixture" >/dev/null 2>&1 ||
  skip_all "keytool could not create the throwaway fixture keystore"

sign_variant() {
  local name="$1" v1="$2" v2="$3" v3="$4"
  "${build_tools_dir}/apksigner" sign \
    --ks fixture.jks --ks-pass pass:fixturepass --key-pass pass:fixturepass \
    --ks-key-alias fixture --min-sdk-version 24 \
    --v1-signing-enabled "${v1}" \
    --v2-signing-enabled "${v2}" \
    --v3-signing-enabled "${v3}" \
    --out "${name}" base.apk >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# The gate must ACCEPT a correctly signed artifact.
# ---------------------------------------------------------------------------
if ! sign_variant signed.apk false true true; then
  skip_all "apksigner could not produce the correctly signed fixture"
fi
[[ -s signed.apk ]] || skip_all "the correctly signed fixture is empty"

gate_rc=0
ANDROID_HOME="${sdk_root}" bash "${GATE}" signed.apk evidence.txt checksum.txt >gate-good.log 2>&1 || gate_rc=$?
if ((gate_rc == 0)); then
  ok "a v2+v3 signed APK passes the gate"
else
  fail "a v2+v3 signed APK passes the gate" "gate exited ${gate_rc}; output: $(tr '\n' ' ' <gate-good.log | cut -c1-200)"
fi

# ---------------------------------------------------------------------------
# The gate must REJECT everything weaker.
# ---------------------------------------------------------------------------
# Unsigned: the exact #97 defect.
cp base.apk unsigned.apk
gate_rc=0
ANDROID_HOME="${sdk_root}" bash "${GATE}" unsigned.apk evidence-unsigned.txt >gate-unsigned.log 2>&1 || gate_rc=$?
if ((gate_rc != 0)); then
  ok "an unsigned APK is rejected"
else
  fail "an unsigned APK is rejected" "gate accepted an unsigned artifact"
fi

# v1/JAR only: what the old, incorrect "V1+V2+V3" claim would have produced.
if sign_variant v1only.apk true false false; then
  gate_rc=0
  ANDROID_HOME="${sdk_root}" bash "${GATE}" v1only.apk evidence-v1.txt >gate-v1.log 2>&1 || gate_rc=$?
  if ((gate_rc != 0)); then
    ok "a v1-only (JAR signing) APK is rejected"
  else
    fail "a v1-only (JAR signing) APK is rejected" "gate accepted a v1-only artifact"
  fi
else
  skip_all "apksigner could not produce the v1-only fixture"
fi

# v2 only: apksigner itself returns 0 here, so only an explicit assertion can
# catch it. If this ever starts passing, the gate has been weakened.
if sign_variant v2only.apk false true false; then
  raw_rc=0
  "${build_tools_dir}/apksigner" verify --verbose v2only.apk >/dev/null 2>&1 || raw_rc=$?
  if ((raw_rc == 0)); then
    ok "fixture sanity: plain apksigner accepts the v2-only APK (exit 0)"
  else
    fail "fixture sanity: plain apksigner accepts the v2-only APK (exit 0)" "apksigner exit ${raw_rc}"
  fi

  gate_rc=0
  ANDROID_HOME="${sdk_root}" bash "${GATE}" v2only.apk evidence-v2.txt >gate-v2.log 2>&1 || gate_rc=$?
  if ((gate_rc != 0)); then
    ok "a v2-only APK is rejected even though apksigner alone accepts it"
  else
    fail "a v2-only APK is rejected even though apksigner alone accepts it" \
      "the gate accepted an artifact with no v3 signature; the release notes claim v3"
  fi
else
  skip_all "apksigner could not produce the v2-only fixture"
fi

# v3 only: the mirror image, and the one that proves the *v2* assertion is
# load-bearing. The v2-only case above is caught by the v3 assertion, so removing
# the v2 line changes nothing for it -- without this fixture the v2 assertion
# could be deleted and all 24 checks would still pass.
if sign_variant v3only.apk false false true; then
  gate_rc=0
  ANDROID_HOME="${sdk_root}" bash "${GATE}" v3only.apk evidence-v3.txt >gate-v3.log 2>&1 || gate_rc=$?
  if ((gate_rc != 0)); then
    if grep -qF 'missing a v2' gate-v3.log 2>/dev/null; then
      ok "a v3-only APK is rejected for the v2 signature specifically"
    else
      fail "a v3-only APK is rejected for the v2 signature specifically" \
        "rejected, but not for the missing v2 signature: $(tr '\n' ' ' <gate-v3.log | cut -c1-200)"
    fi
  else
    fail "a v3-only APK is rejected for the v2 signature specifically" \
      "the gate accepted an artifact with no v2 signature"
  fi
else
  skip_all "apksigner could not produce the v3-only fixture"
fi

# A lying apksigner: exits 0 but reports no successful verification. The gate
# must not trust the exit status alone -- the anchored `grep -qx "Verifies"` is
# the assertion that catches this, and without it this case would pass.
STUB_BIN="${WORK}/stub-bin"
mkdir -p "${STUB_BIN}"
cat >"${STUB_BIN}/apksigner" <<'STUB'
#!/usr/bin/env bash
# A tool that "succeeds" while saying nothing verifiable.
echo "some output that is not a verification transcript"
exit 0
STUB
chmod +x "${STUB_BIN}/apksigner"
gate_rc=0
env -u ANDROID_HOME PATH="${STUB_BIN}:${PATH}" bash "${GATE}" signed.apk evidence-stub.txt >gate-stub.log 2>&1 || gate_rc=$?
if ((gate_rc != 0)); then
  if grep -qF 'did not report a successful verification' gate-stub.log 2>/dev/null; then
    ok "an apksigner that exits 0 without reporting success is rejected"
  else
    fail "an apksigner that exits 0 without reporting success is rejected" \
      "rejected, but not by the success assertion: $(tr '\n' ' ' <gate-stub.log | cut -c1-200)"
  fi
else
  fail "an apksigner that exits 0 without reporting success is rejected" \
    "the gate trusted the exit status alone"
fi

# A failing apksigner whose output happens to contain the success token. The
# `verify_rc != 0` branch must fire first: without it the "Verifies" anchor would
# pass and the gate would accept a tool that reported failure.
cat >"${STUB_BIN}/apksigner" <<'STUB'
#!/usr/bin/env bash
# A tool that fails while its transcript contains the success token.
echo "Verifies"
echo "DOES NOT VERIFY"
exit 1
STUB
chmod +x "${STUB_BIN}/apksigner"
gate_rc=0
env -u ANDROID_HOME PATH="${STUB_BIN}:${PATH}" bash "${GATE}" signed.apk evidence-rc.txt >gate-rc.log 2>&1 || gate_rc=$?
if ((gate_rc != 0)); then
  if grep -qF 'signature verification failed (apksigner exit 1)' gate-rc.log 2>/dev/null; then
    ok "a non-zero apksigner exit is rejected before the transcript is trusted"
  else
    fail "a non-zero apksigner exit is rejected before the transcript is trusted" \
      "rejected, but not by the exit-status branch: $(tr '\n' ' ' <gate-rc.log | cut -c1-200)"
  fi
else
  fail "a non-zero apksigner exit is rejected before the transcript is trusted" \
    "the gate accepted a tool that reported failure"
fi

# A file that is not an APK at all.
printf 'this is not an apk' >notanapk.apk
gate_rc=0
ANDROID_HOME="${sdk_root}" bash "${GATE}" notanapk.apk evidence-junk.txt >gate-junk.log 2>&1 || gate_rc=$?
if ((gate_rc != 0)); then
  ok "a non-APK file is rejected"
else
  fail "a non-APK file is rejected" "gate accepted garbage"
fi

# A missing file must fail with a clear message, not a stack trace.
gate_rc=0
ANDROID_HOME="${sdk_root}" bash "${GATE}" does-not-exist.apk >gate-missing.log 2>&1 || gate_rc=$?
if ((gate_rc != 0)); then
  ok "a missing APK is rejected"
else
  fail "a missing APK is rejected" "gate accepted a path that does not exist"
fi
if grep -q "not found" gate-missing.log; then
  ok "a missing APK is reported as 'not found'"
else
  fail "a missing APK is reported as 'not found'" "$(tr '\n' ' ' <gate-missing.log | cut -c1-200)"
fi

# Bad usage must not be mistaken for success.
gate_rc=0
ANDROID_HOME="${sdk_root}" bash "${GATE}" >/dev/null 2>&1 || gate_rc=$?
if ((gate_rc == 2)); then
  ok "no arguments is a usage error (exit 2), not a pass"
else
  fail "no arguments is a usage error (exit 2), not a pass" "exit was ${gate_rc}"
fi

# ---------------------------------------------------------------------------
# Evidence quality
# ---------------------------------------------------------------------------
if [[ -s evidence.txt ]]; then
  ok "the evidence file is written and non-empty"
else
  fail "the evidence file is written and non-empty" "evidence.txt missing or empty"
fi

if grep -q '^V3.0 Signer: certificate SHA-256 digest: ' evidence.txt 2>/dev/null; then
  ok "the evidence records the signing certificate digest"
else
  fail "the evidence records the signing certificate digest" "no certificate digest in evidence.txt"
fi

if grep -q 'Signing certificate SHA-256: ' gate-good.log 2>/dev/null; then
  ok "the gate prints the certificate digest so a release is traceable to a key"
else
  fail "the gate prints the certificate digest so a release is traceable to a key" "digest not echoed"
fi

if grep -q 'Verified using v1 scheme (JAR signing): false' evidence.txt 2>/dev/null; then
  ok "the evidence shows v1 signing is off (minSdk 24)"
else
  fail "the evidence shows v1 signing is off (minSdk 24)" "unexpected v1 state in evidence.txt"
fi

# The published checksum must be verifiable by a user who downloaded both files.
#
# These are two separate properties. Combining them as `A || B` would let a
# merely well-formatted checksum pass even when the digest is wrong, because a
# failed first branch falls through to the format check in the second.
if [[ -s checksum.txt ]]; then
  ok "the checksum file is written and non-empty"
  if (cd "${WORK}" && sha256sum -c --status checksum.txt) 2>/dev/null; then
    ok "the published checksum actually verifies against the APK"
  else
    fail "the published checksum actually verifies against the APK" \
      "sha256sum -c rejected it: $(tr '\n' ' ' <checksum.txt | cut -c1-160)"
  fi
  if grep -qE '^[0-9a-f]{64}  signed\.apk$' checksum.txt; then
    ok "the checksum records the bare filename, not a path"
  else
    fail "the checksum records the bare filename, not a path" \
      "got: $(tr '\n' ' ' <checksum.txt | cut -c1-160)"
  fi
else
  fail "the checksum file is written and non-empty" "checksum.txt missing or empty"
fi

# Prove the assertion above is load-bearing rather than vacuous: corrupt the
# digest and confirm the verification command rejects it.
if [[ -s checksum.txt ]]; then
  sed 's/^[0-9a-f]\{64\}/0000000000000000000000000000000000000000000000000000000000000000/' \
    checksum.txt >corrupted.sha256
  if (cd "${WORK}" && sha256sum -c --status corrupted.sha256) 2>/dev/null; then
    fail "a corrupted checksum is rejected by the verification command" \
      "sha256sum -c accepted a deliberately wrong digest"
  else
    ok "a corrupted checksum is rejected by the verification command"
  fi
fi

# The assertions above invoke the gate with a bare filename, so "${APK##*/}" and
# "${APK}" are the same string and the path-stripping is never exercised. The
# real caller passes a path (apk/app-release.apk), and stripping it is the entire
# point: a user who downloads the APK and the .sha256 sidecar into one directory
# cannot verify a checksum that names an absolute CI build path.
#
# So exercise the case the first invocation cannot distinguish.
mkdir -p dist
cp signed.apk dist/app-release.apk
if (cd "${WORK}" && ANDROID_HOME="${sdk_root}" bash "${GATE}" \
  dist/app-release.apk evidence-path.txt checksum-path.txt) >/dev/null 2>&1; then
  if grep -qE '^[0-9a-f]{64}  app-release\.apk$' checksum-path.txt; then
    ok "a checksum for an APK given as a path still records the bare filename"
  else
    fail "a checksum for an APK given as a path still records the bare filename" \
      "got: $(tr '\n' ' ' <checksum-path.txt | cut -c1-160)"
  fi
  if (cd "${WORK}/dist" && sha256sum -c --status ../checksum-path.txt) 2>/dev/null; then
    ok "that checksum verifies next to the downloaded APK, as a user would run it"
  else
    fail "that checksum verifies next to the downloaded APK, as a user would run it" \
      "$(tr '\n' ' ' <checksum-path.txt | cut -c1-160)"
  fi
else
  fail "a checksum for an APK given as a path still records the bare filename" \
    "the gate rejected dist/app-release.apk"
fi

# The evidence directory is created by the gate, so a caller may legitimately hand
# it a path that does not exist yet. The signature here is valid, so the run must
# succeed; the interesting case is a failure that reports a signature problem
# when the real fault is a missing directory, which sends the operator to
# investigate something that is not broken.
if (cd "${WORK}" && ANDROID_HOME="${sdk_root}" bash "${GATE}" \
  signed.apk no/such/dir/evidence.txt checksum-missing-dir.txt) >gate-missing-dir.log 2>&1; then
  if [[ -s no/such/dir/evidence.txt ]]; then
    ok "a missing evidence directory is created and the run still succeeds"
  else
    fail "a missing evidence directory is created and the run still succeeds" \
      "the gate passed but wrote no evidence"
  fi
else
  fail "a missing evidence directory is created and the run still succeeds" \
    "the gate failed on a valid APK: $(tr '\n' ' ' <gate-missing-dir.log | cut -c1-200)"
fi

# An unwritable evidence directory must be reported as such. Otherwise the
# redirect into it fails, the transcript is empty, and the failure reads as an
# apksigner problem -- sending the operator to re-check a signature that is fine.
#
# `[[ -w ]]` is true for root regardless of the mode bits, so as root this case is
# not reproducible and the assertions would be meaningless. That is reported as a
# skip rather than quietly passing.
if [[ "$(id -u)" == "0" ]]; then
  skip_one "an unwritable evidence directory is reported as such" \
    "running as root: the mode bits are ignored, so the writability check cannot fail here"
  skip_one "an unwritable evidence directory is not misreported as a signature problem" \
    "running as root: the mode bits are ignored, so the writability check cannot fail here"
else
  mkdir -p ro-evidence
  chmod 0500 ro-evidence
  if (cd "${WORK}" && ANDROID_HOME="${sdk_root}" bash "${GATE}" \
    signed.apk ro-evidence/evidence.txt checksum-ro.txt) >gate-ro.log 2>&1; then
    fail "an unwritable evidence directory is reported as such" \
      "the gate passed despite not being able to write its evidence"
  else
    if grep -Fq "evidence directory" gate-ro.log; then
      ok "an unwritable evidence directory is reported as such"
    else
      fail "an unwritable evidence directory is reported as such" \
        "it failed, but not as a directory problem: $(tr '\n' ' ' <gate-ro.log | cut -c1-200)"
    fi
    if grep -Fq "DOES NOT VERIFY" gate-ro.log; then
      fail "an unwritable evidence directory is not misreported as a signature problem" \
        "the log blames the signature: $(tr '\n' ' ' <gate-ro.log | cut -c1-200)"
    else
      ok "an unwritable evidence directory is not misreported as a signature problem"
    fi
  fi
  chmod 0700 ro-evidence
fi

# -F, not -E: the temp directory is caller-controlled, and any ERE metacharacter
# in it would make this pattern match the wrong thing or nothing at all, silently
# turning the leak check into a no-op.
if grep -qF -- "$(pwd)" checksum.txt 2>/dev/null; then
  fail "the published checksum does not leak the CI build path" \
    "checksum.txt embeds an absolute build path: $(tr '\n' ' ' <checksum.txt | cut -c1-160)"
else
  ok "the published checksum does not leak the CI build path"
fi

# No secret material may appear in the evidence a release publishes.
if grep -qiE 'fixturepass|BEGIN PRIVATE KEY|password' evidence.txt checksum.txt 2>/dev/null; then
  fail "no secret material appears in the published evidence" "a password or key marker leaked into the evidence"
else
  ok "no secret material appears in the published evidence"
fi

printf '\n%d passed, %d failed, %d skipped\n' "${pass_count}" "${fail_count}" "${skip_count}"
((fail_count == 0))
