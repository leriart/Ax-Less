pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import qs.config
import qs.modules.services
import qs.modules.globals
import "ai"
import "ai/strategies"

Singleton {
    id: root

    // ============================================
    // PROPERTIES
    // ============================================

    property string chatDir: Quickshell.env("HOME") + "/.local/share/ambxst/chats"
    property string tmpDir: "/tmp/ambxst-ai"

    property list<AiModel> models: []

    property AiModel currentModel: models.length > 0 ? models[0] : null
    property bool persistenceReady: false
    property string savedModelId: ""
    property bool isRestored: false

    onCurrentModelChanged: {
        if (persistenceReady && currentModel && isRestored) {
            StateService.set("lastAiModel", currentModel.model);
        }
        updateStrategy();
    }

    function restoreModel() {
        const lastModelId = StateService.get("lastAiModel", "gemini-2.0-flash");
        savedModelId = lastModelId;
        tryRestore();
        persistenceReady = true;
    }

    function tryRestore() {
        if (isRestored || models.length === 0)
            return;

        let found = false;

        for (let i = 0; i < models.length; i++) {
            if (models[i].model === savedModelId) {
                currentModel = models[i];
                found = true;
                break;
            }
        }

        if (!found && savedModelId) {
            for (let i = 0; i < models.length; i++) {
                if (models[i].model.endsWith(savedModelId) || models[i].model.endsWith("/" + savedModelId)) {
                    currentModel = models[i];
                    found = true;
                    break;
                }
            }
        }

        if (found)
            isRestored = true;
    }

    property bool _restored: false
    Connections {
        target: StateService
        function onInitializedChanged() {
            root._restore();
        }
    }
    Connections {
        target: KeyStore
        function onKeysChanged() {
            fetchAvailableModels();
        }
    }

    Component.onCompleted: root._restore()

    function _restore() {
        if (StateService.initialized && !root._restored) {
            root._restored = true;
            restoreModel();
        }
    }

    // Lazy init: trigger fetchAvailableModels/reloadHistory/createNewChat
    // when AI sidebar is opened for the first time.
    property bool _aiInitialized: false
    function _ensureInit() {
        if (_aiInitialized) return;
        _aiInitialized = true;
        if (models.length === 0)
            fetchAvailableModels();
        reloadHistory();
        createNewChat();
    }

    // Trigger lazy init when AI sidebar is opened
    Connections {
        target: GlobalStates
        function onAssistantVisibleChanged() {
            if (GlobalStates.assistantVisible)
                root._ensureInit();
        }
    }

    // ============================================
    // STRATEGIES
    // ============================================

    property OpenAiApiStrategy openaiStrategy: OpenAiApiStrategy {}
    property GeminiApiStrategy geminiStrategy: GeminiApiStrategy {}
    property AnthropicApiStrategy anthropicStrategy: AnthropicApiStrategy {}
    property MistralApiStrategy mistralStrategy: MistralApiStrategy {}
    property GroqApiStrategy groqStrategy: GroqApiStrategy {}
    property OllamaApiStrategy ollamaStrategy: OllamaApiStrategy {}
    property MiniMaxApiStrategy minimaxStrategy: MiniMaxApiStrategy {}

    property ApiStrategy currentStrategy: openaiStrategy

    function getStrategyForProvider(providerName) {
        switch (providerName) {
        case "openai": return openaiStrategy;
        case "gemini": return geminiStrategy;
        case "anthropic": return anthropicStrategy;
        case "mistral": return mistralStrategy;
        case "groq": return groqStrategy;
        case "ollama": return ollamaStrategy;
        case "minimax": return minimaxStrategy;
        // axless.core: everything else that speaks the OpenAI wire format.
        case "deepseek":
        case "openrouter":
        case "xai":
        case "lmstudio":
        case "custom":
        default: return openaiStrategy;
        }
    }

    function updateStrategy() {
        if (currentModel)
            currentStrategy = getStrategyForProvider(currentModel.provider);
        else
            currentStrategy = openaiStrategy;
    }

    // ============================================
    // STATE
    // ============================================

    property bool isLoading: false

    // axless.core: set while stopping so onExited keeps the partial answer and
    // does not overwrite it with a network error.
    property bool stoppedByUser: false

    // Abort the in-flight request. The streamed text stays in the message.
    function stopGeneration() {
        if (!root.isLoading && !curlProcess.running)
            return;
        root.stoppedByUser = true;
        if (curlProcess.running)
            curlProcess.running = false;
        root.isLoading = false;
        root.responseBuffer = "";
    }
    property string lastError: ""
    property string responseBuffer: ""

    // axless.core: tool-call loop state, built on the original engine.
    // The original sent `tools` but ignored the streamed tool calls entirely,
    // so nothing ever executed. These hold the call being assembled and the
    // registry of tools the connected agents advertise.
    property var _pendingToolCalls: []

    // axless.core: chat vs agent. In chat mode no tools are advertised, so
    // the sidebar's toggle is not cosmetic - it changes what the model is
    // offered. currentAgentId narrows the tool set to one connected agent.
    signal modeChanged()
    signal agentChanged()
    property string currentMode: "agent"
    property string currentAgentId: ""

    function setMode(mode) {
        if (mode !== "chat" && mode !== "agent")
            return;
        if (currentMode === mode)
            return;
        currentMode = mode;
        modeChanged();
    }

    function setAgent(id) {
        let next = id || "";
        if (currentAgentId === next)
            return;
        currentAgentId = next;
        agentChanged();
    }

    // How many agents are connected right now, for the sidebar badge.
    readonly property int connectedAgents: {
        let reg = root.agentToolRegistry;
        if (!reg || !reg.tools)
            return 0;
        let ids = {};
        for (let i = 0; i < reg.tools.length; i++) {
            let a = reg.tools[i] && reg.tools[i]._agentId;
            if (a) ids[a] = true;
        }
        return Object.keys(ids).length;
    }

    property AgentToolRegistry agentToolRegistry: AgentToolRegistry {}
    property AgentManager agentManager: AgentManager {
        toolRegistry: root.agentToolRegistry
    }

    // Current Chat
    property var currentChat: []
    property string currentChatId: ""

    // Chat History List (files)
    property var chatHistory: []

    FileView {
        id: chatFileView
        printErrors: false
    }

    FileView {
        id: bodyFileView
        printErrors: false
    }

    // ==== axless.debug (TEMPORAL): deja un rastro en archivo para localizar
    // el cuelgue de la UI. Se escribe solo; quitar cuando se arregle. ====
    readonly property string _dbgPath: Quickshell.env("HOME") + "/.cache/ambxst/axless-debug.log"
    property string _dbgBuf: ""
    property bool _dbgInit: false
    property int _streamChunks: 0

    function _log(tag, msg) {
        let line = (new Date()).toISOString() + " [" + tag + "] " + msg;
        console.log("[axless] " + line);
        if (!root._dbgInit) {
            root._dbgInit = true;
            _dbgTrunc.command = ["bash", "-c", "mkdir -p " + Quickshell.env("HOME") + "/.cache/ambxst; : > " + root._dbgPath];
            _dbgTrunc.running = true;
        }
        root._dbgBuf += line + "\n";
        _dbgFlush.restart();
    }

    Timer {
        id: _dbgFlush
        interval: 60
        onTriggered: {
            if (root._dbgBuf.length === 0)
                return;
            _dbgApp.environment = ({ AXLESS_LINE: root._dbgBuf });
            _dbgApp.command = ["bash", "-c", "printf '%s' \"$AXLESS_LINE\" >> " + root._dbgPath];
            root._dbgBuf = "";
            _dbgApp.running = true;
        }
    }
    Process { id: _dbgApp }
    Process { id: _dbgTrunc }

    Timer {
        interval: 2000
        running: true
        repeat: true
        onTriggered: root._log("hb", "tick loading=" + root.isLoading + " n=" + root.currentChat.length)
    }

    // ============================================
    // TOOLS
    // ============================================

    function regenerateResponse(index) {
        if (index < 0 || index >= currentChat.length)
            return;

        let newChat = currentChat.slice(0, index);
        currentChat = newChat;

        isLoading = true;
        lastError = "";
        makeRequest();
    }

    function updateMessage(index, newContent) {
        if (index < 0 || index >= currentChat.length)
            return;

        let newChat = Array.from(currentChat);
        let msg = newChat[index];
        msg.content = newContent;
        newChat[index] = msg;

        currentChat = newChat;
        saveCurrentChat();
    }

    // axless.core: the registry only exposes tools whose agent is actually
    // connected, so the model is never told about a tool nobody can serve.
    property var systemTools: {
        if (root.currentMode !== "agent")
            return [];
        let t = [
        {
            name: "run_shell_command",
            description: "Execute a shell command on the user's system (Linux). Use this to list files, control the system, or run utilities. Output will be returned.",
            parameters: {
                type: "object",
                properties: {
                    command: {
                        type: "string",
                        description: "The shell command to run (e.g. 'ls -la', 'ip addr')"
                    }
                },
                required: ["command"]
            }
        }
        ];
        let reg = root.agentToolRegistry;
        if (reg && reg.tools) {
            for (let i = 0; i < reg.tools.length; i++) {
                let tool = reg.tools[i];
                if (!tool)
                    continue;
                if (root.currentAgentId !== ""
                        && tool._agentId !== root.currentAgentId)
                    continue;
                t.push(tool);
            }
        }
        return t;
    }

    // ============================================
    // CHAT MANAGEMENT
    // ============================================

    function deleteChat(id) {
        if (id === currentChatId)
            createNewChat();

        let filename = chatDir + "/" + id + ".json";
        deleteChatProcess.command = ["rm", filename];
        deleteChatProcess.running = true;
    }

    // ============================================
    // LOGIC
    // ============================================

    function setModel(modelName) {
        for (let i = 0; i < models.length; i++) {
            if (models[i].name === modelName) {
                currentModel = models[i];
                return;
            }
        }
    }

    function getApiKey(model) {
        if (!model || !model.requires_key)
            return "";

        // Try KeyStore first
        let ksKey = KeyStore.getKey(model.provider);
        if (ksKey)
            return ksKey;

        return "";
    }

    function processCommand(text) {
        let cmd = text.trim();
        if (!cmd.startsWith("/"))
            return false;

        let parts = cmd.split(" ");
        let command = parts[0].toLowerCase();
        let args = parts.slice(1).join(" ");

        switch (command) {
        case "/new":
            createNewChat();
            return true;
        case "/model":
            if (args) {
                let found = false;
                for (let i = 0; i < models.length; i++) {
                    if (models[i].name.toLowerCase().includes(args.toLowerCase()) || models[i].model.toLowerCase() === args.toLowerCase()) {
                        setModel(models[i].name);
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    pushSystemMessage(I18n.t("ai.model_not_found").replace("%1", args));
                } else {
                    pushSystemMessage(I18n.t("ai.switched_to_model").replace("%1", currentModel.name));
                }
            } else {
                modelSelectionRequested();
            }
            return true;
        case "/help":
            pushSystemMessage(I18n.t("ai.help_message"));
            return true;
        }

        return false;
    }

    function pushSystemMessage(text) {
        let newChat = Array.from(currentChat);
        newChat.push({
            role: "system",
            content: text
        });
        currentChat = newChat;
    }

    // Function Call Handling
    function approveCommand(index) {
        root._log("approveCommand", "index=" + index);
        let msg = currentChat[index];
        if (!msg.functionCall)
            return;

        let newChat = Array.from(currentChat);
        newChat[index].functionPending = false;
        newChat[index].functionApproved = true;
        currentChat = newChat;
        saveCurrentChat();

        let name = msg.functionCall.name;
        let args = msg.functionCall.args || {};

        if (name === "run_shell_command") {
            commandExecutionProc.command = ["bash", "-c", args.command];
            commandExecutionProc.targetIndex = index;
            commandExecutionProc.running = true;
            return;
        }

        // axless.core: a tool from a connected agent. The registry routes it
        // to whichever agent advertised it; if none can, it answers with an
        // error string that is returned to the model like any other result,
        // so the conversation stays well-formed instead of stalling.
        if (root.agentToolRegistry && root.agentToolRegistry.hasTool(name)) {
            root.agentToolRegistry.invoke(name, args, function(result) {
                let out = "";
                if (result && result.error)
                    out = "Error: " + result.error;
                else if (result && result.content !== undefined)
                    out = result.content;
                root._finishToolCall(index, name, out);
            });
            return;
        }

        root._finishToolCall(index, name,
            "Error: tool '" + name + "' is not available.");
    }

    // Push a tool result and let the model continue. Uses the current OpenAI
    // shape (role "tool" + tool_call_id) so the request is valid.
    function _finishToolCall(index, name, output) {
        root._log("_finishToolCall", "name=" + name);
        let msg = currentChat[index];
        let newChat = Array.from(currentChat);
        newChat.push({
            role: "tool",
            name: name,
            toolCallId: msg ? msg.toolCallId : "",
            content: output
        });
        root.currentChat = newChat;
        root.saveCurrentChat();
        root.makeRequest();
    }

    function rejectCommand(index) {
        let newChat = Array.from(currentChat);
        newChat[index].functionPending = false;
        newChat[index].functionApproved = false;

        newChat.push({
            role: "tool",
            name: newChat[index].functionCall.name,
            toolCallId: newChat[index].toolCallId || "",
            content: "The user rejected this tool call."
        });

        currentChat = newChat;
        saveCurrentChat();
        makeRequest();
    }

    function sendMessage(text, attachments) {
        root._log("sendMessage", "textlen=" + (text ? text.length : 0));
        if (text.trim() === "" && (!attachments || attachments.length === 0))
            return;
        if (processCommand(text))
            return;
        isLoading = true;
        lastError = "";
        let userMsg = {
            role: "user",
            content: text
        };
        if (attachments && attachments.length > 0)
            userMsg.attachments = attachments;
        let newChat = Array.from(currentChat);
        newChat.push(userMsg);
        currentChat = newChat;
        saveCurrentChat();
        makeRequest();
    }

    function makeRequest() {
        root._log("makeRequest", "n=" + currentChat.length + " tools=" + (systemTools ? systemTools.length : -1));
        let apiKey = getApiKey(currentModel);
        if (!apiKey && currentModel.requires_key) {
            lastError = I18n.t("ai.api_key_missing").replace("%1", currentModel.name).replace("%2", currentModel.key_id || I18n.t("ai.env_variable"));
            isLoading = false;

            let errChat = Array.from(currentChat);
            errChat.push({
                role: "assistant",
                content: "Error: " + lastError
            });
            currentChat = errChat;
            return;
        }

        // Determine endpoint — Gemini streaming uses a different endpoint
        let endpoint;
        let isGemini = currentModel.provider === "gemini";
        if (isGemini && geminiStrategy._getStreamEndpoint) {
            endpoint = geminiStrategy._getStreamEndpoint(currentModel, apiKey);
        } else {
            endpoint = currentStrategy.getEndpoint(currentModel, apiKey);
        }

        let headers = currentStrategy.getHeaders(apiKey);

        // Build messages array
        let messages = [];
        if (Config.ai.systemPrompt) {
            messages.push({
                role: "system",
                content: Config.ai.systemPrompt
            });
        }

        for (let i = 0; i < currentChat.length; i++) {
            let msg = currentChat[i];
            let apiMsg = {
                role: msg.role,
                content: msg.content
            };
            if (msg.attachments)
                apiMsg.attachments = msg.attachments;
            if (msg.functionCall)
                apiMsg.functionCall = msg.functionCall;
            if (msg.geminiParts)
                apiMsg.geminiParts = msg.geminiParts;
            if (msg.name)
                apiMsg.name = msg.name;
            messages.push(apiMsg);
        }

        // Build body — always use streaming
        root._log("makeRequest", "msgs=" + messages.length + " -> getStreamBody");
        let body = currentStrategy.getStreamBody(messages, currentModel, systemTools);
        root._log("makeRequest", "getStreamBody ok");

        // Reset streaming buffer
        responseBuffer = "";
        _pendingToolCalls = [];
        _streamChunks = 0;

        // Add placeholder assistant message for streaming
        let streamChat = Array.from(currentChat);
        streamChat.push({
            role: "assistant",
            content: "",
            model: currentModel ? currentModel.name : "Unknown"
        });
        currentChat = streamChat;

        root._log("makeRequest", "stringify body");
        writeTempBody(JSON.stringify(body), headers, endpoint);
    }

    function writeTempBody(jsonBody, headers, endpoint) {
        root._log("writeTempBody", "len=" + (jsonBody ? jsonBody.length : 0));
        requestProcess.command = ["/usr/bin/mkdir", "-p", tmpDir];
        requestProcess.step = "mkdir";
        requestProcess.payload = {
            body: jsonBody,
            headers: headers,
            endpoint: endpoint
        };
        requestProcess.running = true;
    }

    function executeRequest(payload) {
        root._log("executeRequest", "endpoint set");
        let bodyPath = tmpDir + "/body.json";
        bodyFileView.path = bodyPath;
        bodyFileView.setText(payload.body);
        Qt.callLater(() => runCurl(payload));
    }

    function runCurl(payload) {
        root._log("runCurl", "endpoint=" + (payload ? payload.endpoint : "?"));
        let bodyPath = tmpDir + "/body.json";
        let headerArgs = payload.headers.map(h => "-H \"" + h + "\"").join(" ");

        // Check for custom curl template
        let customCurl = "";
        if (currentModel && currentModel.customCurlTemplate) {
            customCurl = currentModel.customCurlTemplate;
        } else if (currentModel && KeyStore.getCustomCurl(currentModel.provider)) {
            customCurl = KeyStore.getCustomCurl(currentModel.provider);
        }

        let curlCmd;
        if (customCurl) {
            // Replace placeholders in custom curl
            curlCmd = customCurl
                .replace("{{BODY_PATH}}", bodyPath)
                .replace("{{ENDPOINT}}", payload.endpoint)
                .replace("{{API_KEY}}", getApiKey(currentModel));
        } else {
            curlCmd = "curl -s --no-buffer -N -X POST \"" + payload.endpoint + "\" " + headerArgs + " -d @" + bodyPath;
        }

        curlProcess.command = ["/usr/bin/bash", "-c", curlCmd];
        curlProcess.running = true;
    }

    // ============================================
    // PROCESSES
    // ============================================

    Process {
        id: requestProcess
        property string step: ""
        property var payload: ({})

        onExited: exitCode => {
            if (exitCode === 0 && step === "mkdir") {
                executeRequest(payload);
            } else if (exitCode !== 0) {
                root.lastError = "Failed to create temp directory";
                root.isLoading = false;
            }
        }
    }

    Process {
        id: writeBodyProcess
        property var payload: ({})
        stderr: StdioCollector {
            id: writeBodyStderr
        }

        onExited: exitCode => {
            if (exitCode === 0) {
                runCurl(payload);
            } else {
                root.lastError = "Failed to write request body: " + writeBodyStderr.text;
                root.isLoading = false;
            }
        }
    }

    Process {
        id: curlProcess

        // Use SplitParser for streaming — emits onRead per line
        stdout: SplitParser {
            onRead: data => {
                let result = root.currentStrategy.parseStreamChunk(data);
                root._streamChunks++;
                if (root._streamChunks === 1 || root._streamChunks % 40 === 0)
                    root._log("onRead", "chunk=" + root._streamChunks);

                if (result.error) {
                    root.lastError = result.error;
                    return;
                }

                if (result.content) {
                    root.responseBuffer += result.content;
                    // Update the last message in currentChat with accumulated text
                    let newChat = Array.from(root.currentChat);
                    if (newChat.length > 0) {
                        newChat[newChat.length - 1].content = root.responseBuffer;
                        root.currentChat = newChat;
                    }
                }

                // axless.core: accumulate streamed tool calls. They arrive as
                // fragments - the name once, the arguments over several chunks -
                // so they are merged by index and only read once the stream
                // ends. The original parser surfaced these deltas and then
                // nothing consumed them.
                if (result.toolCallDelta) {
                    for (let k = 0; k < result.toolCallDelta.length; k++) {
                        let d = result.toolCallDelta[k];
                        if (!d)
                            continue;
                        let idx = (typeof d.index === "number" && isFinite(d.index)
                                   && d.index >= 0 && d.index < 64) ? Math.floor(d.index) : 0;
                        let calls = root._pendingToolCalls.slice();
                        while (calls.length <= idx)
                            calls.push({ id: "", name: "", args: "" });
                        let slot = calls[idx];
                        if (d.id)
                            slot.id = d.id;
                        if (d.function) {
                            if (d.function.name)
                                slot.name += d.function.name;
                            if (d.function.arguments)
                                slot.args += d.function.arguments;
                        }
                        root._pendingToolCalls = calls;
                    }
                }

                // Note: done is handled in onExited
            }
        }

        stderr: StdioCollector {
            id: curlStderr
        }

        onExited: exitCode => {
            root.isLoading = false;
            root._log("onExited", "code=" + exitCode + " pending=" + root._pendingToolCalls.length
                + " buf=" + root.responseBuffer.length);

            if (root.stoppedByUser) {
                // The user aborted. Keep whatever streamed so far and record
                // it without treating the killed process as a failure.
                root.stoppedByUser = false;
                root.responseBuffer = "";
                root.saveCurrentChat();
                return;
            }

            if (exitCode === 0) {
                // axless.core: a completed tool call becomes the assistant
                // message's `functionCall`, which is the shape the sidebar
                // already renders for approval and which the strategy now
                // echoes back as `tool_calls`.
                if (root._pendingToolCalls.length > 0) {
                    let calls = root._pendingToolCalls;
                    root._pendingToolCalls = [];
                    let first = calls[0];
                    let args = {};
                    try { args = JSON.parse(first.args || "{}"); } catch (e) { args = {}; }
                    let chat = Array.from(root.currentChat);
                    if (chat.length > 0 && first.name) {
                        let last = chat[chat.length - 1];
                        last.functionCall = { name: first.name, args: args };
                        last.toolCallId = first.id || ("call_" + Date.now());
                        last.functionPending = true;
                        last.functionApproved = false;
                        root.currentChat = chat;
                        root.saveCurrentChat();
                    }
                    root.responseBuffer = "";
                    return;
                }

                // Check if we got any content during streaming
                if (root.responseBuffer === "" && root.currentChat.length > 0) {
                    // No streaming data received — might be non-streaming response or error
                    // The last message is our placeholder, leave as is
                    let lastMsg = root.currentChat[root.currentChat.length - 1];
                    if (!lastMsg.content) {
                        let newChat = Array.from(root.currentChat);
                        newChat[newChat.length - 1].content = I18n.t("ai.no_response");
                        root.currentChat = newChat;
                    }
                }

                root.saveCurrentChat();
                root._log("onExited", "done ok");
            } else {
                root.lastError = I18n.t("ai.network_failed").replace("%1", curlStderr.text);

                // Update the placeholder message with error
                let errChat = Array.from(root.currentChat);
                if (errChat.length > 0) {
                    errChat[errChat.length - 1].content = "Error: " + root.lastError;
                }
                root.currentChat = errChat;
            }

            root.responseBuffer = "";
        }
    }

    Process {
        id: commandExecutionProc
        property int targetIndex: -1

        stdout: StdioCollector {
            id: cmdStdout
        }
        stderr: StdioCollector {
            id: cmdStderr
        }

        onExited: exitCode => {
            let output = cmdStdout.text + "\n" + cmdStderr.text;
            if (output.trim() === "")
                output = I18n.t("ai.cmd_no_output");

            let msg = currentChat[targetIndex];
            let newChat = Array.from(currentChat);

            newChat.push({
                role: "tool",
                name: msg.functionCall.name,
                toolCallId: msg.toolCallId || "",
                content: output
            });

            root.currentChat = newChat;
            root.saveCurrentChat();
            root.makeRequest();
        }
    }

    // ============================================
    // CHAT STORAGE
    // ============================================

    function createNewChat() {
        currentChat = [];
        currentChatId = Date.now().toString();
        chatModelChanged();
    }

    function saveCurrentChat() {
        root._log("saveCurrentChat", "n=" + currentChat.length);
        if (currentChat.length === 0)
            return;

        let filename = chatDir + "/" + currentChatId + ".json";
        let data = JSON.stringify(currentChat, null, 2);

        saveChatProcess.filePath = filename;
        saveChatProcess.data = data;
        saveChatProcess.command = ["/usr/bin/mkdir", "-p", chatDir];
        saveChatProcess.running = true;
    }

    function reloadHistory() {
        listHistoryProcess.command = ["ambxst", "chatlist", chatDir];
        listHistoryProcess.running = true;
    }

    function loadChat(id) {
        let filename = chatDir + "/" + id + ".json";
        loadChatProcess.targetId = id;
        loadChatProcess.command = ["cat", filename];
        loadChatProcess.running = true;
    }

    Process {
        id: saveChatProcess
        property string filePath: ""
        property string data: ""
        onExited: exitCode => {
            if (exitCode === 0) {
                if (filePath.length > 0)
                    chatFileView.path = filePath;
                if (data.length > 0)
                    chatFileView.setText(data);
                reloadHistory();
            } else {
                console.warn("Failed to create chat directory");
            }
        }
    }

    Process {
        id: deleteChatProcess
        onExited: reloadHistory()
    }

    Process {
        id: listHistoryProcess
        stdout: StdioCollector {
            id: listHistoryStdout
        }
        onExited: exitCode => {
            if (exitCode === 0) {
                let lines = listHistoryStdout.text.trim().split("\n");
                let history = [];
                for (let i = 0; i < lines.length; i++) {
                    let line = lines[i];
                    if (line === "")
                        continue;
                    let parts = line.split("|");
                    if (parts.length >= 2) {
                        history.push({
                            id: parts[0],
                            title: parts.slice(1).join("|"),
                            path: chatDir + "/" + parts[0] + ".json"
                        });
                    }
                }
                root.chatHistory = history;
                root.historyModelChanged();
            }
        }
    }

    Process {
        id: loadChatProcess
        property string targetId: ""
        stdout: StdioCollector {
            id: loadChatStdout
        }
        onExited: exitCode => {
            if (exitCode === 0) {
                try {
                    root.currentChat = JSON.parse(loadChatStdout.text);
                    root.currentChatId = targetId;
                    root.chatModelChanged();
                } catch (e) {
                    console.log("Error loading chat: " + e);
                }
            }
        }
    }

    // ============================================
    // DYNAMIC MODEL FETCHING
    // ============================================

    property bool fetchingModels: false
    property int pendingFetches: 0

    // axless.core: every provider is queried live. There are no hardcoded
    // model lists: when a key is saved (or a local backend is enabled) the
    // provider's own models endpoint is asked and whatever it returns becomes
    // the list. This table is the single source of truth for endpoints, auth
    // style and key ids, so adding a provider is one entry.
    readonly property var modelProviders: [
        { id: "openai",     label: "OpenAI",     base: "https://api.openai.com",                            path: "/v1/models", auth: "bearer",    keyId: "OPENAI_API_KEY",     icon: "openai.svg" },
        { id: "anthropic",  label: "Anthropic",  base: "https://api.anthropic.com",                         path: "/v1/models", auth: "anthropic", keyId: "ANTHROPIC_API_KEY",  icon: "anthropic.svg" },
        { id: "gemini",     label: "Gemini",     base: "https://generativelanguage.googleapis.com/v1beta",  path: "/models",    auth: "query",     keyId: "GEMINI_API_KEY",     icon: "google.svg", format: "gemini" },
        { id: "mistral",    label: "Mistral",    base: "https://api.mistral.ai",                            path: "/v1/models", auth: "bearer",    keyId: "MISTRAL_API_KEY",    icon: "mistral.svg" },
        { id: "groq",       label: "Groq",       base: "https://api.groq.com/openai",                       path: "/v1/models", auth: "bearer",    keyId: "GROQ_API_KEY",       icon: "groq.svg" },
        { id: "deepseek",   label: "DeepSeek",   base: "https://api.deepseek.com",                          path: "/v1/models", auth: "bearer",    keyId: "DEEPSEEK_API_KEY",   icon: "deepseek.svg" },
        { id: "openrouter", label: "OpenRouter", base: "https://openrouter.ai/api",                         path: "/v1/models", auth: "bearer",    keyId: "OPENROUTER_API_KEY", icon: "openrouter.svg" },
        { id: "xai",        label: "xAI",        base: "https://api.x.ai",                                  path: "/v1/models", auth: "bearer",    keyId: "XAI_API_KEY",        icon: "xai.svg" },
        { id: "minimax",    label: "MiniMax",    base: "https://api.minimax.io",                            path: "/v1/models", auth: "bearer",    keyId: "MINIMAX_API_KEY",    icon: "minimax.svg" },
        { id: "ollama",     label: "Ollama",     base: "http://127.0.0.1:11434",                            path: "/api/tags",  auth: "none",      icon: "ollama.svg",   format: "ollama", local: true },
        { id: "lmstudio",   label: "LM Studio",  base: "http://localhost:1234",                             path: "/v1/models", auth: "none",      icon: "lmstudio.svg", local: true }
    ]

    function _providerCommand(prov, key) {
        const url = prov.base + prov.path;
        if (prov.auth === "query")
            return ["bash", "-c", "curl -s '" + url + "?key=" + key + "'"];
        if (prov.auth === "anthropic")
            return ["bash", "-c", "curl -s " + url
                + " -H 'x-api-key: " + key + "' -H 'anthropic-version: 2023-06-01'"];
        if (prov.auth === "bearer")
            return ["bash", "-c", "curl -s " + url
                + " -H 'Authorization: Bearer " + key + "'"];
        return ["bash", "-c", "curl -s " + url];
    }

    function fetchAvailableModels() {
        fetchingModels = true;
        pendingFetches = 0;

        for (let i = 0; i < modelProviders.length; i++) {
            const prov = modelProviders[i];
            let key = "";
            if (prov.local) {
                // Local backends have no key; the settings panel stores an
                // "enabled" flag under their id when the user turns them on.
                if (!KeyStore.hasKey(prov.id))
                    continue;
            } else {
                key = KeyStore.getKey(prov.id);
                if (!key)
                    continue;
            }
            pendingFetches++;
            const proc = modelFetchFactory.createObject(root, {});
            proc._provider = prov;
            proc.command = _providerCommand(prov, key);
            proc.running = true;
        }

        if (pendingFetches === 0) {
            fetchingModels = false;
            tryRestore();
        }
    }

    // One Process per in-flight provider fetch, created on demand so the
    // provider table drives everything. A fixed set of eight hand-written
    // Process blocks used to live here.
    Component {
        id: modelFetchFactory
        Process {
            property var _provider: null
            stdout: StdioCollector {}
            onExited: (code) => {
                if (code === 0)
                    root._ingestModels(_provider, String(stdout.text || ""));
                root.checkFetchCompletion();
                destroy();
            }
        }
    }

    // Parse a provider's response into models. Handles the Gemini, Ollama and
    // OpenAI-compatible shapes; the latter also covers OpenRouter, xAI,
    // DeepSeek, MiniMax, Groq, Mistral and LM Studio.
    function _ingestModels(prov, text) {
        if (!prov || !text || text.length === 0)
            return;
        let data;
        try { data = JSON.parse(text); } catch (e) { return; }
        if (data.error)
            return;

        let entries = [];
        if (prov.format === "gemini") {
            const list = data.models || [];
            for (let i = 0; i < list.length; i++) {
                const id = String(list[i].name || "").replace("models/", "");
                if (id)
                    entries.push({ id: id, name: list[i].displayName || id,
                                   desc: list[i].description || "" });
            }
        } else if (prov.format === "ollama") {
            const list = data.models || [];
            for (let i = 0; i < list.length; i++)
                if (list[i].name)
                    entries.push({ id: list[i].name, name: list[i].name, desc: "" });
        } else {
            const list = data.data || data.models || [];
            for (let i = 0; i < list.length; i++) {
                const e = list[i];
                const id = e.id || e.name;
                if (id)
                    entries.push({ id: id, name: e.display_name || e.name || id,
                                   desc: e.description || "" });
            }
        }

        const newModels = [];
        for (let i = 0; i < entries.length; i++) {
            const e = entries[i];
            const m = aiModelFactory.createObject(root, {
                name: e.name,
                icon: Qt.resolvedUrl("../../../assets/aiproviders/" + prov.icon),
                description: e.desc || prov.label,
                endpoint: prov.base,
                model: e.id,
                provider: prov.id,
                requires_key: !prov.local,
                key_id: prov.keyId || ""
            });
            if (m)
                newModels.push(m);
        }
        mergeModels(newModels);
    }

    function checkFetchCompletion() {
        pendingFetches--;
        if (pendingFetches <= 0) {
            fetchingModels = false;
            pendingFetches = 0;

            tryRestore();

            if (!currentModel && models.length > 0) {
                currentModel = models[0];
                isRestored = true;
            } else if (!isRestored && currentModel) {
                isRestored = true;
            }
        }
    }

    function mergeModels(newModels) {
        let updatedList = [];
        for (let i = 0; i < models.length; i++)
            updatedList.push(models[i]);

        for (let i = 0; i < newModels.length; i++) {
            let m = newModels[i];
            let isDuplicate = false;
            for (let j = 0; j < updatedList.length; j++) {
                if (updatedList[j].model === m.model) {
                    isDuplicate = true;
                    break;
                }
            }
            if (!isDuplicate)
                updatedList.push(m);
        }

        models = updatedList;

        if (!isRestored)
            tryRestore();
    }

    // Signals
    signal chatModelChanged
    signal historyModelChanged
    signal modelSelectionRequested

    Component {
        id: aiModelFactory
        AiModel {}
    }
}
