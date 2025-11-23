#!/usr/bin/env bash
set -euo pipefail

APP_ID="org.freedesktop.Platform.openh264"
REMOTE="flathub"
TIMEOUT=20

# Пароль sudo от GUI (через engine.sh)
SUDO_PASS="${GDT_SUDO_PASS:-}"

run_sudo() {
  if [[ -n "$SUDO_PASS" ]]; then
    printf '%s\n' "$SUDO_PASS" | sudo -S -p '' "$@"
  else
    sudo "$@"
  fi
}

echo "[INFO] Checking for flatpak..."
if ! command -v flatpak >/dev/null 2>&1; then
  echo "[ERR] flatpak not found. Cannot install OpenH264." >&2
  exit 1
fi

# Снимаем маски старого «кривого» фикса: system + user
echo "[INFO] Ensuring OpenH264 is not masked in Flatpak (system and user)..."
if run_sudo flatpak mask --system --remove "${APP_ID}" >/dev/null 2>&1; then
  echo "[INFO] Removed system-level mask for ${APP_ID} (if it existed)."
fi
if flatpak mask --user --remove "${APP_ID}" >/dev/null 2>&1; then
  echo "[INFO] Removed user-level mask for ${APP_ID} (if it existed)."
fi
echo "[INFO] Flatpak masks (if any) for OpenH264 have been removed."

# Чистим user-ветки OpenH264, если они остались от старого фикса
echo "[INFO] Checking for user-level OpenH264 runtimes..."
user_branches="$(
  flatpak list --user --columns=application,branch 2>/dev/null \
    | awk '$1 == "'"${APP_ID}"'" {print $2}' \
    || true
)"

if [[ -n "$user_branches" ]]; then
  echo "[INFO] Found user-level OpenH264 branches:"
  printf '       %s\n' $user_branches
  for b in $user_branches; do
    echo "[INFO] Uninstalling user OpenH264 branch ${b}..."
    flatpak uninstall -y --user "${APP_ID}//${b}" >/dev/null 2>&1 || true
  done
  echo "[INFO] User-level OpenH264 runtimes removed (if any)."
else
  echo "[INFO] No user-level OpenH264 runtimes found."
fi

tmp_err="$(mktemp /tmp/openh264-remote-info.XXXXXX)"
cleanup_tmp() {
  rm -f "$tmp_err" || true
}
trap cleanup_tmp EXIT

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

# Ставим всё, кроме явного legacy 19.08
target_branches=""
for b in $branches; do
  if [[ "$b" == "19.08" ]]; then
    continue
  fi
  target_branches+="$b "
done

# Если осталась только 19.08 — ставим её
if [[ -z "$target_branches" ]]; then
  target_branches="$branches"
fi

echo "[INFO] Will install OpenH264 for branches (system only):"
for b in $target_branches; do
  echo "       $b"
done

overall_ok=0

for b in $target_branches; do
  ref="${APP_ID}//${b}"
  echo "[INFO] Installing ref (system): ${ref}"

  if run_sudo flatpak install -y --system "$ref"; then
    overall_ok=1
    echo "[OK] Installed ${ref} to system flatpak (or it was already installed)."
  else
    echo "[ERR] Failed to install ${ref} to system flatpak." >&2
  fi
done

echo "[INFO] OpenH264 runtimes currently installed:"
flatpak list | grep -i openh264 || echo "[INFO] No openh264 runtimes found in flatpak list."

if (( overall_ok == 0 )); then
  echo "[ERR] Failed to install any OpenH264 branch in system scope." >&2
  exit 1
fi

# Обновляем все flatpak'и: system + user
echo "[INFO] Running 'flatpak update -y --system'..."
if run_sudo flatpak update -y --system; then
  echo "[INFO] System flatpaks updated."
else
  echo "[WARN] Failed to update system flatpaks." >&2
fi

echo "[INFO] Running 'flatpak update -y --user'..."
if flatpak update -y --user; then
  echo "[INFO] User flatpaks updated."
else
  echo "[WARN] Failed to update user flatpaks." >&2
fi

# Мягкий рестарт Discover
echo "[INFO] Restarting Discover (plasma-discover), if present..."
if command -v plasma-discover >/dev/null 2>&1; then
  if pgrep -x plasma-discover >/dev/null 2>&1; then
    echo "[INFO] plasma-discover is running, restarting..."
    pkill plasma-discover || true
    # Попробуем заново запустить в фоне; если не взлетит — не критично
    plasma-discover >/dev/null 2>&1 & disown || true
    echo "[INFO] Discover restart requested."
  else
    echo "[INFO] plasma-discover is not running; nothing to restart."
  fi
else
  echo "[INFO] plasma-discover binary not found; skipping Discover restart."
fi

echo "[INFO] OpenH264 installation/fix completed."
