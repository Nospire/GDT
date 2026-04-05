# Geekcom Deck Tools

## Зависимости для сборки
```bash
sudo pacman -S nodejs npm webkit2gtk
```

## Разработка
```bash
cd gdt && wails dev
```

## Сборка
```bash
cd gdt && wails build
# модули
cd modules/steamos-update && go build -o ~/.config/gdt/modules/steamos-update .
```

## Структура

- `gdt/` — Wails приложение
- `modules/` — отдельные бинари действий
- `config.example.yaml` — пример конфига
