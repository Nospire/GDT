package config

import (
	"os"
	"os/exec"
	"path/filepath"

	"gopkg.in/yaml.v3"
)

type Module struct {
	ID        string `yaml:"id"`
	LabelRu   string `yaml:"label_ru"`
	LabelEn   string `yaml:"label_en"`
	DescRu    string `yaml:"desc_ru"`
	DescEn    string `yaml:"desc_en"`
	Icon      string `yaml:"icon"`
	Binary    string `yaml:"binary"`
	NeedsSudo bool   `yaml:"needs_sudo"`
	NeedsVPN  bool   `yaml:"needs_vpn"`
}

type Config struct {
	Lang            string   `yaml:"lang"`
	SubscriptionURL string   `yaml:"subscription_url"`
	LocalMode       bool     `yaml:"local_mode"`
	Modules         []Module `yaml:"modules"`
}

func Load(path string) (*Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		if !os.IsNotExist(err) {
			return nil, err
		}
		// Config not found — try to copy config.example.yaml from binary dir
		if copied, copyErr := tryBootstrapConfig(path); copyErr == nil && copied {
			data, err = os.ReadFile(path)
			if err != nil {
				return nil, err
			}
		} else {
			// Neither found — return hardcoded default
			return defaultConfig(), nil
		}
	}
	var cfg Config
	if err := yaml.Unmarshal(data, &cfg); err != nil {
		return nil, err
	}
	if os.Getenv("GDT_LOCAL_MODE") == "1" {
		cfg.LocalMode = true
	}
	return &cfg, nil
}

// tryBootstrapConfig looks for config.example.yaml next to the running binary
// and copies it to path. Returns (true, nil) on success.
func tryBootstrapConfig(destPath string) (bool, error) {
	binPath, err := exec.LookPath(os.Args[0])
	if err != nil {
		binPath = os.Args[0]
	}
	binDir := filepath.Dir(binPath)
	examplePath := filepath.Join(binDir, "config.example.yaml")

	data, err := os.ReadFile(examplePath)
	if err != nil {
		return false, err
	}
	if err := os.MkdirAll(filepath.Dir(destPath), 0700); err != nil {
		return false, err
	}
	if err := os.WriteFile(destPath, data, 0644); err != nil {
		return false, err
	}
	return true, nil
}

func defaultConfig() *Config {
	return &Config{
		Lang: "ru",
		Modules: []Module{
			{
				ID: "steamos-update", LabelRu: "Обновить SteamOS", LabelEn: "Update SteamOS",
				DescRu: "через VPN-туннель", DescEn: "via VPN tunnel",
				Icon: "arrow-up", Binary: "modules/steamos-update",
				NeedsSudo: true, NeedsVPN: true,
			},
			{
				ID: "flatpak-update", LabelRu: "Обновить Flatpak", LabelEn: "Update Flatpak",
				DescRu: "все приложения", DescEn: "all applications",
				Icon: "grid", Binary: "modules/flatpak-update",
				NeedsSudo: true, NeedsVPN: false,
			},
			{
				ID: "openh264-fix", LabelRu: "Fix OpenH264", LabelEn: "Fix OpenH264",
				DescRu: "ошибка 403 Flatpak", DescEn: "Flatpak 403 error",
				Icon: "play", Binary: "modules/openh264-fix",
				NeedsSudo: true, NeedsVPN: true,
			},
			{
				ID: "proxy", LabelRu: "Прокси", LabelEn: "Proxy",
				DescRu: "подписка rw.geekcom.org", DescEn: "rw.geekcom.org subscription",
				Icon: "vpn", Binary: "",
				NeedsSudo: false, NeedsVPN: false,
			},
		},
	}
}

func Save(cfg *Config, path string) error {
	data, err := yaml.Marshal(cfg)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return err
	}
	return os.WriteFile(path, data, 0644)
}

func DefaultPath() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return "config.yaml"
	}
	return filepath.Join(home, ".config", "gdt", "config.yaml")
}
