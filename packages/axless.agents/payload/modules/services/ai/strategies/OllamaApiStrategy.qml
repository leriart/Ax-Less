import QtQuick

// Ollama via its OpenAI-compatible endpoint (since Ollama v0.1.14).
// Uses /v1/chat/completions which fully supports tool calling,
// unlike the legacy /api/chat native endpoint that silently drops
// the `tools` field and rejects tool-result messages.
OpenAiCompatibleStrategy {
    defaultBaseEndpoint: "http://localhost:11434"

    function getHeaders(apiKey) {
        return ["Content-Type: application/json"]
    }
}
