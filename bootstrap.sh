#!/usr/bin/env bash
set -euo pipefail

GITHUB_USER="Nospire"
GITHUB_REPO="GDT"

BIN_NAME="geekcom-deck-tools"

BIN_URL="https://github.com/${GITHUB_USER}/${GITHUB_REPO}/releases/latest/download/${BIN_NAME}"
RAW_BASE="https://raw.githubusercontent.com/${GITHUB_USER}/${GITHUB_REPO}/main"

BASE_DIR="${HOME}/.scripts"
APP_DIR="${BASE_DIR}/geekcom-deck-tools"
ACTIONS_DIR="${APP_DIR}/actions"

LOCAL_BIN="${APP_DIR}/${BIN_NAME}"
LOCAL_ENGINE="${APP_DIR}/engine.sh"

echo "[INFO] Geekcom Deck Tools bootstrap"
echo "[INFO] Target dir: ${APP_DIR}"

mkdir -p "${APP_DIR}"
mkdir -p "${ACTIONS_DIR}"

echo "[STEP] Downloading binary from: ${BIN_URL}"
curl -fsSL -o "${LOCAL_BIN}.tmp" "${BIN_URL}"
mv "${LOCAL_BIN}.tmp" "${LOCAL_BIN}"
chmod +x "${LOCAL_BIN}"

echo "[STEP] Downloading engine from: ${RAW_BASE}/engine.sh"
curl -fsSL -o "${LOCAL_ENGINE}.tmp" "${RAW_BASE}/engine.sh"
mv "${LOCAL_ENGINE}.tmp" "${LOCAL_ENGINE}"
chmod +x "${LOCAL_ENGINE}"

for f in openh264_fix.sh steamos_update.sh flatpak_update.sh antizapret.sh; do
  echo "[STEP] Downloading action: ${f}"
  curl -fsSL -o "${ACTIONS_DIR}/${f}.tmp" "${RAW_BASE}/actions/${f}"
  mv "${ACTIONS_DIR}/${f}.tmp" "${ACTIONS_DIR}/${f}"
  chmod +x "${ACTIONS_DIR}/${f}"
done

echo "[OK] Geekcom Deck Tools updated."
echo "[RUN] Starting GUI..."

exec "${LOCAL_BIN}"
