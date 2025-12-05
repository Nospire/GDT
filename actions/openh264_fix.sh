#!/usr/bin/env bash
set -euo pipefail

APP_ID="org.freedesktop.Platform.openh264"

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

echo "[INFO] Ensuring OpenH264 is not masked in Flatpak (system and user)..."
if run_sudo flatpak mask --system --remove "${APP_ID}" >/dev/null 2>&1; then
  echo "[INFO] Removed system-level mask for ${APP_ID} (if it existed)."
fi
if flatpak mask --user --remove "${APP_ID}" >/dev/null 2>&1; then
  echo "[INFO] Removed user-level mask for ${APP_ID} (if it existed)."
fi
echo "[INFO] Flatpak masks (if any) for OpenH264 have been removed."

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

echo "[INFO] Installing system-level OpenH264 runtime from flathub..."

INSTALL_OUTPUT=""
INSTALL_RC=0

if INSTALL_OUTPUT="$(run_sudo flatpak install -y --system flathub ${APP_ID} 2>&1)"; then
  INSTALL_RC=0
else
  INSTALL_RC=$?
fi

if [[ -n "$INSTALL_OUTPUT" ]]; then
  printf '%s\n' "$INSTALL_OUTPUT"
fi

if [[ $INSTALL_RC -ne 0 ]]; then
  if printf '%s\n' "$INSTALL_OUTPUT" | grep -qi "already installed"; then
    echo "[INFO] OpenH264 is already installed system-wide."
    INSTALL_RC=0
  else
    echo "[ERR] Failed to install OpenH264 (exit code ${INSTALL_RC})." >&2
    echo "[ERR] If this persists, try manual command:" >&2
    echo "[ERR]   flatpak install --system flathub org.freedesktop.Platform.openh264" >&2
  fi
fi

if [[ $INSTALL_RC -ne 0 ]]; then
  exit "$INSTALL_RC"
fi

echo "[INFO] OpenH264 installation/fix completed."
exit 0
