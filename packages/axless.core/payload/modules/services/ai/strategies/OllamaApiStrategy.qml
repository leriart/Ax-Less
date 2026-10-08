import QtQuick

// axless.core: native Ollama /api/chat, with working tool calling.
//
// The upstream strategy dropped the `tools` argument on the floor (getBody /
// getStreamBody never added it) and its stream parser only looked at
// message.content, so a model's native tool_calls were invisible to the shell
// and the assistant turn came back empty - which is why local models could
// never call tools. Ollama streams NDJSON (one JSON object per line, no SSE
// "data:" prefix) and returns tool calls under message.tool_calls with the
// arguments already decoded to an object.
ApiStrategy {
    id: root

    supportsStreaming: true

    function _endpoint(modelObj) {
        let base = (modelObj && modelObj.endpoint) ? modelObj.endpoint : "http://localhost:11434";
        if (base.endsWith("/api/chat"))
            return base;
        if (base.endsWith("/v1"))
            base = base.substring(0, base.length - 3);
        return base + "/api/chat";
    }

    function getEndpoint(modelObj, apiKey) {
        return _endpoint(modelObj);
    }

    function getHeaders(apiKey) {
        return ["Content-Type: application/json"];
    }

    // Ollama speaks the OpenAI message shapes for tools: an assistant turn that
    // called a tool carries `tool_calls`, and the result comes back as a
    // `role: "tool"` message. Ai.qml stores the call as `functionCall` and the
    // id alongside it, so translate here.
    function _formatMessages(messages) {
        let out = [];
        for (let i = 0; i < messages.length; i++) {
            let m = messages[i];
            if (!m)
                continue;
            if (m.role === "tool") {
                let toolMsg = { role: "tool", content: m.content || "" };
                if (m.name)
                    toolMsg.tool_name = m.name;
                out.push(toolMsg);
                continue;
            }
            if (m.functionCall) {
                out.push({
                    role: "assistant",
                    content: m.content || "",
                    tool_calls: [{
                        function: {
                            name: m.functionCall.name,
                            arguments: m.functionCall.args || {}
                        }
                    }]
                });
                continue;
            }
            out.push({ role: m.role, content: m.content || "" });
        }
        return out;
    }

    function _buildBody(messages, model, tools, stream) {
        let body = {
            model: model.model,
            messages: _formatMessages(messages),
            stream: stream
        };
        if (tools && tools.length > 0) {
            body.tools = tools.map(t => ({
                type: "function",
                function: {
                    name: t.name,
                    description: t.description,
                    parameters: t.parameters
                }
            }));
        }
        return body;
    }

    function getBody(messages, model, tools) {
        return _buildBody(messages, model, tools, false);
    }

    function getStreamBody(messages, model, tools) {
        return _buildBody(messages, model, tools, true);
    }

    function parseResponse(response) {
        try {
            let json = JSON.parse(response);
            if (json.error)
                return { content: "Ollama Error: " + (json.error.message || JSON.stringify(json.error)) };
            let msg = json.message || {};
            let result = { content: msg.content || "" };
            if (msg.tool_calls && msg.tool_calls.length > 0) {
                let tc = msg.tool_calls[0];
                result.functionCall = {
                    name: tc.function ? tc.function.name : "",
                    args: (tc.function && tc.function.arguments) ? tc.function.arguments : {}
                };
                result.toolCallId = tc.id || "";
            }
            return result;
        } catch (e) {
            return { content: "Error parsing response: " + e.message };
        }
    }

    // Ollama uses NDJSON, not SSE - each line is a JSON object.
    function parseStreamChunk(line) {
        let trimmed = line.trim();
        if (trimmed === "")
            return emptyResult();

        try {
            let json = JSON.parse(trimmed);
            if (json.error)
                return { content: "", done: false, error: (json.error.message || JSON.stringify(json.error)), toolCallDelta: null };

            let msg = json.message || {};
            let result = emptyResult();

            if (msg.content)
                result.content = msg.content;

            // Normalise native tool_calls to the OpenAI delta shape Ai.qml
            // accumulates ({index, id, function:{name, arguments:<string>}}).
            if (msg.tool_calls && msg.tool_calls.length > 0) {
                result.toolCallDelta = msg.tool_calls.map((tc, i) => {
                    let fn = tc.function || {};
                    let args = fn.arguments;
                    return {
                        index: (fn.index !== undefined) ? fn.index : i,
                        id: tc.id || "",
                        function: {
                            name: fn.name || "",
                            arguments: (args === undefined)
                                ? ""
                                : (typeof args === "string" ? args : JSON.stringify(args))
                        }
                    };
                });
            }

            if (json.done)
                result.done = true;
            return result;
        } catch (e) {
            return emptyResult();
        }
    }

    function emptyResult() {
        return { content: "", done: false, error: null, toolCallDelta: null };
    }
}
