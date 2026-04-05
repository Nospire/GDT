package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"strings"
)

type Input struct {
	SudoPass  string `json:"sudo_pass"`
	ConfigDir string `json:"config_dir"`
	Lang      string `json:"lang"`
}

func main() {
	var inp Input
	if err := json.NewDecoder(os.Stdin).Decode(&inp); err != nil {
		fatal("failed to read input: " + err.Error())
	}

	// Проверяем наличие steamos-update
	if _, err := exec.LookPath("steamos-update"); err != nil {
		fatal("steamos-update not found — SteamOS only")
	}

	log("Проверяем наличие обновлений...")
	state("checking")

	// steamos-update check
	checkOut, checkRC := runSudo(inp.SudoPass, "steamos-update", "check")
	for _, line := range checkOut {
		log(line)
	}

	if checkRC == 7 || containsAny(checkOut, "no update available") {
		log("Обновлений нет.")
		progress(100)
		done(0)
		return
	}

	if checkRC != 0 {
		log(fmt.Sprintf("Ошибка проверки (код %d)", checkRC))
		done(checkRC)
		return
	}

	log("Найдено обновление. Загружаем...")
	state("updating")

	// steamos-update
	rc := runSudoStream(inp.SudoPass, "steamos-update")
	if rc == 0 {
		log("Обновление установлено успешно!")
		progress(100)
		state("done")
	} else {
		log(fmt.Sprintf("Ошибка обновления (код %d)", rc))
	}
	done(rc)
}

func log(msg string)   { fmt.Println("LOG:" + msg) }
func state(s string)   { fmt.Println("STATE:" + s) }
func progress(n int)   { fmt.Printf("PROGRESS:%d\n", n) }
func done(rc int)      { fmt.Printf("DONE:%d\n", rc) }
func fatal(msg string) { log("ОШИБКА: " + msg); done(1); os.Exit(1) }

func runSudo(pass, cmd string, args ...string) ([]string, int) {
	c := exec.Command("sudo", append([]string{"-S", "-k", "-p", "", "--", cmd}, args...)...)
	c.Stdin = strings.NewReader(pass + "\n")
	out, err := c.Output()
	lines := strings.Split(strings.TrimSpace(string(out)), "\n")
	if err != nil {
		if e, ok := err.(*exec.ExitError); ok {
			return lines, e.ExitCode()
		}
		return lines, 1
	}
	return lines, 0
}

func runSudoStream(pass, cmd string, args ...string) int {
	c := exec.Command("sudo", append([]string{"-S", "-k", "-p", "", "--", cmd}, args...)...)
	c.Stdin = strings.NewReader(pass + "\n")
	stdout, _ := c.StdoutPipe()
	stderr, _ := c.StderrPipe()
	c.Start()

	scan := func(s *bufio.Scanner) {
		for s.Scan() {
			line := s.Text()
			log(line)
			// прогресс из "XX%"
			for _, f := range strings.Fields(line) {
				f = strings.TrimRight(f, "%")
				var n int
				if _, err := fmt.Sscanf(f, "%d", &n); err == nil && n >= 0 && n <= 100 {
					if strings.Contains(line, f+"%") {
						progress(n)
					}
				}
			}
			// состояния
			lower := strings.ToLower(line)
			if strings.Contains(lower, "downloading") {
				state("downloading")
			} else if strings.Contains(lower, "applying") || strings.Contains(lower, "installing") {
				state("applying")
			}
		}
	}

	go scan(bufio.NewScanner(stdout))
	go scan(bufio.NewScanner(stderr))

	if err := c.Wait(); err != nil {
		if e, ok := err.(*exec.ExitError); ok {
			return e.ExitCode()
		}
		return 1
	}
	return 0
}

func containsAny(lines []string, substr string) bool {
	for _, l := range lines {
		if strings.Contains(strings.ToLower(l), strings.ToLower(substr)) {
			return true
		}
	}
	return false
}
