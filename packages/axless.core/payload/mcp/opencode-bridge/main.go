// Command opencode-bridge is the Go port of the mod's OpenCode adapter.
//
// `opencode serve` exposes a full agent API but it does not speak the protocol
// the shell's HttpAgentClient understands, which is:
//
//	GET  <endpoint><toolsPath>   -> [ {name, description, parameters} ]
//	POST <endpoint><invokePath>  -> { "name": ..., "arguments": {...} }
//	                                -> { "content": ..., "error": null }
//
// This adapter publishes a curated subset of the OpenCode API as bridge tools
// and forwards each call to the documented endpoint. Only read/search
// primitives plus a shell escape hatch; session turn-taking is left out.
//
// OPENCODE_SERVER_PASSWORD turns on HTTP basic auth, with the username
// defaulting to "opencode". Standard library only.
package main

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"strings"
	"sync"
	"syscall"
	"time"
)

var (
	upstream   = strings.TrimRight(envOr("OPENCODE_BRIDGE_UPSTREAM", "http://127.0.0.1:4096"), "/")
	listenHost = envOr("OPENCODE_BRIDGE_HOST", "127.0.0.1")
	listenPort = envOr("OPENCODE_BRIDGE_PORT", "8791")

	sessionMu sync.Mutex
	sessionID string
)

func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func authHeader() string {
	password := os.Getenv("OPENCODE_SERVER_PASSWORD")
	if password == "" {
		return ""
	}
	user := envOr("OPENCODE_SERVER_USERNAME", "opencode")
	token := base64.StdEncoding.EncodeToString([]byte(user + ":" + password))
	return "Basic " + token
}

// request calls the upstream and returns (payload, error).
func request(method, path string, params map[string]any, body any) (any, string) {
	target := upstream + path
	if len(params) > 0 {
		q := url.Values{}
		for k, v := range params {
			if v == nil {
				continue
			}
			q.Set(k, fmt.Sprintf("%v", v))
		}
		if enc := q.Encode(); enc != "" {
			target += "?" + enc
		}
	}

	var reader io.Reader
	if body != nil {
		enc, err := json.Marshal(body)
		if err != nil {
			return nil, err.Error()
		}
		reader = strings.NewReader(string(enc))
	}

	req, err := http.NewRequest(method, target, reader)
	if err != nil {
		return nil, err.Error()
	}
	req.Header.Set("Accept", "application/json")
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	if a := authHeader(); a != "" {
		req.Header.Set("Authorization", a)
	}

	client := &http.Client{Timeout: 30 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		var uerr *url.Error
		if errors.As(err, &uerr) {
			return nil, fmt.Sprintf("cannot reach opencode at %s (%v). Is `opencode serve` running?", upstream, uerr.Err)
		}
		return nil, err.Error()
	}
	defer resp.Body.Close()

	raw, _ := io.ReadAll(resp.Body)
	if resp.StatusCode >= 400 {
		detail := string(raw)
		if len(detail) > 300 {
			detail = detail[:300]
		}
		return nil, fmt.Sprintf("opencode HTTP %d on %s: %s", resp.StatusCode, path, detail)
	}
	if strings.TrimSpace(string(raw)) == "" {
		return map[string]any{}, ""
	}
	var out any
	if err := json.Unmarshal(raw, &out); err != nil {
		return nil, fmt.Sprintf("non-JSON response from %s", path)
	}
	return out, ""
}

func ensureSession() (string, string) {
	sessionMu.Lock()
	defer sessionMu.Unlock()
	if sessionID != "" {
		return sessionID, ""
	}
	payload, err := request("POST", "/session", nil, map[string]any{})
	if err != "" {
		return "", err
	}
	if m, ok := payload.(map[string]any); ok {
		if id, ok := m["id"].(string); ok {
			sessionID = id
		} else if info, ok := m["info"].(map[string]any); ok {
			if id, ok := info["id"].(string); ok {
				sessionID = id
			}
		}
	}
	if sessionID == "" {
		return "", "opencode did not return a session id"
	}
	return sessionID, ""
}

func text(v any) string {
	if s, ok := v.(string); ok {
		return s
	}
	enc, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return fmt.Sprintf("%v", v)
	}
	return string(enc)
}

type result = map[string]any

func ok(v any) result { return result{"content": text(v), "error": nil} }
func fail(msg string) result {
	return result{"content": "", "error": msg}
}

func argString(args map[string]any, key string) string {
	if v, ok := args[key].(string); ok {
		return v
	}
	return ""
}

// ---- tools ----

func tHealth(args map[string]any) result {
	p, err := request("GET", "/global/health", nil, nil)
	if err != "" {
		return fail(err)
	}
	return ok(p)
}

func tListFiles(args map[string]any) result {
	path := argString(args, "path")
	if path == "" {
		path = "."
	}
	p, err := request("GET", "/file", map[string]any{"path": path}, nil)
	if err != "" {
		return fail(err)
	}
	return ok(p)
}

func tReadFile(args map[string]any) result {
	path := argString(args, "path")
	if path == "" {
		return fail("read_file needs 'path'")
	}
	p, err := request("GET", "/file/content", map[string]any{"path": path}, nil)
	if err != "" {
		return fail(err)
	}
	if m, isMap := p.(map[string]any); isMap {
		body, _ := m["content"].(string)
		meta := map[string]any{}
		for k, v := range m {
			if k != "content" {
				meta[k] = v
			}
		}
		if len(meta) > 0 {
			body += "\n\n[meta] " + text(meta)
		}
		return result{"content": body, "error": nil}
	}
	return ok(p)
}

func tFindInFiles(args map[string]any) result {
	pattern := argString(args, "pattern")
	if pattern == "" {
		return fail("find_in_files needs 'pattern'")
	}
	p, err := request("GET", "/find", map[string]any{"pattern": pattern}, nil)
	if err != "" {
		return fail(err)
	}
	return ok(p)
}

func tFindFiles(args map[string]any) result {
	query := argString(args, "query")
	if query == "" {
		return fail("find_files needs 'query'")
	}
	params := map[string]any{"query": query}
	for _, k := range []string{"type", "directory", "limit"} {
		if v, present := args[k]; present {
			params[k] = v
		}
	}
	p, err := request("GET", "/find/file", params, nil)
	if err != "" {
		return fail(err)
	}
	return ok(p)
}

func tFindSymbols(args map[string]any) result {
	query := argString(args, "query")
	if query == "" {
		return fail("find_symbols needs 'query'")
	}
	p, err := request("GET", "/find/symbol", map[string]any{"query": query}, nil)
	if err != "" {
		return fail(err)
	}
	return ok(p)
}

func tRunShell(args map[string]any) result {
	command := argString(args, "command")
	if command == "" {
		return fail("run_shell needs 'command'")
	}
	session, err := ensureSession()
	if err != "" {
		return fail(err)
	}
	agent := argString(args, "agent")
	if agent == "" {
		agent = "build"
	}
	p, reqErr := request("POST", "/session/"+session+"/shell", nil,
		map[string]any{"agent": agent, "command": command})
	if reqErr != "" {
		return fail(reqErr)
	}
	return ok(p)
}

func tListAgents(args map[string]any) result {
	p, err := request("GET", "/agent", nil, nil)
	if err != "" {
		return fail(err)
	}
	return ok(p)
}

func tListMCP(args map[string]any) result {
	p, err := request("GET", "/mcp", nil, nil)
	if err != "" {
		return fail(err)
	}
	return ok(p)
}

func tListSessions(args map[string]any) result {
	p, err := request("GET", "/session", nil, nil)
	if err != "" {
		return fail(err)
	}
	return ok(p)
}

var handlers = map[string]func(map[string]any) result{
	"opencode_health":            tHealth,
	"opencode_list_files":        tListFiles,
	"opencode_read_file":         tReadFile,
	"opencode_find_in_files":     tFindInFiles,
	"opencode_find_files":        tFindFiles,
	"opencode_find_symbols":      tFindSymbols,
	"opencode_run_shell":         tRunShell,
	"opencode_list_agents":       tListAgents,
	"opencode_list_mcp_servers":  tListMCP,
	"opencode_list_sessions":     tListSessions,
}

// ---- catalogue ----

func s(desc string) map[string]any { return map[string]any{"type": "string", "description": desc} }
func i(desc string) map[string]any {
	return map[string]any{"type": "integer", "description": desc}
}
func obj(props map[string]any, required ...string) map[string]any {
	if required == nil {
		required = []string{}
	}
	return map[string]any{
		"type":                 "object",
		"properties":           props,
		"required":             required,
		"additionalProperties": false,
	}
}

var tools = []map[string]any{
	{"name": "opencode_health",
		"description": "Check that the OpenCode server is reachable and report its version. Call this first when a connection fails.",
		"parameters":  obj(map[string]any{})},
	{"name": "opencode_list_files",
		"description": "List files and directories at a path in the OpenCode project.",
		"parameters":  obj(map[string]any{"path": s("Path to list. Default '.'")})},
	{"name": "opencode_read_file",
		"description": "Read a file's contents through OpenCode.",
		"parameters":  obj(map[string]any{"path": s("File to read")}, "path")},
	{"name": "opencode_find_in_files",
		"description": "Search file contents for a literal pattern.",
		"parameters":  obj(map[string]any{"pattern": s("Text to search for")}, "pattern")},
	{"name": "opencode_find_files",
		"description": "Find files by fuzzy name.",
		"parameters": obj(map[string]any{
			"query":     s("Fuzzy file name to search"),
			"type":      s("Restrict to 'file' or 'directory'"),
			"directory": s("Override the project root"),
			"limit":     i("Max results, 1-200"),
		}, "query")},
	{"name": "opencode_find_symbols",
		"description": "Find workspace symbols matching a query.",
		"parameters":  obj(map[string]any{"query": s("Symbol search query")}, "query")},
	{"name": "opencode_run_shell",
		"description": "Run a shell command inside the OpenCode project.",
		"parameters": obj(map[string]any{
			"command": s("Command to run"),
			"agent":   s("Agent to run it as. Default 'build'"),
		}, "command")},
	{"name": "opencode_list_agents",
		"description": "List the agents OpenCode has available.",
		"parameters":  obj(map[string]any{})},
	{"name": "opencode_list_mcp_servers",
		"description": "List the MCP servers OpenCode is connected to, with their status.",
		"parameters":  obj(map[string]any{})},
	{"name": "opencode_list_sessions",
		"description": "List OpenCode sessions.",
		"parameters":  obj(map[string]any{})},
}

func writeJSON(w http.ResponseWriter, status int, payload any) {
	body, _ := json.Marshal(payload)
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Content-Length", fmt.Sprintf("%d", len(body)))
	w.Header().Set("Connection", "close")
	w.WriteHeader(status)
	_, _ = w.Write(body)
}

func mux() http.Handler {
	m := http.NewServeMux()
	m.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		route := r.URL.Path
		if r.Method == http.MethodGet && route == "/tools" {
			writeJSON(w, 200, tools)
			return
		}
		if r.Method == http.MethodGet && route == "/health" {
			health := tHealth(map[string]any{})
			content, _ := health["content"].(string)
			writeJSON(w, 200, map[string]any{
				"upstream": upstream, "bridge": "ok", "opencode": content,
			})
			return
		}
		if r.Method == http.MethodPost && route == "/tools" {
			raw, _ := io.ReadAll(r.Body)
			var body map[string]any
			if err := json.Unmarshal(raw, &body); err != nil {
				writeJSON(w, 400, map[string]any{"content": "", "error": "Invalid JSON: " + err.Error()})
				return
			}
			name, _ := body["name"].(string)
			args, _ := body["arguments"].(map[string]any)
			if args == nil {
				args = map[string]any{}
			}
			handler, found := handlers[name]
			if !found {
				writeJSON(w, 200, map[string]any{"content": "", "error": "unknown tool: " + name})
				return
			}
			defer func() {
				if rec := recover(); rec != nil {
					writeJSON(w, 200, map[string]any{"content": "", "error": fmt.Sprintf("panic: %v", rec)})
				}
			}()
			writeJSON(w, 200, handler(args))
			return
		}
		writeJSON(w, 404, map[string]any{"error": "Not found", "content": ""})
	})
	return m
}

// ---- lifecycle: idempotent on the port, clears orphans ----

func bridgeAlreadyRunning() bool {
	client := &http.Client{Timeout: 2 * time.Second}
	resp, err := client.Get("http://" + net.JoinHostPort(listenHost, listenPort) + "/health")
	if err != nil {
		return false
	}
	defer resp.Body.Close()
	return resp.StatusCode == http.StatusOK
}

func pidHoldingPort(port int) int {
	inode := ""
	for _, path := range []string{"/proc/net/tcp", "/proc/net/tcp6"} {
		fh, err := os.Open(path)
		if err != nil {
			continue
		}
		data, _ := io.ReadAll(fh)
		fh.Close()
		for _, line := range strings.Split(string(data), "\n")[1:] {
			f := strings.Fields(line)
			if len(f) < 10 || f[3] != "0A" {
				continue
			}
			idx := strings.LastIndex(f[1], ":")
			if idx < 0 {
				continue
			}
			var lport int
			if _, err := fmt.Sscanf(f[1][idx+1:], "%x", &lport); err != nil {
				continue
			}
			if lport == port {
				inode = f[9]
				break
			}
		}
		if inode != "" {
			break
		}
	}
	if inode == "" {
		return 0
	}
	target := "socket:[" + inode + "]"
	matches, _ := os.ReadDir("/proc")
	for _, e := range matches {
		if !e.IsDir() {
			continue
		}
		var pid int
		if _, err := fmt.Sscanf(e.Name(), "%d", &pid); err != nil {
			continue
		}
		fds, err := os.ReadDir("/proc/" + e.Name() + "/fd")
		if err != nil {
			continue
		}
		for _, fd := range fds {
			link, err := os.Readlink("/proc/" + e.Name() + "/fd/" + fd.Name())
			if err == nil && link == target {
				return pid
			}
		}
	}
	return 0
}

func clearOrphan(port int) bool {
	pid := pidHoldingPort(port)
	if pid == 0 || pid == os.Getpid() {
		return false
	}
	cmdline, err := os.ReadFile(fmt.Sprintf("/proc/%d/cmdline", pid))
	if err != nil {
		return false
	}
	cmd := strings.ReplaceAll(string(cmdline), "\x00", " ")
	if !strings.Contains(cmd, "opencode") {
		fmt.Fprintf(os.Stderr, "[opencode-bridge] port %d is held by pid %d, not touching it\n", port, pid)
		return false
	}
	fmt.Fprintf(os.Stderr, "[opencode-bridge] clearing orphaned instance pid %d\n", pid)
	_ = syscall.Kill(pid, syscall.SIGTERM)
	for i := 0; i < 20; i++ {
		time.Sleep(100 * time.Millisecond)
		if pidHoldingPort(port) == 0 {
			return true
		}
	}
	_ = syscall.Kill(pid, syscall.SIGKILL)
	time.Sleep(200 * time.Millisecond)
	return pidHoldingPort(port) == 0
}

func main() {
	addr := net.JoinHostPort(listenHost, listenPort)
	var port int
	_, _ = fmt.Sscanf(listenPort, "%d", &port)

	if bridgeAlreadyRunning() {
		fmt.Fprintf(os.Stderr, "[opencode-bridge] one is already listening on %s, nothing to do\n", addr)
		return
	}

	ln, err := net.Listen("tcp", addr)
	if err != nil {
		if strings.Contains(err.Error(), "address already in use") {
			if bridgeAlreadyRunning() {
				fmt.Fprintf(os.Stderr, "[opencode-bridge] another instance won the race on %s\n", addr)
				return
			}
			if clearOrphan(port) {
				ln, err = net.Listen("tcp", addr)
			}
		}
		if err != nil {
			fmt.Fprintf(os.Stderr, "[opencode-bridge] cannot bind %s: %v\n", addr, err)
			os.Exit(1)
		}
	}

	srv := &http.Server{Handler: mux()}
	go func() {
		sig := make(chan os.Signal, 1)
		signal.Notify(sig, syscall.SIGTERM, syscall.SIGINT)
		<-sig
		_ = srv.Close()
	}()

	fmt.Fprintf(os.Stderr, "[opencode-bridge] %d tools -> %s on http://%s\n", len(tools), upstream, addr)
	if err := srv.Serve(ln); err != nil && !errors.Is(err, http.ErrServerClosed) {
		fmt.Fprintf(os.Stderr, "[opencode-bridge] serve error: %v\n", err)
		os.Exit(1)
	}
}
