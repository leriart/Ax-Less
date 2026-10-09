// NothingClaw bridge - knowledge tools: HTML->text, public-URL guard,
// web_search (SearXNG + DuckDuckGo fallback), fetch_url and the local RAG.
// Ported from server.py. Standard library only.
package main

import (
	"crypto/sha1"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"html"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"
)

// ---- HTML -> text ----

var (
	reComment    = regexp.MustCompile(`(?s)<!--.*?-->`)
	reTags       = regexp.MustCompile(`<[^>]+>`)
	reSpaces     = regexp.MustCompile(`[ \t]+`)
	reBlankLines = regexp.MustCompile(`\n\s*\n+`)
	reTitleTag   = regexp.MustCompile(`(?is)<title[^>]*>(.*?)</title>`)
)

// ---- public web URL guard ----

func isPublicWebURL(raw string) bool {
	u, err := url.Parse(raw)
	if err != nil {
		return false
	}
	if u.Scheme != "http" && u.Scheme != "https" {
		return false
	}
	host := strings.ToLower(u.Hostname())
	if host == "" {
		return false
	}
	switch host {
	case "localhost", "ip6-localhost", "ip6-loopback", "::1", "::":
		return false
	}
	if strings.HasPrefix(host, "127.") || strings.HasPrefix(host, "10.") ||
		strings.HasPrefix(host, "192.168.") || strings.HasPrefix(host, "169.254.") {
		return false
	}
	if strings.HasPrefix(host, "172.") {
		parts := strings.Split(host, ".")
		if len(parts) >= 2 {
			if n, err := parseUint8(parts[1]); err == nil && n >= 16 && n <= 31 {
				return false
			}
		}
	}
	if strings.HasPrefix(host, "100.") {
		parts := strings.Split(host, ".")
		if len(parts) >= 2 {
			if n, err := parseUint8(parts[1]); err == nil && n >= 64 && n <= 127 {
				return false
			}
		}
	}
	if strings.HasPrefix(host, "fe80:") || strings.HasPrefix(host, "fc") || strings.HasPrefix(host, "fd") {
		return false
	}
	return true
}

func parseUint8(s string) (int, error) {
	n := 0
	if s == "" {
		return 0, fmt.Errorf("empty")
	}
	for _, r := range s {
		if r < '0' || r > '9' {
			return 0, fmt.Errorf("nan")
		}
		n = n*10 + int(r-'0')
	}
	return n, nil
}

var httpClient = &http.Client{Timeout: 15 * time.Second}

// httpBodyCap bounds every generic GET. fetchURL has its own larger cap; this
// one previously used io.ReadAll with no limit, so a hostile or broken endpoint
// could drive the bridge out of memory.
const httpBodyCap = 2 << 20 // 2 MiB

func httpGet(rawURL string, headers map[string]string) (string, string, error) {
	req, err := http.NewRequest("GET", rawURL, nil)
	if err != nil {
		return "", "", err
	}
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	resp, err := httpClient.Do(req)
	if err != nil {
		return "", "", err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, httpBodyCap))
	if err != nil {
		return "", "", err
	}
	return string(body), resp.Header.Get("Content-Type"), nil
}

// ---- web_search ----

var defaultMaxResults = map[string]int{"tiny": 3, "small": 5, "medium": 8, "large": 10}

func webSearch(args map[string]any, ctx *requestContext) map[string]any {
	query := strArg(args, "query", "")
	if query == "" {
		return errContent("web_search needs a query")
	}
	cap := intArg(args, "max_results", 0)
	if cap <= 0 {
		cap = defaultMaxResults[ctx.Tier]
		if cap == 0 {
			cap = 5
		}
	}
	if cap > 10 {
		cap = 10
	}
	timeFilter := strArg(args, "time_filter", "")
	region := strArg(args, "region", "")

	var results []map[string]any
	var errStr string
	if searxng := strings.TrimSpace(os.Getenv("NOTHINGCLAW_SEARXNG_URL")); searxng != "" {
		results, errStr = searxngSearch(searxng, query, cap, timeFilter, region)
		if errStr != "" && strings.Contains(strings.ToLower(errStr), "unreachable") {
			results, errStr = ddgSearch(query, cap, timeFilter)
		}
	} else {
		results, errStr = ddgSearch(query, cap, timeFilter)
	}
	if errStr != "" && len(results) == 0 {
		return errContent(errStr)
	}
	if len(results) == 0 {
		return okContent("No results found for: " + query)
	}

	snippetCap := ctx.ToolBudget * 3 / max(len(results), 1)
	if snippetCap < 160 {
		snippetCap = 160
	}
	if snippetCap > 800 {
		snippetCap = 800
	}
	lines := []string{"Web results for: " + query + "\n"}
	sources := []map[string]any{}
	for i, r := range results {
		title, _ := r["title"].(string)
		u, _ := r["url"].(string)
		snippet, _ := r["snippet"].(string)
		if len(title) > 200 {
			title = title[:200]
		}
		if len(snippet) > snippetCap {
			cut := strings.LastIndex(snippet[:snippetCap], " ")
			if cut > 0 {
				snippet = snippet[:cut] + "..."
			} else {
				snippet = snippet[:snippetCap] + "..."
			}
		}
		lines = append(lines, fmt.Sprintf("[%d] %s", i+1, title))
		lines = append(lines, "    "+u)
		lines = append(lines, "    "+snippet)
		lines = append(lines, "")
		sources = append(sources, map[string]any{"i": i + 1, "url": u, "title": title})
	}
	body := strings.TrimRight(strings.Join(lines, "\n"), "\n")
	srcJSON, _ := json.Marshal(sources)
	body += "\n\n<!-- sources: " + string(srcJSON) + " -->"
	body, _ = truncateToBudget(body, ctx.ToolBudget, "")
	return okContent(body)
}

func searxngSearch(baseURL, query string, cap int, timeFilter, region string) ([]map[string]any, string) {
	q := url.Values{}
	q.Set("q", query)
	q.Set("format", "json")
	q.Set("language", "en")
	q.Set("safesearch", "0")
	if region != "" {
		q.Set("region", region)
	}
	if timeFilter != "" {
		q.Set("time_range", timeFilter)
	}
	body, _, err := httpGet(strings.TrimRight(baseURL, "/")+"/search?"+q.Encode(), map[string]string{
		"User-Agent": "NothingClaw/1.0 (+https://github.com/Leriart/NothingLess)",
		"Accept":     "application/json",
	})
	if err != nil {
		return nil, "SearXNG unreachable: " + err.Error()
	}
	var data map[string]any
	if err := json.Unmarshal([]byte(body), &data); err != nil {
		return nil, "SearXNG returned malformed JSON: " + err.Error()
	}
	results := []map[string]any{}
	raw, _ := data["results"].([]any)
	for i, e := range raw {
		if i >= cap {
			break
		}
		m, _ := e.(map[string]any)
		title, _ := m["title"].(string)
		u, _ := m["url"].(string)
		content, _ := m["content"].(string)
		results = append(results, map[string]any{"title": title, "url": u, "snippet": content})
	}
	return results, ""
}

var reDDG = regexp.MustCompile(`(?is)<a[^>]+class="result__a"[^>]+href="([^"]+)"[^>]*>(.*?)</a>.*?<a[^>]+class="result__snippet"[^>]*>(.*?)</a>`)

func ddgSearch(query string, cap int, timeFilter string) ([]map[string]any, string) {
	dfMap := map[string]string{"day": "d", "week": "w", "month": "m", "year": "y"}
	q := url.Values{}
	q.Set("q", query)
	q.Set("kl", "us-en")
	if df := dfMap[timeFilter]; df != "" {
		q.Set("df", df)
	}
	target := "https://html.duckduckgo.com/html/?" + q.Encode()
	body, _, err := httpGet(target, map[string]string{
		"User-Agent":      "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36",
		"Accept":          "text/html,application/xhtml+xml",
		"Accept-Language": "en-US,en;q=0.9",
	})
	if err != nil {
		return nil, "DuckDuckGo unreachable: " + err.Error()
	}
	results := []map[string]any{}
	for _, m := range reDDG.FindAllStringSubmatch(body, -1) {
		href := m[1]
		title := strings.TrimSpace(reTags.ReplaceAllString(m[2], ""))
		snippet := html.UnescapeString(strings.TrimSpace(reTags.ReplaceAllString(m[3], "")))
		if strings.Contains(href, "uddg=") {
			if u, err := url.Parse(href); err == nil {
				if real := u.Query().Get("uddg"); real != "" {
					href = real
				}
			}
		}
		if href == "" || title == "" {
			continue
		}
		results = append(results, map[string]any{"title": title, "url": href, "snippet": snippet})
		if len(results) >= cap {
			break
		}
	}
	if len(results) == 0 {
		return nil, "No results found for: " + query + " (DDG HTML page may have changed shape)"
	}
	return results, ""
}

// ---- fetch_url ----

const fetchHardMaxBytes = 1_500_000

func fetchURL(args map[string]any, ctx *requestContext) map[string]any {
	raw := strArg(args, "url", "")
	if raw == "" {
		return errContent("fetch_url needs a url")
	}
	if !strings.HasPrefix(raw, "http://") && !strings.HasPrefix(raw, "https://") {
		switch {
		case strings.HasPrefix(raw, "//"):
			raw = "https:" + raw
		case strings.HasPrefix(raw, "www."):
			raw = "https://" + raw
		default:
			return errContent("fetch_url only accepts http://, https://, or www.* URLs. Local paths and file:// are blocked - use the read_file tool or run_shell_command.")
		}
	}
	if !isPublicWebURL(raw) {
		return errContent("fetch_url is for the public web only. Refusing to fetch local / private addresses. Use the read_file tool or a shell command for local files.")
	}
	maxBytes := intArg(args, "max_bytes", 0)
	if maxBytes <= 0 || maxBytes > fetchHardMaxBytes {
		maxBytes = fetchHardMaxBytes
	}
	full := boolArg(args, "full", false)

	req, err := http.NewRequest("GET", raw, nil)
	if err != nil {
		return errContent("fetch_url: " + err.Error())
	}
	req.Header.Set("User-Agent", "NothingClaw/1.0 (+https://github.com/Leriart/NothingLess)")
	req.Header.Set("Accept", "text/html,application/xhtml+xml,text/plain;q=0.9")
	resp, err := httpClient.Do(req)
	if err != nil {
		return errContent("fetch_url: " + err.Error())
	}
	defer resp.Body.Close()
	limited := io.LimitReader(resp.Body, int64(maxBytes)+1)
	rawBytes, _ := io.ReadAll(limited)
	truncated := len(rawBytes) > maxBytes
	if truncated {
		rawBytes = rawBytes[:maxBytes]
	}
	ctype := resp.Header.Get("Content-Type")
	text := string(rawBytes)

	if !strings.Contains(strings.ToLower(ctype), "html") &&
		!strings.Contains(strings.ToLower(text[:min(200, len(text))]), "<html") {
		plain := text
		if !full {
			plain, _ = truncateToBudget(plain, ctx.ToolBudget, "")
		}
		return okContent("# " + raw + "\nContent-Type: " + ctype + "\n\n" + plain)
	}

	title, body := htmlToText(text)
	sizeNote := ""
	if truncated {
		sizeNote = fmt.Sprintf("[Note: response was %d+ bytes; truncated to %d before HTML->text conversion.]\n\n", maxBytes, maxBytes)
	}
	out := "# " + firstNonEmpty(title, raw) + "\nSource: " + raw + "\n\n" + sizeNote + body
	if !full {
		var wasTruncated bool
		out, wasTruncated = truncateToBudget(out, ctx.ToolBudget, "")
		if wasTruncated && sizeNote == "" {
			out = "[Note: response truncated to fit the model's context budget. Call fetch_url again with full=true or a more specific URL to see the rest.]\n\n" + out
		}
	}
	return okContent(out)
}

func firstNonEmpty(a, b string) string {
	if a != "" {
		return a
	}
	return b
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}

func max(a, b int) int {
	if a > b {
		return a
	}
	return b
}

// ---- manage_rag ----

const ragDirName = "rag"

var ragTextExts = map[string]bool{
	".md": true, ".txt": true, ".rst": true, ".org": true, ".adoc": true,
	".py": true, ".js": true, ".ts": true, ".jsx": true, ".tsx": true, ".mjs": true, ".cjs": true,
	".json": true, ".yaml": true, ".yml": true, ".toml": true, ".xml": true, ".csv": true, ".tsv": true,
	".html": true, ".htm": true, ".css": true, ".scss": true, ".sass": true, ".less": true,
	".sh": true, ".bash": true, ".zsh": true, ".fish": true, ".ps1": true,
	".c": true, ".h": true, ".cpp": true, ".cc": true, ".cxx": true, ".hpp": true, ".rs": true, ".go": true,
	".java": true, ".kt": true, ".scala": true, ".rb": true, ".php": true, ".pl": true, ".lua": true,
	".sql": true, ".graphql": true, ".proto": true,
	".env": true, ".conf": true, ".cfg": true, ".ini": true, ".properties": true,
	".log": true, ".gitignore": true, ".dockerignore": true,
}

var ragSkipDirs = map[string]bool{
	".git": true, "node_modules": true, "__pycache__": true, "venv": true, ".venv": true,
	"target": true, "build": true, "dist": true, ".cache": true, ".next": true, ".nuxt": true,
	".mypy_cache": true, ".pytest_cache": true, ".ruff_cache": true, "vendor": true,
}

func ragIndexPath(absDir string) string {
	h := sha1.Sum([]byte(absDir))
	hexHash := hex.EncodeToString(h[:])[:16]
	safe := regexp.MustCompile(`[^a-zA-Z0-9_-]`).ReplaceAllString(filepath.Base(absDir), "_")
	if len(safe) > 40 {
		safe = safe[:40]
	}
	if safe == "" {
		safe = "root"
	}
	d := filepath.Join(xdgDataHome(), "ambxst", ragDirName)
	_ = os.MkdirAll(d, 0o755)
	return filepath.Join(d, safe+"_"+hexHash+".json")
}

func isProbablyText(path string) bool {
	f, err := os.Open(path)
	if err != nil {
		return false
	}
	defer f.Close()
	sample := make([]byte, 4096)
	n, _ := f.Read(sample)
	sample = sample[:n]
	if len(sample) == 0 {
		return true
	}
	printable := 0
	for _, b := range sample {
		if b == 0 {
			return false
		}
		if (b >= 32 && b <= 126) || b == 9 || b == 10 || b == 13 {
			printable++
		}
	}
	return float64(printable)/float64(len(sample)) >= 0.85
}

var reTok = regexp.MustCompile(`[a-z0-9_]{2,}`)

func tokenize(text string) []string {
	return reTok.FindAllString(strings.ToLower(text), -1)
}

func chunkText(text string, maxChars int) []string {
	if len(text) <= maxChars {
		return []string{text}
	}
	chunks := []string{}
	rest := text
	for len(rest) > maxChars {
		cut := -1
		for _, sep := range []string{"\n\n", "\n", ". "} {
			idx := strings.LastIndex(rest[:maxChars], sep)
			if idx > maxChars/2 {
				cut = idx + len(sep)
				break
			}
		}
		if cut <= 0 {
			idx := strings.LastIndex(rest[:maxChars], " ")
			if idx > maxChars*3/10 {
				cut = idx + 1
			} else {
				cut = maxChars
			}
		}
		chunks = append(chunks, strings.TrimRight(rest[:cut], " \t\n"))
		rest = strings.TrimLeft(rest[cut:], " \t\n")
	}
	if rest != "" {
		chunks = append(chunks, rest)
	}
	return chunks
}

func manageRag(args map[string]any, ctx *requestContext) map[string]any {
	action := strArg(args, "action", "")
	if action == "" {
		return errContent("manage_rag needs action=list|add_directory|remove_directory|search")
	}
	ragSearchDir := filepath.Join(xdgDataHome(), "ambxst", ragDirName)

	switch action {
	case "list":
		entries, err := os.ReadDir(ragSearchDir)
		if err != nil {
			return okContent("No RAG indexes yet. Use action=add_directory first.")
		}
		lines := []string{"Indexed RAG directories:\n"}
		found := false
		names := []string{}
		for _, e := range entries {
			if strings.HasSuffix(e.Name(), ".json") {
				names = append(names, e.Name())
			}
		}
		sort.Strings(names)
		for _, fn := range names {
			data, err := os.ReadFile(filepath.Join(ragSearchDir, fn))
			if err != nil {
				continue
			}
			var idx map[string]any
			if json.Unmarshal(data, &idx) != nil {
				continue
			}
			files, _ := idx["files"].(map[string]any)
			chunkTotal := 0
			for _, f := range files {
				fm, _ := f.(map[string]any)
				if ch, ok := fm["chunks"].([]any); ok {
					chunkTotal += len(ch)
				}
			}
			dir, _ := idx["directory"].(string)
			lines = append(lines, "- "+dir)
			lines = append(lines, fmt.Sprintf("    files: %d, chunks: %d, updated: %v", len(files), chunkTotal, idx["updated_at"]))
			found = true
		}
		if !found {
			return okContent("No RAG indexes yet. Use action=add_directory first.")
		}
		return okContent(strings.Join(lines, "\n"))

	case "add_directory":
		directory := strArg(args, "directory", "")
		if directory == "" {
			return errContent("add_directory needs a directory path")
		}
		directory = expandAbs(directory)
		if info, err := os.Stat(directory); err != nil || !info.IsDir() {
			return errContent("Directory not found: " + directory)
		}
		maxChunk := intArg(args, "max_chunk_chars", 0)
		if maxChunk == 0 {
			maxChunk = 1200
		}
		return manageRagScan(directory, ragIndexPath(directory), maxChunk)

	case "remove_directory":
		directory := strArg(args, "directory", "")
		if directory == "" {
			return errContent("remove_directory needs a directory path")
		}
		directory = expandAbs(directory)
		idxPath := ragIndexPath(directory)
		if err := os.Remove(idxPath); err != nil {
			return errContent("No RAG index for: " + directory)
		}
		invalidateRag(idxPath)
		return okContent("Removed RAG index for: " + directory)

	case "search":
		query := strArg(args, "query", "")
		if query == "" {
			return errContent("manage_rag search needs a query")
		}
		topK := intArg(args, "top_k", 0)
		if topK <= 0 || topK > 50 {
			topK = 5
		}
		if _, err := os.ReadDir(ragSearchDir); err != nil {
			return errContent("No RAG indexes yet. Use add_directory first.")
		}
		queryTerms := tokenize(query)
		if len(queryTerms) == 0 {
			return errContent("Query has no indexable terms.")
		}
		ranked := searchRag(ragIndexFiles(ragSearchDir), queryTerms, topK)
		if len(ranked) == 0 {
			return errContent("RAG index is empty - add a directory first.")
		}
		perChunkCap := ctx.ToolBudget * 4 / max(len(ranked), 1)
		if perChunkCap < 400 {
			perChunkCap = 400
		}
		if perChunkCap > 2000 {
			perChunkCap = 2000
		}
		lines := []string{"RAG search results for: " + query + "\n"}
		hits := 0
		budgetLeft := ctx.ToolBudget
		for i, r := range ranked {
			if r.Score <= 0 || budgetLeft <= 0 {
				break
			}
			text := r.Chunk.Text
			if len(text) > perChunkCap {
				cut := strings.LastIndex(text[:perChunkCap], " ")
				if cut > 0 {
					text = text[:cut] + "..."
				} else {
					text = text[:perChunkCap] + "..."
				}
			}
			approxTokens := max(1, len(text)/4)
			if approxTokens > budgetLeft {
				continue
			}
			budgetLeft -= approxTokens
			lines = append(lines, fmt.Sprintf("[%d] score=%.3f  %s", i+1, r.Score, r.Chunk.ID))
			lines = append(lines, "    dir: "+r.Chunk.Dir)
			lines = append(lines, "    "+strings.ReplaceAll(text, "\n", "\n    "))
			lines = append(lines, "")
			hits++
		}
		if hits == 0 {
			return okContent("No matching chunks found for: " + query)
		}
		return okContent(strings.TrimRight(strings.Join(lines, "\n"), "\n"))
	}
	return errContent("Unknown action '" + action + "'. Use: list, add_directory, remove_directory, search")
}

func expandAbs(p string) string {
	if strings.HasPrefix(p, "~") {
		home, _ := os.UserHomeDir()
		p = filepath.Join(home, strings.TrimPrefix(p, "~"))
	}
	abs, err := filepath.Abs(p)
	if err != nil {
		return p
	}
	return abs
}

func manageRagScan(absDir, indexPath string, maxChunkChars int) map[string]any {
	absDir, _ = filepath.Abs(absDir)
	index := map[string]any{"directory": absDir, "files": map[string]any{}}
	if data, err := os.ReadFile(indexPath); err == nil {
		_ = json.Unmarshal(data, &index)
	}
	oldFiles, _ := index["files"].(map[string]any)
	if oldFiles == nil {
		oldFiles = map[string]any{}
	}
	seen := map[string]bool{}
	indexedCount, fileCount := 0, 0

	_ = filepath.WalkDir(absDir, func(p string, d os.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		name := d.Name()
		if d.IsDir() {
			if p != absDir && (ragSkipDirs[name] || strings.HasPrefix(name, ".")) {
				return filepath.SkipDir
			}
			return nil
		}
		ext := strings.ToLower(filepath.Ext(name))
		if !ragTextExts[ext] {
			return nil
		}
		seen[p] = true
		info, err := d.Info()
		if err != nil {
			return nil
		}
		mtime := info.ModTime().Unix()
		if old, ok := oldFiles[p].(map[string]any); ok {
			om, _ := old["mtime"].(float64)
			ocs, _ := old["chunk_size"].(float64)
			if int64(om) == mtime && int(ocs) == maxChunkChars {
				fileCount++
				if chs, ok := old["chunks"].([]any); ok {
					indexedCount += len(chs)
				}
				return nil
			}
		}
		if !isProbablyText(p) {
			delete(oldFiles, p)
			return nil
		}
		data, err := os.ReadFile(p)
		if err != nil {
			return nil
		}
		textChunks := chunkText(string(data), maxChunkChars)
		chunks := []any{}
		for j, t := range textChunks {
			terms := tokenize(t)
			tf := map[string]int{}
			for _, w := range terms {
				tf[w]++
			}
			chunks = append(chunks, map[string]any{
				"id": p + "#" + fmt.Sprint(j), "text": t, "terms": tf, "len": len(terms),
			})
		}
		oldFiles[p] = map[string]any{"mtime": mtime, "chunk_size": maxChunkChars, "chunks": chunks}
		fileCount++
		indexedCount += len(chunks)
		return nil
	})

	removed := 0
	for p := range oldFiles {
		if !seen[p] {
			delete(oldFiles, p)
			removed++
		}
	}
	index["files"] = oldFiles
	index["directory"] = absDir
	index["chunk_size"] = maxChunkChars
	index["updated_at"] = time.Now().Format("2006-01-02T15:04:05")
	out, _ := json.Marshal(index)
	if err := os.WriteFile(indexPath, out, 0o644); err != nil {
		return errContent("Failed to write RAG index: " + err.Error())
	}
	invalidateRag(indexPath)
	return okContent(jsonPretty(map[string]any{
		"indexed_files": fileCount, "indexed_chunks": indexedCount,
		"removed_files": removed, "directory": absDir, "index_path": indexPath,
	}))
}
