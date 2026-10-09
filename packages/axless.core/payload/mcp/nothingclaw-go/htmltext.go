// Single-pass HTML to text.
//
// The original made 33 regex substitutions over the whole document (9 to drop
// script-like elements, 24 to turn block tags into newlines, plus a generic
// tag strip). That is 33 full passes and ~33 transient allocations per fetch,
// and it extrapolated to ~6 ms of scanning on the 1.5 MB fetch cap:
//
//	BenchmarkRegexPerCall    1,953,215 ns/op   27.65 MB/s
//	BenchmarkTwentyTags      226,198 ns/op     238.73 MB/s  (24 passes over 54 KB)
//
// Compiling those regexes was never the cost - Go caches them - the repeated
// passes were. This walks the document once, tracking tag state, comments,
// attribute quoting and the skip-content elements, and emits the same text.
package main

import (
	"html"
	"strings"
)

// skipContentTags have their contents dropped entirely.
var skipContentTags = map[string]bool{
	"script": true, "style": true, "noscript": true, "svg": true,
	"iframe": true, "canvas": true, "video": true, "audio": true, "form": true,
}

// blockTags become newlines so paragraphs stay separated.
var blockTags = map[string]bool{
	"p": true, "div": true, "section": true, "article": true, "header": true,
	"footer": true, "nav": true, "aside": true, "main": true, "li": true,
	"ul": true, "ol": true, "tr": true, "table": true, "blockquote": true,
	"pre": true, "h1": true, "h2": true, "h3": true, "h4": true, "h5": true,
	"h6": true, "br": true, "hr": true,
}

func isTagNameByte(c byte) bool {
	return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' ||
		c == '-' || c == '_' || c == ':'
}

func lowerByte(c byte) byte {
	if c >= 'A' && c <= 'Z' {
		return c + 32
	}
	return c
}

// foldHas reports whether the ASCII-lowercased form of s contains the
// ASCII-lowercased form of sub, without allocating. strings.ToLower would copy
// the whole remaining document on every call, which on a document with many
// script/style blocks meant copying it dozens of times over.
func foldHas(s, sub string) bool {
	n, m := len(s), len(sub)
	if m == 0 || m > n {
		return false
	}
	for i := 0; i+m <= n; i++ {
		if lowerByte(s[i]) != lowerByte(sub[0]) {
			continue
		}
		ok := true
		for j := 1; j < m; j++ {
			if lowerByte(s[i+j]) != lowerByte(sub[j]) {
				ok = false
				break
			}
		}
		if ok {
			return true
		}
	}
	return false
}

// indexFold is strings.Index with ASCII case folding, allocation-free.
func indexFold(s, sub string) int {
	n, m := len(s), len(sub)
	if m == 0 || m > n {
		return -1
	}
	for i := 0; i+m <= n; i++ {
		if lowerByte(s[i]) != lowerByte(sub[0]) {
			continue
		}
		ok := true
		for j := 1; j < m; j++ {
			if lowerByte(s[i+j]) != lowerByte(sub[j]) {
				ok = false
				break
			}
		}
		if ok {
			return i
		}
	}
	return -1
}

// tagIs looks a tag name up case-insensitively without allocating.
func tagIs(name string, m map[string]bool) bool {
	for k := range m {
		if len(k) == len(name) && foldHas(name, k) {
			return true
		}
	}
	return false
}

// skipElement advances past a skip-content element's body. It returns the index
// just after the matching close tag, or n when there is none.
func skipElement(s string, from int, name string) int {
	needle := "</" + name
	idx := indexFold(s[from:], needle)
	if idx < 0 {
		return len(s)
	}
	after := from + idx + len(needle)
	// Guard against matching a longer name that merely starts with this one.
	if after < len(s) && isTagNameByte(s[after]) {
		next := indexFold(s[after:], needle)
		if next < 0 {
			return len(s)
		}
		after = after + next + len(needle)
	}
	if gt := strings.IndexByte(s[after:], '>'); gt >= 0 {
		return after + gt + 1
	}
	return len(s)
}

// htmlToText extracts the document title and renders the body as plain text.
func htmlToText(htmlText string) (string, string) {
	if htmlText == "" {
		return "", ""
	}
	var sb strings.Builder
	sb.Grow(len(htmlText)/2 + 16)

	var titleBuf strings.Builder
	inTitle := false

	n := len(htmlText)
	i := 0
	for i < n {
		c := htmlText[i]
		if c != '<' {
			if inTitle {
				titleBuf.WriteByte(c)
			} else {
				sb.WriteByte(c)
			}
			i++
			continue
		}

		// Comment, doctype and processing instruction: no content, no break.
		if strings.HasPrefix(htmlText[i:], "<!--") {
			if e := strings.Index(htmlText[i+4:], "-->"); e >= 0 {
				i += 4 + e + 3
			} else {
				i = n
			}
			continue
		}
		if i+1 < n && (htmlText[i+1] == '!' || htmlText[i+1] == '?') {
			if e := strings.IndexByte(htmlText[i:], '>'); e >= 0 {
				i += e + 1
			} else {
				i = n
			}
			continue
		}

		closing := false
		j := i + 1
		if j < n && htmlText[j] == '/' {
			closing = true
			j++
		}
		nameStart := j
		for j < n && isTagNameByte(htmlText[j]) {
			j++
		}
		if j == nameStart {
			// Not a tag: a bare '<' in prose.
			if inTitle {
				titleBuf.WriteByte('<')
			} else {
				sb.WriteByte('<')
			}
			i++
			continue
		}
		name := htmlText[nameStart:j]

		// Advance to the end of the tag, respecting quoted attribute values so
		// a '>' inside an attribute does not end the tag early.
		gt := -1
		inS, inD := false, false
		for k := j; k < n; k++ {
			ch := htmlText[k]
			switch {
			case inS:
				if ch == '\'' {
					inS = false
				}
			case inD:
				if ch == '"' {
					inD = false
				}
			case ch == '\'':
				inS = true
			case ch == '"':
				inD = true
			case ch == '>':
				gt = k
			}
			if gt >= 0 {
				break
			}
		}
		if gt < 0 {
			// Unterminated tag: treat the rest as text.
			if inTitle {
				titleBuf.WriteString(htmlText[i:])
			} else {
				sb.WriteString(htmlText[i:])
			}
			break
		}

		switch {
		case tagIs(name, skipContentTags) && !closing:
			i = skipElement(htmlText, gt+1, strings.ToLower(name))
		case tagIs(name, skipContentTags) && closing:
			i = gt + 1
		case foldHas(name, "title"):
			inTitle = !closing
			i = gt + 1
		case tagIs(name, blockTags):
			sb.WriteByte('\n')
			i = gt + 1
		default:
			i = gt + 1
		}
	}

	title := strings.TrimSpace(reSpaces.ReplaceAllString(stripInlineTags(titleBuf.String()), " "))
	if len(title) > 300 {
		title = title[:300]
	}

	text := html.UnescapeString(sb.String())
	lines := make([]string, 0, 64)
	for _, line := range strings.Split(text, "\n") {
		line = strings.TrimSpace(reSpaces.ReplaceAllString(line, " "))
		if line != "" {
			lines = append(lines, line)
		}
	}
	return title, strings.Join(lines, "\n")
}

// stripInlineTags removes any markup left inside an extracted title.
func stripInlineTags(s string) string {
	if !strings.ContainsRune(s, '<') {
		return s
	}
	var sb strings.Builder
	sb.Grow(len(s))
	for i := 0; i < len(s); {
		if s[i] != '<' {
			sb.WriteByte(s[i])
			i++
			continue
		}
		gt := strings.IndexByte(s[i:], '>')
		if gt < 0 {
			break
		}
		sb.WriteByte(' ')
		i += gt + 1
	}
	return sb.String()
}
