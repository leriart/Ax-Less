import QtQuick

// MiniMax's coding endpoint is Anthropic-shaped (messages, content blocks,
// tool_use/tool_result), so it inherits the Anthropic message and stream
// handling and only overrides the endpoint, auth header and defaults.
AnthropicApiStrategy {
    function getEndpoint(modelObj, apiKey) {
        return "https://api.minimax.io/anthropic/v1/messages";
    }

    function getHeaders(apiKey) {
        return [
            "Content-Type: application/json",
            "Authorization: Bearer " + apiKey,
            "anthropic-version: 2023-06-01"
        ];
    }

    function getBody(messages, model, tools, options) {
        let body = {
            model: model.model,
            messages: _filterMessages(messages),
            max_tokens: 8192,
            temperature: 1.0,
            top_p: 0.95
        };

        let sysPrompt = _extractSystemPrompt(messages);
        if (sysPrompt)
            body.system = sysPrompt;

        if (tools && tools.length > 0) {
            body.tools = tools.map(t => ({
                name: t.name,
                description: t.description,
                input_schema: t.parameters
            }));
        }

        return body;
    }

    function getStreamBody(messages, model, tools, options) {
        _resetToolSlots();
        let body = getBody(messages, model, tools, options);
        body.stream = true;
        return body;
    }

    function parseResponse(response) {
        try {
            let json = JSON.parse(response);

            if (json.error)
                return { content: "API Error: " + json.error.message };

            if (json.type === "error")
                return { content: "API Error: " + (json.error.message || "Unknown error") };

            if (json.content && json.content.length > 0) {
                let textContent = "";
                let funcCall = null;

                for (let i = 0; i < json.content.length; i++) {
                    let block = json.content[i];
                    if (block.type === "text")
                        textContent += block.text;
                    if (block.type === "tool_use") {
                        funcCall = {
                            name: block.name,
                            args: block.input
                        };
                    }
                }

                if (funcCall)
                    return { content: textContent, functionCall: funcCall };
                return { content: textContent };
            }

            if (json.base_resp && json.base_resp.status_code !== 0)
                return { content: "API Error: " + json.base_resp.status_msg };

            return { content: "Error: No content in response." };
        } catch (e) {
            return { content: "Error parsing response: " + e.message };
        }
    }
}
