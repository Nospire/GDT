package main

import (
	"context"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"time"

	"gdt/internal/config"
	"gdt/internal/orchestrator"
	"gdt/internal/runner"
	"gdt/internal/singbox"
	"gdt/internal/status"
	"gdt/internal/sudo"

	"github.com/wailsapp/wails/v2/pkg/runtime"
)

type App struct {
	ctx          context.Context
	cfg          *config.Config
	cfgPath      string
	sudo         *sudo.Manager
	runner       *runner.Runner
	orchestrator *orchestrator.Client
	singbox      *singbox.SingBox
	sessionID    string
	sessionCtx   context.CancelFunc
}

func NewApp() *App {
	return &App{}
}

// ---- Wails lifecycle -------------------------------------------------------

func (a *App) startup(ctx context.Context) {
	a.ctx = ctx

	// Determine config path and base dir
	a.cfgPath = config.DefaultPath()
	baseDir := filepath.Dir(a.cfgPath)

	// Load or create default config
	cfg, err := config.Load(a.cfgPath)
	if err != nil {
		cfg = &config.Config{Lang: "ru"}
	}
	a.cfg = cfg

	// Init sudo manager and detect state
	a.sudo = sudo.New()
	_ = a.sudo.DetectState()

	// Init runner — emits module messages as Wails events
	a.runner = runner.New(a.sudo, baseDir, func(msg runner.Message) {
		runtime.EventsEmit(a.ctx, "module:msg", msg)
	})

	// Init orchestrator and singbox
	a.orchestrator = orchestrator.New()
	a.singbox = singbox.New(baseDir)

	a.startStatusLoop()
}

// ---- Status ----------------------------------------------------------------

func (a *App) GetStatus() (*status.SystemStatus, error) {
	s, err := status.Collect()
	if err != nil {
		return nil, err
	}
	s.TunnelActive = a.singbox.IsRunning()
	return s, nil
}

func (a *App) getStatusNow() *status.SystemStatus {
	s, _ := status.Collect()
	if s != nil {
		s.TunnelActive = a.singbox.IsRunning()
	}
	return s
}

func (a *App) startStatusLoop() {
	go func() {
		for {
			if s, err := status.Collect(); err == nil {
				s.TunnelActive = a.singbox.IsRunning()
				runtime.EventsEmit(a.ctx, "status:update", s)
			}
			time.Sleep(60 * time.Second)
		}
	}()
}

func (a *App) shutdown(ctx context.Context) {
	// Complete session before stopping sing-box
	if a.sessionID != "" {
		_ = a.orchestrator.Complete(ctx, a.sessionID, "error", "")
		if a.sessionCtx != nil {
			a.sessionCtx()
		}
		a.sessionID = ""
	}

	// Stop proxy
	if a.singbox.IsRunning() {
		_ = a.singbox.Stop()
		_ = a.singbox.ClearSystemProxy()
	}
}

// ---- Config ----------------------------------------------------------------

func (a *App) GetModules() []config.Module {
	if a.cfg == nil {
		return nil
	}
	return a.cfg.Modules
}

func (a *App) GetLang() string {
	if a.cfg == nil {
		return "ru"
	}
	return a.cfg.Lang
}

func (a *App) SetLang(lang string) error {
	a.cfg.Lang = lang
	return config.Save(a.cfg, a.cfgPath)
}

func (a *App) GetSubscriptionURL() string {
	if a.cfg == nil {
		return ""
	}
	return a.cfg.SubscriptionURL
}

func (a *App) SetSubscriptionURL(rawURL string) error {
	if err := singbox.ValidateURL(rawURL); err != nil {
		return err
	}
	a.cfg.SubscriptionURL = rawURL
	return config.Save(a.cfg, a.cfgPath)
}

// ---- Sudo ------------------------------------------------------------------

func (a *App) GetSudoState() string {
	switch a.sudo.State() {
	case sudo.NoPassword:
		return "none"
	case sudo.HasPassword:
		return "has"
	case sudo.Active:
		return "active"
	default:
		return "none"
	}
}

func (a *App) VerifySudo(password string) error {
	return a.sudo.Verify(password)
}

func (a *App) SetSudoPassword(password string) error {
	if a.sudo.State() != sudo.NoPassword {
		return fmt.Errorf("password already set; use VerifySudo")
	}
	return a.sudo.SetPassword(password)
}

// ---- Actions ---------------------------------------------------------------

func (a *App) RunModule(id string) error {
	// Find module by id
	var mod *config.Module
	for i := range a.cfg.Modules {
		if a.cfg.Modules[i].ID == id {
			mod = &a.cfg.Modules[i]
			break
		}
	}
	if mod == nil {
		return fmt.Errorf("module %q not found", id)
	}

	// 1. Проверяем sudo если нужен
	if mod.NeedsSudo && a.sudo.State() != sudo.Active {
		return fmt.Errorf("sudo не активен — введите пароль")
	}

	// 2. Запускаем сессию если нужен VPN
	if mod.NeedsVPN {
		if err := a.startSession(mod.ID); err != nil {
			return fmt.Errorf("start session: %w", err)
		}
	}

	exe, _ := os.Executable()
	exeDir := filepath.Dir(exe)
	modulePath := filepath.Join(exeDir, "modules", filepath.Base(mod.Binary))

	// Kick off the module in a goroutine so the frontend isn't blocked
	go func() {
		err := a.runner.Run(context.Background(), modulePath)

		// Complete session if one was started for this module
		if a.sessionID != "" {
			result := "success"
			if err != nil {
				result = "error"
			}
			_ = a.orchestrator.Complete(context.Background(), a.sessionID, result, "")
			if a.sessionCtx != nil {
				a.sessionCtx()
			}
			_ = a.singbox.Stop()
			_ = a.singbox.ClearSystemProxy()
			a.sessionID = ""
			// Notify frontend that tunnel is now down
			runtime.EventsEmit(a.ctx, "status:update", a.getStatusNow())
		}

		if err != nil {
			runtime.EventsEmit(a.ctx, "module:msg", runner.Message{
				Type:    runner.MsgLog,
				Payload: "runner error: " + err.Error(),
			})
		}
	}()
	return nil
}

func (a *App) CancelModule() error {
	a.runner.Cancel()
	return nil
}

// ---- Proxy -----------------------------------------------------------------

func (a *App) StartProxy() error {
	if a.cfg.SubscriptionURL == "" {
		return fmt.Errorf("subscription URL not configured")
	}
	if err := a.singbox.FetchConfig(a.cfg.SubscriptionURL); err != nil {
		return err
	}
	if err := a.singbox.Start(context.Background()); err != nil {
		return err
	}
	return a.singbox.SetSystemProxy()
}

func (a *App) StopProxy() error {
	if err := a.singbox.Stop(); err != nil {
		return err
	}
	return a.singbox.ClearSystemProxy()
}

func (a *App) IsProxyRunning() bool {
	return a.singbox.IsRunning()
}

// ---- Tavern ----------------------------------------------------------------

func (a *App) OpenTavern() error {
	keyPath := filepath.Join(os.Getenv("HOME"), ".config", "gdt", "id_ed25519")
	if _, err := os.Stat(keyPath); os.IsNotExist(err) {
		os.MkdirAll(filepath.Dir(keyPath), 0700)
		if err := exec.Command("ssh-keygen", "-t", "ed25519", "-N", "",
			"-f", keyPath, "-C", "gdt").Run(); err != nil {
			return fmt.Errorf("keygen: %w", err)
		}
	}
	pubPath := keyPath + ".pub"
	if _, err := os.Stat(pubPath); os.IsNotExist(err) {
		out, err := exec.Command("ssh-keygen", "-y", "-f", keyPath).Output()
		if err == nil {
			os.WriteFile(pubPath, out, 0644)
		}
	}
	host := "inn.geekcom.org"
	port := "22"
	if a.cfg.LocalMode {
		host = "192.168.50.10"
		port = "2222"
	}
	terminals := []string{"konsole", "alacritty", "xterm"}
	for _, t := range terminals {
		if _, err := exec.LookPath(t); err == nil {
			cmd := exec.Command(t, "-e", "ssh",
				"-i", keyPath,
				"-o", "StrictHostKeyChecking=ask",
				"-o", "IdentitiesOnly=yes",
				"-o", "BatchMode=no",
				"-p", port,
				host)
			log.Printf("launching: %v", cmd.Args)
			return cmd.Start()
		}
	}
	return fmt.Errorf("no terminal emulator found")
}

// ---- internal helpers ------------------------------------------------------

// startSession starts an orchestrator session and sing-box if not already running.
// action is passed to the orchestrator (module ID, e.g. "steamos-update").
// mihomo_config from the response is written directly as singbox config.
func (a *App) startSession(action string) error {
	if a.sessionID != "" {
		return nil // already have a session
	}

	session, err := a.orchestrator.Start(context.Background(), action)
	if err != nil {
		return fmt.Errorf("orchestrator start: %w", err)
	}
	a.sessionID = session.ID

	// Start sing-box using VLESS links from the orchestrator response
	if !a.singbox.IsRunning() {
		if err := a.singbox.FetchConfigFromString(session.MihomoConfig); err != nil {
			return fmt.Errorf("singbox config: %w", err)
		}
		if err := a.singbox.Start(context.Background()); err != nil {
			return fmt.Errorf("singbox start: %w", err)
		}
		if err := a.singbox.SetSystemProxy(); err != nil {
			return fmt.Errorf("singbox proxy: %w", err)
		}
	}

	// Set env proxy vars so child processes route through the tunnel
	proxyAddr := fmt.Sprintf("http://127.0.0.1:%d", singbox.ProxyPort)
	os.Setenv("http_proxy", proxyAddr)
	os.Setenv("https_proxy", proxyAddr)

	// Run heartbeat until session ends
	hbCtx, hbCancel := context.WithCancel(context.Background())
	a.sessionCtx = hbCancel
	go a.orchestrator.RunHeartbeat(hbCtx, a.sessionID)

	// Notify frontend that tunnel is now up
	runtime.EventsEmit(a.ctx, "status:update", a.getStatusNow())

	return nil
}
