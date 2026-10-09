import QtQuick

ApiStrategy {
    id: root
    supportsStreaming: true

    function getEndpoint(modelObj, apiKey) {
        let base = modelObj.endpoint || "https://api.openai.com";
        // Ensure we don't double-append /v1
        if (base.endsWith("/v1"))
            return base + "/chat/completions";
        return base + "/v1/chat/completions";
    }

    function getHeaders(apiKey) {
        return [
            "Content-Type: application/json",
            "Authorization: Bearer " + apiKey
        ];
    }

    function _formatMessages(messages) {
        let formatted = [];
        // axless.core: remember the id of the last assistant tool_calls so a
        // following tool result can be paired even when the stored message has
        // no id of its own (older chats). Some gateways reject the request with
        // "missing field `tool_call_id`" rather than tolerate it.
        let lastToolCallId = "";
        for (let i = 0; i < messages.length; i++) {
            let msg = messages[i];

            if (msg.role === "tool") {
                let id = msg.toolCallId || lastToolCallId || ("call_" + i);
                formatted.push({ role: "tool", tool_call_id: id, content: msg.content || "" });
                continue;
            }

            // axless.core: an assistant turn that asked for a tool. The call
            // has to be echoed back as `tool_calls` - the original code dropped
            // it entirely, so the model saw a conversation where its own request
            // had vanished and answered as if it had never been made.
            if (msg.functionCall) {
                let id = msg.toolCallId || ("call_" + i);
                lastToolCallId = id;
                let am = {
                    role: "assistant",
                    content: msg.content || null,
                    tool_calls: [{
                        id: id,
                        type: "function",
                        function: {
                            name: msg.functionCall.name,
                            arguments: JSON.stringify(msg.functionCall.args || {})
                        }
                    }]
                };
                if (msg.reasoningContent)
                    am.reasoning_content = msg.reasoningContent;
                else if (root._wantsReasoning)
                    am.reasoning_content = "";
                formatted.push(am);
                continue;
            }

            lastToolCallId = "";

            if (msg.attachments && msg.attachments.length > 0) {
                let contentParts = [{type: "text", text: msg.content}];
                for (let j = 0; j < msg.attachments.length; j++) {
                    let att = msg.attachments[j];
                    if (att.type === "image") {
                        contentParts.push({
                            type: "image_url",
                            image_url: { url: "data:" + att.mimeType + ";base64," + att.base64 }
                        });
                    }
                }
                formatted.push({ role: msg.role, content: contentParts });
            } else {
                let m = { role: msg.role, content: msg.content };
                if (msg.role === "assistant" && (msg.reasoningContent || root._wantsReasoning))
                    m.reasoning_content = msg.reasoningContent || "";
                formatted.push(m);
            }
        }
        return formatted;
    }
    // axless.core: reasoning models (DeepSeek thinking, o1/o3, r1, qwq) need the
    // assistant reasoning_content echoed back. Detected by model name.
    property string _modelName: ""
    readonly property bool _wantsReasoning: /deepseek|reason|think|qwq|(^|[^a-z])r1|o1|o3/i.test(_modelName)

    function getBody(messages, model, tools) {
        root._modelName = model ? (model.model || "") : "";
        let body = {
            model: model.model,
            messages: _formatMessages(messages),
            temperature: 0.7
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

    function getStreamBody(messages, model, tools) {
        let body = getBody(messages, model, tools);
        body.stream = true;
        return body;
    }

    function parseResponse(response) {
        try {
            let json = JSON.parse(response);
            if (json.choices && json.choices.length > 0) {
                let msg = json.choices[0].message;
                if (msg.tool_calls && msg.tool_calls.length > 0) {
                    let tc = msg.tool_calls[0];
                    return {
                        content: msg.content || "",
                        functionCall: {
                            name: tc.function.name,
                            args: JSON.parse(tc.function.arguments)
                        }
                    };
                }
                return { content: msg.content };
            }
            if (json.error)
                return { content: "API Error: " + json.error.message };
            return { content: "Error: No content in response." };
        } catch (e) {
            return { content: "Error parsing response: " + e.message };
        }
    }

    function parseStreamChunk(line) {
        let trimmed = line.trim();
        if (trimmed === "" || trimmed.startsWith("event:"))
            return { content: "", done: false, error: null };

        // axless.core: some OpenAI-compatible endpoints (and gateways) ignore
        // stream:true and return one full chat-completion object instead of SSE.
        // Accept it so a non-streaming reply is not dropped as "no response".
        if (trimmed.startsWith("{")) {
            try {
                let full = JSON.parse(trimmed);
                if (full.error)
                    return { content: "", done: true, error: (full.error.message || JSON.stringify(full.error)) };
                if (full.choices && full.choices.length > 0) {
                    let msg = full.choices[0].message || {};
                    let out = { content: msg.content || "", done: true, error: null };
                    if (msg.reasoning_content)
                        out.reasoningContent = String(msg.reasoning_content);
                    else if (msg.reasoning)
                        out.reasoningContent = String(msg.reasoning);
                    if (msg.tool_calls && msg.tool_calls.length > 0)
                        out.toolCallDelta = msg.tool_calls;
                    return out;
                }
            } catch (e) {}
            return { content: "", done: false, error: null };
        }

        if (trimmed === "data: [DONE]")
            return { content: "", done: true, error: null };

        if (!trimmed.startsWith("data: "))
            return { content: "", done: false, error: null };

        try {
            let json = JSON.parse(trimmed.substring(6));
            if (json.choices && json.choices.length > 0) {
                let delta = json.choices[0].delta || {};
                // axless.core: thinking-mode models stream reasoning that the API
                // requires to be echoed back. Build one result so a chunk that
                // carries both content and reasoning loses neither.
                let out = { content: "", done: false, error: null };
                if (delta.reasoning_content)
                    out.reasoningContent = delta.reasoning_content;
                else if (delta.reasoning)
                    out.reasoningContent = delta.reasoning;
                if (delta.content)
                    out.content = delta.content;
                if (delta.tool_calls)
                    out.toolCallDelta = delta.tool_calls;
                if (json.choices[0].finish_reason)
                    out.done = true;
                return out;
            }
            if (json.error)
                return { content: "", done: false, error: json.error.message };
            return { content: "", done: false, error: null };
        } catch (e) {
            return { content: "", done: false, error: null };
        }
    }
}
