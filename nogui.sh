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

# Ask for sudo password if not provided from outside.
if [ "${GDT_SUDO_PASS-}" = "" ]; then
  TTY_DEV="/dev/tty"

  if [ ! -r "$TTY_DEV" ] || [ ! -w "$TTY_DEV" ]; then
    echo "[ERR] No TTY available. Set GDT_SUDO_PASS in environment." >&2
    exit 1
  fi

  printf "Enter sudo password (input will be hidden): " >"$TTY_DEV"

  stty_state=""
  stty_state="$(stty -g <"$TTY_DEV" 2>/dev/null || echo "")"
  stty -echo <"$TTY_DEV" 2>/dev/null || true

  IFS= read -r GDT_SUDO_PASS <"$TTY_DEV" || GDT_SUDO_PASS=""

  if [ -n "$stty_state" ]; then
    stty "$stty_state" <"$TTY_DEV" 2>/dev/null || true
  fi
  printf "\n" >"$TTY_DEV"
fi

export GDT_SUDO_PASS

echo "[RUN] Starting SteamOS update (no GUI)..."
exec "${LOCAL_ENGINE}" steamos_update en
