#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="${ROOT_DIR}/app"
HOST_BASE_URL="${PRIVATE_GALLERY_SMOKE_HOST_BASE_URL:-http://127.0.0.1:4821}"
DEVICE_BASE_URL="${PRIVATE_GALLERY_SMOKE_DEVICE_BASE_URL:-http://127.0.0.1:4821}"
REQUESTED_DEVICE_SERIALS="${PRIVATE_GALLERY_SMOKE_DEVICE_SERIALS:-}"
REQUIRE_DEVICE_COUNT="${PRIVATE_GALLERY_APP_SMOKE_REQUIRE_DEVICE_COUNT:-2}"
APP_ID="${PRIVATE_GALLERY_APP_ID:-com.privategallery.app}"
ACTIVITY="${PRIVATE_GALLERY_APP_ACTIVITY:-com.privategallery.app/.MainActivity}"
AUTODRIVE="${PRIVATE_GALLERY_APP_SMOKE_AUTODRIVE:-1}"
CLEAR_DATA="${PRIVATE_GALLERY_APP_SMOKE_CLEAR_DATA:-1}"
UPLOAD_NEWEST="${PRIVATE_GALLERY_APP_SMOKE_UPLOAD_NEWEST:-0}"
PAIR_MODE="${PRIVATE_GALLERY_APP_SMOKE_PAIR_MODE:-direct}"
UI_DUMP_TIMEOUT_SECONDS="${PRIVATE_GALLERY_APP_SMOKE_UI_DUMP_TIMEOUT_SECONDS:-8}"
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

xml_escape() {
  sed -e 's/&/\&amp;/g' -e 's/"/\&quot;/g' -e "s/'/\&apos;/g" -e 's/</\&lt;/g' -e 's/>/\&gt;/g' <<<"$1"
}

adb_text() {
  local serial="$1"
  local text="$2"
  text="${text// /%s}"
  adb -s "${serial}" shell input text "${text}" >/dev/null
}

clear_focused_text() {
  local serial="$1"
  adb -s "${serial}" shell input keyevent KEYCODE_MOVE_END >/dev/null 2>&1 || true
  for _ in {1..80}; do
    adb -s "${serial}" shell input keyevent KEYCODE_DEL >/dev/null 2>&1 || true
  done
}

dump_ui() {
  local serial="$1"
  local output="$2"
  if ! timeout "${UI_DUMP_TIMEOUT_SECONDS}s" adb -s "${serial}" shell uiautomator dump /sdcard/private-gallery-window.xml >/dev/null; then
    echo "[${serial}] uiautomator dump failed or timed out after ${UI_DUMP_TIMEOUT_SECONDS}s" >&2
    return 1
  fi
  if ! timeout "${UI_DUMP_TIMEOUT_SECONDS}s" adb -s "${serial}" exec-out cat /sdcard/private-gallery-window.xml >"${output}"; then
    echo "[${serial}] failed to pull uiautomator dump" >&2
    return 1
  fi
  [[ -s "${output}" ]]
}

node_bounds_for_text() {
  local dump_file="$1"
  local text
  text="$(xml_escape "$2")"
  grep -o "<node[^>]*\\(text=\"${text}\"\\|content-desc=\"${text}\"\\)[^>]*>" "${dump_file}" \
    | head -1 \
    | sed -n 's/.*bounds="\[\([0-9][0-9]*\),\([0-9][0-9]*\)\]\[\([0-9][0-9]*\),\([0-9][0-9]*\)\]".*/\1 \2 \3 \4/p'
}

tap_text() {
  local serial="$1"
  local text="$2"
  local dump_file="${TMP_DIR}/$(tr -c 'A-Za-z0-9._-' '_' <<<"${serial}")-window.xml"
  local bounds=""
  for _ in {1..12}; do
    dump_ui "${serial}" "${dump_file}" || true
    bounds="$(node_bounds_for_text "${dump_file}" "${text}")"
    if [[ -n "${bounds}" ]]; then
      break
    fi
    sleep 1
  done
  if [[ -z "${bounds}" ]]; then
    echo "[${serial}] could not find UI text: ${text}" >&2
    return 1
  fi
  read -r left top right bottom <<<"${bounds}"
  adb -s "${serial}" shell input tap "$(((left + right) / 2))" "$(((top + bottom) / 2))" >/dev/null
}

wait_for_any_text() {
  local serial="$1"
  shift
  local dump_file="${TMP_DIR}/$(tr -c 'A-Za-z0-9._-' '_' <<<"${serial}")-wait.xml"
  for _ in {1..30}; do
    dump_ui "${serial}" "${dump_file}" || true
    for expected in "$@"; do
      if [[ -n "$(node_bounds_for_text "${dump_file}" "${expected}")" ]]; then
        echo "${expected}"
        return 0
      fi
    done
    sleep 1
  done
  echo "[${serial}] timed out waiting for any of: $*" >&2
  return 1
}

grant_permission() {
  local serial="$1"
  local permission="$2"
  adb -s "${serial}" shell pm grant "${APP_ID}" "${permission}" >/dev/null 2>&1 || true
}

launch_app() {
  local serial="$1"
  adb -s "${serial}" shell am force-stop "${APP_ID}" >/dev/null 2>&1 || true
  adb -s "${serial}" shell am start -n "${ACTIVITY}" >/dev/null
}

create_pairing_token() {
  local serial="$1"
  local model="$2"
  curl -fsS -X POST "${HOST_BASE_URL}/pairing/sessions" \
    -H 'content-type: application/json' \
    -d "$(jq -nc --arg name "${model} app smoke ${serial}" '{device_name:$name, platform:"android"}')" \
    | jq -r '.pairing_token'
}

pair_mobile_session() {
  local pairing_token="$1"
  local device_name="$2"
  curl -fsS -X POST "${HOST_BASE_URL}/mobile/pair" \
    -H 'content-type: application/json' \
    -d "$(jq -nc --arg token "${pairing_token}" --arg name "${device_name}" \
      '{pairing_token:$token,device_name:$name,platform:"android"}')"
}

launch_app_with_debug_session() {
  local serial="$1"
  local bearer_token="$2"
  local device_name="$3"
  adb -s "${serial}" shell am force-stop "${APP_ID}" >/dev/null 2>&1 || true
  adb -s "${serial}" shell am start \
    -n "${ACTIVITY}" \
    --es private_gallery_desktop_url "${DEVICE_BASE_URL}" \
    --es private_gallery_mobile_bearer_token "${bearer_token}" \
    --es private_gallery_device_name "${device_name}" >/dev/null
}

wait_for_debug_pairing_marker() {
  local serial="$1"
  local marker
  for _ in {1..30}; do
    marker="$(
      adb -s "${serial}" shell run-as "${APP_ID}" \
        cat files/private_gallery_mobile_pairing_status.json 2>/dev/null \
        | tr -d '\r' || true
    )"
    if jq -e --arg base "${DEVICE_BASE_URL}" \
      '.token_present == true and .desktop_url == $base' \
      <<<"${marker}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  echo "[${serial}] debug pairing marker was not written by the app" >&2
  return 1
}

verify_host_session() {
  local bearer_token="$1"
  curl -fsS "${HOST_BASE_URL}/mobile/session" \
    -H "authorization: Bearer ${bearer_token}" >/dev/null
}

manual_steps() {
  local serial="$1"
  local token="$2"
  cat <<EOF

[${serial}] Manual fallback:
  1. Open Private Gallery.
  2. Tap "Join Existing Group".
  3. Tap "Use code".
  4. Enter Desktop URL: ${DEVICE_BASE_URL}
  5. Enter pairing token: ${token}
  6. Tap "Pair now".
  7. Confirm the paired workspace shows "Same-network sync active" or "Paired locally".
  8. For real camera-roll smoke, tap "Upload newest item", refresh, then tap "Download first original".
EOF
}

run_autodrive_pairing() {
  local serial="$1"
  local token="$2"
  wait_for_any_text "${serial}" "Welcome to Private Gallery" "Join Existing Group" >/dev/null
  tap_text "${serial}" "Join Existing Group"
  tap_text "${serial}" "Use code"
  tap_text "${serial}" "Desktop URL"
  clear_focused_text "${serial}"
  adb_text "${serial}" "${DEVICE_BASE_URL}"
  tap_text "${serial}" "Invite JSON or pairing token"
  clear_focused_text "${serial}"
  adb_text "${serial}" "${token}"
  tap_text "${serial}" "Pair now"
  wait_for_any_text "${serial}" "Same-network sync active" "Paired locally" "Check session" >/dev/null
  if [[ "${UPLOAD_NEWEST}" == "1" ]]; then
    tap_text "${serial}" "Upload newest item" || tap_text "${serial}" "Upload newest"
    wait_for_any_text "${serial}" "Upload ended as completed" "Upload ended as duplicate" "Download first original" "Download first" >/dev/null
  fi
}

require_tool adb
require_tool awk
require_tool curl
require_tool flutter
require_tool grep
require_tool jq
require_tool sed
require_tool timeout
require_tool tr

require_uint PRIVATE_GALLERY_APP_SMOKE_REQUIRE_DEVICE_COUNT "${REQUIRE_DEVICE_COUNT}"
require_uint PRIVATE_GALLERY_APP_SMOKE_UI_DUMP_TIMEOUT_SECONDS "${UI_DUMP_TIMEOUT_SECONDS}"
case "${PAIR_MODE}" in
  direct | ui | manual) ;;
  *)
    echo "PRIVATE_GALLERY_APP_SMOKE_PAIR_MODE must be direct, ui, or manual" >&2
    exit 1
    ;;
esac
curl -fsS "${HOST_BASE_URL}/health" >/dev/null

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

if [[ "${#DEVICE_SERIALS[@]}" -ne "${REQUIRE_DEVICE_COUNT}" ]]; then
  echo "expected ${REQUIRE_DEVICE_COUNT} authorized adb device(s), found ${#DEVICE_SERIALS[@]}" >&2
  adb devices -l >&2
  exit 1
fi

echo "Building debug APK..."
(cd "${APP_DIR}" && flutter build apk --debug)
APK_PATH="${APP_DIR}/build/app/outputs/flutter-apk/app-debug.apk"
if [[ ! -f "${APK_PATH}" ]]; then
  echo "debug APK was not produced at ${APK_PATH}" >&2
  exit 1
fi

for serial in "${DEVICE_SERIALS[@]}"; do
  echo
  echo "[${serial}] installing ${APP_ID}"
  adb -s "${serial}" install -r "${APK_PATH}" >/dev/null
  if [[ "${CLEAR_DATA}" == "1" ]]; then
    adb -s "${serial}" shell pm clear "${APP_ID}" >/dev/null
  fi
  grant_permission "${serial}" android.permission.CAMERA
  grant_permission "${serial}" android.permission.READ_MEDIA_IMAGES
  grant_permission "${serial}" android.permission.READ_MEDIA_VIDEO
  grant_permission "${serial}" android.permission.READ_MEDIA_VISUAL_USER_SELECTED
  grant_permission "${serial}" android.permission.READ_EXTERNAL_STORAGE

  model="$(adb -s "${serial}" shell getprop ro.product.model | tr -d '\r')"
  [[ -n "${model}" ]] || model="${serial}"
  device_name="$(tr -c 'A-Za-z0-9._-' '_' <<<"${model}_app_smoke_${serial}" | sed 's/_$//')"
  token="$(create_pairing_token "${serial}" "${device_name}")"
  invite_file="${TMP_DIR}/${serial}-invite.json"
  jq -nc \
    --arg group "Private Gallery" \
    --arg base "${DEVICE_BASE_URL}" \
    --arg token "${token}" \
    '{type:"private_gallery_device_group_invite",version:1,action:"join_group",mode:"lan",group_name:$group,base_url:$base,pairing_token:$token}' \
    >"${invite_file}"
  adb -s "${serial}" push "${invite_file}" "/sdcard/Download/private-gallery-invite-${serial}.json" >/dev/null || true

  if [[ "${PAIR_MODE}" == "direct" ]]; then
    pair_response="$(pair_mobile_session "${token}" "${device_name}")"
    bearer_token="$(jq -r '.bearer_token' <<<"${pair_response}")"
    if [[ -z "${bearer_token}" || "${bearer_token}" == "null" ]]; then
      echo "[${serial}] mobile pair response did not include a bearer token" >&2
      exit 1
    fi
    verify_host_session "${bearer_token}"
    launch_app_with_debug_session "${serial}" "${bearer_token}" "${device_name}"
    wait_for_debug_pairing_marker "${serial}"
    echo "[${serial}] installed app loaded a debug local group session"
  elif [[ "${PAIR_MODE}" == "ui" && "${AUTODRIVE}" == "1" ]]; then
    launch_app "${serial}"
    if run_autodrive_pairing "${serial}" "${token}"; then
      echo "[${serial}] paired through Flutter UI"
    else
      manual_steps "${serial}" "${token}"
      exit 1
    fi
  else
    launch_app "${serial}"
    manual_steps "${serial}" "${token}"
  fi
done

echo
echo "Android app smoke setup completed for ${#DEVICE_SERIALS[@]} device(s)."
if [[ "${UPLOAD_NEWEST}" != "1" ]]; then
  echo "Set PRIVATE_GALLERY_APP_SMOKE_UPLOAD_NEWEST=1 to attempt the real camera-roll upload button after pairing."
fi
if [[ "${PAIR_MODE}" == "direct" ]]; then
  echo "Direct mode leaves debug APKs paired to the local group until sessions are revoked or app data is cleared."
fi
