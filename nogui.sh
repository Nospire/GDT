#!/usr/bin/env bash
set -euo pipefail

GITHUB_USER="Nospire"
GITHUB_REPO="GDT"

RAW_BASE="https://raw.githubusercontent.com/${GITHUB_USER}/${GITHUB_REPO}/main"

BASE_DIR="${HOME}/.scripts"
APP_DIR="${BASE_DIR}/geekcom-deck-tools"
ACTIONS_DIR="${APP_DIR}/actions"

LOCAL_ENGINE="${APP_DIR}/engine.sh"

echo "[INFO] Geekcom Deck Tools no-GUI bootstrap"
echo "[INFO] Target dir: ${APP_DIR}"

mkdir -p "${ACTIONS_DIR}"

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

<<<<<<< HEAD
# Если пароль не передан извне, спрашиваем в TTY.
if [[ -z "${GDT_SUDO_PASS:-}" ]]; then
  printf "Enter sudo password (input will be hidden): "
  read -r -s GDT_SUDO_PASS
  echo
fi
export GDT_SUDO_PASS

echo "[RUN] Starting SteamOS update (no GUI)..."
exec "${LOCAL_ENGINE}" steamos_update ru
=======
# In no-GUI mode we do not pass the sudo password via env
unset GDT_SUDO_PASS || true

echo "[STEP] sudo authentication (TTY or terminal will prompt)..."
if ! sudo -v; then
  echo "[ERR] sudo authentication failed." >&2
  exit 1
fi

echo "[RUN] Starting SteamOS update (no GUI)..."
exec "${LOCAL_ENGINE}" steamos_update en
>>>>>>> b50e2ac (Add no-GUI updater)
