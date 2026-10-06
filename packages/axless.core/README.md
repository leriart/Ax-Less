# axless.core

The NothingLess feature set as a single Ambxst mod. No companion packages, no
dependencies: one install gets everything.

| Feature | Status |
|---|---|
| Agent platform (MCP / HTTP bridge / command agents) | done |
| Single compositor menu, per-compositor options | done |
| Monitors, per compositor, runtime only | done |
| Per-monitor shell positions | planned |
| Notch metrics | planned |
| Bar island mode | planned |
| Video wallpaper engine | planned |
| Task board | planned |
| Boot splash | planned |
| Hax spotlight | planned |

Everything is adapted to Ambxst's own services, colours and animation model.
Nothing here reimplements what Ambxst 1.3.10 already does natively in its Go
backend; see the repository README for the exclusion list.

## Agent platform

Turns the assistant from "a chat box with one hardcoded `run_shell_command`
tool" into an agent host: you register agents, each agent advertises its own
tools, and the tools discovered from every connected agent are merged into the
request the model sees.

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
- `Icons.qml` — aliases for 8 icon names the agent UI expects but the Ambxst
  icon set does not define (patch).

## Installing

```bash
ambxst mods install /path/to/Ax-Less/packages/axless.core
ambxst mods enable axless.core
ambxst reload
```

One package, no dependencies.

## Advanced compositor panel

`CompositorAdvancedPanel.qml`, registered as Settings **section 11** (10 is
Mods).

It offers only what genuinely reaches the compositor:

- **A capability report** from `axctl system get-capabilities`.
- **Layout selection** via `axctl layout set/next/prev`, flagging entries that
  come from axctl's static fallback list rather than the running compositor.

### Why there are no appearance controls here

Compositor settings travel `Panel QML -> Config.qml -> IPC compositor.write ->
Go backend -> axctl.toml -> the axctl binary -> hyprland.lua / niri.kdl /
mango.conf`. A mod can add QML but cannot recompile the Go backend or extend
the `axctl` binary, and **axctl has a fixed vocabulary**: an unknown key is
silently dropped from the generated config, and `axctl config set` rejects it.

Verified live against niri on Ambxst 1.3.10:

```
axctl config set cursor.size 1              -> Error: unsupported config key
axctl config set touchpad.natural_scroll 1  -> Error: unsupported config key
an invented [zztest.foo] in axctl.toml      -> absent from the generated niri.kdl
```

Even the nine accepted keys do not all apply. `axctl config set
opacity.active 0.92` reports success and `axctl config get` returns `0.92`,
yet the generated `axctl.toml` still carries `active = 1.0`, and the
`niri.kdl` axctl writes says:

```
// Not supported in niri static config: outer gaps (use inner gaps in niri);
// opacity (niri uses per-app window-rule opacity); blur (configure via
// blur {} block at top level in niri); shadow (configure per-app ...)
```

An earlier revision of this panel did offer window opacity, written live
through `axctl config set`. It was removed: on niri it is a control that
reports success and changes nothing. Appearance settings stay in the stock
Compositor panel, which drives the TOML path where the values do apply.

NothingLess's panel was not restricted this way because it wrote
`hyprland.conf` directly through `scripts/sync-hyprland.py` (1533 lines),
bypassing axctl entirely — which is also why it was Hyprland-only.

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

## Animations

NothingLess drives every animation through its own `Anim` singleton and an
`AnimatedBehavior` wrapper. That system is **not** ported. All 41
`AnimatedBehavior` blocks and every `Anim.*` reference in the ported files were
translated to Ambxst's native idiom:

| NothingLess | Here |
|---|---|
| `AnimatedBehavior { type: "standard"; size: "fast" }` | `NumberAnimation { duration: Config.animDuration; easing.type: Easing.OutQuart }` |
| `AnimatedBehavior { ...; variant: "exit" }` | same, with `Easing.InQuad` |
| `Anim.animationsEnabled` | `Config.animDuration > 0` |
| `Anim.easing("standard"/"emphasized").type` | `Easing.OutQuart` |
| `Anim.standardSmall/Normal/Large`, `Anim.emphasizedNormal` | `Config.animDuration` |

`Easing.OutQuart` is the dominant easing in the Ambxst tree (252 uses, against
145 for `OutCubic`), so the assistant now animates like everything around it.
Setting `Config.animDuration` to 0, or entering game mode, disables it exactly
as it does for the rest of the shell — one source of truth, no second motion
system to keep in sync.

## Not ported

`SidebarHeader.qml`, `SidebarInputBar.qml`, `SidebarMessageBubble.qml`,
`SidebarChatHistory.qml`, `SidebarModeBar.qml`, `QuickAddAgentPopup.qml` and
`AgentProfilesTab.qml` (2770 + 571 lines) are **dead code in NothingLess** —
nothing instantiates them. They are leftovers from an abandoned sidebar
refactor and were left behind.

`AiModeButton.qml` (the bar's chat/agent mode switch) is also skipped, so
`BarContent.qml` is not patched at all. Mode and agent selection live in the
assistant sidebar and in `AiPanel`.

`AssistantSidebarWindow.qml` is skipped too: NothingLess moved the sidebar
into its own `PanelWindow`, but Ambxst 1.3.x embeds it in
`UnifiedShellPanel.qml` behind a newer focus-grab architecture. The ported
`AssistantSidebar.qml` keeps Ambxst's `active` / `wantsFocus` / `hitbox`
contract, so it plugs into the existing embedding with no patch to
`UnifiedShellPanel.qml`.

## Single compositor menu

NothingLess ships a 12-subsection compositor panel: general, colors, shadows,
blur, opacity, snap, input, cursor, monitors, gestures, layouts, advanced. This
package replaces Ambxst's `CompositorPanel.qml` so that menu is section 8 — the
original one, integrated — instead of adding parallel sections.

Options are filtered by the running compositor, per subsection:

| Backend | Compositors | Sections |
|---|---|---|
| Ambxst TOML (`axctl.toml` → axctl) | all | general, colors, shadows, blur |
| `hyprctl keyword` | Hyprland | opacity, snap, input, cursor, gestures, layouts, advanced (73 settings) |
| compositor output IPC | all | monitors |
| Hyprland only | Hyprland | the 73 NothingLess settings |

On this machine (niri) that means five of the twelve subsections are offered:
the four Ambxst already wrote for every compositor, plus monitors. Verified:

```
PROBE compositor = "niri"
PROBE   general    via-keyword=false via-toml=true  => VISIBLE
PROBE   colors     via-keyword=false via-toml=true  => VISIBLE
PROBE   shadows    via-keyword=false via-toml=true  => VISIBLE
PROBE   blur       via-keyword=false via-toml=true  => VISIBLE
PROBE   opacity    via-keyword=false via-toml=false => oculta
...
PROBE   monitors   => VISIBLE
```

The seven NothingLess subsections are hidden rather than shown dead. On Hyprland
they appear and write through `hyprctl keyword`, which accepts essentially every
Hyprland keyword — that path is written from the documented CLI but could not be
exercised here, since Hyprland is not installed on this machine.

The 73 new keys are declared in both `config/defaults/compositor.js` and the
`compositorLoader` JsonAdapter, and registered in
`GlobalStates._compositorProps` so Apply and Discard cover them.

### Why niri has no compositor keywords

`niri msg` exposes no config or reload verb; its configuration is static KDL.
The only runtime-configurable thing is output configuration, via
`niri msg output <name> <action>`. Hyprland, by contrast, has
`hyprctl keyword <section>:<key> <value>` and `hyprctl reload config-only`.

## Monitors

`MonitorsPanel.qml`, hosted as the compositor panel's `monitors` subsection.

Per compositor:

- **niri** — `niri msg --json outputs` to read, `niri msg output <name> ...` to
  write: `off`, `on`, `mode`, `custom-mode`, `modeline`, `scale`, `transform`,
  `position`, `vrr`.
- **Hyprland** — `hyprctl monitors -j` to read, `hyprctl keyword monitor
  <name>,<key>,<value>` to write.
- **Mango** — sway-style IPC via `MANGO_INSTANCE_SIGNATURE`. Not verifiable
  here; Mango is not installed, and the panel reports that rather than
  guessing.

Layout and appearance follow NothingLess's `MonitorArrangementView`: a
logical-pixel canvas with a 500 px grid, an origin marker, per-output boxes
scaled to their real logical size, a numbered badge, three readout lines, and
drag-to-move with edge snapping (15 px while dragging, 25 px on release) plus
overlap resolution. What differs is the write: a drop goes straight to the
compositor's output API instead of being staged for a config-file writer.

Runtime only. Nothing here writes a compositor config file, so values reset
when the compositor restarts.

Verified against the live niri daemon with two real outputs:

```
PROBE compositor = "niri" outputs = 2
PROBE viewBounds = {"minX":-100,"minY":-100,"maxX":3556,"maxY":1180,"spanW":3656,"spanH":1280}
PROBE   HDMI-A-1   logico=1920x1080 canvas=174,20 rotated=false
PROBE   eDP-1      logico=1229x768  canvas=20,20  rotated=false
```

`eDP-1` at 1229×768 is 1536×960 divided by its 1.25 scale, and its canvas
position 20,20 is the logical origin. Scale and transform writes were exercised
against the live compositor and restored.

### An Ambxst bug this panel routes around

`AxctlService.qml:143` does `id: parseInt(mon.id) || 0`. niri's monitor id is a
string name (`"eDP-1"`), so `parseInt` is `NaN` and **every monitor comes back
with id 0**. Anything comparing monitor ids by equality is unreliable on niri.
This panel does not read `AxctlService.monitors`; it queries the compositor's
own IPC.

`AxctlService.compositorName` is also not trusted verbatim: Ambxst's probe
assigns `stdout.trim()` without checking whether the call failed, so with axctl
down it captures the client's error text as the compositor name. Both this panel
and `CompositorKeywords` whitelist the three real names and fall back to probing
the clients directly.
