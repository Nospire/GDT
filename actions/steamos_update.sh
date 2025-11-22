#!/usr/bin/env bash
set -euo pipefail

# Пароль sudo, который GUI положил в окружение при запуске engine.sh
SUDO_PASS="${GDT_SUDO_PASS:-}"

run_sudo() {
  if [[ -n "$SUDO_PASS" ]]; then
    # Кормим пароль через stdin, без TTY и без prompt'а
    printf '%s\n' "$SUDO_PASS" | sudo -S -p '' "$@"
  else
    # Теоретически в нормальном сценарии не должно срабатывать
    sudo "$@"
  fi
}

echo "[INFO] Checking for steamos-update..."
if ! command -v steamos-update >/dev/null 2>&1; then
  echo "[ERR] steamos-update command not found. This action is only for SteamOS." >&2
  exit 1
fi

echo "[INFO] Running 'steamos-update check'..."
if ! run_sudo steamos-update check; then
  echo "[ERR] 'steamos-update check' failed." >&2
  exit 1
fi

echo "[INFO] Running full 'steamos-update'..."
run_sudo steamos-update

echo "[INFO] SteamOS update command finished."
