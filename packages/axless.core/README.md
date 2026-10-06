# axless.core

The NothingLess feature set as a single Ambxst mod. No companion packages, no
dependencies: one install gets everything.

| Feature | Status |
|---|---|
| Agent platform (MCP / HTTP bridge / command agents) | done |
| Single compositor menu, per-compositor options | done |
| Monitors, per compositor, runtime only | done |
| Video wallpaper engine (interpolation + crossfade) | done |
| Task board (dashboard tab + calendar) | done |
| Per-monitor shell positions | done |
| Translations (en / es / ru) | done |

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

### Snapping and placement

Two things were wrong about dragging a monitor, both from the same root
cause: thresholds expressed in canvas pixels and divided by `viewScale`.

On a 3656 px wide desktop the canvas lands near `viewScale` 0.11, so
NothingLess's `15 / viewScale` was **132 logical px while dragging and 220 on
release**. Any monitor dropped within 220 px of a neighbour got yanked flush
against it, so two screens could not be left a few pixels apart, and the yank
got worse the larger the desktop. The threshold is now converted to logical
units and capped at 24 px while dragging and 40 px on release - a little under
two steps of the 10 px grid, enough to feel magnetic without taking over the
placement.

Horizontal placement is bounded: a monitor may sit entirely left of everything
or entirely right of everything, but cannot be flung into empty space beyond
the arrangement. Vertical placement is deliberately unbounded, because
lining one monitor up under another is a normal thing to want.

### Scaled monitors snapping to the wrong edge

`ArrangementView.logicalWidth` divided by the scale unconditionally, which is
Hyprland's convention: `hyprctl` reports pixel dimensions plus a separate scale
and positions outputs in already-divided logical units. niri does not - it
reports `logical.width` in pixels and positions in that same space.

At 1.25 scale this made every measurement wrong in a way that only appears once
the scale is not 1.0:

```
eDP-1              real 1536x960    drawn as 1536/1.25 = 1229 px wide
snap target        0 + 1229 = 1229
eDP-1 really spans  0..1536          -> 307 px of overlap
```

So dropping a monitor "next to" its neighbour landed it inside that neighbour,
and the overlap resolution then shoved it somewhere else entirely, which reads
as *the monitors spring apart and refuse to be placed*. The canvas size and the
snap targets now both come from `pixelsAreLogical`, true for niri and false for
the sway-style clients, so the drawn box and the snap edges match what the
compositor actually reports.

Verified against the live daemon, both outputs at 1.25:

```
PROBE compositor=niri pixelsAreLogical=true av.pixelsAreLogical=true
PROBE   HDMI-A-1  scale=1.25 logged=1536x864  (niri real: 1536x864)  x=1536
PROBE   eDP-1     scale=1.25 logged=1536x960  (niri real: 1536x960)  x=0
PROBE ancho logico usado para imantar contra eDP-1 = 1536
     -> coincide con su borde real (0+1536=1536)
```

### Negative positions rejected outright

Moving a monitor left of, or above, the desktop origin failed with:

```
error: unexpected argument '-1' found
  tip: to pass '-1' as a value, use '-- -1'
Usage: niri msg output position set <X> <Y>
```

niri's argument parser reads a leading `-` as an option name, so any negative
coordinate was rejected and the monitor never moved. That is what made dragging
between monitors impossible: as soon as the dragged box went left of the origin
the write failed and the box snapped back. niri documents the fix in its own
error message, and it is harmless for positive coordinates:

```
argv = ["niri", "msg", "output", id, "position", "set", "--", x, y]
```

Verified against the live daemon, restoring afterwards:

```
PROBE moviendo a la IZQUIERDA del origen: x=-1600 y=0   -> -1600,0   err=""
PROBE moviendo ARRIBA (y negativo):    x=-1600 y=-700  -> -1600,-700 err=""
PROBE restaurando a 1540,0                              -> 1540,0    err=""
```

The Hyprland path needs no equivalent: `hyprctl keyword monitor
<name>,position,<x>,<y>` passes the coordinates inside a single comma-separated
token, so a leading `-` is never parsed as an option.

Snap thresholds were also tightened to 16 px while dragging and 24 px on
release. A wider release threshold swallowed small deliberate gaps - drop a
monitor 30 px from its neighbour with a 40 px threshold and it snapped flush,
which is the same "it won't let me place them" complaint wearing a different
hat. Gaps of 30 px and 50 px are now preserved; only sub-24 px closes.

### Horizontal limit that blocked every placement with breathing room

`xBounds` returned `min = leftmost neighbour's x - ownW` and
`max = rightmost neighbour's right edge`. That is exactly the zero-gap
arrangement, so *any* placement with room to breathe was rejected:

```
neighbour unscaled box ends at 1536 (eDP-1, 1.25 scale)
max allowed = 1536
x = 1700  (a 164 px gap)  -> BLOQUEADO  ← should be fine
x = -1700 (left of it)    -> BLOQUEADO
```

With HDMI-A-1 and eDP-1 both at 1.25 and sharing x=0, every interesting target
fell inside the forbidden band, which made the monitors feel welded. The bound
now allows **a full monitor width of margin on each side**, so a screen can
sit a whole screen's gap to the left or right of everything else, and only a
genuinely absurd fling (more than a screen beyond the edge) is clamped.
Verified: `[-3072, 3072]` for a 1536-wide neighbour, accepting both 1700 and
-1700 while still rejecting -4000 and 9000.

### Bugs found and fixed while making it functional

**Reading an output's on/off state.** niri still lists an output that is off,
and gives no `disabled` flag. The signal is that it reports `current_mode: null`
and `logical: null`. The panel had `enabled: true` hardcoded, so an output the
user had switched off still claimed to be on. Confirmed against the live
compositor by toggling HDMI-A-1 off and diffing the payload.

**Canvas geometry was wrong for niri.** `logicalWidth`/`logicalHeight` divided
by scale, which is Hyprland's convention: `hyprctl` reports pixel dimensions
plus a separate scale and positions in already-divided logical units. niri
reports `logical.width` in pixels and positions in that same space - a 1536-wide
panel at scale 1.25 puts the next output at x=1536, not 1229. The same rule for
both compositors misplaced every box. It is now `pixelsAreLogical`, true for
niri and false for the sway-style clients.

**Hyprland had no `positionAuto`.** The write map had no case for it, so the
Auto button reported "Unknown action". Mapped to `monitor <name>,position,auto`.

**Hyprland VRR state could not be read back.** `hyprctl` reports whether VRR
is supported but not whether it is on, so the toggle would always show off.
Whatever was last requested is now remembered per output.

**One shared error string for every output.** A rejected change on one monitor
showed on the panel title with no indication of which output it belonged to.
Errors are now per output, shown on the card, and cleared on success.

**The poll could fight the writes.** The 4 s refresh could land between the
compositor applying a change and the panel's own bookkeeping, flicking a
control back to its old value. The poll now stands down while any write is in
flight, and a second write for the same output supersedes the first instead of
racing it.

### Improvements over the first version

- Collapsible cards. A 27" panel here exposes 39 modes; rendering every one as
  a chip made the list unusable.
- Preferred modes are marked with a star, and there is an Auto chip for both
  mode and scale, which niri supports.
- Identify. Neither niri nor hyprctl exposes a flash-this-output verb, so it
  highlights the output on the canvas for ~2 s and dims the others.
- Per-output busy and error state, and stale state is dropped when an output
  disappears and comes back.
- Serial number and physical size shown when the compositor reports them.

### Verified against the live compositor

Every write path exercised on HDMI-A-1 and restored afterwards:

```
scale 1.5              -> applied (niri adjusted the mode to 1280x720 logically)
transform 90           -> applied (720x1280, rotated)
position 3000,0        -> applied
mode 1920x1080@74.998  -> applied (switched to 75 Hz)
invalid action         -> clean "Unknown action"
off                    -> enabled=false width=0 refresh=0.000
on                     -> enabled=true
restore                -> scale 1, Normal, 1536,0, 1920x1080@60.000
```

### Labels showing as bare key names

`I18n.t()` falls back to `humanize(key)` when a key is absent, so a missing
`mp.title` rendered as the literal word "title" on the section button. The
translation patch had been regenerated from a tree whose `translations/` had
been reset, which silently dropped the `ca.*` and `mp.*` keys and left only the
20 added most recently.

Translations are now generated from the set of keys the payload actually
references rather than added in batches, so a key cannot be used without one
existing. All 139 keys used by the mod resolve in en, es and ru, and the patch
deletes zero lines.

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

## Video wallpaper engine

Ambxst renders video wallpapers with `MediaPlayer` + `VideoOutput`. That
`VideoOutput` is a straight path to the screen: no frame handles, no
timestamps, no motion vectors. There is nothing to interpolate *through*, so
any real interpolation needs its own decode path.

### Frame interpolation

`InterpolatedVideo.qml` replaces the renderer inside `VideoWallpaper`. It keeps
a live `Video` element and a frozen copy of the previous frame as two
`ShaderEffectSource` textures, and a `FrameAnimation` advances a blend factor
on the vsync. The `interpol.frag` shader warps both frames along the motion
vectors the decoder produced and blends them, synthesising the frames the
source never had. A 30 fps wallpaper plays at the display's refresh rate.

Two details took real debugging:

- **The shader must be compiled with `qsb --glsl 440`.** A bare `qsb` bakes no
  GLSL into the `.qsb`, and the effect renders nothing. The vertex shader uses
  `texelFetch`, which the legacy ES profile rejects, so the version flag is
  mandatory. `shaders/build.sh` records the exact invocation.
- **Sampling had to move to UV space.** Mixing `texture()` (resolution
  independent) with `texelFetch(ivec2(uv * iResolution))` reads a sub-rectangle
  stretched over the full effect — on a scaled output that is exactly the
  devicePixelRatio, so the wallpaper rendered zoomed in. All sampling is UV
  now.

An optional pre-rendered path exists for heavy sources: the Go helper
`axvideo` (in `video/`) decodes with `AV_CODEC_FLAG2_EXPORT_MVS` and writes an
interpolated clip that the shell then loops, and `axprobe` reads the real
`avg_frame_rate` through libavformat without decoding frames so the blend
interval matches the source. Prebuilt binaries ship in `video/bin/`;
`video/build.sh` rebuilds them.

### Crossfade transitions

Changing the wallpaper crossfades between the old and the new with a gentle
zoom from 0.97, ported from NothingLess's two-layer design. The part that
matters: **each layer carries its own source string**. The incoming wallpaper
loads into whichever layer is idle while the current one keeps showing the old
one at full opacity; only once the incoming layer reports its content is ready
does a short settle timer start the fade. Sharing one source between both
layers and flipping which is active makes the pending source equal the current
one immediately, the swap never fires, and the wallpaper freezes on the first
image it ever loaded — that was the bug the port was written to fix.

A 3 s safety timeout forces the fade for formats that never signal readiness,
and the layer that faded out is emptied so it stops holding the image or the
video decoder. The wallpapers tab gains an interpolation toggle and an x2 to x5
multiplier selector, inserted as siblings of the tint control in the filter
bar.

## Task board

`TodoBoard.qml` backs a fourth dashboard tab with a kanban-style board and a
calendar view (`TodoTab.qml`, `TodoCalendar.qml`). The dashboard tab row was
patched to count the extra tab instead of assuming three.

## Per-monitor shell positions

`PerMonitorConfig.qml` plus a patch make shell elements remember their position
per monitor, keyed by output name.
