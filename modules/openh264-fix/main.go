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

	// Шаг 1 — добавляем flathub в user если нет
	log("Проверяем flathub remote...")
	out, _ := exec.Command("flatpak", "remotes", "--user").Output()
	if !strings.Contains(string(out), "flathub") {
		log("Добавляем flathub remote в user space...")
		rc := runStream("flatpak", "remote-add", "--user", "--if-not-exists",
			"flathub", "https://dl.flathub.org/repo/flathub.flatpakrepo")
		if rc != 0 {
			fatal("Не удалось добавить flathub remote")
		}
	} else {
		log("flathub remote уже есть")
	}

	// Шаг 2 — снимаем маски (system + user)
	state("unmasking")
	log("Снимаем маску системного репозитория...")
	runSudo(inp.SudoPass, "flatpak", "mask", "--system", "--remove",
		"org.freedesktop.Platform.openh264")

	log("Снимаем маску пользовательского репозитория...")
	exec.Command("flatpak", "mask", "--user", "--remove",
		"org.freedesktop.Platform.openh264").Run()

	// Шаг 3 — устанавливаем в USER (без sudo, flathub теперь есть)
	state("installing")
	log("Устанавливаем org.freedesktop.Platform.openh264//2.5.1 (user)...")
	rc := runStream("flatpak", "install", "-y", "--user", "flathub",
		"org.freedesktop.Platform.openh264//2.5.1")
	if rc != 0 {
		// "already installed" даёт ненулевой код — проверяем через list
		log("Установка вернула ненулевой код, проверяем наличие пакета...")
	}

	// Шаг 4 — проверяем через flatpak list --user
	state("verifying")
	log("Проверяем установку...")
	listOut, err := exec.Command("flatpak", "list", "--user").Output()
	if err != nil || !strings.Contains(string(listOut), "openh264") {
		fatal("openh264 не найден в пользовательских пакетах после установки")
	}
	log("openh264 установлен успешно:")
	for _, line := range strings.Split(strings.TrimSpace(string(listOut)), "\n") {
		if strings.Contains(line, "openh264") {
			log("  " + line)
		}
	}

	progress(100)
	log("Готово! OpenH264 установлен.")
	done(0)
}

func log(msg string)   { fmt.Println("LOG:" + msg) }
func state(s string)   { fmt.Println("STATE:" + s) }
func progress(n int)   { fmt.Printf("PROGRESS:%d\n", n) }
func done(rc int)      { fmt.Printf("DONE:%d\n", rc) }
func fatal(msg string) { log("ОШИБКА: " + msg); done(1); os.Exit(1) }

func runSudo(pass, cmd string, args ...string) int {
	c := exec.Command("sudo", append([]string{"-S", "-k", "-p", "", "-E", "--", cmd}, args...)...)
	c.Stdin = strings.NewReader(pass + "\n")
	if err := c.Run(); err != nil {
		if e, ok := err.(*exec.ExitError); ok {
			return e.ExitCode()
		}
		return 1
	}
	return 0
}

func runStream(cmd string, args ...string) int {
	c := exec.Command(cmd, args...)
	stdout, _ := c.StdoutPipe()
	stderr, _ := c.StderrPipe()
	c.Start()
	scan := func(s *bufio.Scanner) {
		for s.Scan() {
			line := s.Text()
			log(line)
			lower := strings.ToLower(line)
			if strings.Contains(lower, "downloading") {
				state("downloading")
			} else if strings.Contains(lower, "installing") {
				state("installing")
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
