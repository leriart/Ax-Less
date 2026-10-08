// Filesystem tools for NothingClaw, ported from fs_tools.py.
//
// Everything is confined to a root directory (NOTHINGCLAW_FS_ROOT, default
// ~). The default is the home directory rather than / on purpose: the desktop
// tools can already do damage, but a file API that reaches / turns a confused
// small model into a root-level mistake. Escape is blocked both lexically
// (after resolving symlinks) and on open.
package main

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

const (
	maxReadBytes    = 512 * 1024
	maxWriteBytes   = 512 * 1024
	maxSearchHits   = 100
	maxListEntries  = 500
)

var skipDirs = map[string]bool{
	".git": true, "node_modules": true, "__pycache__": true, ".venv": true,
	"venv": true, ".cache": true, "build": true, "dist": true,
	".mypy_cache": true, ".pytest_cache": true, ".gradle": true,
	".terraform": true, "target": true,
}

var binaryExtensions = map[string]bool{
	".png": true, ".jpg": true, ".jpeg": true, ".gif": true, ".webp": true,
	".svg": true, ".ico": true, ".bmp": true, ".pdf": true, ".zip": true,
	".tar": true, ".gz": true, ".xz": true, ".7z": true, ".rar": true,
	".so": true, ".dylib": true, ".dll": true, ".exe": true, ".bin": true,
	".o": true, ".a": true, ".class": true, ".woff": true, ".woff2": true,
	".ttf": true, ".otf": true, ".eot": true, ".mp3": true, ".mp4": true,
	".mkv": true, ".avi": true, ".mov": true, ".webm": true, ".wav": true,
	".flac": true, ".db": true, ".sqlite": true, ".sqlite3": true,
}

func fsRoot() string {
	root := os.Getenv("NOTHINGCLAW_FS_ROOT")
	if root == "" {
		root = "~"
	}
	if strings.HasPrefix(root, "~") {
		if home, err := os.UserHomeDir(); err == nil {
			root = filepath.Join(home, strings.TrimPrefix(root, "~"))
		}
	}
	real, err := filepath.EvalSymlinks(root)
	if err != nil {
		return root
	}
	return real
}

// resolveSandbox resolves path inside the root, rejecting escapes.
// The symlink resolution happens before the containment check so that
// ../../etc/shadow and a symlink to /etc are both rejected.
func resolveSandbox(path string, mustExist bool) (string, error) {
	root := fsRoot()
	raw := strings.TrimSpace(path)
	if raw == "" {
		raw = "."
	}
	if strings.HasPrefix(raw, "~") {
		if home, err := os.UserHomeDir(); err == nil {
			raw = filepath.Join(home, strings.TrimPrefix(raw, "~"))
		}
	}
	candidate := raw
	if !filepath.IsAbs(raw) {
		candidate = filepath.Join(root, raw)
	}
	real, err := filepath.EvalSymlinks(candidate)
	if err != nil {
		if mustExist {
			return "", fmt.Errorf("no such path: %s", path)
		}
		real = filepath.Clean(candidate)
	}
	if real != root && !strings.HasPrefix(real, root+string(os.PathSeparator)) {
		return "", fmt.Errorf("path escapes the sandbox root (%s): %s", root, raw)
	}
	if mustExist {
		if _, err := os.Stat(real); err != nil {
			return "", fmt.Errorf("no such path: %s", path)
		}
	}
	return real, nil
}

func looksBinary(path string) bool {
	if binaryExtensions[strings.ToLower(filepath.Ext(path))] {
		return true
	}
	f, err := os.Open(path)
	if err != nil {
		return true
	}
	defer f.Close()
	buf := make([]byte, 4096)
	n, _ := f.Read(buf)
	return strings.ContainsRune(string(buf[:n]), 0)
}

func okResult(content string) map[string]any {
	return map[string]any{"content": content, "error": nil}
}

func errResult(msg string) map[string]any {
	return map[string]any{"content": "", "error": msg}
}

func argStrDefault(args map[string]any, key, def string) string {
	if v, ok := args[key].(string); ok && v != "" {
		return v
	}
	return def
}

func argBool(args map[string]any, key string) bool {
	v, ok := args[key].(bool)
	return ok && v
}

func argInt(args map[string]any, key string, def int) int {
	switch v := args[key].(type) {
	case float64:
		return int(v)
	case int:
		return v
	case string:
		var n int
		if _, err := fmt.Sscanf(v, "%d", &n); err == nil {
			return n
		}
	}
	return def
}

func fsListDir(args map[string]any) map[string]any {
	path := argStrDefault(args, "path", ".")
	showHidden := argBool(args, "show_hidden")
	real, err := resolveSandbox(path, true)
	if err != nil {
		return errResult(err.Error())
	}
	info, err := os.Stat(real)
	if err != nil || !info.IsDir() {
		return errResult("not a directory: " + path)
	}
	names, err := os.ReadDir(real)
	if err != nil {
		return errResult(err.Error())
	}
	sort.Slice(names, func(i, j int) bool { return names[i].Name() < names[j].Name() })

	entries := []map[string]any{}
	for _, e := range names {
		name := e.Name()
		if !showHidden && strings.HasPrefix(name, ".") {
			continue
		}
		full := filepath.Join(real, name)
		st, err := os.Stat(full)
		if err != nil {
			continue
		}
		kind := "file"
		if st.IsDir() {
			kind = "dir"
		}
		entries = append(entries, map[string]any{
			"name":     name,
			"type":     kind,
			"size":     st.Size(),
			"modified": st.ModTime().Unix(),
		})
		if len(entries) >= maxListEntries {
			entries = append(entries, map[string]any{
				"name": "...", "type": "truncated",
				"note": fmt.Sprintf("showing first %d entries", maxListEntries),
			})
			break
		}
	}
	out, _ := json.MarshalIndent(map[string]any{"path": path, "entries": entries}, "", "  ")
	return okResult(string(out))
}

func fsReadFile(args map[string]any) map[string]any {
	path := argStrDefault(args, "path", "")
	offset := argInt(args, "offset", 0)
	limit := argInt(args, "limit", 0)
	if limit == 0 {
		limit = maxReadBytes
	}
	real, err := resolveSandbox(path, true)
	if err != nil {
		return errResult(err.Error())
	}
	if info, err := os.Stat(real); err == nil && info.IsDir() {
		return errResult("is a directory, use list_dir: " + path)
	}
	if looksBinary(real) {
		return errResult("looks binary, refusing to read: " + path)
	}
	f, err := os.Open(real)
	if err != nil {
		return errResult(err.Error())
	}
	defer f.Close()
	if _, err := f.Seek(int64(offset), io.SeekStart); err != nil {
		return errResult(err.Error())
	}
	if limit > maxReadBytes {
		limit = maxReadBytes
	}
	raw, err := io.ReadAll(io.LimitReader(f, int64(limit)))
	if err != nil {
		return errResult(err.Error())
	}
	text := string(raw)
	lines := strings.Split(text, "\n")
	numbered := make([]string, len(lines))
	for i, line := range lines {
		numbered[i] = fmt.Sprintf("%d\t%s", offset+i+1, line)
	}
	lineCount := strings.Count(text, "\n")
	if text != "" {
		lineCount++
	}
	out, _ := json.Marshal(map[string]any{
		"path":    path,
		"offset":  offset,
		"bytes":   len(raw),
		"lines":   lineCount,
		"content": strings.Join(numbered, "\n"),
	})
	return okResult(string(out))
}

func fsWriteFile(args map[string]any) map[string]any {
	path := argStrDefault(args, "path", "")
	content, present := args["content"]
	if !present {
		return errResult("missing 'content'")
	}
	text := fmt.Sprintf("%v", content)
	if s, ok := content.(string); ok {
		text = s
	}
	appendMode := argBool(args, "append")
	if len([]byte(text)) > maxWriteBytes {
		return errResult(fmt.Sprintf("content too large (limit %d bytes)", maxWriteBytes))
	}
	real, err := resolveSandbox(path, false)
	if err != nil {
		return errResult(err.Error())
	}
	if err := os.MkdirAll(filepath.Dir(real), 0o755); err != nil {
		return errResult("cannot create directory: " + err.Error())
	}
	flags := os.O_CREATE | os.O_WRONLY | os.O_TRUNC
	mode := "w"
	if appendMode {
		flags = os.O_CREATE | os.O_WRONLY | os.O_APPEND
		mode = "a"
	}
	f, err := os.OpenFile(real, flags, 0o644)
	if err != nil {
		return errResult(err.Error())
	}
	if _, err := f.WriteString(text); err != nil {
		f.Close()
		return errResult(err.Error())
	}
	f.Close()
	out, _ := json.Marshal(map[string]any{
		"path": path, "bytes_written": len([]byte(text)), "mode": mode,
	})
	return okResult(string(out))
}

func globMatch(pattern, name string, ignoreCase bool) bool {
	if ignoreCase {
		pattern = strings.ToLower(pattern)
		name = strings.ToLower(name)
	}
	ok, _ := filepath.Match(pattern, name)
	return ok
}

func fsSearchFiles(args map[string]any) map[string]any {
	pattern := strings.TrimSpace(fmt.Sprintf("%v", args["pattern"]))
	if pattern == "" || pattern == "<nil>" {
		return errResult("missing 'pattern'")
	}
	rootArg := argStrDefault(args, "path", ".")
	ignoreCase := argBool(args, "ignore_case")
	maxHits := argInt(args, "max_results", maxSearchHits)

	root, err := resolveSandbox(rootArg, true)
	if err != nil {
		return errResult(err.Error())
	}
	if info, err := os.Stat(root); err != nil || !info.IsDir() {
		return errResult("not a directory: " + rootArg)
	}

	hits := []map[string]any{}
	truncated := false

	_ = filepath.WalkDir(root, func(p string, d os.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		name := d.Name()
		if d.IsDir() {
			if p != root && (skipDirs[name] || strings.HasPrefix(name, ".")) {
				return filepath.SkipDir
			}
			return nil
		}
		if strings.HasPrefix(name, ".") || looksBinary(p) {
			return nil
		}
		if info, err := d.Info(); err != nil || info.Size() > maxReadBytes {
			return nil
		}
		f, err := os.Open(p)
		if err != nil {
			return nil
		}
		defer f.Close()
		data, err := io.ReadAll(f)
		if err != nil {
			return nil
		}
		for i, line := range strings.Split(string(data), "\n") {
			probe := strings.TrimSpace(line)
			if globMatch(pattern, probe, ignoreCase) {
				rel, _ := filepath.Rel(root, p)
				text := line
				if len(text) > 300 {
					text = text[:300]
				}
				hits = append(hits, map[string]any{
					"path": rel, "line": i + 1, "text": text,
				})
				if len(hits) >= maxHits {
					truncated = true
					break
				}
			}
		}
		if truncated {
			return fmt.Errorf("done")
		}
		return nil
	})

	out, _ := json.MarshalIndent(map[string]any{
		"pattern": pattern, "path": rootArg, "count": len(hits),
		"truncated": truncated, "matches": hits,
	}, "", "  ")
	return okResult(string(out))
}

var fsHandlers = map[string]func(map[string]any) map[string]any{
	"list_dir":     fsListDir,
	"read_file":    fsReadFile,
	"write_file":   fsWriteFile,
	"search_files": fsSearchFiles,
}

func fsTools() []map[string]any {
	str := func(d string) map[string]any { return map[string]any{"type": "string", "description": d} }
	num := func(d string) map[string]any { return map[string]any{"type": "integer", "description": d} }
	boolean := func(d string) map[string]any { return map[string]any{"type": "boolean", "description": d} }
	o := func(props map[string]any, required ...string) map[string]any {
		if required == nil {
			required = []string{}
		}
		return map[string]any{"type": "object", "properties": props,
			"required": required, "additionalProperties": false}
	}
	return []map[string]any{
		{"name": "list_dir",
			"description": "List the contents of a directory. Start here when you do not know what files exist. Paths are relative to the home directory.",
			"parameters": o(map[string]any{
				"path":        str("Directory to list, relative to home. Default '.'"),
				"show_hidden": boolean("Include dotfiles. Default false"),
			})},
		{"name": "read_file",
			"description": "Read a UTF-8 text file. Returns the content with 1-based line numbers so you can cite exact lines.",
			"parameters": o(map[string]any{
				"path":   str("File to read, relative to home"),
				"offset": num("Byte offset to start from. Default 0"),
				"limit":  num("Max bytes to read. Default reads the whole file"),
			}, "path")},
		{"name": "write_file",
			"description": "Create or overwrite a text file. Parent directories are created automatically.",
			"parameters": o(map[string]any{
				"path":    str("File to write, relative to home"),
				"content": str("Full new contents of the file"),
				"append":  boolean("Append instead of overwriting. Default false"),
			}, "path", "content")},
		{"name": "search_files",
			"description": "Recursively search file contents with a glob pattern (e.g. '*.qml'). Skips .git, node_modules and build directories.",
			"parameters": o(map[string]any{
				"pattern":     str("Glob matched against each line, e.g. '*.qml'"),
				"path":        str("Directory to search from. Default '.'"),
				"ignore_case": boolean("Case-insensitive match. Default false"),
				"max_results": num("Stop after this many hits. Default 100"),
			}, "pattern")},
	}
}
