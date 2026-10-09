// NothingClaw bridge - the invoke_tool dispatcher. Ported from server.py.
package main

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

// normalizeArgs makes tool calls forgiving for small/minimal models, which
// frequently (a) echo the function-call envelope, wrapping the real payload in
// a nested "parameters"/"arguments" object, or (b) use a generic key such as
// "name"/"app" instead of the schema's "app_name".
func normalizeArgs(name string, in map[string]any) map[string]any {
	args := map[string]any{}
	for k, v := range in {
		args[k] = v
	}
	// (a) unwrap a single nested payload object.
	for _, wrap := range []string{"parameters", "arguments", "args", "input"} {
		inner, ok := args[wrap].(map[string]any)
		if !ok {
			continue
		}
		for k, v := range inner {
			if _, exists := args[k]; !exists {
				args[k] = v
			}
		}
		delete(args, wrap)
	}
	// (b) app-name aliases for the app tools.
	if name == "open_app" || name == "close_app" {
		if strArg(args, "app_name", "") == "" {
			for _, k := range []string{"name", "app", "application", "appname", "query"} {
				if s := strArg(args, k, ""); s != "" {
					args["app_name"] = s
					break
				}
			}
		}
	}
	return args
}

func invokeTool(name string, arguments map[string]any, ctx *requestContext) map[string]any {
	if arguments == nil {
		arguments = map[string]any{}
	}
	if ctx == nil {
		ctx = resolveRequestContext("small", "", "")
	}
	args := normalizeArgs(name, arguments)

	// Filesystem tools.
	if h, ok := fsHandlers[name]; ok {
		return guard(func() map[string]any { return h(args) })
	}

	switch name {
	case "list_windows":
		result := runAxctl([]string{"window", "list"}, 5*time.Second)
		if result["error"] != nil {
			return result
		}
		var windows []any
		if json.Unmarshal([]byte(toString(result["content"])), &windows) != nil {
			return result
		}
		if !boolArg(args, "verbose", false) {
			windowsOut := compactWindows(windows)
			return okContent(jsonPretty(windowsOut))
		}
		return okContent(toString(result["content"]))

	case "list_workspaces":
		return runAxctl([]string{"workspace", "list"}, 5*time.Second)

	case "list_monitors":
		return runAxctl([]string{"monitor", "list"}, 5*time.Second)

	case "focus_window":
		wid := strArg(args, "window_id", "")
		dir := strArg(args, "direction", "")
		if wid != "" {
			return runAxctl([]string{"window", "focus", wid}, 5*time.Second)
		}
		if dir != "" {
			return runAxctl([]string{"window", "focus-dir", dir}, 5*time.Second)
		}
		return errContent("focus_window needs either window_id or direction")

	case "close_window":
		argv := []string{"window", "close"}
		if wid := strArg(args, "window_id", ""); wid != "" {
			argv = append(argv, wid)
		}
		return runAxctl(argv, 5*time.Second)

	case "toggle_window_floating":
		argv := []string{"window", "toggle-floating"}
		if wid := strArg(args, "window_id", ""); wid != "" {
			argv = append(argv, wid)
		}
		return runAxctl(argv, 5*time.Second)

	case "set_window_fullscreen":
		state, ok := args["state"].(bool)
		if !ok {
			return errContent("set_window_fullscreen needs state=true|false")
		}
		s := "0"
		if state {
			s = "1"
		}
		argv := []string{"window", "fullscreen", s}
		if wid := strArg(args, "window_id", ""); wid != "" {
			argv = append(argv, wid)
		}
		return runAxctl(argv, 5*time.Second)

	case "resize_window":
		w, okW := args["width"].(float64)
		h, okH := args["height"].(float64)
		if !okW || !okH {
			return errContent("resize_window needs integer width and height")
		}
		argv := []string{"window", "resize", fmt.Sprint(int(w)), fmt.Sprint(int(h))}
		if wid := strArg(args, "window_id", ""); wid != "" {
			argv = append(argv, wid)
		}
		return runAxctl(argv, 5*time.Second)

	case "move_window_direction":
		dir := strArg(args, "direction", "")
		if dir == "" {
			return errContent("move_window_direction needs direction=l|r|u|d")
		}
		argv := []string{"window", "move", dir}
		if wid := strArg(args, "window_id", ""); wid != "" {
			argv = append(argv, wid)
		}
		return runAxctl(argv, 5*time.Second)

	case "switch_workspace":
		ws := strArg(args, "workspace_id", "")
		if ws == "" {
			return errContent("switch_workspace needs workspace_id")
		}
		return runAxctl([]string{"workspace", "switch", ws}, 5*time.Second)

	case "move_window_to_workspace":
		ws := strArg(args, "workspace_id", "")
		if ws == "" {
			return errContent("move_window_to_workspace needs workspace_id")
		}
		argv := []string{"workspace", "move-to", ws}
		wid := strArg(args, "window_id", "")
		if wid != "" {
			argv = append(argv, wid)
		}
		prevWS := ""
		if wid != "" {
			if lr := runAxctl([]string{"window", "list"}, 5*time.Second); lr["error"] == nil {
				var snap []any
				_ = json.Unmarshal([]byte(toString(lr["content"])), &snap)
				for _, w := range snap {
					if m, ok := w.(map[string]any); ok && fmt.Sprint(m["id"]) == wid {
						prevWS = fmt.Sprint(m["workspace_id"])
						break
					}
				}
			}
		}
		result := runAxctl(argv, 5*time.Second)
		if result["error"] == nil && prevWS != "" {
			var payload map[string]any
			if json.Unmarshal([]byte(toString(result["content"])), &payload) != nil {
				payload = map[string]any{}
			}
			payload["previous_workspace_id"] = prevWS
			payload["window_id"] = wid
			payload["workspace_id"] = ws
			return okContent(jsonPretty(payload))
		}
		return result

	case "move_windows":
		return moveWindows(args)

	case "toggle_special_workspace":
		n := strArg(args, "name", "")
		if n == "" {
			return errContent("toggle_special_workspace needs name")
		}
		return runAxctl([]string{"workspace", "toggle-special", n}, 5*time.Second)

	case "focus_monitor":
		mid := strArg(args, "monitor_id", "")
		if mid == "" {
			return errContent("focus_monitor needs monitor_id")
		}
		return runAxctl([]string{"monitor", "focus", mid}, 5*time.Second)

	case "move_window_to_monitor":
		mid := strArg(args, "monitor_id", "")
		if mid == "" {
			return errContent("move_window_to_monitor needs monitor_id")
		}
		argv := []string{"monitor", "move-to", mid}
		if wid := strArg(args, "window_id", ""); wid != "" {
			argv = append(argv, wid)
		}
		return runAxctl(argv, 5*time.Second)

	case "set_layout":
		l := strArg(args, "name", "")
		if l == "" {
			return errContent("set_layout needs name")
		}
		return runAxctl([]string{"layout", "set", l}, 5*time.Second)

	case "execute_command":
		c := strArg(args, "command", "")
		if c == "" {
			return errContent("execute_command needs command")
		}
		return runAxctl([]string{"system", "execute", c}, 5*time.Second)

	case "run_shell_command":
		c := strArg(args, "command", "")
		if c == "" {
			return errContent("run_shell_command needs command")
		}
		cwd := strArg(args, "cwd", "")
		if cwd != "" {
			resolved, err := resolveSandbox(cwd, true)
			if err != nil {
				return errContent(err.Error())
			}
			cwd = resolved
		}
		return runShell(c, intArg(args, "timeout", 30), cwd)

	case "check_program_installed":
		program := strArg(args, "program_name", "")
		if program == "" {
			return errContent("check_program_installed needs program_name")
		}
		first := strings.Fields(program)[0]
		if path, err := exec.LookPath(first); err == nil {
			return okContent("The program '" + program + "' IS installed at: " + path)
		}
		return okContent("The program '" + program + "' is NOT installed on this system.")

	case "launch_program":
		program := strArg(args, "program_name", "")
		if program == "" {
			return errContent("launch_program needs program_name")
		}
		// exec argv directly whenever the line is a plain command, so a
		// model-supplied program string can never append shell syntax.
		if argv, ok := shellWords(program); ok {
			if fireAndForget(argv) {
				return okContent("Launched '" + program + "' in the background.")
			}
			return errContent("Failed to launch '" + program + "'.")
		}
		if program != "" && fireAndForget([]string{"bash", "-c", "exec " + program + " >/dev/null 2>&1 &"}) {
			return okContent("Launched '" + program + "' in the background (via shell).")
		}
		return errContent("Failed to launch '" + program + "'.")

	case "install_package":
		pkg := strArg(args, "package_name", "")
		if pkg == "" {
			return errContent("install_package needs package_name")
		}
		prefix, _ := detectPackageManager()
		cmd := prefix + " " + pkg
		return runShell(cmd, 180, "")

	case "list_installed_apps":
		// Honour the 60s TTL instead of forcing a rebuild on every call:
		// a forced rebuild spawns flatpak and snap and reads every .desktop
		// file, and an agent typically calls this once per turn.
		catalog := getAppsCatalog(boolArg(args, "force_refresh", false))
		filter := strArg(args, "filter", "")
		if filter != "" {
			needle := strings.ToLower(filter)
			filtered := []map[string]any{}
			for _, a := range catalog {
				name, _ := a["name"].(string)
				gen, _ := a["generic_name"].(string)
				comment, _ := a["comment"].(string)
				if strings.Contains(strings.ToLower(name), needle) ||
					strings.Contains(strings.ToLower(gen), needle) ||
					strings.Contains(strings.ToLower(comment), needle) {
					filtered = append(filtered, a)
				}
			}
			catalog = filtered
		}
		if !boolArg(args, "verbose", false) {
			catalog = compactApps(catalog)
		}
		return okContent(jsonPretty(catalog))

	case "open_url":
		return openURL(args)

	case "open_app":
		return openApp(args)

	case "close_app":
		return closeApp(args)

	case "context_info":
		info := map[string]any{
			"tier": ctx.Tier, "model_name": ctx.ModelName, "model_host": ctx.ModelHost,
			"context_window": ctx.ContextWindow, "tool_budget_tokens": ctx.ToolBudget,
			"input_budget_tokens":     ctx.InputBudget,
			"tools_available_in_tier": tierNamesOr(ctx.Tier),
			"tier_budgets":            defaultToolResultBudget,
		}
		return okContent(jsonPretty(info))

	case "web_search":
		return webSearch(args, ctx)

	case "fetch_url":
		return fetchURL(args, ctx)

	case "manage_rag":
		return manageRag(args, ctx)

	case "manage_memory":
		return manageMemory(args)

	case "capabilities":
		return capabilities()

	case "clipboard":
		return clipboardTool(args)

	case "notify":
		return notifyTool(args)

	case "volume":
		return volumeTool(args)

	case "media":
		return mediaTool(args)

	case "screenshot":
		return screenshotTool(args)

	case "brightness":
		return brightnessTool(args)

	case "power":
		return powerTool(args)

	case "notifications":
		return notificationsTool(args)

	case "system_info":
		return systemInfo()

	case "timer":
		return timerTool(args)

	case "wallpaper":
		return wallpaperTool(args)

	case "recommend_model":
		return recommendModel(args)
	}

	return errContent("Tool '" + name + "' not found")
}

// shq quotes a string for safe use inside a bash -c command.
func shq(s string) string {
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}

func capabilities() map[string]any {
	groups := [][2]string{
		{"windows", "list_windows, focus_window, close_window, move_window_to_workspace, move_windows, move_window_direction, move_window_to_monitor, resize_window, toggle_window_floating, set_window_fullscreen"},
		{"workspaces", "list_workspaces, switch_workspace, move_window_to_workspace, move_windows, toggle_special_workspace"},
		{"monitors", "list_monitors, focus_monitor, move_window_to_monitor"},
		{"apps", "list_installed_apps, open_app, close_app, launch_program, check_program_installed, install_package"},
		{"web", "open_url, web_search, fetch_url, manage_rag"},
		{"system", "execute_command, run_shell_command, clipboard, notify, volume, media, screenshot, brightness, power, notifications, timer, wallpaper"},
		{"files", "list_dir, read_file, write_file, search_files"},
		{"info", "system_info, recommend_model, context_info, capabilities"},
		{"memory", "manage_memory"},
	}
	var sb strings.Builder
	sb.WriteString("NothingClaw can control this Linux desktop and the machine behind it.\nCapability groups:\n")
	for _, g := range groups {
		sb.WriteString("- " + g[0] + ": " + g[1] + "\n")
	}
	sb.WriteString("Read the current state (list_windows / list_workspaces) before acting, and verify after acting.")
	return okContent(sb.String())
}

func clipboardTool(args map[string]any) map[string]any {
	action := strings.ToLower(strArg(args, "action", "get"))
	switch action {
	case "get", "read":
		for _, c := range []string{"wl-paste -n", "xclip -selection clipboard -o", "xsel -b"} {
			r := runShell(c, 5, "")
			if r["error"] == nil {
				if s, _ := r["content"].(string); strings.TrimSpace(s) == "" {
					return okContent("(clipboard is empty)")
				}
				return r
			}
		}
		return errContent("No clipboard tool found (install wl-clipboard, xclip or xsel).")
	case "set", "write", "copy":
		text := strArg(args, "text", "")
		if text == "" {
			return errContent("clipboard 'set' needs text")
		}
		cmd := "printf '%s' " + shq(text) + " | wl-copy"
		alt := "printf '%s' " + shq(text) + " | xclip -selection clipboard"
		alt2 := "printf '%s' " + shq(text) + " | xsel -b -i"
		for _, c := range []string{cmd, alt, alt2} {
			if runShell(c, 5, "")["error"] == nil {
				return okContent("Copied to clipboard.")
			}
		}
		return errContent("No clipboard tool found.")
	}
	return errContent("clipboard action must be 'get' or 'set'")
}

func notifyTool(args map[string]any) map[string]any {
	body := strArg(args, "body", strArg(args, "text", ""))
	if body == "" {
		return errContent("notify needs body")
	}
	title := strArg(args, "title", "NothingClaw")
	urgency := strings.ToLower(strArg(args, "urgency", "normal"))
	switch urgency {
	case "low", "normal", "critical":
	default:
		urgency = "normal"
	}
	if fireAndForget([]string{"notify-send", "-u", urgency, title, body}) {
		return okContent("Notification sent.")
	}
	return errContent("notify-send not found (install libnotify).")
}

func clampPct(n int) int {
	if n < 0 {
		return 0
	}
	if n > 150 {
		return 150
	}
	return n
}

func volumeTool(args map[string]any) map[string]any {
	action := strings.ToLower(strArg(args, "action", "get"))
	if _, err := exec.LookPath("wpctl"); err == nil {
		switch action {
		case "get":
			return runShell("wpctl get-volume @DEFAULT_AUDIO_SINK@", 5, "")
		case "set":
			return runShell(fmt.Sprintf("wpctl set-volume @DEFAULT_AUDIO_SINK@ %d%%", clampPct(intArg(args, "value", 50))), 5, "")
		case "up":
			return runShell("wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%+", 5, "")
		case "down":
			return runShell("wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-", 5, "")
		case "mute":
			return runShell("wpctl set-mute @DEFAULT_AUDIO_SINK@ 1", 5, "")
		case "unmute":
			return runShell("wpctl set-mute @DEFAULT_AUDIO_SINK@ 0", 5, "")
		case "toggle":
			return runShell("wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle", 5, "")
		}
	}
	if _, err := exec.LookPath("pactl"); err == nil {
		switch action {
		case "get":
			return runShell("pactl get-sink-volume @DEFAULT_SINK@", 5, "")
		case "set":
			p := clampPct(intArg(args, "value", 50))
			return runShell(fmt.Sprintf("pactl set-sink-volume @DEFAULT_SINK@ %d%%", p), 5, "")
		case "up":
			return runShell("pactl set-sink-volume @DEFAULT_SINK@ +5%", 5, "")
		case "down":
			return runShell("pactl set-sink-volume @DEFAULT_SINK@ -5%", 5, "")
		case "mute":
			return runShell("pactl set-sink-mute @DEFAULT_SINK@ 1", 5, "")
		case "unmute":
			return runShell("pactl set-sink-mute @DEFAULT_SINK@ 0", 5, "")
		case "toggle":
			return runShell("pactl set-sink-mute @DEFAULT_SINK@ toggle", 5, "")
		}
	}
	return errContent("no volume control found (install wireplumber for wpctl or pulseaudio-utils for pactl).")
}

func mediaTool(args map[string]any) map[string]any {
	action := strings.ToLower(strArg(args, "action", "status"))
	switch action {
	case "play", "pause", "play-pause", "next", "previous", "stop", "status":
		return runShell("playerctl "+action, 5, "")
	}
	return errContent("media action must be play/pause/play-pause/next/previous/stop/status")
}

func screenshotTool(args map[string]any) map[string]any {
	path := strArg(args, "path", "/tmp/nothingclaw-screenshot.png")
	if _, err := exec.LookPath("grim"); err == nil {
		if r := runShell("grim "+shq(path), 15, ""); r["error"] == nil {
			return okContent("Screenshot saved to " + path)
		}
	}
	if _, err := exec.LookPath("maim"); err == nil {
		if r := runShell("maim "+shq(path), 15, ""); r["error"] == nil {
			return okContent("Screenshot saved to " + path)
		}
	}
	if _, err := exec.LookPath("scrot"); err == nil {
		if r := runShell("scrot "+shq(path), 15, ""); r["error"] == nil {
			return okContent("Screenshot saved to " + path)
		}
	}
	return errContent("no screenshot tool found (install grim for Wayland, or maim/scrot for X11).")
}

// guard converts a panic inside a tool handler into a normal tool error.
// The previous version deferred an empty function, which is not a recover:
// the panic unwound past it, run() returned a nil map, and the agent loop
// then handed the model the literal string "<nil>".
func guard(f func() map[string]any) (result map[string]any) {
	defer func() {
		if rec := recover(); rec != nil {
			result = map[string]any{
				"content": "",
				"error":   fmt.Sprintf("tool panicked: %v", rec),
			}
		}
	}()
	return f()
}

func toString(v any) string {
	if s, ok := v.(string); ok {
		return s
	}
	return fmt.Sprint(v)
}

func tierNamesOr(tier string) []string {
	if n, ok := tierNames[tier]; ok {
		return n
	}
	return tierNames["small"]
}

// ---- move_windows ----

func moveWindows(args map[string]any) map[string]any {
	type pair struct{ wid, ws string }
	var pairs []pair

	if assignments, ok := args["assignments"].([]any); ok {
		for _, item := range assignments {
			m, ok := item.(map[string]any)
			if !ok {
				continue
			}
			wid := strArg(m, "window_id", "")
			ws := strArg(m, "workspace_id", "")
			if wid != "" && ws != "" {
				pairs = append(pairs, pair{wid, resolveWorkspaceID(ws)})
			}
		}
	}

	if len(pairs) == 0 {
		if ws := strArg(args, "workspace_id", ""); ws != "" {
			resolved := resolveWorkspaceID(ws)
			if windowIDs, ok := args["window_ids"].([]any); ok {
				for _, wid := range windowIDs {
					if s := strings.TrimSpace(fmt.Sprint(wid)); s != "" && wid != nil {
						pairs = append(pairs, pair{s, resolved})
					}
				}
			}
			if len(pairs) == 0 {
				if appNames, ok := args["app_names"].([]any); ok && len(appNames) > 0 {
					lr := runAxctl([]string{"window", "list"}, 5*time.Second)
					if lr["error"] != nil {
						return lr
					}
					var windows []any
					_ = json.Unmarshal([]byte(toString(lr["content"])), &windows)
					needles := []string{}
					for _, n := range appNames {
						if s := strings.ToLower(strings.TrimSpace(fmt.Sprint(n))); s != "" && n != nil {
							needles = append(needles, s)
						}
					}
					for _, w := range windows {
						m, ok := w.(map[string]any)
						if !ok {
							continue
						}
						hays := []string{
							strings.ToLower(fmt.Sprint(m["app_id"])),
							strings.ToLower(fmt.Sprint(m["title"])),
							strings.ToLower(fmt.Sprint(m["wm_class"])),
						}
						hit := false
						for _, n := range needles {
							for _, h := range hays {
								if h != "" && strings.Contains(h, n) {
									hit = true
									break
								}
							}
							if hit {
								break
							}
						}
						if hit {
							if wid := m["id"]; wid != nil {
								pairs = append(pairs, pair{fmt.Sprint(wid), resolved})
							}
						}
					}
				}
			}
		}
	}

	if len(pairs) == 0 {
		_, hasAssign := args["assignments"].([]any)
		_, hasIDs := args["window_ids"].([]any)
		_, hasApps := args["app_names"].([]any)
		ws := strArg(args, "workspace_id", "")
		valid := hasAssign || (hasIDs && ws != "") || (hasApps && ws != "")
		if !valid {
			return errContent("move_windows needs one of: (a) 'assignments'; (b) 'window_ids' + 'workspace_id'; (c) 'app_names' + 'workspace_id'.")
		}
		return errContent("move_windows found no windows to move - check that the supplied window_ids or app_names match open windows (use list_windows to verify).")
	}

	prev := snapshotWorkspaces()
	if prev == nil {
		return errContent("move_windows could not snapshot window state before moving")
	}

	moved := []map[string]any{}
	failures := []map[string]any{}
	for _, p := range pairs {
		r := runAxctl([]string{"workspace", "move-to", p.ws, p.wid}, 5*time.Second)
		if r["error"] != nil {
			failures = append(failures, map[string]any{"window_id": p.wid, "workspace_id": p.ws,
				"previous_workspace_id": prev[p.wid], "error": r["error"]})
		} else {
			moved = append(moved, map[string]any{"window_id": p.wid, "workspace_id": p.ws,
				"previous_workspace_id": prev[p.wid]})
		}
	}

	// Verify, then retry once for stragglers.
	current := snapshotWorkspaces()
	verified := []map[string]any{}
	for _, e := range moved {
		wid := fmt.Sprint(e["window_id"])
		if actual, ok := current[wid]; ok && fmt.Sprint(actual) != fmt.Sprint(e["workspace_id"]) {
			failures = append(failures, map[string]any{"window_id": wid,
				"workspace_id": e["workspace_id"],
				"error":        "axctl reported Success but window is still on workspace " + fmt.Sprint(actual)})
		} else {
			verified = append(verified, e)
		}
	}
	moved = verified
	// Only pay the compositor settle delay when there is actually something to
	// re-check; the common all-success path used to block the handler 200ms
	// and then take a third snapshot for nothing.
	finalFailures := []map[string]any{}
	if len(failures) > 0 {
		time.Sleep(200 * time.Millisecond)
		retry := snapshotWorkspaces()
		for _, e := range failures {
			wid := fmt.Sprint(e["window_id"])
			if actual, ok := retry[wid]; ok && fmt.Sprint(actual) == fmt.Sprint(e["workspace_id"]) {
				moved = append(moved, map[string]any{"window_id": wid, "workspace_id": e["workspace_id"]})
			} else {
				finalFailures = append(finalFailures, e)
			}
		}
	}

	return okContent(jsonPretty(map[string]any{
		"requested": len(pairs), "moved": moved, "failed": finalFailures}))
}

func snapshotWorkspaces() map[string]any {
	lr := runAxctl([]string{"window", "list"}, 5*time.Second)
	if lr["error"] != nil {
		return nil
	}
	var windows []any
	if json.Unmarshal([]byte(toString(lr["content"])), &windows) != nil {
		return map[string]any{}
	}
	snap := map[string]any{}
	for _, w := range windows {
		if m, ok := w.(map[string]any); ok && m["id"] != nil {
			snap[fmt.Sprint(m["id"])] = m["workspace_id"]
		}
	}
	return snap
}

// wsListCache memoises the workspace list for a couple of seconds. Resolving
// a workspace by name used to spawn one `axctl workspace list` per lookup,
// which is N spawns for a batch move_windows call.
var (
	wsListMu     sync.Mutex
	wsListAt     time.Time
	wsListByName map[string]string
)

func workspaceIDByName() map[string]string {
	wsListMu.Lock()
	defer wsListMu.Unlock()
	if wsListByName != nil && time.Since(wsListAt) < 2*time.Second {
		return wsListByName
	}
	lr := runAxctl([]string{"workspace", "list"}, 5*time.Second)
	if lr["error"] != nil {
		return nil
	}
	var workspaces []any
	if json.Unmarshal([]byte(toString(lr["content"])), &workspaces) != nil {
		return nil
	}
	m := make(map[string]string, len(workspaces))
	for _, w := range workspaces {
		wm, ok := w.(map[string]any)
		if !ok {
			continue
		}
		wid := fmt.Sprint(wm["id"])
		if name := fmt.Sprint(wm["name"]); name != "" && name != "<nil>" {
			m[strings.ToLower(name)] = wid
		}
	}
	wsListByName = m
	wsListAt = time.Now()
	return m
}

func resolveWorkspaceID(ws string) string {
	s := strings.TrimSpace(ws)
	if s == "" {
		return ws
	}
	if _, err := parseUint8(s); err == nil {
		return s
	}
	if id, ok := workspaceIDByName()[strings.ToLower(s)]; ok && id != "" {
		return id
	}
	return ws
}

// ---- open_url / open_app / close_app ----

var urlAliases = map[string]string{
	"youtube": "https://www.youtube.com", "yt": "https://www.youtube.com",
	"youtu": "https://www.youtube.com", "youtubemusic": "https://music.youtube.com",
	"ytmusic": "https://music.youtube.com", "github": "https://github.com",
	"gh": "https://github.com", "gmail": "https://mail.google.com",
	"mail": "https://mail.google.com", "google": "https://www.google.com",
	"calendar": "https://calendar.google.com", "maps": "https://maps.google.com",
	"drive": "https://drive.google.com", "docs": "https://docs.google.com",
	"reddit": "https://www.reddit.com", "twitter": "https://twitter.com",
	"x": "https://twitter.com", "wikipedia": "https://wikipedia.org",
	"wiki": "https://wikipedia.org", "stackoverflow": "https://stackoverflow.com",
	"so": "https://stackoverflow.com", "chatgpt": "https://chat.openai.com",
	"gemini": "https://gemini.google.com", "perplexity": "https://www.perplexity.ai",
	"hackernews": "https://news.ycombinator.com", "hn": "https://news.ycombinator.com",
	"archwiki": "https://wiki.archlinux.org", "arch": "https://archlinux.org",
	"man": "https://man.archlinux.org", "aur": "https://aur.archlinux.org",
}

func openURL(args map[string]any) map[string]any {
	raw := strArg(args, "url", "")
	if raw == "" {
		return errContent("open_url needs a url argument")
	}
	key := strings.ToLower(raw)
	for _, prefix := range []string{"https://", "http://", "www."} {
		key = strings.TrimPrefix(key, prefix)
	}
	key = strings.SplitN(key, "/", 2)[0]
	resolved, ok := urlAliases[key]
	if !ok {
		if strings.Contains(key, ".") {
			resolved = raw
			if !strings.Contains(resolved, "://") {
				resolved = "https://" + resolved
			}
		} else {
			keys := []string{}
			for k := range urlAliases {
				keys = append(keys, k)
			}
			sort.Strings(keys)
			if len(keys) > 8 {
				keys = keys[:8]
			}
			return errContent("Unknown URL or alias '" + raw + "'. Pass a full URL or a known alias. Common aliases: " + strings.Join(keys, ", ") + ", ...")
		}
	}
	if _, err := exec.LookPath("xdg-open"); err != nil {
		for _, fb := range []string{"gio", "x-www-browser", "sensible-browser"} {
			if _, err := exec.LookPath(fb); err == nil {
				var argv []string
				if fb == "gio" {
					argv = []string{fb, "open", resolved}
				} else {
					argv = []string{fb, resolved}
				}
				if fireAndForget(argv) {
					return okContent("Dispatched '" + resolved + "' via " + fb + ".")
				}
			}
		}
		return errContent("xdg-open not found on PATH and no fallback is available. Install xdg-utils.")
	}
	if fireAndForget([]string{"xdg-open", resolved}) {
		return okContent("Dispatched '" + resolved + "' to the default browser.")
	}
	return errContent("xdg-open failed to launch. Try installing xdg-utils.")
}

func openApp(args map[string]any) map[string]any {
	query := strArg(args, "app_name", "")
	if query == "" {
		return errContent("open_app needs app_name")
	}
	catalog := getAppsCatalog(false)
	match := findApp(query, catalog)
	if match == nil {
		suggestions := []string{}
		q := strings.ToLower(query)
		prefix := q
		if len(prefix) > 3 {
			prefix = prefix[:3]
		}
		for _, e := range catalog {
			name, _ := e["name"].(string)
			if strings.Contains(strings.ToLower(name), prefix) {
				suggestions = append(suggestions, name)
			}
			if len(suggestions) >= 5 {
				break
			}
		}
		hint := ""
		if len(suggestions) > 0 {
			hint = " Did you mean: " + strings.Join(suggestions, ", ") + "?"
		}
		return errContent("No installed app matches '" + query + "'." + hint)
	}
	cmd, _ := match["command"].(string)
	cmd = stripExecPlaceholders(cmd)
	// Prefer exec'ing the parsed argv: an Exec= line that cannot be tokenised
	// (pipes, field codes, substitutions) goes to gio, which applies the
	// desktop-entry quoting rules for us instead of a hand-rolled shell.
	if argv, ok := shellWords(cmd); ok && fireAndForget(argv) {
		name, _ := match["name"].(string)
		source, _ := match["source"].(string)
		return okContent("Opened '" + name + "' (" + source + "). Use list_windows to see the new window.")
	}
	if _, err := exec.LookPath("gio"); err == nil && fireAndForget([]string{"gio", "launch", cmd}) {
		name, _ := match["name"].(string)
		source, _ := match["source"].(string)
		return okContent("Opened '" + name + "' (" + source + ") via gio. Use list_windows to see the new window.")
	}
	return errContent("Failed to launch: " + cmd)
}

func closeApp(args map[string]any) map[string]any {
	query := strArg(args, "app_name", "")
	needle := strings.ToLower(strings.TrimSpace(query))
	if needle == "" {
		return errContent("close_app needs app_name")
	}
	lr := runAxctl([]string{"window", "list"}, 5*time.Second)
	if lr["error"] != nil {
		return lr
	}
	var windows []any
	if json.Unmarshal([]byte(toString(lr["content"])), &windows) != nil {
		return errContent("Could not parse axctl output")
	}
	matches := []map[string]any{}
	for _, w := range windows {
		m, ok := w.(map[string]any)
		if !ok {
			continue
		}
		hays := []string{
			strings.ToLower(fmt.Sprint(m["app_id"])),
			strings.ToLower(fmt.Sprint(m["title"])),
			strings.ToLower(fmt.Sprint(m["wm_class"])),
		}
		for _, h := range hays {
			if h != "" && strings.Contains(h, needle) {
				matches = append(matches, m)
				break
			}
		}
	}
	if len(matches) == 0 {
		return errContent("No open window matches '" + query + "'. Try list_windows to see what's running.")
	}
	closed := []map[string]any{}
	failures := []map[string]any{}
	for _, w := range matches {
		wid := w["id"]
		if wid == nil {
			continue
		}
		r := runAxctl([]string{"window", "close", fmt.Sprint(wid)}, 5*time.Second)
		if r["error"] != nil {
			failures = append(failures, map[string]any{"id": wid, "title": w["title"], "error": r["error"]})
		} else {
			closed = append(closed, map[string]any{"id": wid, "title": w["title"], "app_id": w["app_id"]})
		}
	}
	return okContent(jsonPretty(map[string]any{"closed": closed, "failed": failures, "matched": len(matches)}))
}

// ---- manage_memory ----

func manageMemory(args map[string]any) map[string]any {
	_ = os.MkdirAll(memDir(), 0o755)
	memPath := filepath.Join(memDir(), "nothingclaw_memory.json")
	action := strArg(args, "action", "")
	if action == "" || (action != "set" && action != "get" && action != "delete" && action != "list") {
		return errContent("manage_memory needs action=set|get|delete|list")
	}
	store := map[string]any{}
	if data, err := os.ReadFile(memPath); err == nil {
		_ = json.Unmarshal(data, &store)
	}
	switch action {
	case "list":
		if len(store) == 0 {
			return okContent("Memory is empty.")
		}
		keys := make([]string, 0, len(store))
		for k := range store {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		lines := []string{fmt.Sprintf("Memory entries (%d):", len(store))}
		for _, k := range keys {
			vs := fmt.Sprint(store[k])
			if len(vs) > 120 {
				vs = vs[:117] + "..."
			}
			lines = append(lines, "  "+k+" = "+vs)
		}
		return okContent(strings.Join(lines, "\n"))
	case "get":
		key := strArg(args, "key", "")
		if key == "" {
			return errContent("manage_memory get needs key")
		}
		v, ok := store[key]
		if !ok {
			return errContent("Key '" + key + "' not found")
		}
		out, _ := json.Marshal(v)
		return okContent(string(out))
	case "set":
		key := strArg(args, "key", "")
		if key == "" {
			return errContent("manage_memory set needs key")
		}
		value := strArg(args, "value", "")
		store[key] = map[string]any{"value": value, "updated_at": time.Now().Format("2006-01-02T15:04:05")}
		if err := writeJSONFile(memPath, store); err != nil {
			return errContent("Memory write failed: " + err.Error())
		}
		return okContent(key + " = " + value)
	case "delete":
		key := strArg(args, "key", "")
		if key == "" {
			return errContent("manage_memory delete needs key")
		}
		if _, ok := store[key]; !ok {
			return errContent("Key '" + key + "' not found")
		}
		delete(store, key)
		if err := writeJSONFile(memPath, store); err != nil {
			return errContent("Memory write failed: " + err.Error())
		}
		return okContent("Deleted: " + key)
	}
	return errContent("Unknown action")
}

func writeJSONFile(path string, v any) error {
	data, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, data, 0o644)
}
