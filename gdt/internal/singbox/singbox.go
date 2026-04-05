package singbox

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

const (
	ProxyPort                = 7890
	AllowedSubscriptionHost  = "rw.geekcom.org"
)

// ---- sing-box config structures --------------------------------------------

type singboxConfig struct {
	Log       sbLog       `json:"log"`
	Inbounds  []sbInbound `json:"inbounds"`
	Outbounds []sbOutbound `json:"outbounds"`
}

type sbLog struct {
	Level string `json:"level"`
}

type sbInbound struct {
	Type        string `json:"type"`
	Tag         string `json:"tag"`
	Listen      string `json:"listen"`
	ListenPort  int    `json:"listen_port"`
	SetSystemProxy bool `json:"set_system_proxy,omitempty"`
}

type sbOutbound struct {
	Type       string `json:"type"`
	Tag        string `json:"tag"`
	Server     string `json:"server,omitempty"`
	ServerPort int    `json:"server_port,omitempty"`
	UUID       string `json:"uuid,omitempty"`
	Flow       string `json:"flow,omitempty"`
	TLS        *sbTLS `json:"tls,omitempty"`
	Transport  *sbTransport `json:"transport,omitempty"`
}

type sbTLS struct {
	Enabled    bool       `json:"enabled"`
	ServerName string     `json:"server_name,omitempty"`
	UTLS       *sbUTLS    `json:"utls,omitempty"`
	Reality    *sbReality `json:"reality,omitempty"`
}

type sbUTLS struct {
	Enabled     bool   `json:"enabled"`
	Fingerprint string `json:"fingerprint,omitempty"`
}

type sbReality struct {
	Enabled   bool   `json:"enabled"`
	PublicKey string `json:"public_key,omitempty"`
	ShortID   string `json:"short_id,omitempty"`
}

type sbTransport struct {
	Type string `json:"type"`
}

// ---- SingBox ----------------------------------------------------------------

type SingBox struct {
	binaryPath string // ~/.config/gdt/sing-box
	configPath string // ~/.config/gdt/singbox.json
	cmd        *exec.Cmd
	cancel     context.CancelFunc
}

func New(baseDir string) *SingBox {
	s := &SingBox{
		binaryPath: filepath.Join(baseDir, "sing-box"), // fallback
		configPath: filepath.Join(baseDir, "singbox.json"),
	}

	exe, _ := os.Executable()
	exeDir := filepath.Dir(exe)

	home, _ := os.UserHomeDir()
	candidates := []string{
		filepath.Join(exeDir, "sing-box"),
		filepath.Join(baseDir, "sing-box"),
		filepath.Join(home, "Builder_base", "sing-box"), // dev fallback
	}
	for _, p := range candidates {
		if _, err := os.Stat(p); err == nil {
			s.binaryPath = p
			break
		}
	}

	return s
}

// ValidateURL checks that the subscription URL's host is AllowedSubscriptionHost.
func ValidateURL(rawURL string) error {
	u, err := url.Parse(rawURL)
	if err != nil {
		return fmt.Errorf("singbox: invalid URL: %w", err)
	}
	if u.Hostname() != AllowedSubscriptionHost {
		return fmt.Errorf("singbox: subscription host must be %s, got %s",
			AllowedSubscriptionHost, u.Hostname())
	}
	return nil
}

// FetchConfig downloads the subscription, parses VLESS links,
// and writes singbox.json with an HTTP proxy inbound on port 7890.
func (s *SingBox) FetchConfig(subscriptionURL string) error {
	if err := ValidateURL(subscriptionURL); err != nil {
		return err
	}

	// Download subscription
	client := &http.Client{Timeout: 30 * time.Second}
	resp, err := client.Get(subscriptionURL)
	if err != nil {
		return fmt.Errorf("singbox: fetch subscription: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return fmt.Errorf("singbox: fetch subscription: status %d", resp.StatusCode)
	}
	raw, err := io.ReadAll(resp.Body)
	if err != nil {
		return fmt.Errorf("singbox: read subscription: %w", err)
	}

	// Subscription is base64-encoded list of VLESS links
	decoded, err := base64.StdEncoding.DecodeString(strings.TrimSpace(string(raw)))
	if err != nil {
		// try raw (already decoded)
		decoded = raw
	}
	links := strings.Split(strings.TrimSpace(string(decoded)), "\n")

	outbounds, err := parseVLESSLinks(links)
	if err != nil {
		return fmt.Errorf("singbox: parse VLESS: %w", err)
	}
	if len(outbounds) == 0 {
		return fmt.Errorf("singbox: no valid VLESS links in subscription")
	}

	// Add direct and block outbounds
	outbounds = append(outbounds,
		sbOutbound{Type: "direct", Tag: "direct"},
		sbOutbound{Type: "block", Tag: "block"},
	)

	cfg := singboxConfig{
		Log: sbLog{Level: "info"},
		Inbounds: []sbInbound{
			{
				Type:       "http",
				Tag:        "http-in",
				Listen:     "127.0.0.1",
				ListenPort: ProxyPort,
			},
		},
		Outbounds: outbounds,
	}

	data, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		return fmt.Errorf("singbox: marshal config: %w", err)
	}
	if err := os.MkdirAll(filepath.Dir(s.configPath), 0700); err != nil {
		return err
	}
	return os.WriteFile(s.configPath, data, 0600)
}

// WriteConfig writes a ready-made config string directly to configPath.
// Used when the orchestrator returns mihomo_config as a complete JSON blob.
func (s *SingBox) WriteConfig(content string) error {
	if !json.Valid([]byte(content)) {
		return fmt.Errorf("invalid JSON config: %.100s", content)
	}
	if err := os.MkdirAll(filepath.Dir(s.configPath), 0700); err != nil {
		return err
	}
	return os.WriteFile(s.configPath, []byte(content), 0600)
}

// Start launches the sing-box subprocess.
func (s *SingBox) Start(ctx context.Context) error {
	if s.IsRunning() {
		return fmt.Errorf("singbox: already running")
	}
	runCtx, cancel := context.WithCancel(ctx)
	cmd := exec.CommandContext(runCtx, s.binaryPath, "run", "-c", s.configPath)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Start(); err != nil {
		cancel()
		return fmt.Errorf("singbox: start: %w", err)
	}
	s.cmd = cmd
	s.cancel = cancel
	return nil
}

// Stop sends SIGTERM and waits for the process to exit.
func (s *SingBox) Stop() error {
	if !s.IsRunning() {
		return nil
	}
	_ = s.cmd.Process.Signal(syscall.SIGTERM)
	_ = s.cmd.Wait()
	s.cmd = nil
	s.cancel = nil
	return nil
}

// IsRunning reports whether a sing-box process is active.
func (s *SingBox) IsRunning() bool {
	return s.cmd != nil && s.cmd.Process != nil
}

func findKwriteconfig() (string, error) {
	for _, cmd := range []string{"kwriteconfig6", "kwriteconfig5", "kwriteconfig"} {
		if _, err := exec.LookPath(cmd); err == nil {
			return cmd, nil
		}
	}
	return "", fmt.Errorf("kwriteconfig not found in PATH")
}

// SetSystemProxy configures KDE system proxy via kwriteconfig.
func (s *SingBox) SetSystemProxy() error {
	kwrite, err := findKwriteconfig()
	if err != nil {
		return err
	}
	proxyURL := fmt.Sprintf("http://127.0.0.1:%d", ProxyPort)
	cmds := [][]string{
		{kwrite, "--file", "kioslaverc", "--group", "Proxy Settings",
			"--key", "ProxyType", "1"},
		{kwrite, "--file", "kioslaverc", "--group", "Proxy Settings",
			"--key", "httpProxy", proxyURL},
		{kwrite, "--file", "kioslaverc", "--group", "Proxy Settings",
			"--key", "httpsProxy", proxyURL},
	}
	for _, args := range cmds {
		if err := exec.Command(args[0], args[1:]...).Run(); err != nil {
			return fmt.Errorf("singbox: set proxy (%v): %w", args, err)
		}
	}
	// Signal KDE to reload proxy settings
	_ = exec.Command("dbus-send", "--type=signal", "/KIO/Scheduler",
		"org.kde.KIO.Scheduler.reparseSlaveConfiguration", "string:").Run()
	return nil
}

// ClearSystemProxy removes the KDE system proxy configuration.
func (s *SingBox) ClearSystemProxy() error {
	kwrite, err := findKwriteconfig()
	if err != nil {
		return err
	}
	if err := exec.Command(kwrite, "--file", "kioslaverc",
		"--group", "Proxy Settings", "--key", "ProxyType", "0").Run(); err != nil {
		return fmt.Errorf("singbox: clear proxy: %w", err)
	}
	_ = exec.Command("dbus-send", "--type=signal", "/KIO/Scheduler",
		"org.kde.KIO.Scheduler.reparseSlaveConfiguration", "string:").Run()
	return nil
}

// ---- FetchConfigFromString -------------------------------------------------

// FetchConfigFromString parses a VLESS link list (plain or base64-encoded),
// picks the best link (or first), builds a proper sing-box config and writes it.
// Uses "mixed" inbound so both HTTP and SOCKS5 clients work on port 7890.
func (s *SingBox) FetchConfigFromString(vlessLinks string) error {
	// Base64 decode if needed
	if dec, err := base64.StdEncoding.DecodeString(strings.TrimSpace(vlessLinks)); err == nil {
		vlessLinks = string(dec)
	}

	uuid, server, port, sni, pbk, sid, fp, err := pickBestVlessLink(vlessLinks, "")
	if err != nil {
		return fmt.Errorf("singbox: %w", err)
	}

	portNum := 0
	fmt.Sscan(port, &portNum)

	cfg := map[string]any{
		"log": map[string]any{"level": "warn"},
		"inbounds": []any{
			map[string]any{
				"type":        "mixed",
				"tag":         "mixed-in",
				"listen":      "127.0.0.1",
				"listen_port": ProxyPort,
			},
		},
		"outbounds": []any{
			map[string]any{
				"type":        "vless",
				"tag":         "proxy",
				"server":      server,
				"server_port": portNum,
				"uuid":        uuid,
				"flow":        "xtls-rprx-vision",
				"tls": map[string]any{
					"enabled":     true,
					"server_name": sni,
					"utls": map[string]any{
						"enabled":     true,
						"fingerprint": fp,
					},
					"reality": map[string]any{
						"enabled":    true,
						"public_key": pbk,
						"short_id":   sid,
					},
				},
			},
			map[string]any{"type": "direct", "tag": "direct"},
		},
		"route": map[string]any{
			"final": "proxy",
		},
	}

	data, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		return fmt.Errorf("singbox: marshal config: %w", err)
	}
	if err := os.MkdirAll(filepath.Dir(s.configPath), 0700); err != nil {
		return err
	}
	return os.WriteFile(s.configPath, data, 0600)
}

// pickBestVlessLink returns params of the first (or preferServer-matching) VLESS link.
func pickBestVlessLink(vlessLinks, preferServer string) (uuid, server, port, sni, pbk, sid, fp string, err error) {
	extract := func(line string) (string, string, string, string, string, string, string) {
		u, _ := url.Parse(line)
		q := u.Query()
		get := func(key, def string) string {
			if v := q.Get(key); v != "" {
				return v
			}
			return def
		}
		return u.User.Username(), u.Hostname(), u.Port(),
			get("sni", ""), get("pbk", ""), get("sid", ""), get("fp", "chrome")
	}

	var firstLine string
	for _, line := range strings.Split(vlessLinks, "\n") {
		line = strings.TrimSpace(line)
		if !strings.HasPrefix(line, "vless://") {
			continue
		}
		if firstLine == "" {
			firstLine = line
		}
		if preferServer != "" {
			if u, e := url.Parse(line); e == nil &&
				strings.Contains(strings.ToUpper(u.Fragment), strings.ToUpper(preferServer)) {
				uid, srv, p, s, pb, si, f := extract(line)
				return uid, srv, p, s, pb, si, f, nil
			}
		}
	}
	if firstLine == "" {
		return "", "", "", "", "", "", "", fmt.Errorf("no vless:// link found")
	}
	uid, srv, p, s, pb, si, f := extract(firstLine)
	return uid, srv, p, s, pb, si, f, nil
}

// ---- VLESS parser (legacy — used by FetchConfig) ---------------------------

// parseVLESSLinks converts vless:// URIs into sing-box outbound configs.
// Format: vless://uuid@host:port?security=reality&pbk=KEY&sid=SID#name
func parseVLESSLinks(links []string) ([]sbOutbound, error) {
	var out []sbOutbound
	for i, link := range links {
		link = strings.TrimSpace(link)
		if link == "" || !strings.HasPrefix(link, "vless://") {
			continue
		}
		u, err := url.Parse(link)
		if err != nil {
			continue
		}
		q := u.Query()
		tag := u.Fragment
		if tag == "" {
			tag = fmt.Sprintf("vless-%d", i)
		}
		port := 443
		if p := u.Port(); p != "" {
			fmt.Sscanf(p, "%d", &port)
		}
		ob := sbOutbound{
			Type:       "vless",
			Tag:        tag,
			Server:     u.Hostname(),
			ServerPort: port,
			UUID:       u.User.Username(),
			Flow:       q.Get("flow"),
		}
		if q.Get("security") == "reality" {
			ob.TLS = &sbTLS{
				Enabled:    true,
				ServerName: q.Get("sni"),
				UTLS: &sbUTLS{
					Enabled:     true,
					Fingerprint: "chrome",
				},
				Reality: &sbReality{
					Enabled:   true,
					PublicKey: q.Get("pbk"),
					ShortID:   q.Get("sid"),
				},
			}
		}
		out = append(out, ob)
	}
	return out, nil
}
