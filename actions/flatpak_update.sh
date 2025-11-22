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

echo "[INFO] Checking for flatpak..."
if ! command -v flatpak >/dev/null 2>&1; then
  echo "[ERR] flatpak not found. Cannot update applications." >&2
  exit 1
fi

echo "[INFO] Flatpak version:"
flatpak --version || true

echo "[INFO] Updating system-wide Flatpak apps (if any)..."
if ! run_sudo flatpak update -y --system; then
  echo "[WARN] System-wide flatpak update failed or no system apps present." >&2
fi

echo "[INFO] Updating user Flatpak apps..."
if ! flatpak update -y --user; then
  echo "[ERR] User-level flatpak update failed." >&2
  exit 1
fi

echo "[INFO] Flatpak updates finished."
