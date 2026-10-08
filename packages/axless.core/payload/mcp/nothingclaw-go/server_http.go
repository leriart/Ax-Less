// NothingClaw bridge - HTTP surface and entry point. Ported from server.py.
package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"
)

func sendJSON(w http.ResponseWriter, status int, payload any) {
	body, _ := json.Marshal(payload)
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Content-Length", fmt.Sprint(len(body)))
	w.Header().Set("Connection", "close")
	w.WriteHeader(status)
	_, _ = w.Write(body)
}

func queryFirst(q map[string][]string, key string) string {
	if v := q[key]; len(v) > 0 {
		return v[0]
	}
	return ""
}

func handleGetTools(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	explicit := strings.ToLower(strings.TrimSpace(firstOf(queryFirst(q, "capability"), r.Header.Get("X-Capability"))))
	modelName := firstOf(queryFirst(q, "model"), r.Header.Get("X-Model-Name"))
	modelHost := firstOf(queryFirst(q, "host"), r.Header.Get("X-Model-Host"))
	lite := q.Has("lite")
	search := strings.TrimSpace(queryFirst(q, "q"))

	if search != "" {
		names := rankToolsByQuery(search, 8)
		always := map[string]bool{
			"manage_memory": true, "list_windows": true, "list_installed_apps": true,
			"move_window_to_workspace": true, "open_url": true,
		}
		seen := map[string]bool{}
		ordered := []string{}
		for k := range always {
			ordered = append(ordered, k)
			seen[k] = true
		}
		for _, n := range names {
			if !seen[n] {
				ordered = append(ordered, n)
				seen[n] = true
			}
		}
		set := map[string]bool{}
		for _, n := range ordered {
			set[n] = true
		}
		payload := []map[string]any{}
		for _, t := range toolsList() {
			if set[t["name"].(string)] {
				payload = append(payload, t)
			}
		}
		sendJSON(w, 200, payload)
		return
	}

	tier := "small"
	switch {
	case explicit == "tiny" || explicit == "small" || explicit == "medium" || explicit == "large":
		tier = explicit
	case modelName != "":
		tier = detectCapability(modelName, modelHost)
	case lite:
		tier = "small"
	}
	sendJSON(w, 200, filterToolsForCapability(tier))
}

func firstOf(vals ...string) string {
	for _, v := range vals {
		if strings.TrimSpace(v) != "" {
			return v
		}
	}
	return ""
}

func handlePostTools(w http.ResponseWriter, r *http.Request) {
	raw, _ := io.ReadAll(r.Body)
	var body map[string]any
	if err := json.Unmarshal(raw, &body); err != nil {
		sendJSON(w, 400, map[string]any{"content": "", "error": "Invalid JSON: " + err.Error()})
		return
	}
	name, _ := body["name"].(string)
	if name == "" {
		sendJSON(w, 400, map[string]any{"content": "", "error": "Missing 'name'"})
		return
	}
	arguments, _ := body["arguments"].(map[string]any)
	if arguments == nil {
		arguments = map[string]any{}
	}

	q := r.URL.Query()
	explicit := strings.ToLower(strings.TrimSpace(firstOf(queryFirst(q, "capability"), r.Header.Get("X-Capability"))))
	modelName := firstOf(queryFirst(q, "model"), r.Header.Get("X-Model-Name"))
	modelHost := firstOf(queryFirst(q, "host"), r.Header.Get("X-Model-Host"))
	tier := explicit
	if tier != "tiny" && tier != "small" && tier != "medium" && tier != "large" {
		if modelName != "" {
			tier = detectCapability(modelName, modelHost)
		} else {
			tier = "small"
		}
	}
	ctx := resolveRequestContext(tier, modelName, modelHost)

	defer func() {
		if rec := recover(); rec != nil {
			sendJSON(w, 200, map[string]any{"content": "", "error": fmt.Sprintf("panic: %v", rec)})
		}
	}()
	result := invokeTool(name, arguments, ctx)
	sendJSON(w, 200, result)
}

func handleAgent(w http.ResponseWriter, r *http.Request) {
	raw, _ := io.ReadAll(r.Body)
	var body map[string]any
	if err := json.Unmarshal(raw, &body); err != nil {
		sendJSON(w, 400, map[string]any{"content": "", "error": "Invalid JSON: " + err.Error()})
		return
	}
	goal, _ := body["goal"].(string)

	model := ""
	if m, ok := body["model"].(string); ok {
		model = m
	}
	host := ""
	if h, ok := body["host"].(string); ok {
		host = h
	}
	maxSteps := intArg(body, "max_steps", 12)
	maxSeconds := intArg(body, "max_seconds", 240)
	var allowed []string
	if arr, ok := body["tools"].([]any); ok {
		for _, a := range arr {
			allowed = append(allowed, fmt.Sprint(a))
		}
	}

	invoker := func(n string, a map[string]any, c any) map[string]any {
		rc, _ := c.(*requestContext)
		return invokeTool(n, a, rc)
	}
	result, err := runAgent(goal, invoker, toolsList(),
		resolveRequestContext("medium", model, ""),
		model, host, maxSteps, maxSeconds, allowed, nil)
	if err != nil {
		sendJSON(w, 400, map[string]any{"content": "", "error": err.Error()})
		return
	}
	sendJSON(w, 200, result)
}

func newMux() http.Handler {
	m := http.NewServeMux()
	m.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.Method == http.MethodGet && r.URL.Path == "/agent/models":
			sendJSON(w, 200, listModels(""))
			return
		case r.Method == http.MethodGet && r.URL.Path == "/tools":
			handleGetTools(w, r)
			return
		case r.Method == http.MethodPost && r.URL.Path == "/agent":
			handleAgent(w, r)
			return
		case r.Method == http.MethodPost && r.URL.Path == "/tools":
			handlePostTools(w, r)
			return
		case r.Method == http.MethodGet && r.URL.Path == "/health":
			health := invokeTool("context_info", map[string]any{}, resolveRequestContext("small", "", ""))
			sendJSON(w, 200, map[string]any{"bridge": "ok", "tools": len(toolsList()), "content": health["content"]})
			return
		}
		sendJSON(w, 404, map[string]any{"error": "Not found", "content": ""})
	})
	return m
}

// ---- lifecycle ----

func bridgeAlreadyRunning(host, port string) bool {
	client := &http.Client{Timeout: 2 * time.Second}
	resp, err := client.Get("http://" + net.JoinHostPort(host, port) + "/tools")
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
		fds, err := os.ReadDir("/proc/" + e.Name() + "/fd")
		if err != nil {
			continue
		}
		for _, fd := range fds {
			if link, err := os.Readlink("/proc/" + e.Name() + "/fd/" + fd.Name()); err == nil && link == target {
				return pid
			}
		}
	}
	return 0
}

func clearOrphan(host string, port int) bool {
	pid := pidHoldingPort(port)
	if pid == 0 || pid == os.Getpid() {
		return false
	}
	cmdline, err := os.ReadFile(fmt.Sprintf("/proc/%d/cmdline", pid))
	if err != nil {
		return false
	}
	cmd := strings.ReplaceAll(string(cmdline), "\x00", " ")
	if !strings.Contains(cmd, "nothingclaw") {
		fmt.Fprintf(os.Stderr, "NothingClaw bridge: port %d is held by pid %d, not touching it\n", port, pid)
		return false
	}
	fmt.Fprintf(os.Stderr, "NothingClaw bridge: clearing orphaned instance pid %d\n", pid)
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
	host := envDefault("NOTHINGCLAW_HOST", "127.0.0.1")
	port := envDefault("NOTHINGCLAW_PORT", "8000")
	addr := net.JoinHostPort(host, port)
	var portNum int
	_, _ = fmt.Sscanf(port, "%d", &portNum)

	if bridgeAlreadyRunning(host, port) {
		fmt.Printf("NothingClaw bridge already listening on http://%s, nothing to do\n", addr)
		return
	}

	ln, err := net.Listen("tcp", addr)
	if err != nil {
		if strings.Contains(err.Error(), "address already in use") {
			if bridgeAlreadyRunning(host, port) {
				fmt.Printf("NothingClaw bridge: another instance won the race on %s\n", addr)
				return
			}
			if clearOrphan(host, portNum) {
				ln, err = net.Listen("tcp", addr)
			}
		}
		if err != nil {
			fmt.Fprintf(os.Stderr, "NothingClaw bridge: cannot bind %s: %v\n", addr, err)
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

	fmt.Printf("NothingClaw bridge listening on http://%s\n", addr)
	if err := srv.Serve(ln); err != nil && err != http.ErrServerClosed {
		fmt.Fprintf(os.Stderr, "NothingClaw bridge: serve error: %v\n", err)
		os.Exit(1)
	}
}
