// Tests for the correctness fixes in the NothingClaw bridge: shell-word
// parsing, panic containment, argument coercion, context trimming and the
// tool-call recovery scanner. Run with: go test ./...
package main

import (
	"strings"
	"testing"
)

func TestShellWordsPlainCommand(t *testing.T) {
	words, ok := shellWords("firefox https://example.com")
	if !ok {
		t.Fatalf("plain command rejected")
	}
	if len(words) != 2 || words[0] != "firefox" || words[1] != "https://example.com" {
		t.Fatalf("got %#v", words)
	}
}

func TestShellWordsQuotesAndEscapes(t *testing.T) {
	cases := []struct {
		in   string
		want []string
	}{
		{`gimp "my file.png"`, []string{"gimp", "my file.png"}},
		{`echo 'it is' ok`, []string{"echo", "it is", "ok"}},
		{`echo a\ b`, []string{"echo", "a b"}},
		{`  spaced   out  `, []string{"spaced", "out"}},
		{`echo ""`, []string{"echo", ""}},
	}
	for _, c := range cases {
		got, ok := shellWords(c.in)
		if !ok {
			t.Errorf("shellWords(%q) rejected", c.in)
			continue
		}
		if strings.Join(got, "\x00") != strings.Join(c.want, "\x00") {
			t.Errorf("shellWords(%q) = %#v, want %#v", c.in, got, c.want)
		}
	}
}

// Anything with shell syntax must be refused so the caller falls back to a
// real shell instead of us silently mis-parsing it.
func TestShellWordsRejectsShellSyntax(t *testing.T) {
	for _, in := range []string{
		"foo; rm -rf ~",
		"foo && bar",
		"foo | tee /tmp/x",
		"foo > /tmp/x",
		"$(whoami)",
		"`id`",
		"foo &",
		"*.png",
		"~/bin/run",
		"foo 'unterminated",
		"",
	} {
		if _, ok := shellWords(in); ok {
			t.Errorf("shellWords(%q) accepted, want rejection", in)
		}
	}
}

func TestGuardConvertsPanicToError(t *testing.T) {
	res := guard(func() map[string]any { panic("boom") })
	if res == nil {
		t.Fatal("guard returned nil; the agent loop would show the model <nil>")
	}
	if res["error"] == nil {
		t.Fatalf("guard lost the error: %#v", res)
	}
	if msg, _ := res["error"].(string); !strings.Contains(msg, "boom") {
		t.Fatalf("error %q does not mention the panic", msg)
	}
}

func TestGuardPassesThroughSuccess(t *testing.T) {
	res := guard(func() map[string]any { return okContent("fine") })
	if res["error"] != nil || res["content"] != "fine" {
		t.Fatalf("unexpected result %#v", res)
	}
}

func TestStrArgCoercion(t *testing.T) {
	args := map[string]any{
		"s":   "  hello  ",
		"n":   float64(5),
		"b":   true,
		"i":   7,
		"obj": []string{"x"},
	}
	if got := strArg(args, "s", "d"); got != "hello" {
		t.Errorf("string: %q", got)
	}
	// Integral floats must not render as 5.000000.
	if got := strArg(args, "n", "d"); got != "5" {
		t.Errorf("float: %q", got)
	}
	if got := strArg(args, "b", "d"); got != "true" {
		t.Errorf("bool: %q", got)
	}
	if got := strArg(args, "i", "d"); got != "7" {
		t.Errorf("int: %q", got)
	}
	if got := strArg(args, "missing", "d"); got != "d" {
		t.Errorf("missing: %q", got)
	}
	if got := strArg(args, "obj", "d"); got != "[x]" {
		t.Errorf("fallback: %q", got)
	}
}

func TestEstimateTokensASCIIFasterPathSanity(t *testing.T) {
	// Four Latin chars per token is the documented estimate.
	if n := estimateTokens(strings.Repeat("a", 400)); n < 100 || n > 110 {
		t.Fatalf("estimateTokens(400 ascii) = %d, want ~104", n)
	}
	if n := estimateTokens(""); n != 0 {
		t.Fatalf("empty string = %d", n)
	}
}

func TestTrimMessagesToBudgetKeepsSystemAndLast(t *testing.T) {
	msgs := []map[string]any{
		{"role": "system", "content": "you are helpful"},
		{"role": "user", "content": strings.Repeat("old question ", 400)},
		{"role": "assistant", "content": strings.Repeat("old answer ", 400)},
		{"role": "user", "content": "newest question"},
	}
	out := trimMessagesToBudget(msgs, 200)
	if out[0]["role"] != "system" {
		t.Fatal("dropped the system message")
	}
	if out[len(out)-1]["content"] != "newest question" {
		t.Fatal("dropped the last message")
	}
	if len(out) >= len(msgs) {
		t.Fatalf("nothing was trimmed: %d -> %d", len(msgs), len(out))
	}
}

func TestTrimMessagesToBudgetNoopWhenWithinBudget(t *testing.T) {
	msgs := []map[string]any{
		{"role": "user", "content": "hi"},
		{"role": "assistant", "content": "hello"},
	}
	if got := trimMessagesToBudget(msgs, 10000); len(got) != 2 {
		t.Fatalf("trimmed unnecessarily: %d", len(got))
	}
}

// The old fallback scanner rescanned from every '{', which is quadratic. This
// only asserts correctness; the complexity guard lives in the benchmark.
func TestExtractToolCallsFenceAndBareJSON(t *testing.T) {
	name := func(call map[string]any) string {
		fn, _ := call["function"].(map[string]any)
		n, _ := fn["name"].(string)
		return n
	}
	got := extractToolCalls("I'll do that.\n```json\n{\"name\":\"list_windows\",\"arguments\":{}}\n```")
	if len(got) != 1 || name(got[0]) != "list_windows" {
		t.Fatalf("fence path: %#v", got)
	}
	got = extractToolCalls(`{"name":"system_info","arguments":{"verbose":true}}`)
	if len(got) != 1 || name(got[0]) != "system_info" {
		t.Fatalf("bare path: %#v", got)
	}
	if got := extractToolCalls("no tools here at all"); len(got) != 0 {
		t.Fatalf("expected none, got %#v", got)
	}
}

func BenchmarkTrimMessagesToBudget(b *testing.B) {
	for _, n := range []int{40, 200} {
		msgs := make([]map[string]any, 0, n)
		msgs = append(msgs, map[string]any{"role": "system", "content": "system"})
		for i := 0; i < n-2; i++ {
			msgs = append(msgs, map[string]any{
				"role":    "assistant",
				"content": strings.Repeat("some tool observation text ", 50),
			})
		}
		msgs = append(msgs, map[string]any{"role": "user", "content": "newest"})
		b.Run(string(rune('0'+n/100))+string(rune('0'+(n/10)%10)), func(b *testing.B) {
			b.ReportAllocs()
			for i := 0; i < b.N; i++ {
				_ = trimMessagesToBudget(msgs, 200)
			}
		})
	}
}

func BenchmarkExtractToolCallsLongProse(b *testing.B) {
	// Prose that mentions braces is the pathological input for the old
	// quadratic brace walk.
	prose := strings.Repeat("here is a json object { but it never closes. ", 800) +
		`{"name":"list_windows","arguments":{}}`
	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		_ = extractToolCalls(prose)
	}
}

func BenchmarkStrArg(b *testing.B) {
	args := map[string]any{"s": "hello", "n": float64(5)}
	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		_ = strArg(args, "s", "d")
		_ = strArg(args, "n", "d")
	}
}

// Trimming from the front can slice an assistant/tool pair in half. A tool
// message whose tool_calls were dropped is rejected outright by every
// OpenAI-compatible API, so the trim must never leave one behind.
func TestTrimNeverLeavesOrphanToolMessage(t *testing.T) {
	big := strings.Repeat("observation text ", 400)
	msgs := []map[string]any{
		{"role": "system", "content": "system"},
		{"role": "user", "content": big},
		{"role": "assistant", "content": "", "tool_calls": []any{
			map[string]any{"id": "c1"}}},
		{"role": "tool", "tool_call_id": "c1", "content": big},
		{"role": "assistant", "content": "", "tool_calls": []any{
			map[string]any{"id": "c2"}}},
		{"role": "tool", "tool_call_id": "c2", "content": big},
		{"role": "assistant", "content": "final answer"},
	}
	out := trimMessagesToBudget(msgs, 100)
	sawToolCalls := false
	for _, m := range out {
		switch m["role"] {
		case "assistant":
			_, hasCalls := m["tool_calls"]
			sawToolCalls = hasCalls
		case "tool":
			if !sawToolCalls {
				t.Fatalf("orphan tool message survived the trim: %#v", out)
			}
		default:
			sawToolCalls = false
		}
	}
}

func TestTrimKeepsFinalAssistantAnswer(t *testing.T) {
	big := strings.Repeat("x", 4000)
	msgs := []map[string]any{
		{"role": "system", "content": "system"},
		{"role": "user", "content": big},
		{"role": "assistant", "content": big},
		{"role": "user", "content": big},
		{"role": "assistant", "content": "the answer"},
	}
	out := trimMessagesToBudget(msgs, 50)
	last := out[len(out)-1]
	if last["content"] != "the answer" {
		t.Fatalf("final answer dropped: %#v", last)
	}
}
