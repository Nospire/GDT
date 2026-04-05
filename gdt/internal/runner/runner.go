package runner

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"

	"gdt/internal/sudo"
)

// ---- message types ---------------------------------------------------------

type MsgType string

const (
	MsgLog      MsgType = "LOG"
	MsgProgress MsgType = "PROGRESS" // payload: "0"–"100"
	MsgState    MsgType = "STATE"
	MsgDone     MsgType = "DONE" // payload: exit code as string
)

type Message struct {
	Type    MsgType `json:"type"`
	Payload string  `json:"payload"`
}

// ---- module stdin envelope -------------------------------------------------

type moduleInput struct {
	SudoPass  string `json:"sudo_pass"`
	ConfigDir string `json:"config_dir"`
	Lang      string `json:"lang"`
}

// ---- Runner -----------------------------------------------------------------

type Runner struct {
	sudo    *sudo.Manager
	baseDir string
	onMsg   func(Message)

	running atomic.Bool
	mu      sync.Mutex
	cancel  context.CancelFunc
}

func New(s *sudo.Manager, baseDir string, onMsg func(Message)) *Runner {
	return &Runner{
		sudo:    s,
		baseDir: baseDir,
		onMsg:   onMsg,
	}
}

// IsRunning reports whether a module process is currently active.
func (r *Runner) IsRunning() bool {
	return r.running.Load()
}

// Cancel sends SIGTERM to the active process via context cancellation.
func (r *Runner) Cancel() {
	r.mu.Lock()
	cancel := r.cancel
	r.mu.Unlock()
	if cancel != nil {
		cancel()
	}
}

// Run launches baseDir/modulePath under sudo.
// Only one module may run at a time; concurrent calls are rejected with an error log.
func (r *Runner) Run(ctx context.Context, modulePath string) error {
	if !r.running.CompareAndSwap(false, true) {
		r.onMsg(Message{Type: MsgLog, Payload: "runner: a module is already running"})
		return fmt.Errorf("runner: already running")
	}
	defer r.running.Store(false)

	runCtx, cancel := context.WithCancel(ctx)
	r.mu.Lock()
	r.cancel = cancel
	r.mu.Unlock()
	defer func() {
		cancel()
		r.mu.Lock()
		r.cancel = nil
		r.mu.Unlock()
	}()

	binary := modulePath
	if !filepath.IsAbs(modulePath) {
		binary = filepath.Join(r.baseDir, modulePath)
	}

	// Build JSON envelope to pass to the module on stdin (after the sudo password line).
	input := moduleInput{
		SudoPass:  r.sudo.Password(),
		ConfigDir: r.baseDir,
		Lang:      "ru",
	}
	envelope, err := json.Marshal(input)
	if err != nil {
		return fmt.Errorf("runner: marshal input: %w", err)
	}

	// sudo -S reads one line for password, then the child process reads the rest.
	stdinPayload := r.sudo.Password() + "\n" + string(envelope) + "\n"

	cmd := exec.CommandContext(runCtx, "sudo", "-S", "-k", "-p", "", binary)
	cmd.Stdin = strings.NewReader(stdinPayload)

	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return fmt.Errorf("runner: stdout pipe: %w", err)
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		return fmt.Errorf("runner: stderr pipe: %w", err)
	}

	if err := cmd.Start(); err != nil {
		return fmt.Errorf("runner: start %s: %w", binary, err)
	}
	r.onMsg(Message{Type: MsgState, Payload: "running"})

	// Drain stdout and stderr concurrently.
	done := make(chan struct{}, 2)
	scanLines := func(s *bufio.Scanner) {
		for s.Scan() {
			r.dispatch(s.Text())
		}
		done <- struct{}{}
	}
	go scanLines(bufio.NewScanner(stdout))
	go scanLines(bufio.NewScanner(stderr))
	<-done
	<-done

	runErr := cmd.Wait()
	exitCode := "0"
	if runErr != nil {
		exitCode = runErr.Error()
	}
	r.onMsg(Message{Type: MsgState, Payload: "idle"})
	r.onMsg(Message{Type: MsgDone, Payload: exitCode})
	return nil
}

// dispatch parses a single output line and emits the appropriate Message.
// Expected prefixes: LOG: / PROGRESS: / STATE: / DONE:
// Unrecognised lines are emitted as MsgLog.
func (r *Runner) dispatch(line string) {
	switch {
	case strings.HasPrefix(line, "LOG:"):
		r.onMsg(Message{Type: MsgLog, Payload: strings.TrimPrefix(line, "LOG:")})
	case strings.HasPrefix(line, "PROGRESS:"):
		r.onMsg(Message{Type: MsgProgress, Payload: strings.TrimPrefix(line, "PROGRESS:")})
	case strings.HasPrefix(line, "STATE:"):
		r.onMsg(Message{Type: MsgState, Payload: strings.TrimPrefix(line, "STATE:")})
	case strings.HasPrefix(line, "DONE:"):
		r.onMsg(Message{Type: MsgDone, Payload: strings.TrimPrefix(line, "DONE:")})
	default:
		r.onMsg(Message{Type: MsgLog, Payload: line})
	}
}
