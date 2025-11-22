#!/usr/bin/env bash
set -euo pipefail

APP_ID="org.freedesktop.Platform.openh264"
REMOTE="flathub"
TIMEOUT=20

# Пароль sudo из GUI (если он есть)
SUDO_PASS="${GDT_SUDO_PASS:-}"

run_sudo() {
  # Если GUI дал пароль — юзаем его.
  # Если нет — предполагаем, что sudo уже активен (кеш), и ходим с -n.
  if [[ -n "$SUDO_PASS" ]]; then
    printf '%s\n' "$SUDO_PASS" | sudo -S -- "$@"
  else
    sudo -n -- "$@"
  fi
}

echo "[INFO] Checking for flatpak..."
if ! command -v flatpak >/dev/null 2>&1; then
  echo "[ERR] flatpak not found. Cannot install OpenH264." >&2
  exit 1
fi

tmp_err="$(mktemp /tmp/openh264-remote-info.XXXXXX)"
trap 'rm -f "$tmp_err" || true' EXIT

echo "[INFO] Querying branches list via flatpak remote-info..."

# Берём список веток из stderr remote-info (там Multiple branches available ...)
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

# Фильтруем legacy 19.08, если есть другие ветки
filtered="$(printf '%s\n' $branches | grep -v '^19\.08$' || true)"
if [[ -n "$filtered" ]]; then
  latest_branch="$(printf '%s\n' "$filtered" | tail -n1)"
else
  latest_branch="$(printf '%s\n' $branches | tail -n1)"
fi

echo "[INFO] Latest OpenH264 branch: ${latest_branch}"
ref="${APP_ID}//${latest_branch}"
echo "[INFO] Installing ref: ${ref}"

# Пытаемся поставить в system через sudo (с учётом GDT_SUDO_PASS)
if run_sudo flatpak install -y --system "$ref"; then
  echo "[OK] Installed to system flatpak."
else
  echo "[WARN] System install failed, trying user install..."
  if flatpak install -y --user "$ref"; then
    echo "[OK] Installed to user flatpak."
  else
    echo "[ERR] Failed to install OpenH264 both system and user." >&2
    exit 1
  fi
fi

echo "[INFO] OpenH264 runtimes currently installed:"
flatpak list | grep -i openh264 || echo "[INFO] No openh264 runtimes found in flatpak list."
