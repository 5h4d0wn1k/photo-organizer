#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST_BASE_URL="${PRIVATE_GALLERY_SMOKE_HOST_BASE_URL:-http://127.0.0.1:4821}"
DEVICE_BASE_URL="${PRIVATE_GALLERY_SMOKE_DEVICE_BASE_URL:-http://127.0.0.1:4821}"
LIBRARY_ROOT="${PRIVATE_GALLERY_SMOKE_LIBRARY_ROOT:-/tmp/private-gallery-android-smoke-library}"
DEVICE_HTTP_JAR="/data/local/tmp/private-gallery-http-smoke.jar"
TMP_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

require_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required tool: $1" >&2
    exit 1
  fi
}

require_tool adb
require_tool base64
require_tool curl
require_tool jar
require_tool javac
require_tool jq
require_tool sha256sum

D8_BIN="${ANDROID_D8:-}"
if [[ -z "${D8_BIN}" ]]; then
  if [[ -n "${ANDROID_HOME:-}" ]]; then
    D8_BIN="$(find "${ANDROID_HOME}" -path '*/d8' -type f 2>/dev/null | sort | tail -1)"
  fi
fi
if [[ -z "${D8_BIN}" || ! -x "${D8_BIN}" ]]; then
  echo "missing Android d8; set ANDROID_D8 or ANDROID_HOME" >&2
  exit 1
fi

cat >"${TMP_DIR}/HttpSmoke.java" <<'JAVA'
import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.util.Base64;

public final class HttpSmoke {
  public static void main(String[] args) throws Exception {
    if (args.length != 5) {
      throw new IllegalArgumentException("usage: HttpSmoke METHOD URL TOKEN_OR_DASH CONTENT_TYPE_OR_DASH BODY_BASE64_OR_DASH");
    }
    String method = args[0];
    String url = args[1];
    String token = args[2];
    String contentType = args[3];
    byte[] body = "-".equals(args[4]) ? new byte[0] : Base64.getDecoder().decode(args[4]);

    HttpURLConnection connection = (HttpURLConnection) new URL(url).openConnection();
    connection.setConnectTimeout(5000);
    connection.setReadTimeout(15000);
    connection.setRequestMethod(method);
    connection.setRequestProperty("Connection", "close");
    connection.setRequestProperty("User-Agent", "private-gallery-android-smoke");
    if (!"-".equals(token)) {
      connection.setRequestProperty("Authorization", "Bearer " + token);
    }
    if (body.length > 0 || "POST".equals(method) || "PUT".equals(method)) {
      connection.setDoOutput(true);
      if (!"-".equals(contentType)) {
        connection.setRequestProperty("Content-Type", contentType);
      }
      connection.setFixedLengthStreamingMode(body.length);
      try (OutputStream output = connection.getOutputStream()) {
        output.write(body);
      }
    }

    int status = connection.getResponseCode();
    InputStream input = status >= 400 ? connection.getErrorStream() : connection.getInputStream();
    byte[] response = readAll(input);
    System.out.println("HTTP_STATUS=" + status);
    System.out.println("CONTENT_TYPE=" + connection.getContentType());
    System.out.println("BODY_BASE64=" + Base64.getEncoder().encodeToString(response));
  }

  private static byte[] readAll(InputStream input) throws Exception {
    if (input == null) {
      return new byte[0];
    }
    try (InputStream stream = input; ByteArrayOutputStream output = new ByteArrayOutputStream()) {
      byte[] buffer = new byte[8192];
      int read;
      while ((read = stream.read(buffer)) != -1) {
        output.write(buffer, 0, read);
      }
      return output.toByteArray();
    }
  }
}
JAVA

mkdir -p "${TMP_DIR}/classes" "${TMP_DIR}/dex"
javac -Xlint:-options --release 8 -d "${TMP_DIR}/classes" "${TMP_DIR}/HttpSmoke.java"
"${D8_BIN}" --min-api 26 --output "${TMP_DIR}/dex" "${TMP_DIR}/classes/HttpSmoke.class"
jar --create --file "${TMP_DIR}/private-gallery-http-smoke.jar" -C "${TMP_DIR}/dex" classes.dex

device_serials="$(adb devices | awk 'NR > 1 && $2 == "device" {print $1}')"
if [[ -z "${device_serials}" ]]; then
  echo "no attached adb devices are authorized" >&2
  exit 1
fi

ensure_library_initialized() {
  local status_json
  status_json="$(curl -fsS "${HOST_BASE_URL}/library/status")"
  if [[ "$(jq -r '.is_initialized' <<<"${status_json}")" == "true" ]]; then
    return
  fi
  curl -fsS -X POST "${HOST_BASE_URL}/library/settings" \
    -H 'content-type: application/json' \
    -d "$(jq -nc --arg root "${LIBRARY_ROOT}" '{library_root:$root, default_import_mode:"copy"}')" >/dev/null
}

android_http() {
  local serial="$1"
  local method="$2"
  local path="$3"
  local body="${4:-}"
  local token="${5:--}"
  local content_type="${6:--}"
  local body_arg="-"
  if [[ -n "${body}" ]]; then
    body_arg="$(printf '%s' "${body}" | base64 -w0)"
  fi
  adb -s "${serial}" shell \
    "CLASSPATH=${DEVICE_HTTP_JAR} app_process / HttpSmoke '${method}' '${DEVICE_BASE_URL}${path}' '${token}' '${content_type}' '${body_arg}'" \
    | tr -d '\r'
}

response_status() {
  awk -F= '/^HTTP_STATUS=/ {print $2; exit}' "$1"
}

response_body() {
  awk -F= '/^BODY_BASE64=/ {sub(/^BODY_BASE64=/, ""); print; exit}' "$1" | base64 -d
}

ensure_status() {
  local file="$1"
  local expected="$2"
  local label="$3"
  local actual
  actual="$(response_status "${file}")"
  if [[ "${actual}" != "${expected}" ]]; then
    echo "${label} expected HTTP ${expected}, got ${actual}" >&2
    response_body "${file}" >&2 || true
    echo >&2
    exit 1
  fi
}

ensure_library_initialized

for serial in ${device_serials}; do
  echo
  echo "[${serial}] preparing device"
  adb -s "${serial}" reverse tcp:4821 tcp:4821 >/dev/null
  adb -s "${serial}" push "${TMP_DIR}/private-gallery-http-smoke.jar" "${DEVICE_HTTP_JAR}" >/dev/null

  model="$(adb -s "${serial}" shell getprop ro.product.model | tr -d '\r')"
  [[ -n "${model}" ]] || model="${serial}"
  safe_model="$(tr ' /' '__' <<<"${model}")"

  health_file="${TMP_DIR}/${serial}-health.response"
  android_http "${serial}" GET /health >"${health_file}"
  ensure_status "${health_file}" 200 "${serial} health"

  pairing_json="$(curl -fsS -X POST "${HOST_BASE_URL}/pairing/sessions" \
    -H 'content-type: application/json' \
    -d "$(jq -nc --arg name "${model} daily driver" '{device_name:$name, platform:"android"}')")"
  pairing_token="$(jq -r '.pairing_token' <<<"${pairing_json}")"
  pair_body="$(jq -nc --arg token "${pairing_token}" --arg name "${model} daily driver" \
    '{pairing_token:$token, device_name:$name, platform:"android"}')"
  pair_file="${TMP_DIR}/${serial}-pair.response"
  android_http "${serial}" POST /mobile/pair "${pair_body}" - application/json >"${pair_file}"
  ensure_status "${pair_file}" 200 "${serial} pair"
  pair_response="$(response_body "${pair_file}")"
  bearer="$(jq -r '.bearer_token' <<<"${pair_response}")"
  device_id="$(jq -r '.device.id' <<<"${pair_response}")"

  payload="private-gallery-real-phone-smoke-2026-05-15-${serial}-${safe_model}"
  payload_hash="$(printf '%s' "${payload}" | sha256sum | awk '{print $1}')"
  payload_bytes="$(printf '%s' "${payload}" | wc -c | tr -d ' ')"
  reserve_body="$(jq -nc \
    --arg filename "${safe_model}-${serial}.jpg" \
    --arg hash "${payload_hash}" \
    --argjson bytes "${payload_bytes}" \
    '{original_filename:$filename, media_kind:"photo", mime_type:"image/jpeg", bytes:$bytes, content_hash:$hash}')"
  reserve_file="${TMP_DIR}/${serial}-reserve.response"
  android_http "${serial}" POST /mobile/uploads "${reserve_body}" "${bearer}" application/json >"${reserve_file}"
  ensure_status "${reserve_file}" 200 "${serial} reserve upload"
  upload_id="$(response_body "${reserve_file}" | jq -r '.id')"

  upload_file="${TMP_DIR}/${serial}-upload.response"
  android_http "${serial}" PUT "/mobile/uploads/${upload_id}" "${payload}" "${bearer}" application/octet-stream >"${upload_file}"
  ensure_status "${upload_file}" 200 "${serial} upload"
  upload_response="$(response_body "${upload_file}")"
  upload_status="$(jq -r '.status' <<<"${upload_response}")"
  asset_id="$(jq -r '.asset_id' <<<"${upload_response}")"
  if [[ "${upload_status}" != "completed" || -z "${asset_id}" || "${asset_id}" == "null" ]]; then
    echo "${serial} upload did not complete: ${upload_response}" >&2
    exit 1
  fi

  assets_file="${TMP_DIR}/${serial}-assets.response"
  android_http "${serial}" GET /mobile/assets "" "${bearer}" - >"${assets_file}"
  ensure_status "${assets_file}" 200 "${serial} asset list"
  assets_count="$(response_body "${assets_file}" | jq 'length')"

  original_file="${TMP_DIR}/${serial}-original.response"
  android_http "${serial}" GET "/mobile/assets/${asset_id}/original" "" "${bearer}" - >"${original_file}"
  ensure_status "${original_file}" 200 "${serial} original download"
  response_body "${original_file}" >"${TMP_DIR}/${serial}-original.body"
  downloaded_hash="$(sha256sum "${TMP_DIR}/${serial}-original.body" | awk '{print $1}')"
  if [[ "${downloaded_hash}" != "${payload_hash}" ]]; then
    echo "${serial} original hash mismatch: expected ${payload_hash}, got ${downloaded_hash}" >&2
    exit 1
  fi

  echo "[${serial}] paired device_id=${device_id} uploaded_asset=${asset_id} assets_visible=${assets_count} sha256=${downloaded_hash}"
done

echo
echo "Android mobile smoke passed for $(wc -w <<<"${device_serials}" | tr -d ' ') device(s)."
