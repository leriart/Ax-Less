import QtQuick
import Quickshell
import Quickshell.Io

// Stateless command agent: each tool invocation spawns the configured command
// with the request JSON passed as the last argument. The command must print
// a JSON response to stdout.
QtObject {
    id: root

    signal connected
    signal disconnected
    signal toolsDiscovered(var tools)
    signal error(string message)

    property bool isConnected: false
    property string command: ""
    property list<var> args: []
    property var discoveredTools: []

    // Default timeout for command-agent operations, in milliseconds.
    // Command agents are expected to be stateless and fast; a hung
    // command would otherwise freeze the AI tool pipeline.
    //
    // Set to 35s to give command agents (e.g. the OpenClaw bridge
    // which has a 30s internal HTTP timeout) enough headroom to
    // respond on slow links.  Previously 15s — the bridge would
    // get killed mid-request and return a false "timeout" error
    // even though the gateway was responding normally.
    property int commandTimeoutMs: 35000

    property Timer _invokeTimeout: Timer {
        interval: root.commandTimeoutMs
        repeat: false
        onTriggered: {
            if (invokeProcess.running) {
                invokeProcess.running = false;
            }
            let cb = invokeProcess._callback;
            invokeProcess._callback = null;
            if (cb) cb({ content: "", error: "Command agent invocation timed out after " + (root.commandTimeoutMs / 1000) + "s", done: true });
        }
    }

    property Timer _discoveryTimeout: Timer {
        interval: root.commandTimeoutMs
        repeat: false
        onTriggered: {
            if (discoveryProcess.running) {
                discoveryProcess.running = false;
            }
            root.isConnected = false;
            root.error("Command agent discovery timed out after " + (root.commandTimeoutMs / 1000) + "s");
        }
    }

    function start(cmd, a) {
        if (cmd) command = cmd;
        if (a) args = a;
        if (!command) {
            error("No command configured");
            return;
        }
        // For command agents, we assume tools are either statically configured
        // in the connection (via extra metadata) or discovered by running
        // command with --list-tools if supported.
        _discoverTools();
    }

    function stop() {
        _invokeTimeout.stop();
        _discoveryTimeout.stop();
        if (invokeProcess.running) invokeProcess.running = false;
        if (discoveryProcess.running) discoveryProcess.running = false;
        isConnected = false;
        disconnected();
    }

    function invokeTool(toolName, toolArgs, callback) {
        let payload = JSON.stringify({ name: toolName, arguments: toolArgs || {} });
        let cmd = [command];
        if (args && args.length > 0) {
            for (let i = 0; i < args.length; i++) cmd.push(args[i]);
        }
        cmd.push(payload);

        _invokeTimeout.stop();
        invokeProcess._callback = callback || function() {};
        invokeProcess.command = cmd;
        invokeProcess.running = true;
        _invokeTimeout.start();
    }

    function _discoverTools() {
        let cmd = [command];
        if (args && args.length > 0) {
            for (let i = 0; i < args.length; i++) cmd.push(args[i]);
        }
        cmd.push(JSON.stringify({ action: "list-tools" }));
        _discoveryTimeout.stop();
        discoveryProcess.command = cmd;
        discoveryProcess.running = true;
        _discoveryTimeout.start();
    }

    property Process discoveryProcess: Process {
        stdout: StdioCollector { id: discoveryOut }
        stderr: StdioCollector { id: discoveryErr }
        onExited: exitCode => {
            _discoveryTimeout.stop();
            if (exitCode !== 0) {
                root.isConnected = false;
                root.error("Command discovery failed: " + discoveryErr.text);
                return;
            }
            try {
                let data = JSON.parse(discoveryOut.text);
                let tools = Array.isArray(data) ? data : (data.tools || []);
                root.discoveredTools = tools;
                root.isConnected = true;
                root.connected();
                root.toolsDiscovered(tools);
            } catch (e) {
                // Some command agents may not support discovery; treat as no tools.
                root.discoveredTools = [];
                root.isConnected = true;
                root.connected();
                root.toolsDiscovered([]);
            }
        }
    }

    property Process invokeProcess: Process {
        property var _callback: null
        stdout: StdioCollector { id: invokeOut }
        stderr: StdioCollector { id: invokeErr }
        onExited: exitCode => {
            _invokeTimeout.stop();
            let cb = _callback;
            _callback = null;
            if (exitCode !== 0) {
                if (cb) cb({ content: "", error: "Command failed: " + invokeErr.text, done: true });
                return;
            }
            try {
                let data = JSON.parse(invokeOut.text);
                if (cb) cb({ content: data.content || data.result || "", error: data.error || null, done: true });
            } catch (e) {
                if (cb) cb({ content: invokeOut.text, error: null, done: true });
            }
        }
    }
}
