// Context-budget helpers for NothingClaw, ported from context_budget.py.
//
// Pure standard library. Estimates token counts without a tokenizer (~4
// chars/token for Latin/code, ~1.5 for CJK), resolves a model's input budget
// from a table of known context windows with headroom, and truncates tool
// results at a natural boundary so the cut is invisible to the model.
package main

import (
	"strings"
	"unicode"
)

type cjkRange struct{ lo, hi rune }

var cjkRanges = []cjkRange{
	{0x4E00, 0x9FFF}, // CJK Unified Ideographs
	{0x3400, 0x4DBF}, // CJK Extension A
	{0x3040, 0x309F}, // Hiragana
	{0x30A0, 0x30FF}, // Katakana
	{0xAC00, 0xD7AF}, // Hangul Syllables
	{0xFF00, 0xFFEF}, // Halfwidth/Fullwidth
}

func isCJK(r rune) bool {
	for _, rng := range cjkRanges {
		if r >= rng.lo && r <= rng.hi {
			return true
		}
	}
	return false
}

// estimateTokens approximates the token count for a string.
func estimateTokens(text string) int {
	if text == "" {
		return 0
	}
	var latin, cjk, other int
	for _, r := range text {
		switch {
		case unicode.IsSpace(r):
			other++
		case isCJK(r):
			cjk++
		case r < 128:
			latin++
		default:
			other++
		}
	}
	tokens := float64(latin)/4.0 + float64(cjk)/1.5 + float64(other)/4.0
	return int(tokens) + 4
}

type contextWindow struct {
	needle string
	ctx    int
}

// Known context windows, longest-prefix match wins. Order is not required to
// be sorted because the lookup scans for the longest match.
var knownContextWindows = []contextWindow{
	{"gpt-5", 400000},
	{"gpt-4.1", 1000000},
	{"gpt-4o", 128000},
	{"gpt-4-turbo", 128000},
	{"gpt-4", 8192},
	{"o1-preview", 128000},
	{"o1-mini", 128000},
	{"o3-mini", 200000},
	{"gpt-3.5-turbo", 16385},
	{"claude-3-opus", 200000},
	{"claude-3.5-sonnet", 200000},
	{"claude-3-sonnet", 200000},
	{"claude-3-haiku", 200000},
	{"claude-4", 200000},
	{"gemini-2.5-pro", 1000000},
	{"gemini-2.0-pro", 2000000},
	{"gemini-2.0-flash", 1000000},
	{"gemini-1.5-pro", 2000000},
	{"gemini-1.5-flash", 1000000},
	{"deepseek-chat", 128000},
	{"deepseek-reasoner", 128000},
	{"mistral-large", 128000},
	{"mistral-medium", 32768},
	{"mistral-small", 32768},
	{"grok-2", 131072},
	{"llama-3.1-405b", 131072},
	{"llama-3.1-70b", 131072},
	{"llama-3.1-8b", 131072},
	{"qwen2.5-72b", 131072},
	{"qwen2.5-32b", 131072},
	{"qwen2.5-14b", 131072},
	{"qwen2.5-7b", 32768},
	{"qwen2.5-3b", 32768},
	{"qwen2.5-1.5b", 32768},
	{"qwen2.5-0.5b", 32768},
	{"command-r-plus", 128000},
	{"phi-3-medium", 4096},
	{"phi-3-small", 4096},
	{"phi-3-mini", 4096},
	{":70b", 32768},
	{":32b", 32768},
	{":14b", 16384},
	{":13b", 8192},
	{":8b", 8192},
	{":7b", 8192},
	{":3b", 4096},
	{":1.5b", 4096},
	{":1b", 4096},
	{"-8b", 8192},
	{"-7b", 8192},
	{"-3b", 4096},
}

// lookupKnownContext returns the context window for a model name, or 0 when
// unknown. Longest-prefix match wins; a provider prefix is stripped first.
func lookupKnownContext(modelName string) int {
	if modelName == "" {
		return 0
	}
	cleaned := strings.ToLower(strings.TrimSpace(modelName))
	if i := strings.Index(cleaned, "/"); i >= 0 {
		cleaned = cleaned[i+1:]
	}
	best := 0
	bestLen := 0
	for _, cw := range knownContextWindows {
		if strings.Contains(cleaned, cw.needle) && len(cw.needle) > bestLen {
			best = cw.ctx
			bestLen = len(cw.needle)
		}
	}
	return best
}

var defaultToolResultBudget = map[string]int{
	"tiny": 1000, "small": 2000, "medium": 4000, "large": 8000,
}

// computeInputTokenBudget resolves the effective input budget.
func computeInputTokenBudget(configured, contextLength int) int {
	const def = 6000
	const headroom = 0.85
	const hardMax = 200000
	if configured > 0 {
		if configured > hardMax {
			return hardMax
		}
		return configured
	}
	if contextLength > 0 {
		v := int(float64(contextLength) * headroom)
		if v > hardMax {
			return hardMax
		}
		return v
	}
	return def
}

// toolResultBudget returns the per-tool-result token budget for a tier.
func toolResultBudget(tier string) int {
	if tier == "" {
		return defaultToolResultBudget["small"]
	}
	if v, ok := defaultToolResultBudget[strings.ToLower(tier)]; ok {
		return v
	}
	return defaultToolResultBudget["small"]
}

const defaultTruncateMarker = "\n\n[Result truncated to fit the model's context budget. " +
	"Call again with a more specific query for the rest.]"

// truncateToBudget truncates text to about maxTokens, cutting at the nearest
// paragraph/sentence/line boundary. Returns the text and whether it was cut.
func truncateToBudget(text string, maxTokens int, marker string) (string, bool) {
	if text == "" {
		return text, false
	}
	if estimateTokens(text) <= maxTokens {
		return text, false
	}
	approxChars := int(float64(maxTokens) * 4 * 1.1)
	if approxChars >= len(text) {
		return text, false
	}
	cut := text[:approxChars]
	boundaries := []string{"\n\n", ". ", ".\n", "\n"}
	cutAt := -1
	for _, sep := range boundaries {
		idx := strings.LastIndex(cut, sep)
		if idx > int(float64(approxChars)*0.6) {
			cutAt = idx + len(sep)
			break
		}
	}
	if cutAt >= 0 {
		cut = strings.TrimRight(cut[:cutAt], " \t\n")
	} else if idx := strings.LastIndex(cut, " "); idx > int(float64(approxChars)*0.6) {
		cut = cut[:idx]
	}
	if marker == "" {
		marker = defaultTruncateMarker
	}
	return cut + marker, true
}

// chatMessage is the minimal shape the trimming helper needs.
type chatMessage struct {
	Role    string `json:"role"`
	Content any    `json:"content"`
}

func messageContent(m map[string]any) string {
	if s, ok := m["content"].(string); ok {
		return s
	}
	return ""
}

// trimMessagesToBudget drops the oldest non-system turns until the estimated
// total fits, always keeping system messages and the last message.
func trimMessagesToBudget(messages []map[string]any, maxTokens int) []map[string]any {
	if len(messages) == 0 {
		return messages
	}
	total := 0
	for _, m := range messages {
		total += estimateTokens(messageContent(m))
	}
	if total <= maxTokens {
		return messages
	}
	out := make([]map[string]any, len(messages))
	copy(out, messages)

	protected := func(idx []map[string]any) map[int]bool {
		p := map[int]bool{}
		for i, m := range idx {
			if m["role"] == "system" || i == len(idx)-1 {
				p[i] = true
			}
		}
		return p
	}

	for total > maxTokens && len(out) > 1 {
		p := protected(out)
		drop := -1
		for i := range out {
			if !p[i] {
				drop = i
				break
			}
		}
		if drop < 0 {
			break
		}
		out = append(out[:drop], out[drop+1:]...)
		total = 0
		for _, m := range out {
			total += estimateTokens(messageContent(m))
		}
	}
	return out
}
