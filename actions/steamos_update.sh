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
CHECK_OUTPUT=""
CHECK_RC=0

# STDERR steamos-update сразу отправляем в STDOUT, чтобы GUI не лепил лишних [ERR]
if CHECK_OUTPUT="$(run_sudo steamos-update check 2>&1)"; then
  CHECK_RC=0
else
  CHECK_RC=$?
fi

# Печатаем вывод check, чтобы он был виден в логе GUI
if [[ -n "$CHECK_OUTPUT" ]]; then
  printf '%s\n' "$CHECK_OUTPUT"
fi

# Случай "No update available" — считаем УСПЕХОМ
if printf '%s\n' "$CHECK_OUTPUT" | grep -qi "no update available"; then
  echo "[INFO] No SteamOS updates available. Nothing to do."
  exit 0
fi

# Остальные ненулевые коды — реальные ошибки
if [[ $CHECK_RC -ne 0 ]]; then
  echo "[ERR] 'steamos-update check' failed with exit code ${CHECK_RC}." >&2
  exit "$CHECK_RC"
fi

echo "[INFO] Updates appear to be available. Running 'steamos-update'..."

UPDATE_OUTPUT=""
UPDATE_RC=0

if UPDATE_OUTPUT="$(run_sudo steamos-update 2>&1)"; then
  UPDATE_RC=0
else
  UPDATE_RC=$?
fi

if [[ -n "$UPDATE_OUTPUT" ]]; then
  printf '%s\n' "$UPDATE_OUTPUT"
fi

if [[ $UPDATE_RC -eq 0 ]]; then
  echo "[INFO] 'steamos-update' finished successfully."
  exit 0
else
  echo "[ERR] 'steamos-update' failed with exit code ${UPDATE_RC}." >&2
  exit "$UPDATE_RC"
fi
