// NothingClaw bridge - system/desktop tools (brightness, power, notifications,
// system info, timers, wallpaper, local-model recommendation). Companion to
// server_dispatch.go.
package main

import (
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
)

func brightnessTool(args map[string]any) map[string]any {
	action := strings.ToLower(strArg(args, "action", "get"))
	if _, err := exec.LookPath("brightnessctl"); err == nil {
		switch action {
		case "get":
			return runShell("brightnessctl -m | cut -d, -f4", 5, "")
		case "set":
			return runShell(fmt.Sprintf("brightnessctl set %d%%", clampPct(intArg(args, "value", 50))), 5, "")
		case "up":
			return runShell("brightnessctl set 5%+", 5, "")
		case "down":
			return runShell("brightnessctl set 5%-", 5, "")
		}
	}
	if action == "get" {
		return runShell("cat /sys/class/backlight/*/brightness /sys/class/backlight/*/max_brightness 2>/dev/null", 5, "")
	}
	return errContent("brightnessctl not found; install it (or grant write access to /sys/class/backlight).")
}

func powerTool(args map[string]any) map[string]any {
	action := strings.ToLower(strArg(args, "action", ""))
	confirm := boolArg(args, "confirm", false)
	switch action {
	case "lock":
		if fireAndForget([]string{"loginctl", "lock-session"}) {
			return okContent("Session locked.")
		}
		if fireAndForget([]string{"bash", "-c", "swaylock || hyprlock || gtklock || betterlockscreen -l"}) {
			return okContent("Lock screen launched.")
		}
		return errContent("no lock method found")
	case "suspend":
		if fireAndForget([]string{"systemctl", "suspend"}) {
			return okContent("Suspending.")
		}
		return errContent("systemctl suspend failed")
	case "hibernate":
		if fireAndForget([]string{"systemctl", "hibernate"}) {
			return okContent("Hibernating.")
		}
		return errContent("systemctl hibernate failed")
	case "logout":
		if fireAndForget([]string{"bash", "-c", "loginctl terminate-user \"$USER\""}) {
			return okContent("Logging out.")
		}
		return errContent("logout failed")
	case "reboot":
		if !confirm {
			return errContent("refusing to reboot without confirm=true")
		}
		if fireAndForget([]string{"systemctl", "reboot"}) {
			return okContent("Rebooting.")
		}
		return errContent("reboot failed")
	case "poweroff":
		if !confirm {
			return errContent("refusing to power off without confirm=true")
		}
		if fireAndForget([]string{"systemctl", "poweroff"}) {
			return okContent("Powering off.")
		}
		return errContent("poweroff failed")
	}
	return errContent("power action must be lock/suspend/hibernate/logout/reboot/poweroff")
}

func notificationsTool(args map[string]any) map[string]any {
	action := strings.ToLower(strArg(args, "action", "list"))
	if _, err := exec.LookPath("makoctl"); err == nil {
		switch action {
		case "list":
			return runShell("makoctl list", 5, "")
		case "dismiss":
			return runShell("makoctl dismiss", 5, "")
		case "dismiss_all":
			return runShell("makoctl dismiss --all", 5, "")
		}
	}
	if _, err := exec.LookPath("dunstctl"); err == nil {
		switch action {
		case "list":
			return runShell("dunstctl history", 5, "")
		case "dismiss":
			return runShell("dunstctl close", 5, "")
		case "dismiss_all":
			return runShell("dunstctl close-all", 5, "")
		}
	}
	return errContent("no notification daemon control found (install mako or dunst).")
}

func systemInfo() map[string]any {
	var b strings.Builder
	if out, err := os.ReadFile("/proc/loadavg"); err == nil {
		b.WriteString("loadavg: " + strings.TrimSpace(string(out)) + "\n")
	}
	if out, err := os.ReadFile("/proc/meminfo"); err == nil {
		for _, l := range strings.Split(string(out), "\n") {
			if strings.HasPrefix(l, "MemTotal:") || strings.HasPrefix(l, "MemAvailable:") {
				b.WriteString(strings.TrimSpace(l) + "\n")
			}
		}
	}
	if out, err := exec.Command("df", "-h", "/").Output(); err == nil {
		b.WriteString(strings.TrimSpace(string(out)) + "\n")
	}
	if out, err := os.ReadFile("/proc/uptime"); err == nil {
		f := strings.Fields(string(out))
		if len(f) > 0 {
			if secs, err := strconv.ParseFloat(f[0], 64); err == nil {
				b.WriteString(fmt.Sprintf("uptime: %.1f hours\n", secs/3600))
			}
		}
	}
	if out, err := exec.Command("bash", "-c",
		"for x in /sys/class/power_supply/BAT*; do [ -d \"$x\" ] || continue; "+
			"echo \"$(basename $x): $(cat $x/capacity 2>/dev/null)% $(cat $x/status 2>/dev/null)\"; done").Output(); err == nil {
		s := strings.TrimSpace(string(out))
		if s != "" {
			b.WriteString("battery: " + s + "\n")
		}
	}
	if b.Len() == 0 {
		return errContent("could not read system info")
	}
	return okContent(strings.TrimRight(b.String(), "\n"))
}

func timerTool(args map[string]any) map[string]any {
	secs := intArg(args, "seconds", 0)
	if secs <= 0 {
		return errContent("timer needs seconds > 0")
	}
	msg := strArg(args, "message", "Reminder")
	title := strArg(args, "title", "Reminder")
	cmd := fmt.Sprintf("sleep %d && notify-send %s %s", secs, shq(title), shq(msg))
	if fireAndForget([]string{"bash", "-c", cmd}) {
		return okContent(fmt.Sprintf("Reminder set for %d seconds from now.", secs))
	}
	return errContent("could not set timer")
}

func wallpaperTool(args map[string]any) map[string]any {
	path := strArg(args, "path", "")
	if path == "" {
		return errContent("wallpaper needs path")
	}
	if !strings.HasPrefix(path, "/") {
		home, _ := os.UserHomeDir()
		path = home + "/" + path
	}
	if _, err := os.Stat(path); err != nil {
		return errContent("file not found: " + path)
	}
	if _, err := exec.LookPath("ambxst"); err == nil {
		if r := runShell("ambxst wallpaper "+shq(path), 25, ""); r["error"] == nil {
			return okContent("Wallpaper set to " + path)
		}
	}
	for _, c := range []string{
		"swww img " + shq(path),
		"hyprctl hyprpaper wallpaper ," + shq(path),
		"swaybg -i " + shq(path) + " -m fill",
	} {
		if fireAndForget([]string{"bash", "-c", c}) {
			return okContent("Wallpaper set to " + path)
		}
	}
	return errContent("no wallpaper tool found (install swww, hyprpaper or swaybg).")
}

func recommendModel(args map[string]any) map[string]any {
	task := strings.ToLower(strArg(args, "task", "chat"))
	totalKB := 0
	if out, err := os.ReadFile("/proc/meminfo"); err == nil {
		for _, l := range strings.Split(string(out), "\n") {
			if strings.HasPrefix(l, "MemTotal:") {
				f := strings.Fields(l)
				if len(f) >= 2 {
					totalKB, _ = strconv.Atoi(f[1])
				}
			}
		}
	}
	ramGB := totalKB / 1024 / 1024
	gpu := ""
	if out, err := exec.Command("bash", "-c", "lspci 2>/dev/null | grep -iE 'vga|3d' | head -1").Output(); err == nil {
		gpu = strings.TrimSpace(string(out))
	}
	vram := 0
	if out, err := exec.Command("bash", "-c",
		"nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1").Output(); err == nil {
		vram, _ = strconv.Atoi(strings.TrimSpace(string(out)))
	}
	var rec string
	switch {
	case ramGB >= 32 || vram >= 12000:
		rec = "up to ~14B q4 - e.g. qwen2.5:14b, llama3.1:8b"
	case ramGB >= 16 || vram >= 8000:
		rec = "~7-8B q4 - e.g. llama3.1:8b, qwen2.5:7b"
	case ramGB >= 8:
		rec = "~3-4B q4 - e.g. llama3.2:3b, qwen2.5:3b"
	default:
		rec = "~1-2B q4 - e.g. llama3.2:1b, qwen2.5:1.5b"
	}
	var sb strings.Builder
	fmt.Fprintf(&sb, "RAM: %d GB\n", ramGB)
	if gpu != "" {
		sb.WriteString("GPU: " + gpu + "\n")
	}
	if vram > 0 {
		fmt.Fprintf(&sb, "VRAM: %d MB\n", vram)
	}
	sb.WriteString("Task: " + task + "\n")
	sb.WriteString("Recommended: " + rec + "\n")
	sb.WriteString("For tool use, pick the largest your RAM/VRAM allows - small models call tools poorly.")
	return okContent(sb.String())
}
