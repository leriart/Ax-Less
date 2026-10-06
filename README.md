# Ax-Less

Ambxst mods that bring the NothingLess feature set to
[Ambxst](https://github.com/Axenide/Ambxst) 1.3.10.

NothingLess is a full shell fork that diverged from Ambxst around v1.1.0. Most
of what it added is **already in Ambxst 1.3.10 natively**, in the Go backend
(`backend/pkg/svc/*`) rather than in QML and shell scripts. Those parts are not
ported — copying them backwards would undo work Ambxst has since done, including
multi-compositor parity (`hyprland | niri | mango`).

## Packages

| Package | Status | Summary |
|---|---|---|
| [`axless.core`](packages/axless.core) | working | Everything in one mod: an AI agent platform, a compositor panel filtered to what the running compositor supports, a monitor manager with a drag canvas, a video wallpaper engine with GPU frame interpolation and crossfade transitions, a dashboard task board, and per-monitor shell positions. |

## What `axless.core` includes

### AI agent platform

The assistant stops being "a chat box with one hardcoded tool" and becomes an
agent host. You register agents; each agent advertises its own tools; the tools
discovered from every connected agent are merged into the request the model
sees.

- Three transports: **MCP over stdio**, **HTTP bridge**, and **command agents**.
- Two reference servers ship in the mod: **NothingClaw** (a self-driving agent
  loop over Ollama with sandboxed filesystem and shell tools) and an **OpenCode
  adapter** exposing the `opencode serve` API.
- The AI engine is reworked: correct OpenAI `tool_calls` / `role: "tool"`
  shaping, a model-capability probe that asks the model what it can do instead
  of guessing, multi-step chain enforcement, a text-based tool-call fallback
  for small local models, and per-tier timeouts.

### Compositor panel and monitors

- The compositor settings menu shows **only what the running compositor
  supports**. On niri that is the Ambxst TOML sections plus monitors; on
  Hyprland the 73 extra NothingLess settings appear and write through
  `hyprctl keyword`.
- A monitor manager with a logical-pixel drag canvas, edge snapping, overlap
  resolution, per-output error reporting, and writes that go straight to the
  compositor's own IPC (`niri msg output`, `hyprctl keyword monitor`). Runtime
  only: nothing writes a compositor config file.

### Video wallpaper engine

- **GPU frame interpolation.** A `Video` element is decoded through a
  shader-based interpolator (`interpol.frag`) that synthesizes the frames the
  source never had, using motion vectors. An optional Go helper (`axvideo`)
  pre-renders an interpolated clip for heavy sources, and `axprobe` reads the
  real frame rate so the blend interval matches the source.
- **Crossfade transitions.** Changing the wallpaper crossfades between the old
  and the new with a gentle zoom, ported from NothingLess's two-layer design:
  each layer holds its own source and the fade only starts once the incoming
  layer reports its content is ready, so it works for images, GIFs and video
  alike, with a safety timeout for formats that never signal readiness.
- A wallpapers-tab toggle and an x2 to x5 multiplier selector drive the
  interpolator.

### Dashboard task board

A fourth dashboard tab (toggled with F5) with a kanban-style board and a
calendar view, backed by `TodoBoard.qml`.

### Per-monitor shell positions

Shell elements remember their position per monitor (`PerMonitorConfig.qml`).

### Translations

Every key the mod uses resolves in English, Spanish and Russian.

## Install

```bash
for p in packages/*/; do ambxst mods install "$(realpath "$p")"; done
for id in $(ls packages); do ambxst mods enable "$id"; done
ambxst reload
```

There is exactly one package. It declares no dependencies and nothing outside
the Ambxst tree is required. For the optional pre-rendered interpolation path,
`ffmpeg` and a Go toolchain (to rebuild `axvideo`) are used; prebuilt binaries
ship in the mod.

## Conventions

- One package. Everything ships together, so a given feature cannot be enabled
  on its own; prefer gating a feature on its own config key instead.
- Prefer **patches** that only insert lines over `replace` overlays. Two mods
  inserting at the same anchor both survive; two mods rewriting the same base
  lines stop the build. `SettingsTab.qml` indexes `panelComponents` by section
  id, so a new Settings section must claim the next free id and be appended —
  never renumber.
- Declare `author`, `authorUrl`, `homepage` and `license`. The install prompt is
  where a user decides whether to trust the code.
- Pin `compatibility.ambxst` to the range you tested and list
  `testedBaseCommits`.
- Do not ship `expectedSha256` for a payload file identical to the base; it is a
  no-op overlay that will fail the first time upstream touches it.

## License

AGPL-3.0, matching both upstreams ([Ambxst](https://github.com/Axenide/Ambxst)
and NothingLess). See [LICENSE](LICENSE).
