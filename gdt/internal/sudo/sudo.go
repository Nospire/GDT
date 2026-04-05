package sudo

import (
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"strings"
)

// State — три состояния как в Qt версии.
type State int

const (
	NoPassword State = iota // пароля нет вообще
	HasPassword             // пароль есть, но не введён в GDT
	Active                  // пароль введён и проверен
)

type Manager struct {
	state    State
	password string
	userName string
}

func New() *Manager {
	m := &Manager{}
	if u := os.Getenv("USER"); u != "" {
		m.userName = u
	} else {
		// fallback: whoami
		out, err := exec.Command("whoami").Output()
		if err == nil {
			m.userName = strings.TrimSpace(string(out))
		}
	}
	return m
}

// DetectState runs `passwd -S $USER` and sets state to NoPassword or HasPassword.
// Field 2 of the output:
//
//	"L" → locked / no password
//	"P" → password set
//	"NP" → no password (explicitly empty)
func (m *Manager) DetectState() error {
	out, err := exec.Command("passwd", "-S", m.userName).Output()
	if err != nil {
		return fmt.Errorf("passwd -S %s: %w", m.userName, err)
	}
	fields := strings.Fields(string(out))
	if len(fields) < 2 {
		return fmt.Errorf("passwd -S: unexpected output: %q", string(out))
	}
	switch fields[1] {
	case "P":
		m.state = HasPassword
	default:
		// "L", "NP", or anything else → treat as no usable password
		m.state = NoPassword
	}
	return nil
}

// Verify checks the password with `sudo -S -k true`.
// -k invalidates any cached credentials first so we always do a real check.
func (m *Manager) Verify(password string) error {
	cmd := exec.Command("sudo", "-S", "-k", "-p", "", "true")
	cmd.Stdin = strings.NewReader(password + "\n")
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("sudo verify failed: %w", err)
	}
	m.password = password
	m.state = Active
	return nil
}

// SetPassword creates a password via `passwd` (interactive via os.Stdin/Stdout/Stderr)
// when state is NoPassword, then calls Verify.
func (m *Manager) SetPassword(password string) error {
	if m.state == NoPassword {
		cmd := exec.Command("passwd", m.userName)
		cmd.Stdin = os.Stdin
		cmd.Stdout = os.Stdout
		cmd.Stderr = os.Stderr
		if err := cmd.Run(); err != nil {
			return fmt.Errorf("passwd: %w", err)
		}
	}
	return m.Verify(password)
}

// Run prepares a sudo command without starting it.
// The caller is responsible for attaching stdout/stderr pipes and calling Start/Run.
// sudo -S reads the password from Stdin; -k skips the credential cache.
func (m *Manager) Run(command string, args ...string) *exec.Cmd {
	sudoArgs := []string{"-S", "-k", "-p", "", command}
	sudoArgs = append(sudoArgs, args...)
	cmd := exec.Command("sudo", sudoArgs...)
	cmd.Stdin = strings.NewReader(m.password + "\n")
	return cmd
}

// State returns the current authentication state.
func (m *Manager) State() State {
	return m.state
}

// UserName returns the detected user name.
func (m *Manager) UserName() string {
	return m.userName
}

// Password returns the verified sudo password (empty if not yet verified).
func (m *Manager) Password() string {
	return m.password
}
