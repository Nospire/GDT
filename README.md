# Geekcom Deck Tools

Bootstrap + engine scripts for Geekcom Deck Tools on Steam Deck.

## How it works (high level)

- `geekcom-deck-tools.desktop` on Steam Deck downloads `bootstrap.sh` from GitHub.
- `bootstrap.sh` creates `~/.scripts/geekcom-deck-tools/`, downloads:
  - `geekcom-deck-tools` binary (Qt GUI) from GitHub Releases,
  - `engine.sh` from this repo.
- Then it runs the GUI.

`engine.sh` is a dispatcher that will later handle:

- `openh264_fix`
- `steamos_update`
- `flatpak_update`
- `antizapret`
