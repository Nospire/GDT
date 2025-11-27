# Geekcom Deck Tools

[Версия на русском](README.md)

Helper for maintaining SteamOS on Steam Deck:

- fixes **403** error when installing OpenH264 via Flatpak;
- updates **SteamOS** through a temporary VPN tunnel;
- updates all **Flatpak** applications;
- provides **Geekcom antizapret** mode (bypass for blocked services needed by the Deck).

All network operations go through the Geekcom orchestrator: it issues a temporary WireGuard config, the tunnel is brought up, the action is executed, then the tunnel and peer are removed.

## Layout after installation

Everything lives here:

```text
~/.scripts/geekcom-deck-tools/
  engine.sh           — main engine talking to the orchestrator
  actions/*.sh        — individual actions (OpenH264, SteamOS, Flatpak, antizapret)
  geekcom-deck-tools  — Qt GUI binary
```

The engine:

1. Requests a config from `https://fix.geekcom.org` (`/api/v1/vpn/request`).
2. Brings up a temporary WireGuard tunnel and checks `ping 8.8.8.8`.
3. Runs one of the scripts in `actions/`.
4. Calls `/vpn/finish` and tears the tunnel down.

## Installation and usage (GUI)

### Option 1: desktop shortcut

1. Download the desktop file:

   ```text
   https://raw.githubusercontent.com/Nospire/GDT/main/GeekcomDeckTools.desktop
   ```

2. Save it to `~/Desktop/` (or any folder) and make it executable:

   ```bash
   chmod +x ~/Desktop/GeekcomDeckTools.desktop
   ```

3. Launch it. On first run:

   - the central bottom button sets/enters the sudo password;
   - once the indicator turns green, main buttons are available:

     - **OpenH264 / fix 403** — fix OpenH264 only;
     - **Update SteamOS** — check for and install SteamOS updates;
     - **Update apps (Flatpak)** — update all Flatpak applications;
     - **Geekcom antizapret** — enable anti-blocking rules.

The GUI validates the sudo password and passes it to the engine via the `GDT_SUDO_PASS` environment variable, so `engine.sh` does not need to prompt again.

### Option 2: terminal bootstrap (still with GUI)

From a regular desktop session:

```bash
curl -fsSL https://fix.geekcom.org/gdt | bash
```

This script downloads/updates `engine.sh`, `actions/*.sh` and the GUI binary, then starts the Qt app.

## no-GUI mode (from TTY)

Use this when the desktop cannot be started but SteamOS must be updated.

1. Attach a keyboard.
2. Switch to a TTY (`Ctrl` + `Alt` + `F4`).
3. Log in as `deck`.
4. If `deck` has no password yet, set one:

   ```bash
   passwd deck
   ```

5. Run the no-GUI script:

   ```bash
   curl -fsSL https://fix.geekcom.org/ngdt | bash
   ```

`nogui.sh` will:

- download/update `engine.sh` and `actions/*.sh`;
- ask for the sudo password (hidden input) and export `GDT_SUDO_PASS`;
- run `engine.sh steamos_update ru`.

After the update completes, reboot:

```bash
sudo reboot
```

## Removal

```bash
rm -rf ~/.scripts/geekcom-deck-tools
```
