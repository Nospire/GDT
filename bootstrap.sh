#!/usr/bin/env bash
set -euo pipefail

# === SETTINGS ===

GITHUB_USER="nospire"
GITHUB_REPO="geekcom-deck-tools"

BIN_NAME="geekcom-deck-tools"
BIN_URL="https://github.com/${GITHUB_USER}/${GITHUB_REPO}/releases/latest/download/${BIN_NAME}"

ENGINE_PATH="engine.sh"
ENGINE_URL="https://raw.githubusercontent.com/${GITHUB_USER}/${GITHUB_REPO}/main/${ENGINE_PATH}"

BASE_DIR="${HOME}/.scripts"
APP_DIR="${BASE_DIR}/geekcom-deck-tools"
LOCAL_BIN="${APP_DIR}/${BIN_NAME}"
LOCAL_ENGINE="${APP_DIR}/engine.sh"

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

echo "[OK] Geekcom Deck Tools updated."
echo "[RUN] Starting GUI..."

exec "${LOCAL_BIN}"
