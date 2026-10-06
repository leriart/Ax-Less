import QtQuick
import Quickshell
import Quickshell.Io

/*!
    MCP stdio client.

    Spawns `scripts/mcp_stdio_bridge.py` which, in turn, runs the
    user-configured MCP server with its stdin connected to a
    per-instance FIFO. The bridge prints the FIFO path on its first
    stdout line (``__FIFO__:/path/to/in.fifo``) — we capture it and
    then forward outgoing JSON-RPC messages by simply ``echo``-ing
    them into the FIFO.

    Why this layout
    ===============
    Quickshell's `Process` element does not currently expose a way
    to write to a child's stdin from QML. The original implementation
    of this file tried to create the FIFO in a separate
    ``Component.onCompleted`` proc and then patch the spawn command —
    that produced obvious race conditions (the process could start
    before the FIFO existed, or with a different command than intended).
    Routing the FIFO creation through the bridge process itself is
    race-free: the QML side just spawns one command and waits for the
    bridge to announce the FIFO path.

    Lifecycle
    =========
    - ``start(command, args)``: spawn the bridge.
    - On first stdout line beginning with ``__FIFO__:``: record the
      FIFO path; send the JSON-RPC ``initialize`` request.
    - On ``initialize`` response: emit ``connected`` and request
      ``tools/list``.
    - On ``tools/list`` response: emit ``toolsDiscovered(tools)``.
    - ``invokeTool(name, args, cb)``: send ``tools/call``.
    - ``stop()``: kill the bridge (which cleans up the FIFO).
*/
QtObject {
    id: root

    signal connected
    signal disconnected
    signal toolsDiscovered(var tools)
    signal error(string message)

    property bool isConnected: false
    property string fifoPath: ""
    property var serverInfo: ({})
    property var capabilities: ({})

    property int _requestCounter: 1
    property string _requestIdPrefix: "nl_"
    property var _pendingCallbacks: ({})
    property var _pendingWrites: []

    // Per-request timeout. MCP servers should reply to tool calls and
    // discovery quickly; a hung server otherwise freezes the AI pipeline.
    property int requestTimeoutMs: 15000

    readonly property string _bridgePath: Qt.resolvedUrl("../../scripts/mcp_stdio_bridge.py").toString().replace("file://", "")

    function start(command, args) {
        if (!command) {
            error("No command specified for MCP stdio client");
            return;
        }
        // Build the bridge invocation. The double-dash separator is
        // required so the bridge can split its own argv from the
        // user-configured MCP command.
        let invocation = ["python3", "-u", _bridgePath, "--", command];
        if (args && args.length > 0) {
            for (let i = 0; i < args.length; i++) invocation.push(String(args[i]));
        }
        isConnected = false;
        fifoPath = "";
        _pendingCallbacks = {};
        _pendingWrites = [];
        mcpProcess.command = invocation;
        mcpProcess.running = true;
    }

    function stop() {
        for (let id in _pendingCallbacks) {
            let entry = _pendingCallbacks[id];
            if (entry && entry.timer) entry.timer.stop();
            if (entry && typeof entry.callback === "function") {
                entry.callback({ message: "MCP client stopped" }, null);
            }
        }
        _pendingCallbacks = {};
        mcpProcess.running = false;
        isConnected = false;
        fifoPath = "";
        disconnected();
    }

    function sendRequest(method, params, callback) {
        let id = _requestIdPrefix + (_requestCounter++);
        let msg = { jsonrpc: "2.0", id: id, method: method, params: params || {} };
        if (callback) {
            let timer = Qt.createQmlObject('import QtQuick; Timer { interval: ' + root.requestTimeoutMs + '; repeat: false }', root);
            timer.triggered.connect(function() { root._requestTimedOut(id); });
            _pendingCallbacks[id] = { callback: callback, timer: timer };
        }
        _sendLine(JSON.stringify(msg));
    }

    function _requestTimedOut(id) {
        let entry = _pendingCallbacks[id];
        if (!entry) return;
        delete _pendingCallbacks[id];
        if (typeof entry.callback === "function") {
            entry.callback({ message: "MCP request timed out after " + (root.requestTimeoutMs / 1000) + "s" }, null);
        }
        if (entry.timer) entry.timer.destroy();
    }

    function sendNotification(method, params) {
        let msg = { jsonrpc: "2.0", method: method, params: params || {} };
        _sendLine(JSON.stringify(msg));
    }

    function invokeTool(toolName, args, callback) {
        sendRequest("tools/call", { name: toolName, arguments: args || {} }, function(err, result) {
            if (!callback) return;
            if (err) {
                let msg = err.message || (typeof err === "string" ? err : JSON.stringify(err));
                callback({ content: "", error: msg, done: true });
                return;
            }
            let content = "";
            let isError = false;
            if (result) {
                if (result.isError) isError = true;
                if (Array.isArray(result.content)) {
                    // MCP content can be a list of content parts; we
                    // join the textual ones together for display.
                    let texts = [];
                    for (let i = 0; i < result.content.length; i++) {
                        let p = result.content[i];
                        if (!p) continue;
                        if (typeof p === "string") texts.push(p);
                        else if (p.type === "text" && p.text) texts.push(p.text);
                        else texts.push(JSON.stringify(p));
                    }
                    content = texts.join("\n");
                } else if (typeof result.content === "string") {
                    content = result.content;
                } else if (result.result !== undefined) {
                    content = typeof result.result === "string" ? result.result : JSON.stringify(result.result);
                } else {
                    content = JSON.stringify(result);
                }
            }
            callback({
                content: content,
                error: isError ? content : null,
                done: true
            });
        });
    }

    // ── Internals ──────────────────────────────────────────────────

    function _sendLine(line) {
        if (!fifoPath) {
            // Bridge hasn't announced the FIFO yet — queue and flush
            // once it shows up. Note this only happens for a very
            // short window during startup.
            _pendingWrites.push(line);
            return;
        }
        writeProcess.command = ["bash", "-c", "printf '%s\\n' " + _shQuote(line) + " > " + _shQuote(fifoPath)];
        writeProcess.running = true;
    }

    function _shQuote(s) {
        return "'" + String(s).replace(/'/g, "'\\''") + "'";
    }

    function _flushPending() {
        if (!fifoPath) return;
        let queued = _pendingWrites;
        _pendingWrites = [];
        for (let i = 0; i < queued.length; i++) {
            _sendLine(queued[i]);
        }
    }

    function _onFifoReady(path) {
        fifoPath = path;
        // MCP handshake. The protocolVersion string follows the
        // spec; we advertise a minimal client capability set —
        // tools support is implicit (we only ever call tools).
        sendRequest("initialize", {
            protocolVersion: "2024-11-05",
            capabilities: { tools: {} },
            clientInfo: { name: "Ambxst", version: "1.3.10" }
        }, function(err, result) {
            if (err) {
                let msg = err.message || JSON.stringify(err);
                root.error("MCP initialize failed: " + msg);
                return;
            }
            if (result) {
                root.serverInfo = result.serverInfo || {};
                root.capabilities = result.capabilities || {};
            }
            root.isConnected = true;
            root.connected();
            // Per spec, send `notifications/initialized` after the
            // initialize round-trip succeeds.
            root.sendNotification("notifications/initialized", {});
            // Discover the server's tool set.
            root.sendRequest("tools/list", {}, function(err2, result2) {
                if (err2) {
                    root.error("tools/list failed: " + (err2.message || JSON.stringify(err2)));
                    return;
                }
                let tools = (result2 && Array.isArray(result2.tools)) ? result2.tools : [];
                root.toolsDiscovered(tools);
            });
        });
        _flushPending();
    }

    function _handleLine(line) {
        if (!line) return;
        let trimmed = String(line).trim();
        if (!trimmed) return;

        // The bridge's own out-of-band metadata starts with this prefix.
        if (trimmed.startsWith("__FIFO__:")) {
            _onFifoReady(trimmed.substring("__FIFO__:".length).trim());
            return;
        }

        let msg;
        try {
            msg = JSON.parse(trimmed);
        } catch (e) {
            // MCP servers occasionally emit non-JSON debug noise on
            // their stdout; report it as a diagnostic but don't kill
            // the connection.
            root.error("Non-JSON output from MCP server: " + trimmed.substring(0, 200));
            return;
        }
        if (!msg || msg.jsonrpc !== "2.0") return;

        // Responses to requests we made.
        if (msg.id !== undefined && msg.id !== null) {
            let entry = _pendingCallbacks[msg.id];
            if (entry) {
                delete _pendingCallbacks[msg.id];
                if (entry.timer) entry.timer.stop();
                if (typeof entry.callback === "function") entry.callback(msg.error || null, msg.result);
                if (entry.timer) entry.timer.destroy();
            }
            return;
        }

        // Server-originated notifications.
        if (msg.method === "notifications/tools/list_changed") {
            root.sendRequest("tools/list", {}, function(err, result) {
                if (!err && result && Array.isArray(result.tools)) {
                    root.toolsDiscovered(result.tools);
                }
            });
            return;
        }

        if (msg.method === "notifications/message") {
            // Diagnostic relay from the bridge wrapper. We don't
            // surface every line as a hard error — only the explicit
            // error level.
            let p = msg.params || {};
            if (p.level === "error" && p.data) {
                root.error(String(p.data));
            }
            return;
        }
    }

    // ── Subprocess ────────────────────────────────────────────────

    property Process mcpProcess: Process {
        running: false
        stdout: SplitParser {
            onRead: data => root._handleLine(data)
        }
        stderr: SplitParser {
            onRead: data => {
                if (data && String(data).trim().length > 0) {
                    root.error("MCP bridge stderr: " + data);
                }
            }
        }
        onExited: exitCode => {
            root.isConnected = false;
            if (exitCode !== 0 && exitCode !== null) {
                root.error("MCP bridge exited with code " + exitCode);
            }
            root.fifoPath = "";
            root.disconnected();
        }
    }

    property Process writeProcess: Process {
        running: false
    }

    Component.onDestruction: stop()
}
