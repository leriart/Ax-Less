// Autonomous agent loop for NothingClaw, ported from agent_loop.py.
//
// The rest of the bridge is a passive tool surface; the model on the other end
// decides what to call. This drives the tools itself:
//
//	goal -> model -> (tool_calls | final answer) -> execute -> observe -> repeat
//
// Three rules keep small models usable: observations are truncated before
// going back into the history, both max_steps and max_seconds are enforced,
// and several tool calls in one turn are executed as issued.
package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"regexp"
	"strings"
	"time"
)

func envDefault(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

var (
	// axless.core: OpenAI-compatible transport. Ollama, LM Studio, vLLM and
	// every cloud API speak the same /v1/chat/completions surface, so the
	// loop drives any model - local or remote - not just Ollama.
	apiBase           = envDefault("NOTHINGCLAW_API_BASE", "http://127.0.0.1:11434/v1")
	apiKey            = envDefault("NOTHINGCLAW_API_KEY", "")
	defaultAgentModel = envDefault("NOTHINGCLAW_MODEL", "llama3.2:latest")
)

const (
	observationCharBudget = 8000
	maxToolsForAgent      = 24
)

// AgentError is raised for unrecoverable agent failures.
type AgentError struct{ msg string }

func (e *AgentError) Error() string { return e.msg }

// doJSON performs a request against the model backend, adding the bearer
// token when one is configured.
func doJSON(method, url string, payload any, timeout time.Duration) ([]byte, error) {
	var reader io.Reader
	if payload != nil {
		data, err := json.Marshal(payload)
		if err != nil {
			return nil, &AgentError{err.Error()}
		}
		reader = bytes.NewReader(data)
	}
	req, err := http.NewRequest(method, url, reader)
	if err != nil {
		return nil, &AgentError{err.Error()}
	}
	req.Header.Set("Content-Type", "application/json")
	if apiKey != "" {
		req.Header.Set("Authorization", "Bearer "+apiKey)
	}
	client := &http.Client{Timeout: timeout}
	resp, err := client.Do(req)
	if err != nil {
		return nil, &AgentError{fmt.Sprintf("Cannot reach %s: %v", url, err)}
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode >= 400 {
		detail := string(body)
		if len(detail) > 400 {
			detail = detail[:400]
		}
		return nil, &AgentError{fmt.Sprintf("HTTP %d from %s: %s", resp.StatusCode, url, detail)}
	}
	return body, nil
}

// listModels returns the names the backend advertises. Reads the OpenAI
// {data:[{id}]} shape, falling back to Ollama's {models:[{name}]}.
func listModels(base string) map[string]any {
	if base == "" {
		base = apiBase
	}
	body, err := doJSON("GET", strings.TrimRight(base, "/")+"/models", nil, 10*time.Second)
	if err != nil {
		return map[string]any{"error": err.Error(), "models": []string{}}
	}
	var openai struct {
		Data []struct {
			ID string `json:"id"`
		} `json:"data"`
	}
	if json.Unmarshal(body, &openai) == nil && len(openai.Data) > 0 {
		names := []string{}
		for _, m := range openai.Data {
			if m.ID != "" {
				names = append(names, m.ID)
			}
		}
		return map[string]any{"error": nil, "models": names}
	}
	var ollama struct {
		Models []struct {
			Name string `json:"name"`
		} `json:"models"`
	}
	if json.Unmarshal(body, &ollama) == nil {
		names := []string{}
		for _, m := range ollama.Models {
			if m.Name != "" {
				names = append(names, m.Name)
			}
		}
		return map[string]any{"error": nil, "models": names}
	}
	return map[string]any{"error": "could not parse the model list", "models": []string{}}
}

// chat sends one turn and returns the assistant message object
// ({content, tool_calls}).
func chat(base, model string, messages []map[string]any, tools []map[string]any, timeout time.Duration) (map[string]any, error) {
	payload := map[string]any{
		"model":       model,
		"messages":    messages,
		"stream":      false,
		"temperature": 0.1,
	}
	if len(tools) > 0 {
		payload["tools"] = tools
	}
	body, err := doJSON("POST", strings.TrimRight(base, "/")+"/chat/completions", payload, timeout)
	if err != nil {
		return nil, err
	}
	var out struct {
		Choices []struct {
			Message map[string]any `json:"message"`
		} `json:"choices"`
	}
	if err := json.Unmarshal(body, &out); err != nil {
		return nil, &AgentError{fmt.Sprintf("bad JSON from %s: %v", base, err)}
	}
	if len(out.Choices) == 0 || out.Choices[0].Message == nil {
		return map[string]any{}, nil
	}
	return out.Choices[0].Message, nil
}

func clip(text string, budget int) string {
	if budget == 0 {
		budget = observationCharBudget
	}
	if len(text) <= budget {
		return text
	}
	dropped := len(text) - budget
	return text[:budget] + fmt.Sprintf("\n... [truncated %d characters - narrow the query or read the file in chunks]", dropped)
}

// normaliseArguments tolerates a dict, a JSON string, or a malformed string.
func normaliseArguments(raw any) map[string]any {
	switch v := raw.(type) {
	case nil:
		return map[string]any{}
	case map[string]any:
		return v
	case string:
		text := strings.TrimSpace(v)
		if text == "" {
			return map[string]any{}
		}
		var parsed any
		if err := json.Unmarshal([]byte(text), &parsed); err != nil {
			return map[string]any{"_raw": text}
		}
		if m, ok := parsed.(map[string]any); ok {
			return m
		}
		return map[string]any{"_raw": parsed}
	default:
		return map[string]any{"_raw": raw}
	}
}

func toolSchema(tools []map[string]any, allow []string) []map[string]any {
	allowSet := map[string]bool{}
	for _, a := range allow {
		allowSet[a] = true
	}
	out := []map[string]any{}
	for _, tool := range tools {
		name, _ := tool["name"].(string)
		if name == "" {
			continue
		}
		if allow != nil && !allowSet[name] {
			continue
		}
		params, ok := tool["inputSchema"]
		if !ok {
			params, ok = tool["parameters"]
		}
		if !ok {
			params = map[string]any{"type": "object", "properties": map[string]any{}}
		}
		out = append(out, map[string]any{
			"type": "function",
			"function": map[string]any{
				"name":        name,
				"description": tool["description"],
				"parameters":  params,
			},
		})
	}
	return out
}

// ---- fallback parsing ----

var nameKeys = []string{"name", "tool", "tool_name", "function"}
var argsKeys = []string{"parameters", "arguments", "args", "input", "params"}

func coerceToolCall(name string, rawArgs any) map[string]any {
	if s, ok := rawArgs.(string); ok {
		rawArgs = normaliseArguments(s)
	}
	var argMap map[string]any
	if m, ok := rawArgs.(map[string]any); ok {
		argMap = m
	} else {
		argMap = map[string]any{}
	}
	if name == "" {
		if fn, ok := argMap["function"].(map[string]any); ok {
			if n, ok := fn["name"].(string); ok {
				name = n
			}
			if fn["arguments"] != nil {
				argMap = normaliseArguments(fn["arguments"])
			} else {
				argMap = normaliseArguments(fn["parameters"])
			}
		}
	}
	if name == "" {
		return nil
	}
	return map[string]any{
		"function": map[string]any{
			"name":      name,
			"arguments": normaliseArguments(argMap),
		},
	}
}

var reName = regexp.MustCompile(`"(?:name|tool|tool_name|function)"\s*:\s*"([^"\\]{1,64})"`)
var rePairStart = regexp.MustCompile(`"([A-Za-z_][A-Za-z0-9_]{0,40})"\s*:\s*"`)

// lenientPairs salvages "key": "value" pairs from malformed JSON, scanning for
// a closing quote followed by a comma or brace so embedded quotes survive.
func lenientPairs(blob string) map[string]string {
	pairs := map[string]string{}
	locs := rePairStart.FindAllStringSubmatchIndex(blob, -1)
	for _, loc := range locs {
		key := blob[loc[2]:loc[3]]
		start := loc[1] // end of the opening quote of the value
		end := -1
		for i := start; i < len(blob); i++ {
			if blob[i] != '"' {
				continue
			}
			j := i + 1
			for j < len(blob) && (blob[j] == ' ' || blob[j] == '\t' || blob[j] == '\n' || blob[j] == '\r') {
				j++
			}
			if j < len(blob) && (blob[j] == ',' || blob[j] == '}') {
				end = i
				break
			}
		}
		if end < 0 {
			// No natural close; take up to the last quote.
			if i := strings.LastIndex(blob[start:], `"`); i >= 0 {
				end = start + i
			} else {
				continue
			}
		}
		if _, exists := pairs[key]; !exists {
			pairs[key] = blob[start:end]
		}
	}
	return pairs
}

func salvage(text string) map[string]any {
	names := reName.FindStringSubmatch(text)
	if names == nil {
		return nil
	}
	name := names[1]
	pairs := lenientPairs(text)
	args := map[string]any{}
	skip := map[string]bool{"name": true, "tool": true, "tool_name": true,
		"function": true, "parameters": true, "arguments": true, "args": true, "input": true}
	for k, v := range pairs {
		if !skip[k] {
			args[k] = v
		}
	}
	return coerceToolCall(name, args)
}

var reFence = regexp.MustCompile("(?s)```(?:json|tool_call|tool)?\\s*(.+?)```")

// extractToolCalls pulls tool calls out of a text response.
func extractToolCalls(text string) []map[string]any {
	if text == "" {
		return nil
	}
	var candidates []any
	try := func(blob string) {
		blob = strings.TrimSpace(blob)
		if blob == "" || (blob[0] != '{' && blob[0] != '[') {
			return
		}
		var parsed any
		if err := json.Unmarshal([]byte(blob), &parsed); err == nil {
			candidates = append(candidates, parsed)
		}
	}

	for _, m := range reFence.FindAllStringSubmatch(text, -1) {
		try(m[1])
	}
	stripped := strings.TrimSpace(text)
	try(stripped)

	if len(candidates) == 0 {
		start := strings.Index(stripped, "{")
		for start != -1 {
			depth := 0
			for i := start; i < len(stripped); i++ {
				if stripped[i] == '{' {
					depth++
				} else if stripped[i] == '}' {
					depth--
					if depth == 0 {
						try(stripped[start : i+1])
						break
					}
				}
			}
			next := strings.Index(stripped[start+1:], "{")
			if next == -1 {
				break
			}
			start = start + 1 + next
		}
	}

	if len(candidates) == 0 {
		if s := salvage(text); s != nil {
			return []map[string]any{s}
		}
		return nil
	}

	var calls []map[string]any
	for _, parsed := range candidates {
		items := []any{parsed}
		if arr, ok := parsed.([]any); ok {
			items = arr
		}
		if m, ok := parsed.(map[string]any); ok {
			if tc, ok := m["tool_calls"].([]any); ok {
				items = tc
			}
		}
		for _, it := range items {
			item, ok := it.(map[string]any)
			if !ok {
				continue
			}
			if fn, ok := item["function"].(map[string]any); ok {
				var args any
				if fn["arguments"] != nil {
					args = fn["arguments"]
				} else {
					args = fn["parameters"]
				}
				item = map[string]any{"name": fn["name"], "arguments": args}
			}
			name := ""
			for _, k := range nameKeys {
				if s, ok := item[k].(string); ok {
					name = s
					break
				}
			}
			var args any
			for _, k := range argsKeys {
				if v, present := item[k]; present {
					args = v
					break
				}
			}
			if call := coerceToolCall(name, args); call != nil {
				if fn, ok := call["function"].(map[string]any); ok {
					if n, _ := fn["name"].(string); n != "" {
						calls = append(calls, call)
					}
				}
			}
		}
	}

	unique := []map[string]any{}
	seen := map[string]bool{}
	for _, call := range calls {
		fn, _ := call["function"].(map[string]any)
		name, _ := fn["name"].(string)
		argBytes, _ := json.Marshal(fn["arguments"])
		key := name + "\x00" + string(argBytes)
		if !seen[key] {
			seen[key] = true
			unique = append(unique, call)
		}
	}
	if len(unique) == 0 {
		if s := salvage(text); s != nil {
			unique = append(unique, s)
		}
	}
	return unique
}

const agentSystemPrompt = `You are NothingClaw, an agent that controls this Linux desktop and the machine behind it.

Work in small steps:
- Look before you leap. List windows, workspaces, monitors or a directory before you try to act on something you have not seen yet.
- Call tools with concrete values you actually observed, never with guesses or placeholder ids.
- When a tool reports an error, read it. Do not retry the same call unchanged.
- Stop as soon as the goal is met, and answer in one or two plain sentences describing what you did. Do not narrate a plan you are not going to execute.

If the goal cannot be achieved with the tools you have, say so plainly instead of inventing a result.`

// ToolInvoker is invoke_tool(name, arguments, ctx) -> {"content","error"}.
type ToolInvoker func(name string, args map[string]any, ctx any) map[string]any

// LogFunc receives progress notes.
type LogFunc func(level, message string)

// runAgent drives tools until the goal is met or the budget runs out.
func runAgent(goal string, invokeTool ToolInvoker, tools []map[string]any,
	ctx any, model, host string, maxSteps int, maxSeconds int,
	allowedTools []string, log LogFunc) (map[string]any, error) {

	if strings.TrimSpace(goal) == "" {
		return nil, &AgentError{"Empty goal"}
	}
	if model == "" {
		model = defaultAgentModel
	}
	if host == "" {
		host = apiBase
	}
	if maxSteps == 0 {
		maxSteps = 12
	}
	if maxSeconds == 0 {
		maxSeconds = 240
	}

	started := time.Now()
	transcript := []map[string]any{}

	note := func(kind string, payload map[string]any) {
		entry := map[string]any{"kind": kind, "t": time.Since(started).Seconds()}
		for k, v := range payload {
			entry[k] = v
		}
		transcript = append(transcript, entry)
		if log != nil {
			enc, _ := json.Marshal(payload)
			s := string(enc)
			if len(s) > 160 {
				s = s[:160]
			}
			log("info", kind+" "+s)
		}
	}

	catalogue := toolSchema(tools, allowedTools)
	if len(catalogue) > maxToolsForAgent {
		catalogue = catalogue[:maxToolsForAgent]
		note("warning", map[string]any{"message": fmt.Sprintf("catalogue trimmed to %d tools", len(catalogue))})
	}

	messages := []map[string]any{
		{"role": "system", "content": agentSystemPrompt},
		{"role": "user", "content": goal},
	}

	stopped := "max_steps"
	answer := ""
	steps := 0

	for steps < maxSteps {
		if time.Since(started).Seconds() > float64(maxSeconds) {
			stopped = "timeout"
			break
		}
		steps++

		message, err := chat(host, model, messages, catalogue, time.Duration(maxSeconds)*time.Second)
		if err != nil {
			note("error", map[string]any{"message": err.Error()})
			stopped = "model_error"
			answer = "Could not reach the model backend: " + err.Error()
			break
		}

		toolCalls := []map[string]any{}
		if tc, ok := message["tool_calls"].([]any); ok {
			for _, c := range tc {
				if cm, ok := c.(map[string]any); ok {
					toolCalls = append(toolCalls, cm)
				}
			}
		}
		text, _ := message["content"].(string)
		text = strings.TrimSpace(text)

		if len(toolCalls) == 0 && text != "" {
			if recovered := extractToolCalls(text); len(recovered) > 0 {
				// OpenAI-compatible turns need an id and a JSON-string
				// argument payload; the text extractor produces neither.
				for i := range recovered {
					recovered[i]["id"] = fmt.Sprintf("call_auto_%d", i)
					recovered[i]["type"] = "function"
					if fn, ok := recovered[i]["function"].(map[string]any); ok {
						if _, isStr := fn["arguments"].(string); !isStr {
							enc, _ := json.Marshal(fn["arguments"])
							fn["arguments"] = string(enc)
						}
					}
				}
				toolCalls = recovered
				names := []string{}
				for _, c := range toolCalls {
					fn, _ := c["function"].(map[string]any)
					n, _ := fn["name"].(string)
					names = append(names, n)
				}
				note("recovered_call", map[string]any{
					"message": "tool call recovered from message text", "tools": names})
			}
		}

		if len(toolCalls) == 0 {
			messages = append(messages, map[string]any{"role": "assistant", "content": text})
			if text == "" {
				text = "The agent finished without producing a message."
			}
			answer = text
			stopped = "done"
			note("answer", map[string]any{"content": answer})
			break
		}

		messages = append(messages, map[string]any{
			"role": "assistant", "content": text, "tool_calls": toolCalls})
		note("thought", map[string]any{"content": text, "tool_calls": len(toolCalls)})

		for _, call := range toolCalls {
			callID, _ := call["id"].(string)
			fn, _ := call["function"].(map[string]any)
			name, _ := fn["name"].(string)
			args := normaliseArguments(fn["arguments"])

			var result map[string]any
			func() {
				defer func() {
					if rec := recover(); rec != nil {
						result = map[string]any{"content": "", "error": fmt.Sprintf("panic: %v", rec)}
					}
				}()
				result = invokeTool(name, args, ctx)
			}()

			content := clip(fmt.Sprintf("%v", result["content"]), 0)
			errStr := ""
			if e, ok := result["error"].(string); ok && e != "" {
				errStr = e
				content = "ERROR: " + e
				if c, ok := result["content"].(string); ok && c != "" {
					content += "\n" + c
				}
			}

			note("observation", map[string]any{
				"tool": name, "arguments": args, "content": content, "error": errStr})
			messages = append(messages, map[string]any{
				"role": "tool", "tool_call_id": callID, "name": name, "content": content})
		}
	}

	finalErr := any(nil)
	if stopped != "done" {
		finalErr = "Agent stopped: " + stopped
	}
	return map[string]any{
		"goal": goal, "answer": answer, "steps": steps,
		"stopped_reason": stopped, "elapsed": time.Since(started).Seconds(),
		"model": model, "transcript": transcript,
		"content": answer, "error": finalErr,
	}, nil
}
