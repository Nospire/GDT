# Geekcom Deck Tools

[English version](README.en.md)

Инструмент для обслуживания SteamOS на Steam Deck:

- исправление ошибки **403** при установке OpenH264 через Flatpak;
- обновление самой **SteamOS** через временный VPN-туннель;
- обновление всех **Flatpak**-приложений;
- режим **Geekcom antizapret** (обход блокировок для сервисов, нужных Deck).

Все сетевые действия идут через оркестратор Geekcom: он выдаёт временный WireGuard-конфиг, туннель поднимается, выполняется нужное действие, затем туннель и peer удаляются.

## Структура после установки

Все файлы помощника живут здесь:

```text
~/.scripts/geekcom-deck-tools/
  engine.sh           — общий движок, общается с оркестратором
  actions/*.sh        — отдельные сценарии (OpenH264, SteamOS, Flatpak, antizapret)
  geekcom-deck-tools  — Qt GUI-бинарь
```

Движок:

1. Запрашивает конфиг у `https://fix.geekcom.org` (`/api/v1/vpn/request`).
2. Поднимает временный WireGuard-туннель, проверяет `ping 8.8.8.8`.
3. Запускает один из скриптов в `actions/`.
4. Завершает сессию через `/api/v1/vpn/finish` и гасит туннель.

## Установка и запуск (GUI)

### Вариант 1: через ярлык

1. Скачать файл ярлыка:

   ```text
   https://raw.githubusercontent.com/Nospire/GDT/main/GeekcomDeckTools.desktop
   ```

2. Сохранить, например, в `~/Desktop/` и сделать исполняемым:

   ```bash
   chmod +x ~/Desktop/GeekcomDeckTools.desktop
   ```

3. Запустить ярлык. При первом запуске:

   - снизу по центру — кнопка задания/ввода пароля sudo;
   - когда индикатор стал зелёным, доступны основные кнопки:

     - **OpenH264 / fix 403** — только чинит кодек OpenH264;
     - **Update SteamOS** — проверяет наличие обновления SteamOS и ставит его;
     - **Update apps (Flatpak)** — обновляет все Flatpak-приложения;
     - **Geekcom antizapret** — включает правила обхода блокировок.

GUI валидирует пароль sudo и кладёт его в переменную окружения `GDT_SUDO_PASS`, чтобы `engine.sh` не спрашивал пароль повторно.

### Вариант 2: через терминал (без ярлыка, но с GUI)

В режиме рабочего стола можно просто выполнить:

```bash
curl -fsSL https://fix.geekcom.org/gdt | bash
```

Скрипт:

- скачает / обновит `engine.sh`, `actions/*.sh` и бинарь GUI;
- запустит Qt-приложение.

## Режим без GUI (no-GUI, из TTY)

Нужен, когда рабочий стол не поднимается, а SteamOS нужно обновить.

1. Подключить клавиатуру.
2. Перейти в TTY (`Ctrl` + `Alt` + `F4`).
3. Войти под пользователем `deck`.
4. Если пароля у `deck` нет — задать его:

   ```bash
   passwd deck
   ```

5. Выполнить no-GUI-скрипт:

   ```bash
   curl -fsSL https://fix.geekcom.org/ngdt | bash
   ```

Скрипт `nogui.sh`:

- скачивает/обновляет `engine.sh` и `actions/*.sh`;
- спрашивает пароль sudo (ввод скрыт) и экспортирует `GDT_SUDO_PASS`;
- запускает `engine.sh steamos_update ru`.

По завершении обновления можно перегрузить Deck:

```bash
sudo reboot
```

## Удаление

Полное удаление помощника:

```bash
rm -rf ~/.scripts/geekcom-deck-tools
# при желании удалить ярлык с рабочего стола
```
