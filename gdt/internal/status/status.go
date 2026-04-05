package status

import (
	"bufio"
	"bytes"
	"os"
	"os/exec"
	"strings"
)

type SystemStatus struct {
	OSVersion      string // "3.8.1"
	OSBranch       string // "stable"
	OSBuildID      string // "20260327.100"
	FlatpakUpdates int    // количество ожидающих обновлений
	OpenH264       bool   // установлен ли
	OpenH264Ver    string // "2.5.1" или ""
	TunnelActive   bool
	TunnelCountry  string // "NL"
}

func Collect() (*SystemStatus, error) {
	s := &SystemStatus{}
	collectOS(s)
	collectFlatpak(s)
	return s, nil
}

func collectOS(s *SystemStatus) {
	data, err := os.ReadFile("/etc/os-release")
	if err != nil {
		return
	}
	scanner := bufio.NewScanner(bytes.NewReader(data))
	for scanner.Scan() {
		line := scanner.Text()
		k, v, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		v = strings.Trim(v, `"`)
		switch k {
		case "VERSION_ID":
			s.OSVersion = v
		case "STEAMOS_DEFAULT_UPDATE_BRANCH":
			s.OSBranch = v
		case "BUILD_ID":
			s.OSBuildID = v
		}
	}
}

func collectFlatpak(s *SystemStatus) {
	// Количество доступных обновлений
	out, _ := exec.Command("flatpak", "update", "--no-deploy").Output()
	count := 0
	for _, line := range strings.Split(string(out), "\n") {
		trimmed := strings.TrimSpace(line)
		// строка начинается с цифры и точки: "1.", "2.", etc.
		if len(trimmed) > 0 && trimmed[0] >= '1' && trimmed[0] <= '9' {
			count++
		}
	}
	s.FlatpakUpdates = count

	// Проверка openh264 в обоих пространствах
	for _, scope := range []string{"--system", "--user"} {
		out, _ := exec.Command("flatpak", "list", scope,
			"--columns=application,branch").Output()
		for _, line := range strings.Split(string(out), "\n") {
			if strings.Contains(line, "org.freedesktop.Platform.openh264") {
				fields := strings.Fields(line)
				if len(fields) >= 2 {
					s.OpenH264 = true
					s.OpenH264Ver = fields[1]
				}
			}
		}
	}
}
