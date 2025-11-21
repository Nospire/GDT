#!/usr/bin/env bash
set -euo pipefail

ACTION="${1:-}"
UI_LANG="${2:-en}"

say() {
  local ru_msg="$1"
  local en_msg="$2"
  if [[ "$UI_LANG" == "ru" ]]; then
    echo "$ru_msg"
  else
    echo "$en_msg"
  fi
}

if [[ -z "$ACTION" ]]; then
  if [[ "$UI_LANG" == "ru" ]]; then
    echo "[ERR] Не указано действие." >&2
    echo "Использование: $0 <openh264_fix|steamos_update|flatpak_update|antizapret> [ru|en]" >&2
  else
    echo "[ERR] No ACTION specified." >&2
    echo "Usage: $0 <openh264_fix|steamos_update|flatpak_update|antizapret> [ru|en]" >&2
  fi
  exit 1
fi

# --- Проверка активного sudo (без запроса пароля) ---

if ! sudo -n true 2>/dev/null; then
  say "[ERR] sudo не активен. Сначала нажмите кнопку sudo внизу и введите пароль." \
      "[ERR] sudo is not active. Press the sudo button below and enter your password first."
  exit 1
fi

say "[INFO] Движок Geekcom Deck Tools" \
    "[INFO] Geekcom Deck Tools engine"
say "[INFO] Действие: ${ACTION}" \
    "[INFO] ACTION=${ACTION}"
say "[INFO] Пока это демо-заглушка. Логика будет добавлена позже." \
    "[INFO] This is a demo stub. Real logic will be added later."

case "$ACTION" in
  openh264_fix)
    say "[STEP] Здесь будет исправление ошибки OpenH264 403." \
        "[STEP] Would run OpenH264 403 fix here."
    ;;
  steamos_update)
    say "[STEP] Здесь будет обновление SteamOS." \
        "[STEP] Would run SteamOS update here."
    ;;
  flatpak_update)
    say "[STEP] Здесь будет обновление Flatpak-приложений." \
        "[STEP] Would run Flatpak apps update here."
    ;;
  antizapret)
    say "[STEP] Здесь будет установка/обновление Geekcom antizapret." \
        "[STEP] Would install/update Geekcom antizapret here."
    ;;
  *)
    say "[ERR] Неизвестное действие: ${ACTION}" \
        "[ERR] Unknown ACTION: ${ACTION}" >&2
    exit 1
    ;;
esac

say "[DONE] Заглушка успешно завершена." \
    "[DONE] Stub finished successfully."
