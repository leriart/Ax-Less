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

// strArg reads a string argument. Fast paths avoid fmt.Sprintf, which allocated
// on every dispatch; fmt is only reached for shapes that genuinely need it.
func strArg(args map[string]any, key string, def string) string {
	v, ok := args[key]
	if !ok || v == nil {
		return def
	}
	switch t := v.(type) {
	case string:
		s := strings.TrimSpace(t)
		if s == "" {
			return def
		}
		return s
	case bool:
		if t {
			return "true"
		}
		return "false"
	case float64:
		return trimFloat(t)
	case int:
		return strconv.Itoa(t)
	case int64:
		return strconv.FormatInt(t, 10)
	case json.Number:
		return t.String()
	}
	s := strings.TrimSpace(fmt.Sprintf("%v", v))
	if s == "" {
		return def
	}
	return s
}

// trimFloat renders a float the way encoding/json would for integral values
// (5 not 5.000000), so numeric args stay readable in the transcript.
func trimFloat(f float64) string {
	if f == float64(int64(f)) && f < 1e15 && f > -1e15 {
		return strconv.FormatInt(int64(f), 10)
	}
	return strconv.FormatFloat(f, 'g', -1, 64)
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

// axctlResult carries the outcome of an axctl invocation across the goroutine
// boundary. It used to be three shared locals, which raced on the timeout path.
type axctlResult struct {
	out, errOut []byte
	err         error
}

func runAxctl(argv []string, timeout time.Duration) map[string]any {
	cmd := exec.Command(axctl, argv...)
	done := make(chan axctlResult, 1)
	go func() {
		var o, e strings.Builder
		cmd.Stdout = &o
		cmd.Stderr = &e
		err := cmd.Run()
		done <- axctlResult{out: []byte(o.String()), errOut: []byte(e.String()), err: err}
	}()

	timer := time.NewTimer(timeout)
	defer timer.Stop()

	var res axctlResult
	select {
	case res = <-done:
	case <-timer.C:
		_ = cmd.Process.Kill()
		// Drain the goroutine so its result never outlives this frame; the
		// channel is buffered so it cannot block on us.
		go func() { <-done }()
		return map[string]any{"content": "", "error": fmt.Sprintf("axctl command timed out after %ds", int(timeout.Seconds()))}
	}
	if res.err != nil {
		if _, ok := res.err.(*exec.Error); ok {
			return map[string]any{"content": "", "error": "axctl binary not found at " + axctl + " - install it from https://github.com/leriart/axctl.c"}
		}
	}
	stdout := strings.TrimSpace(string(res.out))
	stderr := strings.TrimSpace(string(res.errOut))
	if res.err == nil {
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
	timer := time.NewTimer(time.Duration(timeout) * time.Second)
	defer timer.Stop()
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
	case <-timer.C:
		_ = cmd.Process.Kill()
		go func() { <-done }()
		return map[string]any{"content": "", "error": fmt.Sprintf("command timed out after %ds", timeout)}
	}
}

func fireAndForget(argv []string) bool {
	if len(argv) == 0 || argv[0] == "" {
		return false
	}
	cmd := exec.Command(argv[0], argv[1:]...)
	cmd.Stdin = nil
	cmd.Stdout = nil
	cmd.Stderr = nil
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	return cmd.Start() == nil
}

// shellWords splits a command line into argv, honouring single quotes, double
// quotes and backslash escapes. It returns ok=false when the input contains
// shell constructs we deliberately refuse to emulate (pipes, redirects,
// substitutions, backgrounding), so callers can fall back to a real shell
// instead of guessing.
func shellWords(s string) (words []string, ok bool) {
	var cur strings.Builder
	inWord := false
	var quote byte
	flush := func() {
		if inWord {
			words = append(words, cur.String())
			cur.Reset()
			inWord = false
		}
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case quote != 0:
			if c == quote {
				quote = 0
				continue
			}
			if quote == '"' && c == '\\' && i+1 < len(s) {
				i++
				cur.WriteByte(s[i])
				inWord = true
				continue
			}
			cur.WriteByte(c)
			inWord = true
		case c == '\'' || c == '"':
			quote = c
			inWord = true
		case c == '\\' && i+1 < len(s):
			i++
			cur.WriteByte(s[i])
			inWord = true
		case c == ' ' || c == '\t' || c == '\n' || c == '\r':
			flush()
		case c == '|' || c == '>' || c == '<' || c == '&' || c == ';' ||
			c == '$' || c == '`' || c == '(' || c == ')' || c == '*' || c == '?' ||
			c == '{' || c == '}' || c == '[' || c == ']' || c == '#' || c == '~':
			return nil, false
		default:
			cur.WriteByte(c)
			inWord = true
		}
	}
	if quote != 0 {
		return nil, false
	}
	flush()
	if len(words) == 0 {
		return nil, false
	}
	return words, true
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

func okContent(s string) map[string]any  { return map[string]any{"content": s, "error": nil} }
func errContent(s string) map[string]any { return map[string]any{"content": "", "error": s} }
