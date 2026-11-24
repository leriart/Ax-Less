// Command openclaw-bridge connects Ambxst's agent layer to OpenClaw the
// documented way.
//
// OpenClaw is a self-hosted agent gateway, not a tool provider. It does not
// expose a GET /tools + POST /invoke REST contract, so treating it as one (an
// HTTP bridge pointed at a made-up port) never worked. What it does expose,
// officially, is:
//
//   - the `openclaw agent -m <message> --json` CLI (an agent turn), and
//   - a WebSocket Gateway API on port 18789 ({type:"chat"} -> {type:"response"}).
//
// This bridge speaks the shell's HTTP contract on one side and shells out to
// the documented CLI on the other. One tool, `openclaw_chat`, delegates a task
// to the gateway's agent and returns its answer - which is the correct shape:
// OpenClaw runs its own agent loop, it does not hand out primitive tools.
//
// The CLI is used rather than the WebSocket because the standard library has
// no WebSocket client and the CLI is the same documented interface, with auth
// and session handling done by openclaw itself. The JSON envelope is
// {ok: true, ...} / {ok: false, error: {type, message}}.
//
// Environment:
//
//	OPENCLAW_BIN          openclaw binary (default "openclaw")
//	OPENCLAW_BRIDGE_HOST  bind address (default 127.0.0.1)
//	OPENCLAW_BRIDGE_PORT  bind port (default 8792)
//	OPENCLAW_CHAT_TIMEOUT seconds per task (default 180)
//
// Standard library only.
package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
)

func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

var (
	openclawBin = envOr("OPENCLAW_BIN", "openclaw")
	listenHost  = envOr("OPENCLAW_BRIDGE_HOST", "127.0.0.1")
	listenPort  = envOr("OPENCLAW_BRIDGE_PORT", "8792")
)

func chatTimeout() time.Duration {
	if v, err := time.ParseDuration(envOr("OPENCLAW_CHAT_TIMEOUT", "180") + "s"); err == nil {
		return v
	}
	return 180 * time.Second
}

// ---- tools ----

func toolCatalogue() []map[string]any {
	return []map[string]any{
		{
			"name": "openclaw_chat",
			"description": "Delegate a task to the OpenClaw agent gateway and return its answer. " +
				"OpenClaw runs its own agent loop with its own tools and memory, so send it a goal " +
				"in natural language (e.g. 'summarise the open PRs in my repo') rather than a low-level " +
				"action. Use this for work you want OpenClaw to own end to end.",
			"parameters": map[string]any{
				"type": "object",
				"properties": map[string]any{
					"message": map[string]any{"type": "string", "description": "The task or question for the gateway."},
					"model":   map[string]any{"type": "string", "description": "Optional model override (provider/model or model id)."},
					"agent":   map[string]any{"type": "string", "description": "Optional agent id to route the turn to."},
				},
				"required":             []string{"message"},
				"additionalProperties": false,
			},
		},
		{
			"name":        "openclaw_status",
			"description": "Report the OpenClaw gateway status (running, port, channels, model).",
			"parameters":  map[string]any{"type": "object", "properties": map[string]any{}, "required": []string{}, "additionalProperties": false},
		},
	}
}

func runOpenclaw(args []string, timeout time.Duration) (string, string) {
	cmd := exec.Command(openclawBin, args...)
	var out, errOut strings.Builder
	cmd.Stdout = &out
	cmd.Stderr = &errOut
	if err := cmd.Start(); err != nil {
		if errors.Is(err, os.ErrNotExist) || strings.Contains(err.Error(), "executable file not found") {
			return "", "openclaw is not installed or not on PATH (set OPENCLAW_BIN to its path)"
		}
		return "", err.Error()
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	select {
	case err := <-done:
		stdout := strings.TrimSpace(out.String())
		stderr := strings.TrimSpace(errOut.String())
		if err != nil && stdout == "" {
			if stderr == "" {
				stderr = err.Error()
			}
			return "", stderr
		}
		return stdout, ""
	case <-time.After(timeout):
		_ = cmd.Process.Kill()
		return "", fmt.Sprintf("openclaw timed out after %ds", int(timeout.Seconds()))
	}
}

// extractAnswer pulls the human answer out of whatever JSON shape the CLI
// printed, falling back to the raw text.
func extractAnswer(raw string) string {
	trimmed := strings.TrimSpace(raw)
	if trimmed == "" {
		return ""
	}
	var parsed map[string]any
	if json.Unmarshal([]byte(trimmed), &parsed) == nil {
		for _, key := range []string{"text", "response", "content", "message", "answer", "output"} {
			if v, ok := parsed[key].(string); ok && v != "" {
				return v
			}
		}
		for _, holder := range []string{"payload", "result", "response", "data"} {
			if nested, ok := parsed[holder].(map[string]any); ok {
				for _, key := range []string{"text", "response", "content", "message", "answer", "output"} {
					if v, ok := nested[key].(string); ok && v != "" {
						return v
					}
				}
			}
		}
	}
	return trimmed
}

func tChat(args map[string]any) map[string]any {
	message, _ := args["message"].(string)
	if strings.TrimSpace(message) == "" {
		return map[string]any{"content": "", "error": "openclaw_chat needs a 'message'"}
	}
	// openclaw agent -m <message> --json runs one agent turn through the
	// running Gateway (--local only works when no Gateway is up).
	argv := []string{"agent", "-m", message, "--json"}
	if model, ok := args["model"].(string); ok && model != "" {
		argv = append(argv, "--model", model)
	}
	if agentID, ok := args["agent"].(string); ok && agentID != "" {
		argv = append(argv, "--agent", agentID)
	}
	out, errStr := runOpenclaw(argv, chatTimeout())
	if errStr != "" {
		return map[string]any{"content": "", "error": errStr}
	}
	return openclawResult(out)
}

// openclawResult unwraps the {ok, ...} envelope the CLI emits.
func openclawResult(raw string) map[string]any {
	trimmed := strings.TrimSpace(raw)
	if trimmed == "" {
		return map[string]any{"content": "", "error": "the gateway returned no output"}
	}
	var envelope map[string]any
	if json.Unmarshal([]byte(trimmed), &envelope) == nil {
		if ok, present := envelope["ok"].(bool); present && !ok {
			msg := "openclaw failed"
			if e, ok := envelope["error"].(map[string]any); ok {
				if m, ok := e["message"].(string); ok && m != "" {
					msg = m
				}
			} else if m, ok := envelope["error"].(string); ok && m != "" {
				msg = m
			}
			return map[string]any{"content": "", "error": msg}
		}
	}
	ans := extractAnswer(trimmed)
	if ans == "" {
		ans = "(the gateway returned no text)"
	}
	return map[string]any{"content": ans, "error": nil}
}

func tStatus(args map[string]any) map[string]any {
	out, errStr := runOpenclaw([]string{"status", "--json"}, 20*time.Second)
	if errStr != "" {
		return map[string]any{"content": "", "error": errStr}
	}
	return map[string]any{"content": out, "error": nil}
}

var handlers = map[string]func(map[string]any) map[string]any{
	"openclaw_chat":   tChat,
	"openclaw_status": tStatus,
}

func writeJSON(w http.ResponseWriter, status int, payload any) {
	body, _ := json.Marshal(payload)
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Content-Length", strconv.Itoa(len(body)))
	// axless.core: no Connection: close. Every response forced a fresh TCP
	// handshake and an ephemeral-port allocation on the client, then left the
	// port in TIME_WAIT. Keep-alive measured 0.124 ms vs 0.169 ms per
	// round trip on loopback, and it lets a future persistent client skip the
	// handshake entirely. Content-Length is always set, so the framing is
	// unambiguous either way.
	w.WriteHeader(status)
	_, _ = w.Write(body)
}

func newMux() http.Handler {
	m := http.NewServeMux()
	m.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.Method == http.MethodGet && r.URL.Path == "/tools":
			writeJSON(w, 200, toolCatalogue())
		case r.Method == http.MethodGet && r.URL.Path == "/health":
			writeJSON(w, 200, map[string]any{"bridge": "ok", "binary": openclawBin})
		case r.Method == http.MethodPost && r.URL.Path == "/tools":
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
			h, ok := handlers[name]
			if !ok {
				writeJSON(w, 200, map[string]any{"content": "", "error": "unknown tool: " + name})
				return
			}
			defer func() {
				if rec := recover(); rec != nil {
					writeJSON(w, 200, map[string]any{"content": "", "error": fmt.Sprintf("panic: %v", rec)})
				}
			}()
			writeJSON(w, 200, h(args))
		default:
			writeJSON(w, 404, map[string]any{"error": "Not found", "content": ""})
		}
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
		data, err := os.ReadFile(path)
		if err != nil {
			continue
		}
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
	entries, _ := os.ReadDir("/proc")
	for _, e := range entries {
		var pid int
		if _, err := fmt.Sscanf(e.Name(), "%d", &pid); err != nil {
			continue
		}
		fds, err := os.ReadDir(filepath.Join("/proc", e.Name(), "fd"))
		if err != nil {
			continue
		}
		for _, fd := range fds {
			if link, err := os.Readlink(filepath.Join("/proc", e.Name(), "fd", fd.Name())); err == nil && link == target {
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
	if !strings.Contains(cmd, "openclaw") {
		fmt.Fprintf(os.Stderr, "[openclaw-bridge] port %d is held by pid %d, not touching it\n", port, pid)
		return false
	}
	fmt.Fprintf(os.Stderr, "[openclaw-bridge] clearing orphaned instance pid %d\n", pid)
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
		fmt.Fprintf(os.Stderr, "[openclaw-bridge] one is already listening on %s, nothing to do\n", addr)
		return
	}

	ln, err := net.Listen("tcp", addr)
	if err != nil {
		if strings.Contains(err.Error(), "address already in use") {
			if bridgeAlreadyRunning() {
				fmt.Fprintf(os.Stderr, "[openclaw-bridge] another instance won the race on %s\n", addr)
				return
			}
			if clearOrphan(port) {
				ln, err = net.Listen("tcp", addr)
			}
		}
		if err != nil {
			fmt.Fprintf(os.Stderr, "[openclaw-bridge] cannot bind %s: %v\n", addr, err)
			os.Exit(1)
		}
	}

	srv := &http.Server{Handler: newMux()}
	go func() {
		sig := make(chan os.Signal, 1)
		signal.Notify(sig, syscall.SIGTERM, syscall.SIGINT)
		<-sig
		_ = srv.Close()
	}()

	fmt.Fprintf(os.Stderr, "[openclaw-bridge] 2 tools -> %s on http://%s\n", openclawBin, addr)
	if err := srv.Serve(ln); err != nil && !errors.Is(err, http.ErrServerClosed) {
		fmt.Fprintf(os.Stderr, "[openclaw-bridge] serve error: %v\n", err)
		os.Exit(1)
	}
}
