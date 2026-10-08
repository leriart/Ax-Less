// NothingClaw bridge - package manager detection and the GUI app catalog.
// Ported from server.py.
package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"
)

func detectPackageManager() (string, string) {
	contents := ""
	if data, err := os.ReadFile("/etc/os-release"); err == nil {
		contents = strings.ToLower(string(data))
	}
	switch {
	case strings.Contains(contents, "arch"), strings.Contains(contents, "cachyos"),
		strings.Contains(contents, "manjaro"):
		return "sudo pacman -S --noconfirm", "pacman"
	case strings.Contains(contents, "fedora"), strings.Contains(contents, "nobara"):
		return "sudo dnf install -y", "dnf"
	case strings.Contains(contents, "debian"), strings.Contains(contents, "ubuntu"),
		strings.Contains(contents, "pop"):
		return "sudo apt-get install -y", "apt"
	}
	return "sudo pacman -S --noconfirm", "pacman"
}

func desktopDirs() []string {
	home, _ := os.UserHomeDir()
	return []string{
		filepath.Join(home, ".local/share/applications"),
		"/usr/local/share/applications",
		"/usr/share/applications",
		"/var/lib/flatpak/exports/share/applications",
		filepath.Join(home, ".local/share/flatpak/exports/share/applications"),
		"/var/lib/snapd/desktop/applications",
	}
}

func appImageDirs() []string {
	home, _ := os.UserHomeDir()
	return []string{
		filepath.Join(home, "Applications"),
		filepath.Join(home, "AppImages"),
		filepath.Join(home, ".local/bin"),
		filepath.Join(home, ".local/share/applications"),
		"/opt",
	}
}

var reExecPlaceholder = regexp.MustCompile(`%[a-zA-Z]`)

func stripExecPlaceholders(execLine string) string {
	return strings.TrimSpace(reExecPlaceholder.ReplaceAllString(execLine, ""))
}

func parseDesktop(path string) map[string]any {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	localeFull := os.Getenv("LANG")
	locale := ""
	if localeFull != "" {
		locale = strings.Split(strings.Split(localeFull, ".")[0], "_")[0]
	}

	entry := map[string]any{}
	inSection := false
	started := false
	namesByLocale := map[string]string{}
	nameDefault := ""
	nameDefaultSet := false

	for _, raw := range strings.Split(string(data), "\n") {
		line := strings.TrimSpace(raw)
		if strings.HasPrefix(line, "#") {
			continue
		}
		if strings.HasPrefix(line, "[") {
			if !started && line == "[Desktop Entry]" {
				started = true
				inSection = true
			} else {
				inSection = false
			}
			continue
		}
		if !strings.Contains(line, "=") || !inSection || !started {
			continue
		}
		eq := strings.Index(line, "=")
		key := strings.TrimSpace(line[:eq])
		val := strings.TrimSpace(line[eq+1:])

		if strings.HasPrefix(key, "Name[") && strings.HasSuffix(key, "]") {
			loc := strings.Split(key[5:len(key)-1], "_")[0]
			namesByLocale[loc] = val
			continue
		}
		if key == "Name" {
			nameDefault = val
			nameDefaultSet = true
			continue
		}
		switch key {
		case "Type", "Hidden", "NoDisplay", "Terminal", "Exec", "GenericName",
			"Comment", "Icon", "Categories", "StartupWMClass":
			entry[key] = val
		}
	}

	if !started {
		return nil
	}
	if t, ok := entry["Type"].(string); ok && t != "Application" {
		return nil
	}
	strAt := func(k string) string {
		if v, ok := entry[k].(string); ok {
			return v
		}
		return ""
	}
	if strings.EqualFold(strAt("Hidden"), "true") ||
		strings.EqualFold(strAt("NoDisplay"), "true") ||
		strings.EqualFold(strAt("Terminal"), "true") {
		return nil
	}

	name := namesByLocale[locale]
	if name == "" && nameDefaultSet {
		name = nameDefault
	}
	execLine, hasExec := entry["Exec"].(string)
	if name == "" || !hasExec {
		return nil
	}

	source := "native"
	if strings.Contains(path, "/flatpak/") {
		source = "flatpak"
	} else if strings.Contains(path, "/snapd/") {
		source = "snap"
	}

	get := func(k string) string {
		if v, ok := entry[k].(string); ok {
			return v
		}
		return ""
	}
	base := filepath.Base(path)
	return map[string]any{
		"id":           strings.ReplaceAll(base, ".desktop", ""),
		"name":         name,
		"generic_name": get("GenericName"),
		"comment":      get("Comment"),
		"command":      execLine,
		"icon":         get("Icon"),
		"categories":   get("Categories"),
		"wmclass":      get("StartupWMClass"),
		"source":       source,
		"desktop_file": path,
	}
}

func scanDesktopDirs() []map[string]any {
	seen := map[string]bool{}
	out := []map[string]any{}
	for _, d := range desktopDirs() {
		entries, err := os.ReadDir(d)
		if err != nil {
			continue
		}
		for _, e := range entries {
			if e.IsDir() || !strings.HasSuffix(e.Name(), ".desktop") {
				continue
			}
			entry := parseDesktop(filepath.Join(d, e.Name()))
			if entry == nil {
				continue
			}
			id, _ := entry["id"].(string)
			if seen[id] {
				continue
			}
			seen[id] = true
			out = append(out, entry)
		}
	}
	return out
}

func scanFlatpakCLI() []map[string]any {
	bin, err := exec.LookPath("flatpak")
	if err != nil {
		return nil
	}
	out, err := runQuick(bin, "list", "--app", "--columns=name,application")
	if err != nil {
		return nil
	}
	res := []map[string]any{}
	for _, line := range strings.Split(out, "\n") {
		parts := strings.Split(line, "\t")
		if len(parts) < 2 {
			continue
		}
		name := strings.TrimSpace(parts[0])
		appID := strings.TrimSpace(parts[1])
		if name == "" || appID == "" {
			continue
		}
		res = append(res, map[string]any{
			"id": appID, "name": name, "generic_name": "", "comment": "",
			"command": "flatpak run " + appID, "icon": "", "categories": "",
			"wmclass": "", "source": "flatpak", "desktop_file": "",
		})
	}
	return res
}

func scanSnapCLI() []map[string]any {
	bin, err := exec.LookPath("snap")
	if err != nil {
		return nil
	}
	out, err := runQuick(bin, "list")
	if err != nil {
		return nil
	}
	lines := strings.Split(out, "\n")
	if len(lines) < 2 {
		return nil
	}
	res := []map[string]any{}
	for _, line := range lines[1:] {
		cols := strings.Fields(line)
		if len(cols) < 2 {
			continue
		}
		name := cols[0]
		res = append(res, map[string]any{
			"id": "snap:" + name, "name": name, "generic_name": "", "comment": "",
			"command": "snap run " + name, "icon": "", "categories": "",
			"wmclass": "", "source": "snap", "desktop_file": "",
		})
	}
	return res
}

func scanAppImages() []map[string]any {
	res := []map[string]any{}
	for _, d := range appImageDirs() {
		entries, err := os.ReadDir(d)
		if err != nil {
			continue
		}
		for _, e := range entries {
			lower := strings.ToLower(e.Name())
			if !strings.HasSuffix(lower, ".appimage") && !strings.HasSuffix(lower, ".app") {
				continue
			}
			full := filepath.Join(d, e.Name())
			info, err := os.Stat(full)
			if err != nil || info.IsDir() || info.Mode()&0o111 == 0 {
				continue
			}
			stem := e.Name()
			for _, ext := range []string{".AppImage", ".appimage", ".app"} {
				if strings.HasSuffix(stem, ext) {
					stem = stem[:len(stem)-len(ext)]
					break
				}
			}
			nice := strings.TrimSpace(strings.NewReplacer("_", " ", "-", " ").Replace(stem))
			if nice == "" {
				nice = stem
			}
			res = append(res, map[string]any{
				"id": "appimage:" + full, "name": nice, "generic_name": "",
				"comment": "", "command": full, "icon": "", "categories": "",
				"wmclass": "", "source": "appimage", "desktop_file": "",
			})
		}
	}
	return res
}

func runQuick(name string, args ...string) (string, error) {
	cmd := exec.Command(name, args...)
	done := make(chan struct{})
	var out []byte
	var runErr error
	go func() {
		out, runErr = cmd.Output()
		close(done)
	}()
	select {
	case <-done:
		return string(out), runErr
	case <-time.After(8 * time.Second):
		_ = cmd.Process.Kill()
		return "", errTimeout
	}
}

var errTimeout = timeoutError{}

type timeoutError struct{}

func (timeoutError) Error() string { return "timeout" }

var (
	appsMu        sync.Mutex
	appsCache     []map[string]any
	appsCacheTime time.Time
)

func buildAppsCatalog() []map[string]any {
	seen := map[string]bool{}
	out := []map[string]any{}
	add := func(entries []map[string]any) {
		for _, e := range entries {
			id, _ := e["id"].(string)
			if seen[id] {
				continue
			}
			seen[id] = true
			out = append(out, e)
		}
	}
	add(scanDesktopDirs())
	add(scanFlatpakCLI())
	add(scanSnapCLI())
	add(scanAppImages())
	sort.Slice(out, func(i, j int) bool {
		a, _ := out[i]["name"].(string)
		b, _ := out[j]["name"].(string)
		return strings.ToLower(a) < strings.ToLower(b)
	})
	return out
}

func getAppsCatalog(force bool) []map[string]any {
	appsMu.Lock()
	defer appsMu.Unlock()
	if !force && appsCache != nil && time.Since(appsCacheTime) < 60*time.Second {
		return appsCache
	}
	appsCache = buildAppsCatalog()
	appsCacheTime = time.Now()
	return appsCache
}

func findApp(name string, catalog []map[string]any) map[string]any {
	needle := strings.ToLower(strings.TrimSpace(name))
	if needle == "" {
		return nil
	}
	for _, e := range catalog {
		n, _ := e["name"].(string)
		if strings.ToLower(n) == needle {
			return e
		}
	}
	for _, e := range catalog {
		n, _ := e["name"].(string)
		if strings.Contains(strings.ToLower(n), needle) {
			return e
		}
	}
	for _, e := range catalog {
		g, _ := e["generic_name"].(string)
		if g != "" && strings.Contains(strings.ToLower(g), needle) {
			return e
		}
	}
	for _, e := range catalog {
		id, _ := e["id"].(string)
		for _, prefix := range []string{"snap:", "appimage:"} {
			if strings.HasPrefix(id, prefix) {
				id = id[len(prefix):]
				break
			}
		}
		if strings.Contains(strings.ToLower(id), needle) {
			return e
		}
	}
	return nil
}
