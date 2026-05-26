#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST_BASE_URL="${PRIVATE_GALLERY_SMOKE_HOST_BASE_URL:-http://127.0.0.1:4821}"
DEVICE_BASE_URL="${PRIVATE_GALLERY_SMOKE_DEVICE_BASE_URL:-http://127.0.0.1:4821}"
LIBRARY_ROOT="${PRIVATE_GALLERY_SMOKE_LIBRARY_ROOT:-/tmp/private-gallery-android-smoke-library}"
REQUIRE_DEVICE_COUNT="${PRIVATE_GALLERY_SMOKE_REQUIRE_DEVICE_COUNT:-}"
REQUESTED_DEVICE_SERIALS="${PRIVATE_GALLERY_SMOKE_DEVICE_SERIALS:-}"
PAYLOAD_BYTES="${PRIVATE_GALLERY_SMOKE_PAYLOAD_BYTES:-3145728}"
CHUNK_BYTES="${PRIVATE_GALLERY_SMOKE_CHUNK_BYTES:-1048576}"
EXPECT_REMOTE_BOUNDARY="${PRIVATE_GALLERY_SMOKE_EXPECT_REMOTE_BOUNDARY:-auto}"
DEVICE_TMP_DIR="${PRIVATE_GALLERY_SMOKE_DEVICE_TMP_DIR:-/data/local/tmp/private-gallery-smoke}"
DEVICE_HTTP_JAR="${DEVICE_TMP_DIR}/private-gallery-http-smoke.jar"
HISTORICAL_AXUM_BODY_LIMIT_BYTES=2097152
MOBILE_UPLOAD_CHUNK_MAX_BYTES=8388608
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

require_uint() {
  local name="$1"
  local value="$2"
  if [[ -z "${value}" || "${value}" =~ [^0-9] ]]; then
    echo "${name} must be an unsigned integer, got: ${value}" >&2
    exit 1
  fi
}

sanitize_id() {
  tr -c 'A-Za-z0-9._-' '_' <<<"$1" | sed 's/_$//'
}

remote_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

is_loopback_base_url() {
  case "${DEVICE_BASE_URL}" in
    http://127.* | https://127.* | http://localhost:* | https://localhost:*) return 0 ;;
    *) return 1 ;;
  esac
}

should_expect_remote_boundary() {
  case "${EXPECT_REMOTE_BOUNDARY}" in
    1 | true | TRUE | yes | YES) return 0 ;;
    0 | false | FALSE | no | NO) return 1 ;;
    auto)
      if is_loopback_base_url; then
        return 1
      fi
      return 0
      ;;
    *)
      echo "PRIVATE_GALLERY_SMOKE_EXPECT_REMOTE_BOUNDARY must be auto, true, or false" >&2
      exit 1
      ;;
  esac
}

response_status() {
  awk -F= '/^HTTP_STATUS=/ {print $2; exit}' "$1"
}

response_body() {
  awk -F= '/^BODY_BASE64=/ {sub(/^BODY_BASE64=/, ""); print; exit}' "$1" | base64 -d
}

response_sha256() {
  awk -F= '/^BODY_SHA256=/ {print $2; exit}' "$1"
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

ensure_not_success() {
  local file="$1"
  local label="$2"
  local actual
  actual="$(response_status "${file}")"
  if [[ "${actual}" -ge 200 && "${actual}" -lt 300 ]]; then
    echo "${label} unexpectedly returned HTTP ${actual}" >&2
    response_body "${file}" >&2 || true
    echo >&2
    exit 1
  fi
}

json_array_length() {
  response_body "$1" | jq 'length'
}

require_tool adb
require_tool awk
require_tool base64
require_tool curl
require_tool dd
require_tool find
require_tool jar
require_tool javac
require_tool jq
require_tool sed
require_tool sha256sum
require_tool sort
require_tool tr
require_tool wc

require_uint PRIVATE_GALLERY_SMOKE_PAYLOAD_BYTES "${PAYLOAD_BYTES}"
require_uint PRIVATE_GALLERY_SMOKE_CHUNK_BYTES "${CHUNK_BYTES}"
if [[ "${PAYLOAD_BYTES}" -le "${HISTORICAL_AXUM_BODY_LIMIT_BYTES}" ]]; then
  echo "PRIVATE_GALLERY_SMOKE_PAYLOAD_BYTES must be larger than ${HISTORICAL_AXUM_BODY_LIMIT_BYTES} to prove chunked upload" >&2
  exit 1
fi
if [[ "${CHUNK_BYTES}" -eq 0 || "${CHUNK_BYTES}" -gt "${MOBILE_UPLOAD_CHUNK_MAX_BYTES}" ]]; then
  echo "PRIVATE_GALLERY_SMOKE_CHUNK_BYTES must be 1..${MOBILE_UPLOAD_CHUNK_MAX_BYTES}" >&2
  exit 1
fi
if [[ "${CHUNK_BYTES}" -ge "${PAYLOAD_BYTES}" ]]; then
  echo "PRIVATE_GALLERY_SMOKE_CHUNK_BYTES must be smaller than PRIVATE_GALLERY_SMOKE_PAYLOAD_BYTES to prove resume behavior" >&2
  exit 1
fi

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
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.security.MessageDigest;
import java.util.Base64;

public final class HttpSmoke {
  public static void main(String[] args) throws Exception {
    if (args.length < 5 || args.length > 7) {
      throw new IllegalArgumentException("usage: HttpSmoke METHOD URL TOKEN_OR_DASH CONTENT_TYPE_OR_DASH BODY_BASE64_OR_DASH_OR_@FILE RANGE_OR_DASH RESPONSE_FILE_OR_DASH");
    }
    String method = args[0];
    String url = args[1];
    String token = args[2];
    String contentType = args[3];
    byte[] body = readBody(args[4]);
    String range = args.length >= 6 ? args[5] : "-";
    String responseFile = args.length >= 7 ? args[6] : "-";

    HttpURLConnection connection = (HttpURLConnection) new URL(url).openConnection();
    connection.setConnectTimeout(5000);
    connection.setReadTimeout(30000);
    connection.setRequestMethod(method);
    connection.setRequestProperty("Connection", "close");
    connection.setRequestProperty("User-Agent", "private-gallery-android-smoke");
    if (!"-".equals(token)) {
      connection.setRequestProperty("Authorization", "Bearer " + token);
    }
    if (!"-".equals(range)) {
      connection.setRequestProperty("Range", range);
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
    System.out.println("BODY_BYTES=" + response.length);
    System.out.println("BODY_SHA256=" + sha256Hex(response));
    if (!"-".equals(responseFile)) {
      try (FileOutputStream output = new FileOutputStream(responseFile)) {
        output.write(response);
      }
      System.out.println("BODY_FILE=" + responseFile);
    } else {
      System.out.println("BODY_BASE64=" + Base64.getEncoder().encodeToString(response));
    }
  }

  private static byte[] readBody(String spec) throws Exception {
    if ("-".equals(spec)) {
      return new byte[0];
    }
    if (spec.startsWith("@")) {
      return readAll(new FileInputStream(spec.substring(1)));
    }
    return Base64.getDecoder().decode(spec);
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

  private static String sha256Hex(byte[] bytes) throws Exception {
    MessageDigest digest = MessageDigest.getInstance("SHA-256");
    byte[] hash = digest.digest(bytes);
    StringBuilder out = new StringBuilder(hash.length * 2);
    for (byte value : hash) {
      out.append(String.format("%02x", value & 0xff));
    }
    return out.toString();
  }
}
JAVA

mkdir -p "${TMP_DIR}/classes" "${TMP_DIR}/dex"
javac -Xlint:-options --release 8 -d "${TMP_DIR}/classes" "${TMP_DIR}/HttpSmoke.java"
"${D8_BIN}" --min-api 26 --output "${TMP_DIR}/dex" "${TMP_DIR}/classes/HttpSmoke.class"
jar --create --file "${TMP_DIR}/private-gallery-http-smoke.jar" -C "${TMP_DIR}/dex" classes.dex

mapfile -t AUTHORIZED_DEVICE_SERIALS < <(adb devices | awk 'NR > 1 && $2 == "device" {print $1}')
DEVICE_SERIALS=()
if [[ -n "${REQUESTED_DEVICE_SERIALS}" ]]; then
  read -r -a REQUESTED_SERIAL_ARRAY <<<"${REQUESTED_DEVICE_SERIALS}"
  for requested in "${REQUESTED_SERIAL_ARRAY[@]}"; do
    found=0
    for authorized in "${AUTHORIZED_DEVICE_SERIALS[@]}"; do
      if [[ "${requested}" == "${authorized}" ]]; then
        found=1
        DEVICE_SERIALS+=("${requested}")
        break
      fi
    done
    if [[ "${found}" -ne 1 ]]; then
      echo "requested adb device is not authorized: ${requested}" >&2
      adb devices -l >&2
      exit 1
    fi
  done
else
  DEVICE_SERIALS=("${AUTHORIZED_DEVICE_SERIALS[@]}")
fi
if [[ "${#DEVICE_SERIALS[@]}" -eq 0 ]]; then
  echo "no attached adb devices are authorized" >&2
  exit 1
fi
if [[ -n "${REQUIRE_DEVICE_COUNT}" ]]; then
  require_uint PRIVATE_GALLERY_SMOKE_REQUIRE_DEVICE_COUNT "${REQUIRE_DEVICE_COUNT}"
  if [[ "${#DEVICE_SERIALS[@]}" -ne "${REQUIRE_DEVICE_COUNT}" ]]; then
    echo "expected ${REQUIRE_DEVICE_COUNT} authorized adb device(s), found ${#DEVICE_SERIALS[@]}" >&2
    adb devices -l >&2
    exit 1
  fi
elif [[ "${#DEVICE_SERIALS[@]}" -lt 2 ]]; then
  echo "warning: only ${#DEVICE_SERIALS[@]} authorized adb device found; set PRIVATE_GALLERY_SMOKE_REQUIRE_DEVICE_COUNT=2 for final acceptance" >&2
fi

ensure_library_initialized() {
  local status_json
  status_json="$(curl -fsS "${HOST_BASE_URL}/library/status")"
  if [[ "$(jq -r '.is_initialized' <<<"${status_json}")" == "true" ]]; then
    return
  fi
  curl -fsS -X POST "${HOST_BASE_URL}/library/settings" \
    -H 'content-type: application/json' \
    -d "$(jq -nc --arg root "${LIBRARY_ROOT}" '{library_root:$root, default_import_mode:"copy", original_storage_policy:"encrypted_only"}')" >/dev/null
}

android_http() {
  local serial="$1"
  local method="$2"
  local path="$3"
  local body="${4:-}"
  local token="${5:--}"
  local content_type="${6:--}"
  local range="${7:--}"
  local response_file="${8:--}"
  local body_arg="-"
  if [[ -n "${body}" ]]; then
    if [[ "${body}" == @* ]]; then
      body_arg="${body}"
    else
      body_arg="$(printf '%s' "${body}" | base64 -w0)"
    fi
  fi
  local command
  command="dalvikvm -cp $(remote_quote "${DEVICE_HTTP_JAR}") HttpSmoke $(remote_quote "${method}") $(remote_quote "${DEVICE_BASE_URL}${path}") $(remote_quote "${token}") $(remote_quote "${content_type}") $(remote_quote "${body_arg}") $(remote_quote "${range}") $(remote_quote "${response_file}")"
  adb -s "${serial}" shell "${command}" \
    | tr -d '\r'
}

prepare_device() {
  local serial="$1"
  echo
  echo "[${serial}] preparing device"
  adb -s "${serial}" shell "mkdir -p $(remote_quote "${DEVICE_TMP_DIR}")" >/dev/null
  if is_loopback_base_url; then
    adb -s "${serial}" reverse tcp:4821 tcp:4821 >/dev/null
  fi
  adb -s "${serial}" push "${TMP_DIR}/private-gallery-http-smoke.jar" "${DEVICE_HTTP_JAR}" >/dev/null
}

make_payload_file() {
  local serial="$1"
  local safe_model="$2"
  local file="$3"
  local label="$4"
  printf 'private-gallery-android-smoke-%s-%s-%s\n' "${serial}" "${safe_model}" "${label}" >"${file}"
  local current
  current="$(wc -c <"${file}" | tr -d ' ')"
  local remaining=$((PAYLOAD_BYTES - current))
  if [[ "${remaining}" -lt 0 ]]; then
    echo "payload header exceeded requested payload size" >&2
    exit 1
  fi
  if [[ "${remaining}" -gt 0 ]]; then
    local blocks=$((remaining / 1048576))
    local tail_bytes=$((remaining % 1048576))
    if [[ "${blocks}" -gt 0 ]]; then
      dd if=/dev/zero bs=1048576 count="${blocks}" >>"${file}" 2>/dev/null
    fi
    if [[ "${tail_bytes}" -gt 0 ]]; then
      dd if=/dev/zero bs=1 count="${tail_bytes}" >>"${file}" 2>/dev/null
    fi
  fi
}

push_chunk_and_put() {
  local serial="$1"
  local bearer="$2"
  local upload_id="$3"
  local offset="$4"
  local chunk_file="$5"
  local label="$6"
  local safe_serial
  safe_serial="$(sanitize_id "${serial}")"
  local device_chunk="${DEVICE_TMP_DIR}/${safe_serial}-chunk.bin"
  local response_file="${TMP_DIR}/${safe_serial}-${label}.response"
  adb -s "${serial}" push "${chunk_file}" "${device_chunk}" >/dev/null
  android_http "${serial}" PUT "/mobile/uploads/${upload_id}/chunks/${offset}" "@${device_chunk}" "${bearer}" application/octet-stream >"${response_file}"
  echo "${response_file}"
}

upload_payload_chunks() {
  local serial="$1"
  local bearer="$2"
  local upload_id="$3"
  local payload_file="$4"
  local label="$5"
  local payload_size
  payload_size="$(wc -c <"${payload_file}" | tr -d ' ')"
  local offset=0
  local chunk_index=0
  while [[ "${offset}" -lt "${payload_size}" ]]; do
    local remaining=$((payload_size - offset))
    local this_chunk="${CHUNK_BYTES}"
    if [[ "${remaining}" -lt "${this_chunk}" ]]; then
      this_chunk="${remaining}"
    fi
    local chunk_file="${TMP_DIR}/$(sanitize_id "${serial}")-${label}-chunk-${chunk_index}.bin"
    dd if="${payload_file}" of="${chunk_file}" bs=1 skip="${offset}" count="${this_chunk}" status=none
    local response_file
    response_file="$(push_chunk_and_put "${serial}" "${bearer}" "${upload_id}" "${offset}" "${chunk_file}" "${label}-${chunk_index}")"
    ensure_status "${response_file}" 200 "${serial} upload ${label} chunk ${chunk_index}"
    offset=$((offset + this_chunk))
    chunk_index=$((chunk_index + 1))
  done
}

reserve_upload() {
  local serial="$1"
  local bearer="$2"
  local filename="$3"
  local payload_hash="$4"
  local payload_bytes="$5"
  local label="$6"
  local reserve_body reserve_file
  reserve_body="$(jq -nc \
    --arg filename "${filename}" \
    --arg hash "${payload_hash}" \
    --argjson bytes "${payload_bytes}" \
    '{original_filename:$filename, media_kind:"photo", mime_type:"image/jpeg", bytes:$bytes, content_hash:$hash}')"
  reserve_file="${TMP_DIR}/$(sanitize_id "${serial}")-${label}-reserve.response"
  android_http "${serial}" POST /mobile/uploads "${reserve_body}" "${bearer}" application/json >"${reserve_file}"
  ensure_status "${reserve_file}" 200 "${serial} reserve ${label} upload"
  response_body "${reserve_file}" | jq -r '.id'
}

complete_upload() {
  local serial="$1"
  local bearer="$2"
  local upload_id="$3"
  local label="$4"
  local response_file
  response_file="${TMP_DIR}/$(sanitize_id "${serial}")-${label}-complete.response"
  android_http "${serial}" POST "/mobile/uploads/${upload_id}/complete" "" "${bearer}" application/json >"${response_file}"
  ensure_status "${response_file}" 200 "${serial} complete ${label} upload"
  response_body "${response_file}"
}

verify_download_hash() {
  local serial="$1"
  local bearer="$2"
  local asset_id="$3"
  local path="$4"
  local range="$5"
  local expected_status="$6"
  local expected_hash="$7"
  local label="$8"
  local safe_serial response_file device_output actual_hash
  safe_serial="$(sanitize_id "${serial}")"
  response_file="${TMP_DIR}/${safe_serial}-${label}.response"
  device_output="${DEVICE_TMP_DIR}/${safe_serial}-${label}.body"
  android_http "${serial}" GET "${path}" "" "${bearer}" - "${range}" "${device_output}" >"${response_file}"
  ensure_status "${response_file}" "${expected_status}" "${serial} ${label}"
  actual_hash="$(response_sha256 "${response_file}")"
  if [[ "${actual_hash}" != "${expected_hash}" ]]; then
    echo "${serial} ${label} hash mismatch: expected ${expected_hash}, got ${actual_hash}" >&2
    exit 1
  fi
  adb -s "${serial}" shell "rm -f '${device_output}'" >/dev/null || true
}

curl -fsS "${HOST_BASE_URL}/health" >/dev/null
ensure_library_initialized

declare -A MODEL_BY_SERIAL
declare -A SAFE_MODEL_BY_SERIAL
declare -A SAFE_SERIAL_BY_SERIAL
declare -A BEARER_BY_SERIAL
declare -A DEVICE_ID_BY_SERIAL
declare -A ASSET_ID_BY_SERIAL
declare -A PAYLOAD_FILE_BY_SERIAL
declare -A PAYLOAD_HASH_BY_SERIAL
declare -A PAYLOAD_BYTES_BY_SERIAL
declare -A SEARCH_LABEL_BY_SERIAL

for serial in "${DEVICE_SERIALS[@]}"; do
  prepare_device "${serial}"
  model="$(adb -s "${serial}" shell getprop ro.product.model | tr -d '\r')"
  [[ -n "${model}" ]] || model="${serial}"
  safe_model="$(sanitize_id "${model}")"
  safe_serial="$(sanitize_id "${serial}")"
  MODEL_BY_SERIAL["${serial}"]="${model}"
  SAFE_MODEL_BY_SERIAL["${serial}"]="${safe_model}"
  SAFE_SERIAL_BY_SERIAL["${serial}"]="${safe_serial}"
  SEARCH_LABEL_BY_SERIAL["${serial}"]="pgsmoke-${safe_serial}"

  health_file="${TMP_DIR}/${safe_serial}-health.response"
  android_http "${serial}" GET /health >"${health_file}"
  ensure_status "${health_file}" 200 "${serial} health"

  if should_expect_remote_boundary; then
    boundary_file="${TMP_DIR}/${safe_serial}-library-status-remote.response"
    android_http "${serial}" GET /library/status >"${boundary_file}"
    ensure_status "${boundary_file}" 403 "${serial} remote library/status boundary"
    pairing_boundary_file="${TMP_DIR}/${safe_serial}-pairing-sessions-remote.response"
    android_http "${serial}" POST /pairing/sessions '{"device_name":"blocked remote","platform":"android"}' - application/json >"${pairing_boundary_file}"
    ensure_status "${pairing_boundary_file}" 403 "${serial} remote pairing/sessions boundary"
  fi
done

for serial in "${DEVICE_SERIALS[@]}"; do
  model="${MODEL_BY_SERIAL[${serial}]}"
  safe_serial="${SAFE_SERIAL_BY_SERIAL[${serial}]}"
  echo "[${serial}] pairing ${model}"
  pairing_json="$(curl -fsS -X POST "${HOST_BASE_URL}/pairing/sessions" \
    -H 'content-type: application/json' \
    -d "$(jq -nc --arg name "${model} smoke" '{device_name:$name, platform:"android"}')")"
  pairing_token="$(jq -r '.pairing_token' <<<"${pairing_json}")"
  pair_body="$(jq -nc --arg token "${pairing_token}" --arg name "${model} smoke" \
    '{pairing_token:$token, device_name:$name, platform:"android"}')"
  pair_file="${TMP_DIR}/${safe_serial}-pair.response"
  android_http "${serial}" POST /mobile/pair "${pair_body}" - application/json >"${pair_file}"
  ensure_status "${pair_file}" 200 "${serial} pair"
  pair_response="$(response_body "${pair_file}")"
  BEARER_BY_SERIAL["${serial}"]="$(jq -r '.bearer_token' <<<"${pair_response}")"
  DEVICE_ID_BY_SERIAL["${serial}"]="$(jq -r '.device.id' <<<"${pair_response}")"

  session_file="${TMP_DIR}/${safe_serial}-session.response"
  android_http "${serial}" GET /mobile/session "" "${BEARER_BY_SERIAL[${serial}]}" - >"${session_file}"
  ensure_status "${session_file}" 200 "${serial} session"

  refresh_file="${TMP_DIR}/${safe_serial}-session-refresh.response"
  old_bearer="${BEARER_BY_SERIAL[${serial}]}"
  android_http "${serial}" POST /mobile/session/refresh '{}' "${old_bearer}" application/json >"${refresh_file}"
  ensure_status "${refresh_file}" 200 "${serial} refresh session token"
  refreshed_body="$(response_body "${refresh_file}")"
  refreshed_bearer="$(jq -r '.bearer_token' <<<"${refreshed_body}")"
  if [[ -z "${refreshed_bearer}" || "${refreshed_bearer}" == "null" || "${refreshed_bearer}" == "${old_bearer}" ]]; then
    echo "${serial} refresh did not return a replacement bearer token" >&2
    exit 1
  fi
  old_session_file="${TMP_DIR}/${safe_serial}-old-session-rejected.response"
  android_http "${serial}" GET /mobile/session "" "${old_bearer}" - >"${old_session_file}"
  ensure_not_success "${old_session_file}" "${serial} old bearer rejected after refresh"
  BEARER_BY_SERIAL["${serial}"]="${refreshed_bearer}"
done

for serial in "${DEVICE_SERIALS[@]}"; do
  safe_serial="${SAFE_SERIAL_BY_SERIAL[${serial}]}"
  safe_model="${SAFE_MODEL_BY_SERIAL[${serial}]}"
  bearer="${BEARER_BY_SERIAL[${serial}]}"
  label="${SEARCH_LABEL_BY_SERIAL[${serial}]}"
  payload_file="${TMP_DIR}/${safe_serial}-payload.bin"
  make_payload_file "${serial}" "${safe_model}" "${payload_file}" "${label}"
  payload_hash="$(sha256sum "${payload_file}" | awk '{print $1}')"
  payload_bytes="$(wc -c <"${payload_file}" | tr -d ' ')"
  PAYLOAD_FILE_BY_SERIAL["${serial}"]="${payload_file}"
  PAYLOAD_HASH_BY_SERIAL["${serial}"]="${payload_hash}"
  PAYLOAD_BYTES_BY_SERIAL["${serial}"]="${payload_bytes}"

  echo "[${serial}] uploading ${payload_bytes} byte chunked fixture"
  upload_id="$(reserve_upload "${serial}" "${bearer}" "${label}-${safe_model}.jpg" "${payload_hash}" "${payload_bytes}" "primary")"

  incomplete_file="${TMP_DIR}/${safe_serial}-primary-incomplete-complete.response"
  android_http "${serial}" POST "/mobile/uploads/${upload_id}/complete" "" "${bearer}" application/json >"${incomplete_file}"
  ensure_not_success "${incomplete_file}" "${serial} incomplete upload completion"

  first_chunk="${TMP_DIR}/${safe_serial}-primary-first-chunk.bin"
  dd if="${payload_file}" of="${first_chunk}" bs=1 count="${CHUNK_BYTES}" status=none
  first_chunk_file="$(push_chunk_and_put "${serial}" "${bearer}" "${upload_id}" 0 "${first_chunk}" "primary-first")"
  ensure_status "${first_chunk_file}" 200 "${serial} upload primary first chunk"
  retry_file="$(push_chunk_and_put "${serial}" "${bearer}" "${upload_id}" 0 "${first_chunk}" "primary-first-retry")"
  ensure_status "${retry_file}" 200 "${serial} retry primary first chunk"

  upload_status_file="${TMP_DIR}/${safe_serial}-primary-upload-status.response"
  android_http "${serial}" GET "/mobile/uploads/${upload_id}" "" "${bearer}" - >"${upload_status_file}"
  ensure_status "${upload_status_file}" 200 "${serial} upload status after first chunk"
  received_after_first="$(response_body "${upload_status_file}" | jq '.bytes_received')"
  if [[ "${received_after_first}" -ne "${CHUNK_BYTES}" ]]; then
    echo "${serial} upload resume status expected ${CHUNK_BYTES} bytes, got ${received_after_first}" >&2
    response_body "${upload_status_file}" >&2 || true
    echo >&2
    exit 1
  fi

  overlap_file="${TMP_DIR}/${safe_serial}-primary-overlap.response"
  android_http "${serial}" PUT "/mobile/uploads/${upload_id}/chunks/1" "overlap" "${bearer}" application/octet-stream >"${overlap_file}"
  ensure_not_success "${overlap_file}" "${serial} overlapping chunk rejection"

  if [[ "${payload_bytes}" -gt "${CHUNK_BYTES}" ]]; then
    offset="${CHUNK_BYTES}"
    chunk_index=1
    while [[ "${offset}" -lt "${payload_bytes}" ]]; do
      remaining=$((payload_bytes - offset))
      this_chunk="${CHUNK_BYTES}"
      if [[ "${remaining}" -lt "${this_chunk}" ]]; then
        this_chunk="${remaining}"
      fi
      chunk_file="${TMP_DIR}/${safe_serial}-primary-chunk-${chunk_index}.bin"
      dd if="${payload_file}" of="${chunk_file}" bs=1 skip="${offset}" count="${this_chunk}" status=none
      chunk_response="$(push_chunk_and_put "${serial}" "${bearer}" "${upload_id}" "${offset}" "${chunk_file}" "primary-${chunk_index}")"
      ensure_status "${chunk_response}" 200 "${serial} upload primary chunk ${chunk_index}"
      offset=$((offset + this_chunk))
      chunk_index=$((chunk_index + 1))
    done
  fi

  upload_response="$(complete_upload "${serial}" "${bearer}" "${upload_id}" "primary")"
  upload_status="$(jq -r '.status' <<<"${upload_response}")"
  asset_id="$(jq -r '.asset_id' <<<"${upload_response}")"
  if [[ "${upload_status}" != "completed" || -z "${asset_id}" || "${asset_id}" == "null" ]]; then
    echo "${serial} upload did not complete: ${upload_response}" >&2
    exit 1
  fi
  ASSET_ID_BY_SERIAL["${serial}"]="${asset_id}"

  duplicate_id="$(reserve_upload "${serial}" "${bearer}" "${label}-${safe_model}-duplicate.jpg" "${payload_hash}" "${payload_bytes}" "duplicate")"
  upload_payload_chunks "${serial}" "${bearer}" "${duplicate_id}" "${payload_file}" "duplicate"
  duplicate_response="$(complete_upload "${serial}" "${bearer}" "${duplicate_id}" "duplicate")"
  duplicate_asset_id="$(jq -r '.asset_id' <<<"${duplicate_response}")"
  if [[ "${duplicate_asset_id}" != "${asset_id}" ]]; then
    echo "${serial} duplicate upload created asset ${duplicate_asset_id}, expected existing asset ${asset_id}" >&2
    exit 1
  fi

  cancel_id="$(reserve_upload "${serial}" "${bearer}" "${label}-${safe_model}-cancel.jpg" "${payload_hash}" "${payload_bytes}" "cancel")"
  cancel_first_file="$(push_chunk_and_put "${serial}" "${bearer}" "${cancel_id}" 0 "${first_chunk}" "cancel-first")"
  ensure_status "${cancel_first_file}" 200 "${serial} upload cancel first chunk"
  cancel_file="${TMP_DIR}/${safe_serial}-cancel.response"
  android_http "${serial}" DELETE "/mobile/uploads/${cancel_id}" "" "${bearer}" application/json >"${cancel_file}"
  ensure_status "${cancel_file}" 200 "${serial} cancel upload"
  canceled_reject_file="${TMP_DIR}/${safe_serial}-cancel-reject.response"
  android_http "${serial}" PUT "/mobile/uploads/${cancel_id}/chunks/${CHUNK_BYTES}" "late" "${bearer}" application/octet-stream >"${canceled_reject_file}"
  ensure_not_success "${canceled_reject_file}" "${serial} canceled upload rejects chunks"
done

for viewer in "${DEVICE_SERIALS[@]}"; do
  viewer_safe="${SAFE_SERIAL_BY_SERIAL[${viewer}]}"
  viewer_bearer="${BEARER_BY_SERIAL[${viewer}]}"
  sessions_file="${TMP_DIR}/${viewer_safe}-sessions.response"
  android_http "${viewer}" GET /mobile/sessions "" "${viewer_bearer}" - >"${sessions_file}"
  ensure_status "${sessions_file}" 200 "${viewer} session list"
  session_count="$(json_array_length "${sessions_file}")"
  if [[ "${session_count}" -lt "${#DEVICE_SERIALS[@]}" ]]; then
    echo "${viewer} saw ${session_count} active mobile session(s), expected at least ${#DEVICE_SERIALS[@]}" >&2
    response_body "${sessions_file}" >&2 || true
    echo >&2
    exit 1
  fi
  if [[ "$(response_body "${sessions_file}" | jq 'any(.[]; has("token_hash"))')" != "false" ]]; then
    echo "${viewer} session list exposed token_hash" >&2
    exit 1
  fi

  workspace_file="${TMP_DIR}/${viewer_safe}-workspace.response"
  android_http "${viewer}" GET /mobile/workspace "" "${viewer_bearer}" - >"${workspace_file}"
  ensure_status "${workspace_file}" 200 "${viewer} workspace"
  workspace_assets="$(response_body "${workspace_file}" | jq '.timeline.total_assets')"
  workspace_devices="$(response_body "${workspace_file}" | jq '.devices | length')"
  if [[ "${workspace_assets}" -lt "${#DEVICE_SERIALS[@]}" || "${workspace_devices}" -lt "${#DEVICE_SERIALS[@]}" ]]; then
    echo "${viewer} workspace did not expose expected shared library/device state" >&2
    response_body "${workspace_file}" >&2 || true
    echo >&2
    exit 1
  fi

  assets_file="${TMP_DIR}/${viewer_safe}-assets.response"
  android_http "${viewer}" GET /mobile/assets "" "${viewer_bearer}" - >"${assets_file}"
  ensure_status "${assets_file}" 200 "${viewer} asset list"
  assets_count="$(json_array_length "${assets_file}")"
  if [[ "${assets_count}" -lt "${#DEVICE_SERIALS[@]}" ]]; then
    echo "${viewer} saw ${assets_count} mobile asset(s), expected at least ${#DEVICE_SERIALS[@]}" >&2
    response_body "${assets_file}" >&2 || true
    echo >&2
    exit 1
  fi

  for owner in "${DEVICE_SERIALS[@]}"; do
    owner_label="${SEARCH_LABEL_BY_SERIAL[${owner}]}"
    owner_asset_id="${ASSET_ID_BY_SERIAL[${owner}]}"
    owner_hash="${PAYLOAD_HASH_BY_SERIAL[${owner}]}"
    owner_bytes="${PAYLOAD_BYTES_BY_SERIAL[${owner}]}"
    search_file="${TMP_DIR}/${viewer_safe}-search-${owner_label}.response"
    android_http "${viewer}" GET "/mobile/search?text=${owner_label}&include_archived=false&limit=10" "" "${viewer_bearer}" - >"${search_file}"
    ensure_status "${search_file}" 200 "${viewer} search ${owner_label}"
    if [[ "$(response_body "${search_file}" | jq --arg id "${owner_asset_id}" '[.assets[] | select(.id == $id)] | length')" -lt 1 ]]; then
      echo "${viewer} search did not return ${owner}'s uploaded asset ${owner_asset_id}" >&2
      response_body "${search_file}" >&2 || true
      echo >&2
      exit 1
    fi

    availability_file="${TMP_DIR}/${viewer_safe}-availability-${owner_label}.response"
    android_http "${viewer}" GET "/mobile/assets/${owner_asset_id}/availability" "" "${viewer_bearer}" - >"${availability_file}"
    ensure_status "${availability_file}" 200 "${viewer} availability ${owner_label}"
    if [[ "$(response_body "${availability_file}" | jq -r '.asset_id')" != "${owner_asset_id}" ]]; then
      echo "${viewer} availability returned the wrong asset for ${owner_label}" >&2
      exit 1
    fi

    verify_download_hash "${viewer}" "${viewer_bearer}" "${owner_asset_id}" "/mobile/assets/${owner_asset_id}/original" "bytes=0-$((owner_bytes - 1))" 206 "${owner_hash}" "original-${owner_label}"
    verify_download_hash "${viewer}" "${viewer_bearer}" "${owner_asset_id}" "/mobile/assets/${owner_asset_id}/preview" "-" 200 "${owner_hash}" "preview-${owner_label}"
  done
done

for serial in "${DEVICE_SERIALS[@]}"; do
  safe_serial="${SAFE_SERIAL_BY_SERIAL[${serial}]}"
  bearer="${BEARER_BY_SERIAL[${serial}]}"
  asset_id="${ASSET_ID_BY_SERIAL[${serial}]}"
  flags_file="${TMP_DIR}/${safe_serial}-flags.response"
  android_http "${serial}" POST "/mobile/assets/${asset_id}/flags" '{"favorite":true}' "${bearer}" application/json >"${flags_file}"
  ensure_status "${flags_file}" 200 "${serial} flags"
  if [[ "$(response_body "${flags_file}" | jq -r '.favorite')" != "true" ]]; then
    echo "${serial} favorite flag did not update" >&2
    response_body "${flags_file}" >&2 || true
    echo >&2
    exit 1
  fi
done

first_serial="${DEVICE_SERIALS[0]}"
first_safe="${SAFE_SERIAL_BY_SERIAL[${first_serial}]}"
first_bearer="${BEARER_BY_SERIAL[${first_serial}]}"
revoke_file="${TMP_DIR}/${first_safe}-revoke-current.response"
android_http "${first_serial}" POST /mobile/session/revoke '{}' "${first_bearer}" application/json >"${revoke_file}"
ensure_status "${revoke_file}" 200 "${first_serial} revoke current session"
rejected_session_file="${TMP_DIR}/${first_safe}-session-rejected.response"
android_http "${first_serial}" GET /mobile/session "" "${first_bearer}" - >"${rejected_session_file}"
ensure_not_success "${rejected_session_file}" "${first_serial} revoked bearer token"
rejected_assets_file="${TMP_DIR}/${first_safe}-assets-rejected.response"
android_http "${first_serial}" GET /mobile/assets "" "${first_bearer}" - >"${rejected_assets_file}"
ensure_not_success "${rejected_assets_file}" "${first_serial} revoked bearer assets access"
rejected_original_file="${TMP_DIR}/${first_safe}-original-rejected.response"
android_http "${first_serial}" GET "/mobile/assets/${ASSET_ID_BY_SERIAL[${first_serial}]}/original" "" "${first_bearer}" - "bytes=0-0" >"${rejected_original_file}"
ensure_not_success "${rejected_original_file}" "${first_serial} revoked bearer original access"

if [[ "${#DEVICE_SERIALS[@]}" -gt 1 ]]; then
  second_serial="${DEVICE_SERIALS[1]}"
  second_safe="${SAFE_SERIAL_BY_SERIAL[${second_serial}]}"
  second_bearer="${BEARER_BY_SERIAL[${second_serial}]}"
  second_device_id="${DEVICE_ID_BY_SERIAL[${second_serial}]}"
  still_valid_file="${TMP_DIR}/${second_safe}-still-valid.response"
  android_http "${second_serial}" GET /mobile/session "" "${second_bearer}" - >"${still_valid_file}"
  ensure_status "${still_valid_file}" 200 "${second_serial} remains valid after peer revoke"

  device_revoke_file="${TMP_DIR}/${second_safe}-device-revoke.response"
  android_http "${second_serial}" POST "/mobile/devices/${second_device_id}/sessions/revoke" '{}' "${second_bearer}" application/json >"${device_revoke_file}"
  ensure_status "${device_revoke_file}" 200 "${second_serial} revoke device sessions"
  rejected_device_session_file="${TMP_DIR}/${second_safe}-device-session-rejected.response"
  android_http "${second_serial}" GET /mobile/session "" "${second_bearer}" - >"${rejected_device_session_file}"
  ensure_not_success "${rejected_device_session_file}" "${second_serial} device-revoked bearer token"
fi

for serial in "${DEVICE_SERIALS[@]}"; do
  echo "[${serial}] device_id=${DEVICE_ID_BY_SERIAL[${serial}]} uploaded_asset=${ASSET_ID_BY_SERIAL[${serial}]} sha256=${PAYLOAD_HASH_BY_SERIAL[${serial}]} bytes=${PAYLOAD_BYTES_BY_SERIAL[${serial}]}"
done

echo
echo "Android mobile smoke passed for ${#DEVICE_SERIALS[@]} device(s)."
