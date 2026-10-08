// NothingClaw bridge - request context, tool helpers, app catalog,
// knowledge tools and the dispatcher. Companion to server.go.
package main

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// ---- argument extraction (mirrors _str_arg / _int_arg / _bool_arg) ----

func strArg(args map[string]any, key string, def string) string {
	v, ok := args[key]
	if !ok || v == nil {
		return def
	}
	s := strings.TrimSpace(fmt.Sprintf("%v", v))
	if s == "" {
		return def
	}
	return s
}

func intArg(args map[string]any, key string, def int) int {
	v, ok := args[key]
	if !ok || v == nil {
		return def
	}
	var n int
	switch t := v.(type) {
	case float64:
		n = int(t)
	case int:
		n = t
	case string:
		parsed, err := strconv.Atoi(strings.TrimSpace(t))
		if err != nil {
			return def
		}
		n = parsed
	default:
		return def
	}
	if n < 0 {
		return def
	}
	if n == 0 && def != 0 {
		return def
	}
	return n
}

func boolArg(args map[string]any, key string, def bool) bool {
	v, ok := args[key]
	if !ok || v == nil {
		return def
	}
	switch t := v.(type) {
	case bool:
		return t
	case string:
		switch strings.ToLower(t) {
		case "true", "1", "yes", "on":
			return true
		case "false", "0", "no", "off":
			return false
		}
	}
	return def
}

// ---- request context ----

type requestContext struct {
	Tier          string
	ModelName     string
	ModelHost     string
	ContextWindow int
	ToolBudget    int
	InputBudget   int
}

func resolveRequestContext(tier, modelName, modelHost string) *requestContext {
	if tier == "" {
		tier = "small"
	}
	ctxWindow := lookupKnownContext(modelName)
	return &requestContext{
		Tier:          tier,
		ModelName:     modelName,
		ModelHost:     modelHost,
		ContextWindow: ctxWindow,
		ToolBudget:    toolResultBudget(tier),
		InputBudget:   computeInputTokenBudget(0, ctxWindow),
	}
}

// ---- axctl / shell ----

func runAxctl(argv []string, timeout time.Duration) map[string]any {
	cmd := exec.Command(axctl, argv...)
	done := make(chan struct{})
	var out, errOut []byte
	var runErr error
	go func() {
		out, errOut, runErr = func() ([]byte, []byte, error) {
			var o, e strings.Builder
			cmd.Stdout = &o
			cmd.Stderr = &e
			err := cmd.Run()
			return []byte(o.String()), []byte(e.String()), err
		}()
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(timeout):
		_ = cmd.Process.Kill()
		return map[string]any{"content": "", "error": fmt.Sprintf("axctl command timed out after %ds", int(timeout.Seconds()))}
	}
	if runErr != nil {
		if _, ok := runErr.(*exec.Error); ok {
			return map[string]any{"content": "", "error": "axctl binary not found at " + axctl + " - install it from https://github.com/leriart/axctl.c"}
		}
	}
	stdout := strings.TrimSpace(string(out))
	stderr := strings.TrimSpace(string(errOut))
	if runErr == nil {
		for _, line := range strings.Split(stderr, "\n") {
			if strings.HasPrefix(line, "Error:") {
				return map[string]any{"content": "", "error": stderr}
			}
		}
		if stdout == "" {
			stdout = "Success"
		}
		return map[string]any{"content": stdout, "error": nil}
	}
	if stderr != "" {
		return map[string]any{"content": "", "error": stderr}
	}
	return map[string]any{"content": "", "error": "axctl exited with an error"}
}

func runShell(command string, timeout int, cwd string) map[string]any {
	if command == "" {
		return map[string]any{"content": "", "error": "empty command"}
	}
	if timeout < 1 {
		timeout = 1
	}
	if timeout > 300 {
		timeout = 300
	}
	if cwd == "" {
		home, _ := os.UserHomeDir()
		cwd = home
	}
	cmd := exec.Command("bash", "-c", command)
	cmd.Dir = cwd
	var out, errOut strings.Builder
	cmd.Stdout = &out
	cmd.Stderr = &errOut
	if err := cmd.Start(); err != nil {
		return map[string]any{"content": "", "error": err.Error()}
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	select {
	case err := <-done:
		parts := []string{}
		if s := strings.TrimRight(out.String(), "\n"); s != "" {
			parts = append(parts, s)
		}
		if s := strings.TrimRight(errOut.String(), "\n"); s != "" {
			parts = append(parts, "[stderr]\n"+s)
		}
		body := strings.Join(parts, "\n")
		if body == "" {
			body = "(no output)"
		}
		if err != nil {
			return map[string]any{"content": body, "error": "exit code " + strconv.Itoa(cmd.ProcessState.ExitCode())}
		}
		return map[string]any{"content": body, "error": nil}
	case <-time.After(time.Duration(timeout) * time.Second):
		_ = cmd.Process.Kill()
		return map[string]any{"content": "", "error": fmt.Sprintf("command timed out after %ds", timeout)}
	}
}

func fireAndForget(argv []string) bool {
	cmd := exec.Command(argv[0], argv[1:]...)
	cmd.Stdin = nil
	cmd.Stdout = nil
	cmd.Stderr = nil
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	return cmd.Start() == nil
}

func compactWindows(windows []any) []map[string]any {
	out := []map[string]any{}
	for _, w := range windows {
		m, ok := w.(map[string]any)
		if !ok {
			continue
		}
		entry := map[string]any{}
		for _, k := range []string{"id", "app_id", "title", "workspace_id"} {
			if v, present := m[k]; present && v != nil {
				entry[k] = v
			}
		}
		out = append(out, entry)
	}
	return out
}

func compactApps(apps []map[string]any) []map[string]any {
	out := []map[string]any{}
	for _, a := range apps {
		entry := map[string]any{}
		for _, k := range []string{"id", "name", "source", "command"} {
			if v, ok := a[k]; ok && v != nil && v != "" {
				entry[k] = v
			}
		}
		out = append(out, entry)
	}
	return out
}

func jsonPretty(v any) string {
	b, _ := json.MarshalIndent(v, "", "  ")
	return string(b)
}

func okContent(s string) map[string]any { return map[string]any{"content": s, "error": nil} }
func errContent(s string) map[string]any { return map[string]any{"content": "", "error": s} }
