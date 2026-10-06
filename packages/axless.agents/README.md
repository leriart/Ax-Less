# axless.agents

Pluggable agent runtime for the Ambxst assistant, ported from the NothingLess
AI subsystem.

This mod turns the assistant from "a chat box with one hardcoded
`run_shell_command` tool" into an agent host: you register agents, each agent
advertises its own tools, and the tools discovered from every connected agent
are merged into the request the model sees.

## What it adds

### Agent runtime (new files, no base conflict)

| File | Purpose |
|---|---|
| `modules/services/AgentStore.qml` | One JSON file per agent profile under `XDG_DATA_HOME/ambxst/agents/<id>.json`, watched with `FileView`. |
| `modules/services/AgentConnection.qml` | In-memory profile mirror plus live connection status. |
| `modules/services/AgentManager.qml` | Registry. Spawns and kills agent child processes, tracks `process` descriptors, caps auto-reconnect at 5 attempts. |
| `modules/services/HttpAgentClient.qml` | HTTP bridge transport: `GET <ep>/tools`, `POST <ep>/invoke`. |
| `modules/services/CommandAgentClient.qml` | Stateless command transport: spawns per invocation, JSON on stdout, 35 s timeout. |
| `modules/services/McpStdioClient.qml` | Model Context Protocol over stdio, via a FIFO handshake. |
| `modules/services/AgentToolRegistry.qml` | Flattens every discovered tool into the shape `Ai.systemTools` expects. |
| `modules/services/ai/ModelCapabilityProbe.qml` | Asks the model what it can do (Ollama `/api/show`, OpenAI-compatible `/v1/models/{model}`) instead of guessing from the name. |
| `modules/bar/AiModeButton.qml` | Bar button: chat/agent mode switch plus agent picker. |
| `scripts/mcp_stdio_bridge.py` | stdio ↔ FIFO bridge for MCP servers (QML has no stdin). |
| `scripts/ollama-ensure.sh` | Starts the local Ollama daemon if it is not answering. |

### AI engine (replaces the base files)

`Ai.qml` and the whole `modules/services/ai/strategies/` set are replaced. The
strategy layer gains a shared `OpenAiCompatibleStrategy` base, a model-family
capability table, inline `<think>` stripping, and correct OpenAI
`tool_calls` / `role: "tool"` message shaping — the base version dropped
`functionCall` and `tool_call_id` on the floor, so every tool call ended in
"No response received from the API".

New: multi-step chain enforcement, duplicate-call and rate limiting, a
text-based tool-call fallback for small models, per-tier timeouts for slow
local models, throttled streaming, and a request watchdog.

### UI

- `AssistantSidebar.qml` — the agent-capable sidebar, including the agent
  picker, per-tool approval rows and tool-result rendering.
- `AiPanel.qml` — provider, model, keystore and agent connection settings.
- `CodeBlock.qml`, `ModelSelectorPopup.qml` — updated alongside the above.
- `BarContent.qml` — inserts `AiModeButton` in both orientations (patch).
- `Icons.qml` — aliases for 8 icon names the agent UI expects but the Ambxst
  icon set does not define (patch).

## Installing

```bash
ambxst mods install /path/to/Ax-Less/packages/axless.motion
ambxst mods install /path/to/Ax-Less/packages/axless.agents
ambxst mods enable axless.motion
ambxst mods enable axless.agents
```

`axless.agents` declares `axless.motion` as a dependency, so Settings → Mods
will offer to install it for you if it is missing. Enable **motion first**:
`AssistantSidebar`, `CodeBlock` and `AiPanel` all use `AnimatedBehavior`.

## Resetting the system prompt

`ConfigValidator` keeps an existing valid value, so if you already had
`~/.config/ambxst/config/ai.json`, the old non-agent system prompt survives
the upgrade and tool chaining will behave poorly. Reset the AI section in
Settings (or delete the `systemPrompt` key from that file) to pick up the
agent-oriented default.

## Regressions you are accepting

These were Ambxst 1.2/1.3 improvements that the NothingLess AI code predates.
They were **not** re-ported, because doing so would mean diverging further
from a subsystem that is being replaced wholesale:

- **Translations.** The base `Ai.qml`, `AiPanel.qml` and `AssistantSidebar.qml`
  route user-facing strings through `I18n.t()`. The ported versions hardcode
  English. The `ai.*` keys in `translations/*.json` are now unused for the
  assistant.
- **Settings search indexing.** `SettingsCrawler.js` scrapes `label` /
  `settingsSection` properties from panel items. The ported `AiPanel.qml`
  does not set them, so AI entries no longer appear in settings search.

Two fixes were re-applied rather than lost, because they are correctness
issues independent of the agent work:

- **State restore.** `StateService.initialized` flips asynchronously once the
  daemon owns `states.json`, so waiting for `initializedChanged` (with a
  `_restored` guard) instead of the legacy one-shot `stateLoaded` is what
  makes the saved model survive a cold start.
- **Lazy init.** Model fetching, chat-directory listing and new-chat creation
  are deferred to the first sidebar open instead of running on every start.

## Not ported

`SidebarHeader.qml`, `SidebarInputBar.qml`, `SidebarMessageBubble.qml`,
`SidebarChatHistory.qml`, `SidebarModeBar.qml`, `QuickAddAgentPopup.qml` and
`AgentProfilesTab.qml` (2770 + 571 lines) are **dead code in NothingLess** —
nothing instantiates them. They are leftovers from an abandoned sidebar
refactor and were left behind.

`AssistantSidebarWindow.qml` is also skipped: NothingLess moved the sidebar
into its own `PanelWindow`, but Ambxst 1.3.x embeds it in
`UnifiedShellPanel.qml` behind a newer focus-grab architecture. The ported
`AssistantSidebar.qml` keeps Ambxst's `active` / `wantsFocus` / `hitbox`
contract, so it plugs into the existing embedding with no patch to
`UnifiedShellPanel.qml`.
