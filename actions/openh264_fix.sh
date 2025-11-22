#!/usr/bin/env bash
set -euo pipefail

APP_ID="org.freedesktop.Platform.openh264"
REMOTE="flathub"
TIMEOUT=20

# Пароль, который GUI кладёт в окружение при запуске engine.sh
SUDO_PASS="${GDT_SUDO_PASS:-}"

run_sudo() {
  if [[ -n "$SUDO_PASS" ]]; then
    # Кормим пароль через stdin, без попытки лезть в TTY
    printf '%s\n' "$SUDO_PASS" | sudo -S -p '' "$@"
  else
    # Фолбэк, теоретически не должен срабатывать в нормальном сценарии
    sudo "$@"
  fi
}

echo "[INFO] Checking for flatpak..."
if ! command -v flatpak >/dev/null 2>&1; then
  echo "[ERR] flatpak not found. Cannot install OpenH264." >&2
  exit 1
fi

echo "[INFO] Ensuring OpenH264 is not masked in Flatpak (system and user)..."

# Снимаем system-маски через sudo (через наш run_sudo)
run_sudo flatpak mask --system --remove "${APP_ID}"        >/dev/null 2>&1 || true
run_sudo flatpak mask --system --remove "${APP_ID}//2.5.1" >/dev/null 2>&1 || true

# Снимаем user-маски (root не нужен)
flatpak mask --user --remove "${APP_ID}"        >/dev/null 2>&1 || true
flatpak mask --user --remove "${APP_ID}//2.5.1" >/dev/null 2>&1 || true

echo "[INFO] Flatpak masks (if any) for OpenH264 have been removed."

tmp_err="$(mktemp /tmp/openh264-remote-info.XXXXXX)"
trap 'rm -f "$tmp_err" || true' EXIT

echo "[INFO] Querying branches list via flatpak remote-info..."

# Нам важен stderr: там сообщение Multiple branches available ...
if ! timeout "$TIMEOUT" flatpak remote-info --system "$REMOTE" "$APP_ID" 1>/dev/null 2>"$tmp_err"; then
  timeout "$TIMEOUT" flatpak remote-info "$REMOTE" "$APP_ID" 1>/dev/null 2>>"$tmp_err" || true
fi

if [[ ! -s "$tmp_err" ]]; then
  echo "[ERR] flatpak remote-info produced no output; cannot detect branches." >&2
  echo "[HINT] Try manually: flatpak remote-info --system ${REMOTE} ${APP_ID}" >&2
  exit 1
fi

echo "[INFO] Parsing branches from remote-info output..."

branches="$(
  grep -o "${APP_ID}/x86_64/[0-9.]\+" "$tmp_err" \
    | awk -F'/' '{print $NF}' \
    | sort -V \
    | uniq
)"

if [[ -z "${branches}" ]]; then
  echo "[ERR] Failed to extract branches from flatpak remote-info output." >&2
  echo "------ stderr flatpak remote-info ------" >&2
  cat "$tmp_err" >&2 || true
  echo "----------------------------------------" >&2
  exit 1
fi

echo "[INFO] Found branches:"
printf '       %s\n' $branches

# Фильтруем legacy-рантайм 19.08, если есть нормальные ветки
filtered="$(printf '%s\n' $branches | grep -v '^19\.08$' || true)"
if [[ -n "$filtered" ]]; then
  latest_branch="$(printf '%s\n' "$filtered" | tail -n1)"
else
  latest_branch="$(printf '%s\n' $branches | tail -n1)"
fi

echo "[INFO] Latest OpenH264 branch: ${latest_branch}"
ref="${APP_ID}//${latest_branch}"
echo "[INFO] Installing ref: ${ref}"

# Ставим / обновляем только в system-flatpak через run_sudo
run_sudo flatpak install -y --system "$ref"

echo "[OK] Installed to system flatpak."

echo "[INFO] OpenH264 runtimes currently installed:"
flatpak list | grep -i openh264 || echo "[INFO] No openh264 runtimes found in flatpak list."
