#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="${HOME}/.scripts/geekcom-deck-tools"
REPO="Nospire/GDT-v2"
BASE_URL="https://github.com/${REPO}/releases/latest/download"
CONFIG_DIR="${HOME}/.config/gdt"

# ===== Language detection =====
if [[ -n "${DISPLAY:-}" || -n "${WAYLAND_DISPLAY:-}" ]]; then
    LANG_MODE="ru"
else
    LANG_MODE="en"
fi

msg() {
    local ru="$1" en="$2"
    if [[ "$LANG_MODE" == "ru" ]]; then
        printf "%s\n" "$ru"
    else
        printf "%s\n" "$en"
    fi
}

ok()   { printf "[OK] %s\n" "$*"; }
info() { printf "[..] %s\n" "$*"; }
err()  { printf "[ERR] %s\n" "$*" >&2; }

trap 'stty echo 2>/dev/null || true' EXIT INT TERM

echo ""
echo "========================================"
echo "  Geekcom Deck Tools - GDT installer"
echo "========================================"
echo ""

# ===== 1. Check SteamOS =====
if ! grep -q 'steamos' /etc/os-release 2>/dev/null; then
    err "$(msg "Этот скрипт предназначен только для Steam Deck (SteamOS)." \
              "This script is for Steam Deck (SteamOS) only.")"
    exit 1
fi

# ===== 2. TTY warning =====
if [[ -z "${DISPLAY:-}" && -z "${WAYLAND_DISPLAY:-}" ]]; then
    msg "ВНИМАНИЕ: вы в режиме TTY." \
        "WARNING: You are in TTY mode."
    echo ""
    msg "GDT — графическое приложение, оно требует рабочий стол." \
        "GDT is a graphical app and requires desktop mode."
    msg "Нажмите Ctrl+Alt+F7 чтобы вернуться в рабочий стол." \
        "Press Ctrl+Alt+F7 to return to desktop mode."
    echo ""
    msg "Если вам нужно обновить SteamOS из TTY — используйте NGDT:" \
        "If you need to update SteamOS from TTY — use NGDT instead:"
    echo "  curl -fsSL https://fix.geekcom.org/ngdt | bash"
    echo ""
    printf "$(msg "Продолжить всё равно? [y/N]: " "Continue anyway? [y/N]: ")"
    IFS= read -r REPLY </dev/tty || true
    if [[ "${REPLY:-n}" != "y" && "${REPLY:-n}" != "Y" ]]; then
        msg "Отмена." "Aborted."
        exit 0
    fi
    echo ""
fi

# ===== 3. Check/create deck password =====
PASSWD_STATUS="$(passwd -S deck 2>/dev/null | awk '{print $2}')"
if [[ "$PASSWD_STATUS" == "L" || "$PASSWD_STATUS" == "NP" ]]; then
    msg "Пароль пользователя deck не задан." \
        "No password set for user deck."
    msg "Пароль нужен для системных операций." \
        "A password is required for system operations."
    msg "Придумайте и введите пароль:" \
        "Please create a password:"
    echo ""
    passwd deck
    echo ""
fi

# ===== 4. Read sudo password =====
printf "[..] $(msg "Введите пароль sudo (ввод скрыт): " "Enter sudo password (hidden): ")"
stty -echo </dev/tty
IFS= read -r GDT_SUDO_PASS </dev/tty || true
stty echo </dev/tty
printf "\n"

if [[ -z "$GDT_SUDO_PASS" ]]; then
    err "$(msg "Пустой пароль." "Empty password.")"
    exit 1
fi

if ! printf '%s\n' "$GDT_SUDO_PASS" | sudo -S -k -p '' true >/dev/null 2>&1; then
    err "$(msg "Неверный пароль sudo." "Wrong sudo password.")"
    exit 1
fi

ok "$(msg "sudo активирован" "sudo activated")"
export GDT_SUDO_PASS

# ===== 5. Check webkit2gtk-4.1 =====
info "$(msg "Проверяем webkit2gtk-4.1..." "Checking webkit2gtk-4.1...")"

if ! ldconfig -p 2>/dev/null | grep -q 'webkit2gtk-4.1'; then
    msg "webkit2gtk-4.1 не найден. Устанавливаем..." \
        "webkit2gtk-4.1 not found. Installing..."

    # Enable dev mode (makes filesystem writable)
    if ! printf '%s\n' "$GDT_SUDO_PASS" | sudo -S -k -p '' bash -c \
            'echo y | steamos-devmode enable' 2>&1 | tail -5; then
        err "$(msg "Не удалось включить режим разработчика." "Failed to enable dev mode.")"
        exit 1
    fi

    if ! printf '%s\n' "$GDT_SUDO_PASS" | sudo -S -k -p '' pacman -S --noconfirm webkit2gtk-4.1 2>&1; then
        err "$(msg "Не удалось установить webkit2gtk-4.1." "Failed to install webkit2gtk-4.1.")"
        exit 1
    fi

    ok "$(msg "webkit2gtk-4.1 установлен" "webkit2gtk-4.1 installed")"
else
    ok "$(msg "webkit2gtk-4.1 найден" "webkit2gtk-4.1 found")"
fi

# ===== 6. Download binaries =====
info "$(msg "Создаём ${INSTALL_DIR}..." "Creating ${INSTALL_DIR}...")"
mkdir -p "$INSTALL_DIR/modules"

info "$(msg "Скачиваем gdt..." "Downloading gdt...")"
curl -fsSL --progress-bar -o "$INSTALL_DIR/gdt" "${BASE_URL}/gdt"
chmod +x "$INSTALL_DIR/gdt"
ok "$(msg "gdt готов" "gdt ready")"

info "$(msg "Скачиваем sing-box..." "Downloading sing-box...")"
curl -fsSL --progress-bar -o "$INSTALL_DIR/sing-box" "${BASE_URL}/sing-box"
chmod +x "$INSTALL_DIR/sing-box"
ok "$(msg "sing-box готов" "sing-box ready")"

info "$(msg "Скачиваем модули..." "Downloading modules...")"
for mod in steamos-update flatpak-update openh264-fix; do
    curl -fsSL --progress-bar -o "$INSTALL_DIR/modules/${mod}" "${BASE_URL}/${mod}"
    chmod +x "$INSTALL_DIR/modules/${mod}"
    ok "$(msg "${mod} готов" "${mod} ready")"
done

# ===== 7. Config =====
mkdir -p "$CONFIG_DIR"
if [[ ! -f "${CONFIG_DIR}/config.yaml" ]]; then
    info "$(msg "Копируем config.example.yaml..." "Copying config.example.yaml...")"
    curl -fsSL -o "${CONFIG_DIR}/config.yaml" \
        "https://raw.githubusercontent.com/${REPO}/master/config.example.yaml"
    ok "$(msg "Конфиг создан" "Config created")"
else
    ok "$(msg "Конфиг уже есть" "Config already exists")"
fi

# ===== 8. Desktop file =====
DESKTOP_DIR="${HOME}/.local/share/applications"
mkdir -p "$DESKTOP_DIR"
cat > "${DESKTOP_DIR}/gdt.desktop" << DESKTOP
[Desktop Entry]
Name=Geekcom Deck Tools
Comment=Steam Deck management tools
Exec=${INSTALL_DIR}/gdt
Icon=applications-system
Terminal=false
Type=Application
Categories=System;
DESKTOP
ok "$(msg "Ярлык создан" "Desktop entry created")"

echo ""
ok "$(msg "Установка завершена. Запускаем GDT..." "Installation complete. Starting GDT...")"
echo ""

# ===== 9. Launch GDT =====
"$INSTALL_DIR/gdt" &
