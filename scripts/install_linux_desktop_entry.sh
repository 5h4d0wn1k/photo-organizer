#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAUNCHER="${ROOT_DIR}/scripts/private_gallery_linux_launcher.sh"
DESKTOP_DIR="${XDG_DATA_HOME:-${HOME}/.local/share}/applications"
DESKTOP_FILE="${DESKTOP_DIR}/private-gallery.desktop"

mkdir -p "${DESKTOP_DIR}"
chmod +x "${LAUNCHER}"

cat >"${DESKTOP_FILE}" <<EOF
[Desktop Entry]
Type=Application
Name=Private Gallery
Comment=Local-first private photo and video organizer
Exec=/usr/bin/env bash "${LAUNCHER}"
Terminal=false
Categories=Graphics;Photography;
Icon=folder-pictures
StartupNotify=true
EOF

chmod +x "${DESKTOP_FILE}"

if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database "${DESKTOP_DIR}" >/dev/null 2>&1 || true
fi

echo "Installed desktop launcher:"
echo "${DESKTOP_FILE}"
echo
echo "You can now search for 'Private Gallery' in your Linux app launcher."
