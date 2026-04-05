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
	SudoPass string `json:"sudo_pass"`
	Lang     string `json:"lang"`
}

func main() {
	var inp Input
	json.NewDecoder(os.Stdin).Decode(&inp)

	log("Проверяем flatpak...")
	if _, err := exec.LookPath("flatpak"); err != nil {
		fatal("flatpak не найден")
	}

	out, _ := exec.Command("flatpak", "--version").Output()
	log(strings.TrimSpace(string(out)))

	log("Обновляем системные Flatpak приложения...")
	rc := runSudoStream(inp.SudoPass, "flatpak", "update", "-y", "--system")
	if rc != 0 {
		log("WARN: системные приложения не обновились, продолжаем...")
	}

	log("Обновляем пользовательские Flatpak приложения...")
	rc = runStream("flatpak", "update", "-y", "--user")
	if rc != 0 {
		log("Ошибка обновления пользовательских приложений")
		done(1)
		return
	}

	progress(100)
	log("Flatpak обновления завершены успешно!")
	done(0)
}

func log(msg string)   { fmt.Println("LOG:" + msg) }
func progress(n int)   { fmt.Printf("PROGRESS:%d\n", n) }
func done(rc int)      { fmt.Printf("DONE:%d\n", rc) }
func fatal(msg string) { log("ОШИБКА: " + msg); done(1); os.Exit(1) }

func runSudoStream(pass string, cmd string, args ...string) int {
	c := exec.Command("sudo", append([]string{"-S", "-k", "-p", "", "--", cmd}, args...)...)
	c.Stdin = strings.NewReader(pass + "\n")
	return streamCmd(c)
}

func runStream(cmd string, args ...string) int {
	return streamCmd(exec.Command(cmd, args...))
}

func streamCmd(c *exec.Cmd) int {
	stdout, _ := c.StdoutPipe()
	stderr, _ := c.StderrPipe()
	c.Start()
	scan := func(s *bufio.Scanner) {
		for s.Scan() {
			line := s.Text()
			log(line)
			lower := strings.ToLower(line)
			if strings.Contains(lower, "updating") {
				fmt.Println("STATE:updating")
			}
			// прогресс из "XX%"
			for _, f := range strings.Fields(line) {
				trimmed := strings.TrimRight(f, "%")
				if trimmed != f {
					var n int
					if _, err := fmt.Sscan(trimmed, &n); err == nil && n >= 0 && n <= 100 {
						progress(n)
					}
				}
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
