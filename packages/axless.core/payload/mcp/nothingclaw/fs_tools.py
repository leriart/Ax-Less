"""Filesystem tools for NothingClaw.

The bridge was originally desktop-only: every tool was a thin wrapper around
`axctl` or a web fetch. That left a hole - an agent could switch the window
you were looking at but could not touch the machine behind it, which is what
most "do this for me" requests actually need.

Four tools close that hole: `list_dir`, `read_file`, `write_file` and
`search_files`.

Sandboxing
----------
Everything is confined to a root directory (`NOTHINGCLAW_FS_ROOT`,
default `~`). That default is deliberately the home directory rather than
`/`: the desktop tools can already do damage, but a file API that reaches
`/` turns a confused small model into a root-level mistake. Escape is
blocked both lexically (after `realpath`, so `..` and symlinks are caught)
and on open.

Standard library only, same as the rest of the bridge.
"""

import fnmatch
import json
import os
import time

MAX_READ_BYTES = 512 * 1024
MAX_WRITE_BYTES = 512 * 1024
MAX_SEARCH_HITS = 100
MAX_LIST_ENTRIES = 500

SKIP_DIRS = {
    ".git", "node_modules", "__pycache__", ".venv", "venv",
    ".cache", "build", "dist", ".mypy_cache", ".pytest_cache",
    ".gradle", ".terraform", "target",
}

BINARY_EXTENSIONS = {
    ".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg", ".ico", ".bmp",
    ".pdf", ".zip", ".tar", ".gz", ".xz", ".7z", ".rar",
    ".so", ".dylib", ".dll", ".exe", ".bin", ".o", ".a", ".class",
    ".woff", ".woff2", ".ttf", ".otf", ".eot",
    ".mp3", ".mp4", ".mkv", ".avi", ".mov", ".webm", ".wav", ".flac",
    ".db", ".sqlite", ".sqlite3",
}


class SandboxError(Exception):
    """Raised when a path escapes the configured root."""


def _root():
    return os.path.realpath(os.path.expanduser(
        os.environ.get("NOTHINGCLAW_FS_ROOT", "~")))


def _resolve(path, must_exist=False):
    """Resolve `path` inside the sandbox root, or raise SandboxError.

    The realpath dance happens *before* the containment check so that
    `../../etc/shadow` and `/home/user/link -> /etc` are both rejected -
    a plain string prefix test would pass the symlink case.
    """
    root = _root()
    raw = os.path.expanduser(str(path or "")).strip()
    if not raw:
        raw = "."
    candidate = raw if os.path.isabs(raw) else os.path.join(root, raw)
    real = os.path.realpath(candidate)
    if real != root and not real.startswith(root + os.sep):
        raise SandboxError(
            "path escapes the sandbox root (%s): %s" % (root, raw))
    if must_exist and not os.path.exists(real):
        raise SandboxError("no such path: %s" % raw)
    return real


def _looks_binary(path):
    if os.path.splitext(path)[1].lower() in BINARY_EXTENSIONS:
        return True
    try:
        with open(path, "rb") as handle:
            return b"\x00" in handle.read(4096)
    except OSError:
        return True


def _ok(content, error=None):
    return {"content": content, "error": error}


def list_dir(args, ctx=None):
    """Directory listing with file type and size."""
    path = args.get("path") or "."
    show_hidden = bool(args.get("show_hidden"))
    try:
        real = _resolve(path, must_exist=True)
    except SandboxError as exc:
        return _ok("", str(exc))
    if not os.path.isdir(real):
        return _ok("", "not a directory: %s" % path)

    entries = []
    try:
        names = sorted(os.listdir(real))
    except OSError as exc:
        return _ok("", str(exc))

    for name in names:
        if not show_hidden and name.startswith("."):
            continue
        full = os.path.join(real, name)
        try:
            stat = os.stat(full)
        except OSError:
            continue
        entries.append({
            "name": name,
            "type": "dir" if os.path.isdir(full) else "file",
            "size": stat.st_size,
            "modified": int(stat.st_mtime),
        })
        if len(entries) >= MAX_LIST_ENTRIES:
            entries.append({"name": "...", "type": "truncated",
                            "note": "showing first %d entries" % MAX_LIST_ENTRIES})
            break

    return _ok(json.dumps({"path": path, "entries": entries},
                          ensure_ascii=False, indent=2))


def read_file(args, ctx=None):
    """Read a text file, optionally a byte range via offset/limit."""
    path = args.get("path", "")
    offset = int(args.get("offset") or 0)
    limit = int(args.get("limit") or 0) or MAX_READ_BYTES
    try:
        real = _resolve(path, must_exist=True)
    except SandboxError as exc:
        return _ok("", str(exc))
    if os.path.isdir(real):
        return _ok("", "is a directory, use list_dir: %s" % path)
    if not os.access(real, os.R_OK):
        return _ok("", "permission denied: %s" % path)
    if _looks_binary(real):
        return _ok("", "looks binary, refusing to read: %s" % path)

    try:
        with open(real, "rb") as handle:
            handle.seek(offset)
            raw = handle.read(min(limit, MAX_READ_BYTES))
    except OSError as exc:
        return _ok("", str(exc))

    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        return _ok("", "not valid utf-8: %s" % path)

    numbered = "\n".join(
        "%d\t%s" % (offset + i + 1, line)
        for i, line in enumerate(text.split("\n")))
    return _ok(json.dumps({
        "path": path,
        "offset": offset,
        "bytes": len(raw),
        "lines": text.count("\n") + (1 if text else 0),
        "content": numbered,
    }, ensure_ascii=False))


def write_file(args, ctx=None):
    """Create or overwrite a text file inside the sandbox."""
    path = args.get("path", "")
    content = args.get("content")
    append = bool(args.get("append"))
    if content is None:
        return _ok("", "missing 'content'")
    if not isinstance(content, str):
        content = str(content)
    if len(content.encode("utf-8")) > MAX_WRITE_BYTES:
        return _ok("", "content too large (limit %d bytes)" % MAX_WRITE_BYTES)

    try:
        real = _resolve(path)
    except SandboxError as exc:
        return _ok("", str(exc))

    parent = os.path.dirname(real)
    try:
        os.makedirs(parent, exist_ok=True)
    except OSError as exc:
        return _ok("", "cannot create directory: %s" % exc)

    mode = "a" if append else "w"
    try:
        with open(real, mode, encoding="utf-8") as handle:
            handle.write(content)
    except OSError as exc:
        return _ok("", str(exc))

    return _ok(json.dumps({
        "path": path,
        "bytes_written": len(content.encode("utf-8")),
        "mode": mode,
    }))


def search_files(args, ctx=None):
    """Recursive text search (glob *pattern* over file contents)."""
    pattern = str(args.get("pattern") or "")
    if not pattern:
        return _ok("", "missing 'pattern'")
    root_arg = args.get("path") or "."
    ignore_case = bool(args.get("ignore_case"))
    max_hits = int(args.get("max_results") or 0) or MAX_SEARCH_HITS

    if ignore_case:
        matcher = fnmatch.fnmatch(pattern.lower())
    else:
        def matcher(name):
            return fnmatch.fnmatch(name, pattern)

    try:
        root = _resolve(root_arg, must_exist=True)
    except SandboxError as exc:
        return _ok("", str(exc))
    if not os.path.isdir(root):
        return _ok("", "not a directory: %s" % root_arg)

    hits = []
    truncated = False
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames
                       if d not in SKIP_DIRS and not d.startswith(".")]
        for filename in filenames:
            if filename.startswith(".") or _looks_binary(
                    os.path.join(dirpath, filename)):
                continue
            full = os.path.join(dirpath, filename)
            try:
                if os.path.getsize(full) > MAX_READ_BYTES:
                    continue
                with open(full, "r", encoding="utf-8", errors="replace") as fh:
                    for lineno, line in enumerate(fh, 1):
                        probe = line.lower() if ignore_case else line
                        if matcher(probe.strip()):
                            hits.append({
                                "path": os.path.relpath(full, root),
                                "line": lineno,
                                "text": line.rstrip()[:300],
                            })
                            if len(hits) >= max_hits:
                                truncated = True
                                break
            except OSError:
                continue
            if truncated:
                break
        if truncated:
            break

    return _ok(json.dumps({
        "pattern": pattern,
        "path": root_arg,
        "count": len(hits),
        "truncated": truncated,
        "matches": hits,
    }, ensure_ascii=False, indent=2))


# ---------------------------------------------------------------------------
# Tool definitions (bridge schema)
# ---------------------------------------------------------------------------

def _str(description):
    return {"type": "string", "description": description}


def _int(description):
    return {"type": "integer", "description": description}


def _bool(description):
    return {"type": "boolean", "description": description}


def _obj(props, required=None):
    return {
        "type": "object",
        "properties": props,
        "required": list(required or []),
        "additionalProperties": False,
    }


FS_TOOLS = [
    {
        "name": "list_dir",
        "description": "List the contents of a directory. Start here when you "
                       "do not know what files exist. Paths are relative to "
                       "the home directory.",
        "parameters": _obj({
            "path": _str("Directory to list, relative to home. Default '.'"),
            "show_hidden": _bool("Include dotfiles. Default false"),
        }),
    },
    {
        "name": "read_file",
        "description": "Read a UTF-8 text file. Returns the content with "
                       "1-based line numbers so you can cite exact lines.",
        "parameters": _obj({
            "path": _str("File to read, relative to home"),
            "offset": _int("Byte offset to start from. Default 0"),
            "limit": _int("Max bytes to read. Default reads the whole file"),
        }, ["path"]),
    },
    {
        "name": "write_file",
        "description": "Create or overwrite a text file. Parent directories "
                       "are created automatically.",
        "parameters": _obj({
            "path": _str("File to write, relative to home"),
            "content": _str("Full new contents of the file"),
            "append": _bool("Append instead of overwriting. Default false"),
        }, ["path", "content"]),
    },
    {
        "name": "search_files",
        "description": "Recursively search file contents with a glob pattern "
                       "(e.g. '*.qml'). Skips .git, node_modules and build "
                       "directories.",
        "parameters": _obj({
            "pattern": _str("Glob matched against each line, e.g. '*.qml'"),
            "path": _str("Directory to search from. Default '.'"),
            "ignore_case": _bool("Case-insensitive match. Default false"),
            "max_results": _int("Stop after this many hits. Default 100"),
        }, ["pattern"]),
    },
]

FS_HANDLERS = {
    "list_dir": list_dir,
    "read_file": read_file,
    "write_file": write_file,
    "search_files": search_files,
}