package main

import (
	"embed"
	"os"

	"github.com/wailsapp/wails/v2"
	"github.com/wailsapp/wails/v2/pkg/options"
	"github.com/wailsapp/wails/v2/pkg/options/assetserver"
)

const AppVersion = "v1.0.3"

//go:embed all:frontend/dist
var assets embed.FS

func main() {
	for _, arg := range os.Args[1:] {
		if arg == "-lo" {
			os.Setenv("GDT_LOCAL_MODE", "1")
			break
		}
	}

	app := NewApp()

	err := wails.Run(&options.App{
		Title:     "Geekcom Deck Tools",
		Width:     900,
		Height:    660,
		MinWidth:  800,
		MinHeight: 600,
		AssetServer: &assetserver.Options{
			Assets: assets,
		},
		BackgroundColour: &options.RGBA{R: 13, G: 10, B: 7, A: 1},
		OnStartup:        app.startup,
		OnShutdown:       app.shutdown,
		Bind:             []interface{}{app},
	})

	if err != nil {
		println("Error:", err.Error())
	}
}
