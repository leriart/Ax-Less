// NothingClaw MCP bridge - HTTP server, ported from server.py.
//
// Exposes the HTTP-bridge contract the shell understands:
//
//	GET  /tools   -> tool definitions (tiered / ranked)
//	POST /tools   -> { "name", "arguments" } -> { "content", "error" }
//	GET  /agent/models
//	POST /agent   -> run the autonomous loop
//
// The desktop tools wrap axctl; the knowledge tools (web_search, fetch_url,
// manage_rag, context_info) are capability-aware and size their output to the
// requesting model's tier. Pure standard library.
package main

import (
	"encoding/json"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

var axctl = envDefault("NOTHINGCLAW_AXCTL", "/usr/local/bin/axctl")

func xdgDataHome() string {
	if v := os.Getenv("XDG_DATA_HOME"); v != "" {
		return v
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".local", "share")
}

func memDir() string { return filepath.Join(xdgDataHome(), "ambxst") }

// ---- tool schema helpers ----

func tStr(d string) map[string]any { return map[string]any{"type": "string", "description": d} }
func tStrEnum(vals []string, d string) map[string]any {
	return map[string]any{"type": "string", "enum": vals, "description": d}
}
func tBool(d string) map[string]any { return map[string]any{"type": "boolean", "description": d} }
func tInt(d string) map[string]any  { return map[string]any{"type": "integer", "description": d} }
func tArr(items map[string]any, d string) map[string]any {
	return map[string]any{"type": "array", "items": items, "description": d}
}
func tObj(props map[string]any, required ...string) map[string]any {
	if required == nil {
		required = []string{}
	}
	return map[string]any{"type": "object", "properties": props,
		"required": required, "additionalProperties": false}
}

// ---- tiers ----

var toolTiers = map[string][]string{
	"tiny": {
		"manage_memory", "list_windows", "list_installed_apps",
		"move_window_to_workspace", "open_url", "execute_command",
		"run_shell_command", "context_info",
	},
	"small": {
		"list_workspaces", "move_windows", "open_app", "close_app",
		"web_search", "fetch_url", "manage_rag",
	},
	"medium": {
		"list_monitors", "focus_window", "close_window", "switch_workspace",
		"move_window_to_monitor", "list_dir", "read_file", "write_file",
		"search_files",
	},
}

var tierNames = map[string][]string{
	"tiny": toolTiers["tiny"],
	"small": concat(toolTiers["tiny"], toolTiers["small"]),
	"medium": concat(concat(toolTiers["tiny"], toolTiers["small"]), toolTiers["medium"]),
}

func concat(a, b []string) []string {
	out := make([]string, 0, len(a)+len(b))
	out = append(out, a...)
	out = append(out, b...)
	return out
}

// ---- tool catalogue ----

func allTools() []map[string]any {
	tools := []map[string]any{
		{"name": "list_windows",
			"description": "List every window the compositor knows about. Returns JSON with id, title, app_id, workspace_id, is_focused, is_floating, is_fullscreen, monitor_id, pinned and geometry. Call this before focus_window / close_window / move_window_to_workspace when you need to look up an app's window id by name.",
			"parameters":  tObj(map[string]any{})},
		{"name": "list_workspaces",
			"description": "List every workspace with id, name, monitor_id, is_active and is_empty.",
			"parameters":  tObj(map[string]any{})},
		{"name": "list_monitors",
			"description": "List every connected monitor with id, name, description, width, height, refresh_rate, is_focused and is_active.",
			"parameters":  tObj(map[string]any{})},
		{"name": "focus_window",
			"description": "Bring a window to focus. Pass either `window_id` (use list_windows to look it up) OR `direction` (one of l/r/u/d) to focus the neighbour in that direction.",
			"parameters": tObj(map[string]any{
				"window_id": tStr("Window id (e.g. '0x55c18cfa9170'). Omit when using direction."),
				"direction": tStrEnum([]string{"l", "r", "u", "d"}, "Direction to focus when window_id is omitted."),
			})},
		{"name": "close_window",
			"description": "Close a window. Omit window_id to close the currently focused window.",
			"parameters":  tObj(map[string]any{"window_id": tStr("Window id. Omit to close the active window.")})},
		{"name": "toggle_window_floating",
			"description": "Toggle a window between tiled and floating. Omit window_id to target the active window.",
			"parameters":  tObj(map[string]any{"window_id": tStr("Window id. Omit to target the active window.")})},
		{"name": "set_window_fullscreen",
			"description": "Set fullscreen state on a window (true = fullscreen, false = windowed).",
			"parameters": tObj(map[string]any{
				"state":     tBool("True to enter fullscreen, false to leave it."),
				"window_id": tStr("Window id. Omit to target the active window."),
			}, "state")},
		{"name": "resize_window",
			"description": "Resize a window in pixels. The compositor applies the size hint to the active or specified window.",
			"parameters": tObj(map[string]any{
				"width":     tInt("New width in pixels."),
				"height":    tInt("New height in pixels."),
				"window_id": tStr("Window id. Omit to target the active window."),
			}, "width", "height")},
		{"name": "move_window_direction",
			"description": "Move the active (or specified) window in a cardinal direction. Useful for swapping positions in the tiling layout.",
			"parameters": tObj(map[string]any{
				"direction": tStrEnum([]string{"l", "r", "u", "d"}, "Direction to swap with."),
				"window_id": tStr("Window id. Omit to target the active window."),
			}, "direction")},
		{"name": "switch_workspace",
			"description": "Switch the focused workspace.",
			"parameters":  tObj(map[string]any{"workspace_id": tStr("Target workspace id (e.g. '1', '4', or a name).")}, "workspace_id")},
		{"name": "move_window_to_workspace",
			"description": "Move a window to a different workspace. Omit window_id to move the currently focused window.",
			"parameters": tObj(map[string]any{
				"workspace_id": tStr("Target workspace id."),
				"window_id":    tStr("Window id. Omit to move the active window."),
			}, "workspace_id")},
		{"name": "move_windows",
			"description": "Move one or more windows to one or more workspaces in a single batch operation. Two modes are supported, mutually exclusive:\n  (1) MANY-TO-ONE - provide `workspace_id` together with EITHER `window_ids` OR `app_names`. Every matching window is moved to the same target workspace.\n  (2) MANY-TO-MANY - provide `assignments`, a list of {window_id, workspace_id} pairs. Each window is moved to its own target workspace in one call.\nReturns JSON with a `moved` list, a `failed` list and the number attempted. A failure on one window does NOT abort the rest.",
			"parameters": tObj(map[string]any{
				"window_ids": tArr(tStr("Window id, e.g. '0x55c18cfa9170'."), "List of explicit window ids to move. Used only in many-to-one mode."),
				"app_names":  tArr(tStr("Substring to match against window.app_id, window.title or window.wm_class (case-insensitive)."), "Alternative to window_ids. Used only in many-to-one mode."),
				"workspace_id": tStr("Single target workspace id. Required when using window_ids or app_names."),
				"assignments": tArr(tObj(map[string]any{
					"window_id":    tStr("Window id to move."),
					"workspace_id": tStr("Target workspace id for this window."),
				}, "window_id", "workspace_id"), "Per-window target list for many-to-many mode."),
			})},
		{"name": "toggle_special_workspace",
			"description": "Toggle a Hyprland 'special' workspace by name (typically 'scratchpad' or a custom name).",
			"parameters":  tObj(map[string]any{"name": tStr("Special workspace name, e.g. 'scratchpad'.")}, "name")},
		{"name": "focus_monitor",
			"description": "Focus a monitor by id. The currently focused window follows focus.",
			"parameters":  tObj(map[string]any{"monitor_id": tStr("Monitor id (e.g. 'HDMI-A-1', '0').")}, "monitor_id")},
		{"name": "move_window_to_monitor",
			"description": "Move a window to a different monitor.",
			"parameters": tObj(map[string]any{
				"monitor_id": tStr("Target monitor id."),
				"window_id":  tStr("Window id. Omit to target the active window."),
			}, "monitor_id")},
		{"name": "set_layout",
			"description": "Set the active tiling layout (e.g. 'dwindle', 'master', 'spiral' - exact names depend on the compositor).",
			"parameters":  tObj(map[string]any{"name": tStr("Layout name.")}, "name")},
		{"name": "execute_command",
			"description": "Run a command through the compositor's IPC layer (so it is dispatched the same way a keybind would). Use for compositor actions. For ordinary shell work prefer run_shell_command.",
			"parameters":  tObj(map[string]any{"command": tStr("Command to execute.")}, "command")},
		{"name": "run_shell_command",
			"description": "Run a shell command directly and return its stdout and stderr. Use this for real machine work: finding files, inspecting processes, querying disk. cwd is confined to the home directory.",
			"parameters": tObj(map[string]any{
				"command": tStr("Shell command to run."),
				"cwd":     tStr("Working directory, relative to home. Default home."),
				"timeout": tInt("Seconds before giving up. Default 30, max 300."),
			}, "command")},
		{"name": "check_program_installed",
			"description": "Check whether a program is on PATH and return its absolute path.",
			"parameters":  tObj(map[string]any{"program_name": tStr("Program name to look up on $PATH.")}, "program_name")},
		{"name": "launch_program",
			"description": "Launch a GUI application in the background (`nohup <program> &`). Use for opening apps the user already has installed.",
			"parameters":  tObj(map[string]any{"program_name": tStr("Executable name on $PATH, optionally with arguments.")}, "program_name")},
		{"name": "install_package",
			"description": "Install a system package via the distro's package manager (pacman / dnf / apt). Requires sudo without a password prompt; if sudo fails, the tool returns the exact command so the user can run it themselves.",
			"parameters":  tObj(map[string]any{"package_name": tStr("Package name as known by the package manager.")}, "package_name")},
		{"name": "list_installed_apps",
			"description": "List every GUI application installed on this system. Aggregates .desktop files, flatpak exports, snaps and *.AppImage files. Returns JSON with id, name, source and command.",
			"parameters":  tObj(map[string]any{"filter": tStr("Optional case-insensitive substring filter against name / generic_name / comment.")})},
		{"name": "open_url",
			"description": "Open a URL in the user's default browser via xdg-open. USE THIS for any 'open X in browser' request. Accepts full URLs or short aliases ('youtube', 'github', 'gmail'). Do NOT use open_app for URLs.",
			"parameters":  tObj(map[string]any{"url": tStr("URL or short alias.")}, "url")},
		{"name": "open_app",
			"description": "Open a NATIVE GUI application by name. Searches the installed-apps catalog and launches the matching entry. PREFER THIS OVER launch_program for GUI apps. FOR URLs use open_url instead.",
			"parameters":  tObj(map[string]any{"app_name": tStr("App display name. Case-insensitive substring match. DO NOT pass URLs here.")}, "app_name")},
		{"name": "close_app",
			"description": "Close every window belonging to an app by name. Lists windows via axctl, filters by app_id or title match, then closes each match.",
			"parameters":  tObj(map[string]any{"app_name": tStr("App name or window title substring (case-insensitive).")}, "app_name")},
		{"name": "manage_memory",
			"description": "Persistent key-value memory for the agent. Survives bridge restarts. Actions: 'set', 'get', 'delete', 'list'. File-backed in ~/.local/share/ambxst/nothingclaw_memory.json.",
			"parameters": tObj(map[string]any{
				"action": tStrEnum([]string{"set", "get", "delete", "list"}, "Memory action to perform."),
				"key":    tStr("Memory key (set/get/delete)."),
				"value":  tStr("Memory value (set only)."),
			}, "action")},
		{"name": "web_search",
			"description": "Search the public web and return the top results as title + snippet + URL. Backed by SearXNG when configured or DuckDuckGo HTML otherwise. The result size is automatically capped to the requesting model's tier. Pass max_results to override.",
			"parameters": tObj(map[string]any{
				"query":       tStr("Search query. Be specific."),
				"max_results": tInt("Maximum number of results to return."),
				"time_filter": tStrEnum([]string{"day", "week", "month", "year"}, "Optional freshness filter."),
				"region":      tStr("Optional SearXNG region code."),
			}, "query")},
		{"name": "fetch_url",
			"description": "Download a URL and return its readable content as plain text. Strips scripts, styles, navigation and HTML chrome. Hard-capped at 1.5 MB raw download. ALWAYS fetch_url a page before summarising it.",
			"parameters": tObj(map[string]any{
				"url":       tStr("The URL to fetch. Must start with http:// or https://. localhost / private ranges / file:// are BLOCKED."),
				"max_bytes": tInt("Maximum bytes to download (default 1.5 MB)."),
				"full":      tBool("Return the entire body without any tier-based truncation."),
			}, "url")},
		{"name": "manage_rag",
			"description": "Manage a lightweight, dependency-free RAG index of local files. Index a directory once with add_directory, then call 'search' repeatedly. Backed by a plain JSON index with TF-IDF scoring.",
			"parameters": tObj(map[string]any{
				"action":          tStrEnum([]string{"list", "add_directory", "remove_directory", "search"}, "Action to perform."),
				"directory":       tStr("Directory path (for add/remove)."),
				"query":           tStr("Search query (for 'search' action)."),
				"top_k":           tInt("Maximum chunks to return for 'search' (default 5)."),
				"max_chunk_chars": tInt("Maximum characters per chunk when indexing (default 1200)."),
			}, "action")},
		{"name": "context_info",
			"description": "Return metadata about the current request - the model's detected capability tier, its known context window, and the per-tool-result token budget. Call this FIRST in any long chain of tool calls.",
			"parameters":  tObj(map[string]any{})},
	}
	return append(tools, fsTools()...)
}

var cachedTools []map[string]any

func toolsList() []map[string]any {
	if cachedTools == nil {
		cachedTools = allTools()
	}
	return cachedTools
}

// ---- intent map / domain tools (tool ranking) ----

var intentMap = map[string]string{
	"mover": "move", "mueve": "move", "movido": "move", "mueva": "move",
	"moveme": "move", "movelo": "move",
	"abrir": "open", "abre": "open", "cerrar": "close", "cierra": "close",
	"cierre": "close", "navegador": "browser", "browser": "browser",
	"web": "browser", "internet": "browser", "buscar": "search",
	"busca": "search", "ventana": "window", "ventanas": "window",
	"workspace": "workspace", "workspaces": "workspace", "escritorio": "workspace",
	"pantalla": "monitor", "monitor": "monitor", "monitores": "monitor",
	"programa": "app", "app": "app", "apps": "app", "aplicacion": "app",
	"aplicaciones": "app", "url": "url", "link": "url", "enlace": "url",
	"pagina": "url", "lista": "list", "listar": "list",
	"instalado": "installed", "instalada": "installed", "instalados": "installed",
	"instaladas": "installed", "paquete": "package", "paquetes": "package",
	"instalar": "install", "instala": "install", "comando": "command",
	"ejecutar": "execute", "ejecuta": "execute", "correr": "execute",
	"tema": "layout", "layout": "layout", "flotante": "floating",
	"flotar": "floating", "completa": "fullscreen", "completo": "fullscreen",
	"fullscreen": "fullscreen", "tamano": "resize", "resize": "resize",
	"foco": "focus", "enfocar": "focus", "enfoca": "focus",
	"direccion": "direction", "arriba": "direction", "abajo": "direction",
	"izquierda": "direction", "derecha": "direction", "especial": "special",
	"scratchpad": "special", "cambiar": "switch", "cambia": "switch",
	"todos": "all", "varios": "batch", "batch": "batch",
	"multiple": "batch", "multiples": "batch",
}

var domainTools = map[string][]string{
	"window": {"list_windows", "focus_window", "close_window",
		"move_window_to_workspace", "move_windows", "move_window_direction",
		"move_window_to_monitor", "toggle_window_floating",
		"set_window_fullscreen", "resize_window"},
	"workspace": {"list_workspaces", "switch_workspace",
		"move_window_to_workspace", "move_windows", "toggle_special_workspace"},
	"monitor": {"list_monitors", "focus_monitor", "move_window_to_monitor"},
	"app":     {"list_installed_apps", "open_app", "close_app", "launch_program", "check_program_installed"},
	"url":     {"open_url", "execute_command"},
	"system":  {"execute_command", "check_program_installed", "launch_program", "install_package", "run_shell_command"},
	"layout":  {"set_layout", "toggle_window_floating", "set_window_fullscreen", "resize_window"},
	"batch":   {"move_windows", "close_app"},
}

var toolWordIndex map[string]map[string]bool

var reWord = regexp.MustCompile(`[a-z_][a-z_0-9]{2,}`)

func buildToolIndex() {
	if toolWordIndex != nil {
		return
	}
	toolWordIndex = map[string]map[string]bool{}
	for _, t := range toolsList() {
		name, _ := t["name"].(string)
		desc, _ := t["description"].(string)
		text := strings.ToLower(name + " " + desc)
		words := map[string]bool{}
		for _, w := range reWord.FindAllString(text, -1) {
			words[w] = true
		}
		for _, part := range strings.Split(name, "_") {
			if len(part) >= 3 {
				words[part] = true
			}
		}
		toolWordIndex[name] = words
	}
}

var reAlnum = regexp.MustCompile(`[a-z0-9]{2,}`)

func rankToolsByQuery(query string, topK int) []string {
	buildToolIndex()
	if len(toolWordIndex) == 0 || query == "" {
		if query == "" {
			out := []string{}
			for _, t := range toolsList() {
				n, _ := t["name"].(string)
				out = append(out, n)
			}
			return out
		}
		out := []string{}
		for _, t := range toolsList() {
			n, _ := t["name"].(string)
			out = append(out, n)
			if len(out) >= topK {
				break
			}
		}
		return out
	}

	raw := strings.ToLower(strings.TrimSpace(query))
	qwords := map[string]bool{}
	for _, w := range reAlnum.FindAllString(raw, -1) {
		qwords[w] = true
	}
	for w := range qwords {
		if exp, ok := intentMap[w]; ok {
			qwords[exp] = true
		}
	}

	domainKeywords := map[string][]string{
		"window":    {"window", "move", "focus", "close", "resize", "float", "mover", "ventana", "mueve"},
		"workspace": {"workspace", "switch", "desktop", "escritorio"},
		"monitor":   {"monitor", "screen", "pantalla", "display"},
		"app":       {"app", "open", "close", "launch", "install", "abrir", "abre", "programa", "aplicacion"},
		"url":       {"url", "link", "browser", "navegador", "web", "pagina", "http"},
		"system":    {"exec", "shell", "command", "run", "comando", "ejecutar"},
		"layout":    {"layout", "theme", "tema"},
		"batch":     {"batch", "all", "multiple", "todos", "varios", "multiples"},
	}
	activeDomains := map[string]bool{}
	for domain, kws := range domainKeywords {
		for _, kw := range kws {
			if qwords[kw] {
				activeDomains[domain] = true
				break
			}
		}
	}

	type scored struct {
		name  string
		score int
	}
	var scores []scored
	for name, words := range toolWordIndex {
		score := 0
		for w := range qwords {
			if words[w] {
				score++
			}
		}
		for _, part := range strings.Split(name, "_") {
			if qwords[part] {
				score += 3
			}
		}
		for domain := range activeDomains {
			for _, dn := range domainTools[domain] {
				if dn == name {
					score += 2
				}
			}
		}
		if score > 0 {
			scores = append(scores, scored{name, score})
		}
	}
	sort.Slice(scores, func(i, j int) bool {
		if scores[i].score != scores[j].score {
			return scores[i].score > scores[j].score
		}
		return scores[i].name < scores[j].name
	})
	out := []string{}
	for i, s := range scores {
		if i >= topK {
			break
		}
		out = append(out, s.name)
	}
	return out
}

// ---- capability detection ----

var cloudModelHints = map[string]string{
	"gpt-5": "large", "gpt-4o": "large", "gpt-4-turbo": "large", "gpt-4": "large",
	"o1-preview": "large", "o1-mini": "medium", "o3-mini": "medium", "gpt-3.5-turbo": "medium",
	"claude-3-opus": "large", "claude-3.5-sonnet": "large", "claude-3-sonnet": "medium",
	"claude-3.5-haiku": "medium", "claude-3-haiku": "medium",
	"gemini-1.5-pro": "large", "gemini-1.5-flash": "medium", "gemini-2.0-pro": "large",
	"gemini-2.0-flash": "medium", "mistral-large": "large", "mistral-medium": "medium",
	"mistral-small": "medium", "mixtral-8x7b": "medium", "llama-3.1-70b": "large",
	"llama-3.1-405b": "large", "deepseek-chat": "large", "deepseek-reasoner": "large",
	"deepseek-coder": "medium",
}

var ollamaShowCache = map[string]struct {
	ts   time.Time
	data map[string]any
}{}

func ollamaShow(modelName, endpoint string) map[string]any {
	if modelName == "" {
		return nil
	}
	key := strings.ToLower(strings.TrimSpace(modelName)) + "|" + strings.ToLower(strings.TrimSpace(endpoint))
	if c, ok := ollamaShowCache[key]; ok && time.Since(c.ts) < 300*time.Second {
		return c.data
	}
	body, _ := json.Marshal(map[string]any{"name": modelName})
	client := &http.Client{Timeout: 4 * time.Second}
	resp, err := client.Post(strings.TrimRight(endpoint, "/")+"/api/show", "application/json", strings.NewReader(string(body)))
	if err != nil {
		return nil
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	var data map[string]any
	if err := json.Unmarshal(raw, &data); err != nil || data["error"] != nil {
		return nil
	}
	ollamaShowCache[key] = struct {
		ts   time.Time
		data map[string]any
	}{time.Now(), data}
	return data
}

var reParamSize = regexp.MustCompile(`^\s*(\d+(?:\.\d+)?)\s*([BMK]?)\s*$`)

func parseOllamaParamSize(s string) (float64, bool) {
	if s == "" {
		return 0, false
	}
	m := reParamSize.FindStringSubmatch(strings.ToUpper(strings.TrimSpace(s)))
	if m == nil {
		return 0, false
	}
	val, _ := strconv.ParseFloat(m[1], 64)
	switch m[2] {
	case "M":
		return val / 1000.0, true
	case "K":
		return val / 1000000.0, true
	}
	return val, true
}

func paramsToTier(p float64, ok bool) string {
	if !ok {
		return ""
	}
	switch {
	case p <= 3:
		return "tiny"
	case p <= 13:
		return "small"
	case p <= 30:
		return "medium"
	default:
		return "large"
	}
}

var reSizeSuffix = regexp.MustCompile(`(\d+(?:\.\d+)?)\s*([bm])\b`)

func detectCapability(modelName, host string) string {
	if modelName == "" {
		return "small"
	}
	nameLower := strings.ToLower(strings.TrimSpace(modelName))
	for needle, tier := range cloudModelHints {
		if strings.Contains(nameLower, needle) {
			return tier
		}
	}

	ollamaEndpoint := "http://127.0.0.1:11434"
	if host != "" && strings.Contains(host, "11434") {
		ollamaEndpoint = host
	}
	skip := false
	for _, p := range []string{"gpt-", "claude", "gemini", "mistral-", "groq/",
		"deepseek-chat", "deepseek-reasoner", "minimax", "/v1", "openai.com", "anthropic.com"} {
		if strings.Contains(nameLower, p) {
			skip = true
			break
		}
	}
	if !skip {
		if show := ollamaShow(modelName, ollamaEndpoint); show != nil {
			details, _ := show["details"].(map[string]any)
			sizeStr := ""
			if details != nil {
				sizeStr, _ = details["parameter_size"].(string)
			}
			if p, ok := parseOllamaParamSize(sizeStr); ok {
				if tier := paramsToTier(p, true); tier != "" {
					return tier
				}
			}
		}
	}

	if m := reSizeSuffix.FindStringSubmatch(nameLower); m != nil {
		size, _ := strconv.ParseFloat(m[1], 64)
		params := size
		if m[2] == "m" {
			params = size / 1000.0
		}
		return paramsToTier(params, true)
	}

	for _, p := range []string{"ollama", "llama.cpp", "llamacpp", "lm-studio",
		"lmstudio", "kobold", "oobabooga", "local"} {
		if strings.Contains(nameLower, p) {
			return "small"
		}
	}
	return "small"
}

func filterToolsForCapability(tier string) []map[string]any {
	if tier == "" || tier == "large" {
		return toolsList()
	}
	names, ok := tierNames[tier]
	if !ok {
		return toolsList()
	}
	set := map[string]bool{}
	for _, n := range names {
		set[n] = true
	}
	out := []map[string]any{}
	for _, t := range toolsList() {
		if set[t["name"].(string)] {
			out = append(out, t)
		}
	}
	return out
}

// (helpers, app catalog, web/rag and the dispatcher live in server_tools.go)
