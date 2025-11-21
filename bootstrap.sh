#!/usr/bin/env bash
set -euo pipefail

# === SETTINGS ===

GITHUB_USER="nospire"
GITHUB_REPO="geekcom-deck-tools"

BIN_NAME="geekcom-deck-tools"
BIN_URL="https://github.com/${GITHUB_USER}/${GITHUB_REPO}/releases/latest/download/${BIN_NAME}"

ENGINE_PATH="engine.sh"
ENGINE_URL="https://raw.githubusercontent.com/${GITHUB_USER}/${GITHUB_REPO}/main/${ENGINE_PATH}"

SUDO_HELPER_PATH="sudo-helper.sh"
SUDO_HELPER_URL="https://raw.githubusercontent.com/${GITHUB_USER}/${GITHUB_REPO}/main/${SUDO_HELPER_PATH}"

BASE_DIR="${HOME}/.scripts"
APP_DIR="${BASE_DIR}/geekcom-deck-tools"
LOCAL_BIN="${APP_DIR}/${BIN_NAME}"
LOCAL_ENGINE="${APP_DIR}/engine.sh"
LOCAL_SUDO_HELPER="${APP_DIR}/sudo-helper.sh"

# === LOGIC ===

echo "[INFO] Geekcom Deck Tools bootstrap"
echo "[INFO] Target dir: ${APP_DIR}"

mkdir -p "${APP_DIR}"

echo "[STEP] Downloading binary from: ${BIN_URL}"
curl -fsSL -o "${LOCAL_BIN}.tmp" "${BIN_URL}"
mv "${LOCAL_BIN}.tmp" "${LOCAL_BIN}"
chmod +x "${LOCAL_BIN}"

echo "[STEP] Downloading engine from: ${ENGINE_URL}"
curl -fsSL -o "${LOCAL_ENGINE}.tmp" "${ENGINE_URL}"
mv "${LOCAL_ENGINE}.tmp" "${LOCAL_ENGINE}"
chmod +x "${LOCAL_ENGINE}"

echo "[STEP] Downloading sudo helper from: ${SUDO_HELPER_URL}"
curl -fsSL -o "${LOCAL_SUDO_HELPER}.tmp" "${SUDO_HELPER_URL}"
mv "${LOCAL_SUDO_HELPER}.tmp" "${LOCAL_SUDO_HELPER}"
chmod +x "${LOCAL_SUDO_HELPER}"

echo "[OK] Geekcom Deck Tools updated."
echo "[RUN] Starting GUI..."

exec "${LOCAL_BIN}"
