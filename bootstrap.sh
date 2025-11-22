#!/usr/bin/env bash
set -euo pipefail

REPO_OWNER="nospire"
REPO_NAME="geekcom-deck-tools"
RAW_BASE="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/main"

INSTALL_DIR="${HOME}/.scripts/geekcom-deck-tools"

mkdir -p "${INSTALL_DIR}"
mkdir -p "${INSTALL_DIR}/actions"

download() {
  local url="$1"
  local dst="$2"
  echo "[BOOTSTRAP] Fetching ${url} -> ${dst}"
  curl -fsSL "${url}" -o "${dst}"
}

# Бинарь GUI
download "${RAW_BASE}/geekcom-deck-tools" "${INSTALL_DIR}/geekcom-deck-tools"
chmod +x "${INSTALL_DIR}/geekcom-deck-tools"

# Движок
download "${RAW_BASE}/engine.sh" "${INSTALL_DIR}/engine.sh"
chmod +x "${INSTALL_DIR}/engine.sh"

# Actions-скрипты
for f in openh264_fix.sh steamos_update.sh flatpak_update.sh antizapret.sh; do
  download "${RAW_BASE}/actions/${f}" "${INSTALL_DIR}/actions/${f}"
  chmod +x "${INSTALL_DIR}/actions/${f}"
done

echo "[BOOTSTRAP] Done. Starting GUI..."
exec "${INSTALL_DIR}/geekcom-deck-tools"
