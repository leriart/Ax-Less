"""OpenCode bridge for Ambxst.

`opencode serve` exposes a full agent API (`/session`, `/file`, `/find`,
`/mcp`, `/experimental/tool`, ...) but it does NOT speak the protocol
Ambxst's `HttpAgentClient` understands, which is:

    GET  <endpoint><toolsPath>    -> [ {name, description, parameters} ]
    POST <endpoint><invokePath>  -> { "name": ..., "arguments": {...} }
                                    -> { "content": ..., "error": null }

So this adapter sits in between: it publishes a curated subset of the
OpenCode API as bridge tools, and forwards each call to the documented
OpenCode endpoint.

Scope
-----
Only read/search primitives plus a shell escape hatch. Session/agent
turn-taking is deliberately left out - Ambxst already has its own AI
conversation loop and driving a nested agent turn from inside a tool call
would fight it for the model. This is "let the shell reach opencode's view
of the project", not "run a second agent".

Auth
----
`OPENCODE_SERVER_PASSWORD` turns on HTTP basic auth; the username defaults
to `opencode` unless `OPENCODE_SERVER_USERNAME` says otherwise. Passed
straight through, no storage.

Standard library only, like the rest of the agent payload.
"""

import base64
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# Upstream, overridable so the same bridge can front a remote box.
UPSTREAM = os.environ.get("OPENCODE_BRIDGE_UPSTREAM",
                          "http://127.0.0.1:4096").rstrip("/")
LISTEN_HOST = os.environ.get("OPENCODE_BRIDGE_HOST", "127.0.0.1")
LISTEN_PORT = int(os.environ.get("OPENCODE_BRIDGE_PORT", "8791"))

# A cached session, used only by run_shell (OpenCode requires one).
_SESSION_ID = None


def _auth_header():
    password = os.environ.get("OPENCODE_SERVER_PASSWORD", "")
    if not password:
        return {}
    user = os.environ.get("OPENCODE_SERVER_USERNAME", "opencode")
    token = base64.b64encode(("%s:%s" % (user, password)).encode()).decode()
    return {"Authorization": "Basic " + token}


def _request(method, path, params=None, body=None, timeout=30):
    """Call the upstream OpenCode server and return (payload, error)."""
    url = UPSTREAM + path
    if params:
        clean = {k: v for k, v in params.items() if v is not None}
        if clean:
            url += "?" + urllib.parse.urlencode(clean)

    data = None
    headers = {"Accept": "application/json"}
    headers.update(_auth_header())
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        headers["Content-Type"] = "application/json"

    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read().decode("utf-8")
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", "replace")[:300]
        return None, "opencode HTTP %s on %s: %s" % (exc.code, path, detail)
    except urllib.error.URLError as exc:
        return None, ("cannot reach opencode at %s (%s). Is `opencode serve` "
                      "running?" % (UPSTREAM, exc.reason))
    except Exception as exc:  # noqa: BLE001
        return None, "%s: %s" % (type(exc).__name__, exc)

    if not raw.strip():
        return {}, None
    try:
        return json.loads(raw), None
    except ValueError:
        return None, "non-JSON response from %s" % path


def _ensure_session():
    """Create (once) and return an OpenCode session id."""
    global _SESSION_ID
    if _SESSION_ID:
        return _SESSION_ID, None
    payload, err = _request("POST", "/session", body={})
    if err:
        return None, err
    if isinstance(payload, dict):
        _SESSION_ID = payload.get("id") or (payload.get("info") or {}).get("id")
    if not _SESSION_ID:
        return None, "opencode did not return a session id"
    return _SESSION_ID, None


# ---------------------------------------------------------------------------
# Tool implementations - each returns {"content", "error"}
# ---------------------------------------------------------------------------

def _text(value):
    return value if isinstance(value, str) else json.dumps(
        value, ensure_ascii=False, indent=2)


def t_health(args):
    payload, err = _request("GET", "/global/health")
    if err:
        return {"content": "", "error": err}
    return {"content": _text(payload), "error": None}


def t_list_files(args):
    path = args.get("path") or "."
    payload, err = _request("GET", "/file", params={"path": path})
    if err:
        return {"content": "", "error": err}
    return {"content": _text(payload), "error": None}


def t_read_file(args):
    path = args.get("path", "")
    if not path:
        return {"content": "", "error": "read_file needs 'path'"}
    payload, err = _request("GET", "/file/content", params={"path": path})
    if err:
        return {"content": "", "error": err}
    if isinstance(payload, dict):
        body = payload.get("content", "")
        meta = {k: v for k, v in payload.items() if k != "content"}
        return {"content": body + ("\n\n[meta] " + _text(meta) if meta else ""),
                "error": None}
    return {"content": _text(payload), "error": None}


def t_find_in_files(args):
    pattern = args.get("pattern", "")
    if not pattern:
        return {"content": "", "error": "find_in_files needs 'pattern'"}
    payload, err = _request("GET", "/find", params={"pattern": pattern})
    if err:
        return {"content": "", "error": err}
    return {"content": _text(payload), "error": None}


def t_find_files(args):
    query = args.get("query", "")
    if not query:
        return {"content": "", "error": "find_files needs 'query'"}
    payload, err = _request("GET", "/find/file", params={
        "query": query,
        "type": args.get("type"),
        "directory": args.get("directory"),
        "limit": args.get("limit"),
    })
    if err:
        return {"content": "", "error": err}
    return {"content": _text(payload), "error": None}


def t_find_symbols(args):
    query = args.get("query", "")
    if not query:
        return {"content": "", "error": "find_symbols needs 'query'"}
    payload, err = _request("GET", "/find/symbol", params={"query": query})
    if err:
        return {"content": "", "error": err}
    return {"content": _text(payload), "error": None}


def t_run_shell(args):
    command = args.get("command", "")
    if not command:
        return {"content": "", "error": "run_shell needs 'command'"}
    session, err = _ensure_session()
    if err:
        return {"content": "", "error": err}
    payload, err = _request(
        "POST", "/session/%s/shell" % session,
        body={"agent": args.get("agent") or "build",
              "command": command})
    if err:
        return {"content": "", "error": err}
    return {"content": _text(payload), "error": None}


def t_list_agents(args):
    payload, err = _request("GET", "/agent")
    if err:
        return {"content": "", "error": err}
    return {"content": _text(payload), "error": None}


def t_list_mcp(args):
    payload, err = _request("GET", "/mcp")
    if err:
        return {"content": "", "error": err}
    return {"content": _text(payload), "error": None}


def t_list_sessions(args):
    payload, err = _request("GET", "/session")
    if err:
        return {"content": "", "error": err}
    return {"content": _text(payload), "error": None}


HANDLERS = {
    "opencode_health": t_health,
    "opencode_list_files": t_list_files,
    "opencode_read_file": t_read_file,
    "opencode_find_in_files": t_find_in_files,
    "opencode_find_files": t_find_files,
    "opencode_find_symbols": t_find_symbols,
    "opencode_run_shell": t_run_shell,
    "opencode_list_agents": t_list_agents,
    "opencode_list_mcp_servers": t_list_mcp,
    "opencode_list_sessions": t_list_sessions,
}


# ---------------------------------------------------------------------------
# Tool catalogue
# ---------------------------------------------------------------------------

def _s(desc):
    return {"type": "string", "description": desc}


def _i(desc):
    return {"type": "integer", "description": desc}


def _obj(props, required=None):
    return {"type": "object", "properties": props,
            "required": list(required or []),
            "additionalProperties": False}


TOOLS = [
    {"name": "opencode_health",
     "description": "Check that the OpenCode server is reachable and report "
                    "its version. Call this first when a connection fails.",
     "parameters": _obj({})},
    {"name": "opencode_list_files",
     "description": "List files and directories at a path in the OpenCode "
                    "project.",
     "parameters": _obj({"path": _s("Path to list. Default '.'")})},
    {"name": "opencode_read_file",
     "description": "Read a file's contents through OpenCode.",
     "parameters": _obj({"path": _s("File to read")}, ["path"])},
    {"name": "opencode_find_in_files",
     "description": "Search file contents for a literal pattern.",
     "parameters": _obj({"pattern": _s("Text to search for")}, ["pattern"])},
    {"name": "opencode_find_files",
     "description": "Find files by fuzzy name.",
     "parameters": _obj({
         "query": _s("Fuzzy file name to search"),
         "type": _s("Restrict to 'file' or 'directory'"),
         "directory": _s("Override the project root"),
         "limit": _i("Max results, 1-200"),
     }, ["query"])},
    {"name": "opencode_find_symbols",
     "description": "Find workspace symbols matching a query.",
     "parameters": _obj({"query": _s("Symbol search query")}, ["query"])},
    {"name": "opencode_run_shell",
     "description": "Run a shell command inside the OpenCode project.",
     "parameters": _obj({
         "command": _s("Command to run"),
         "agent": _s("Agent to run it as. Default 'build'"),
     }, ["command"])},
    {"name": "opencode_list_agents",
     "description": "List the agents OpenCode has available.",
     "parameters": _obj({})},
    {"name": "opencode_list_mcp_servers",
     "description": "List the MCP servers OpenCode is connected to, with "
                    "their status.",
     "parameters": _obj({})},
    {"name": "opencode_list_sessions",
     "description": "List OpenCode sessions.",
     "parameters": _obj({})},
]


# ---------------------------------------------------------------------------
# HTTP surface (the bridge protocol Ambxst expects)
# ---------------------------------------------------------------------------

class Handler(BaseHTTPRequestHandler):
    server_version = "OpenCodeBridge/1.0"

    def log_message(self, fmt, *args):
        sys.stderr.write("[opencode-bridge] " + (fmt % args) + "\n")

    def _json(self, status, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        route = self.path.split("?", 1)[0]
        if route == "/tools":
            # Drop the introspection tool when the caller asked for a small
            # model: 10 tools already spans a 3B model's attention well.
            self._json(200, TOOLS)
            return
        if route == "/health":
            self._json(200, {"upstream": UPSTREAM,
                             "bridge": "ok",
                             "opencode": t_health({})["content"]})
            return
        self._json(404, {"error": "Not found", "content": ""})

    def do_POST(self):
        if self.path.split("?", 1)[0] != "/tools":
            self._json(404, {"error": "Not found", "content": ""})
            return
        length = int(self.headers.get("Content-Length", "0") or "0")
        raw = self.rfile.read(length) if length > 0 else b""
        try:
            body = json.loads(raw.decode("utf-8") or "{}")
        except Exception as exc:
            self._json(400, {"content": "", "error": "Invalid JSON: " + str(exc)})
            return
        name = body.get("name", "")
        args = body.get("arguments") or {}
        handler = HANDLERS.get(name)
        if handler is None:
            self._json(200, {"content": "",
                             "error": "unknown tool: %s" % name})
            return
        try:
            self._json(200, handler(args))
        except Exception as exc:  # noqa: BLE001
            self._json(200, {"content": "",
                             "error": "%s: %s" % (type(exc).__name__, exc)})


def main():
    server = ThreadingHTTPServer((LISTEN_HOST, LISTEN_PORT), Handler)
    sys.stderr.write(
        "[opencode-bridge] %d tools -> %s on http://%s:%d\n"
        % (len(TOOLS), UPSTREAM, LISTEN_HOST, LISTEN_PORT))
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()