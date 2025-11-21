#!/usr/bin/env bash
set -euo pipefail

UI_LANG="${1:-en}"
USER_NAME="${SUDO_USER:-$USER}"

have_kdialog() {
  command -v kdialog >/dev/null 2>&1
}

msg_info() {
  local ru_msg="$1"
  local en_msg="$2"
  if [[ "$UI_LANG" == "ru" ]]; then
    echo "[INFO] $ru_msg"
    have_kdialog && kdialog --msgbox "$ru_msg" >/dev/null 2>&1 || true
  else
    echo "[INFO] $en_msg"
    have_kdialog && kdialog --msgbox "$en_msg" >/dev/null 2>&1 || true
  fi
}

msg_error() {
  local ru_msg="$1"
  local en_msg="$2"
  if [[ "$UI_LANG" == "ru" ]]; then
    echo "[ERR] $ru_msg" >&2
    have_kdialog && kdialog --error "$ru_msg" >/dev/null 2>&1 || true
  else
    echo "[ERR] $en_msg" >&2
    have_kdialog && kdialog --error "$en_msg" >/dev/null 2>&1 || true
  fi
}

prompt_pass() {
  local ru_msg="$1"
  local en_msg="$2"
  if ! have_kdialog; then
    if [[ "$UI_LANG" == "ru" ]]; then
      echo "[ERR] kdialog недоступен, запрос пароля невозможен." >&2
    else
      echo "[ERR] kdialog is not available, cannot ask for password." >&2
    fi
    return 1
  fi
  if [[ "$UI_LANG" == "ru" ]]; then
    kdialog --password "$ru_msg"
  else
    kdialog --password "$en_msg"
  fi
}

# 1) sudo уже активен?
if sudo -n true 2>/dev/null; then
  msg_info "Режим sudo уже активен." "sudo is already active."
  exit 0
fi

# 2) Есть ли у пользователя пароль?
PASS_STATUS=$(passwd -S "$USER_NAME" 2>/dev/null | awk '{print $2}')
NO_PASS=0
if [[ "$PASS_STATUS" == "NP" || -z "$PASS_STATUS" ]]; then
  NO_PASS=1
fi

if (( NO_PASS )); then
  # --- Новый пароль ---
  msg_info \
    "У пользователя ${USER_NAME} ещё нет пароля. Задайте пароль для sudo.\nЗапомните его — он понадобится для системных операций." \
    "User ${USER_NAME} has no password yet. Set a password for sudo.\nRemember it — it will be required for system operations."

  while true; do
    NEW_PASS=$(prompt_pass "Задайте новый пароль sudo:" "Set new sudo password:")
    [[ $? -ne 0 ]] && exit 1

    CONFIRM_PASS=$(prompt_pass "Повторите новый пароль sudo:" "Repeat new sudo password:")
    [[ $? -ne 0 ]] && exit 1

    if [[ -z "$NEW_PASS" ]]; then
      msg_error "Пароль не может быть пустым." "Password cannot be empty."
      continue
    fi

    if [[ "$NEW_PASS" != "$CONFIRM_PASS" ]]; then
      msg_error "Пароли не совпадают. Попробуйте ещё раз." "Passwords do not match. Try again."
      continue
    fi

    if printf '%s\n%s\n' "$NEW_PASS" "$NEW_PASS" | passwd "$USER_NAME" >/dev/null 2>&1; then
      # Проверяем sudo с новым паролем
      if printf '%s\n' "$NEW_PASS" | sudo -S -k true >/dev/null 2>&1; then
        sudo -v >/dev/null 2>&1 || true
        msg_info "Пароль задан, режим sudo активирован." "Password set, sudo mode activated."
        exit 0
      else
        msg_error "Пароль задан, но sudo не удалось активировать." "Password set, but failed to activate sudo."
        exit 1
      fi
    else
      msg_error "Не удалось задать пароль. Попробуйте ещё раз." "Failed to set password. Try again."
    fi
  done
else
  # --- Пароль уже есть, просто спросить и прогреть sudo ---
  TRIES=3
  msg_info \
    "Введите пароль sudo (пользователь ${USER_NAME})." \
    "Enter sudo password (user ${USER_NAME})."

  for ((i=1; i<=TRIES; i++)); do
    PASS=$(prompt_pass "Введите пароль sudo:" "Enter sudo password:")
    [[ $? -ne 0 ]] && exit 1

    if printf '%s\n' "$PASS" | sudo -S -k true >/dev/null 2>&1; then
      sudo -v >/dev/null 2>&1 || true
      msg_info "Режим sudo активирован." "Sudo mode activated."
      exit 0
    else
      if (( i < TRIES )); then
        msg_error "Неверный пароль. Попробуйте ещё раз." "Wrong password. Try again."
      else
        msg_error "Неверный пароль. Попытки исчерпаны." "Wrong password. Attempts exhausted."
      fi
    fi
  done

  exit 1
fi
