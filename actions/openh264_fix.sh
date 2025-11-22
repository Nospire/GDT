#!/usr/bin/env bash
set -euo pipefail

APP_ID="org.freedesktop.Platform.openh264"
REMOTE="flathub"
TIMEOUT=20

echo "[INFO] Checking for flatpak..."
if ! command -v flatpak >/dev/null 2>&1; then
  echo "[ERR] flatpak not found. Cannot install OpenH264." >&2
  exit 1
fi

echo "[INFO] Ensuring OpenH264 is not masked in Flatpak (system and user)..."

# Сначала пробуем снять system-маски через sudo (sudo уже должен быть активен)
if sudo -n true 2>/dev/null; then
  sudo flatpak mask --system --remove "${APP_ID}"        >/dev/null 2>&1 || true
  sudo flatpak mask --system --remove "${APP_ID}//2.5.1" >/dev/null 2>&1 || true
else
  echo "[WARN] sudo is not active; cannot remove system-level masks, only user-level." >&2
fi

# Потом снимаем user-маски — это не требует root
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

# В норме sudo уже активен (движок это проверил), но подстрахуемся
if sudo -n true 2>/dev/null; then
  if sudo flatpak install -y --system "$ref"; then
    echo "[OK] Installed to system flatpak."
  else
    echo "[WARN] System install failed, trying user install..."
    flatpak install -y --user "$ref"
    echo "[OK] Installed to user flatpak."
  fi
else
  echo "[WARN] sudo -n failed; installing into user flatpak only..."
  flatpak install -y --user "$ref"
fi

echo "[INFO] OpenH264 runtimes currently installed:"
flatpak list | grep -i openh264 || echo "[INFO] No openh264 runtimes found in flatpak list."
