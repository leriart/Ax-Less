<div align="center">

# Ax-Less

**The NothingLess feature set, ported into [Ambxst](https://github.com/Axenide/Ambxst) as a single mod.**

Ambxst is *axtremely* customisable. NothingLess diverged from it and grew a
launcher, an agent platform, a wallpaper engine and more. Ax-Less brings that
work back, as a mod, without forking the shell.

<br>

<a href="https://github.com/leriart/Ax-Less">
  <img src="https://img.shields.io/badge/Ax--Less-0A0A0A?style=for-the-badge&logo=github&logoColor=FFFFFF&labelColor=0A0A0A" alt="repository">
</a>
<a href="https://github.com/Axenide/Ambxst">
  <img src="https://img.shields.io/badge/Mod%20for-Ambxst-E80012?style=for-the-badge&logo=github&logoColor=FFFFFF&labelColor=0A0A0A" alt="mod for Ambxst">
</a>
<a href="https://github.com/leriart/NothingLess">
  <img src="https://img.shields.io/badge/Feature%20set-NothingLess-5865F2?style=for-the-badge&logo=github&logoColor=FFFFFF&labelColor=0A0A0A" alt="NothingLess feature set">
</a>
<a href="https://git.outfoxxed.me/outfoxxed/quickshell">
  <img src="https://img.shields.io/badge/Built%20with-Quickshell-2EA44F?style=for-the-badge&logo=qt&logoColor=FFFFFF&labelColor=0A0A0A" alt="Quickshell">
</a>
<br>
<a href="https://github.com/leriart/Ax-Less/blob/main/LICENSE">
  <img src="https://img.shields.io/badge/License-AGPL--3.0-3DA639?style=for-the-badge&labelColor=0A0A0A" alt="license">
</a>
<img src="https://img.shields.io/badge/Ambxst-1.3.10%20%E2%80%93%201.3.11-E3B341?style=for-the-badge&labelColor=0A0A0A" alt="tested Ambxst">

</div>

---

<h2><sub><img src="https://raw.githubusercontent.com/Tarikul-Islam-Anik/Animated-Fluent-Emojis/master/Emojis/Travel%20and%20places/Rocket.png" alt="Rocket" width="28" height="28" /></sub> One package, everything in it</h2>

There is exactly one package: [`axless.core`](packages/axless.core). It declares
no dependencies and needs nothing outside the Ambxst tree. Four features came
out of this port; the rest were fixes to things NothingLess assumed that Ambxst
does differently, documented so the reasoning survives.

| | Feature | What it does |
|---|---|---|
| <img src="https://raw.githubusercontent.com/Tarikul-Islam-Anik/Animated-Fluent-Emojis/master/Emojis/Smilies/Robot.png" width="20"/> | **AI agent platform** | Register agents over MCP, HTTP or shell commands; their tools are merged into what the model sees. |
| <img src="https://raw.githubusercontent.com/Tarikul-Islam-Anik/Animated-Fluent-Emojis/master/Emojis/Travel%20and%20places/Globe%20Showing%20Americas.png" width="20"/> | **Compositor & monitors** | A compositor menu that shows only what the running compositor supports, plus a drag-canvas monitor manager. |
| <img src="https://raw.githubusercontent.com/Tarikul-Islam-Anik/Animated-Fluent-Emojis/master/Emojis/Activities/Sparkles.png" width="20"/> | **Wallpaper engine** | GPU frame interpolation and crossfade transitions between wallpapers. |
| <img src="https://raw.githubusercontent.com/Tarikul-Islam-Anik/Animated-Fluent-Emojis/master/Emojis/Objects/Magnifying%20Glass%20Tilted%20Left.png" width="20"/> | **Hax launcher** | NothingLess's spotlight, as an alternative to the stock notch launcher. |

---

<h2><sub><img src="https://raw.githubusercontent.com/Tarikul-Islam-Anik/Animated-Fluent-Emojis/master/Emojis/Smilies/Robot.png" alt="Robot" width="28" height="28" /></sub> AI agent platform</h2>

The assistant stops being *a chat box with one hardcoded tool* and becomes an
agent host. You register agents; each advertises its own tools; the tools
discovered from every connected agent are merged into the request the model
sees.

- **Three transports** — MCP over stdio, an HTTP bridge, and command agents.
- **Three adapters ship in the mod** — **NothingClaw**, a self-driving
  agent loop that drives any OpenAI-compatible model; an **OpenCode** adapter
  for the `opencode serve` API; and an **OpenClaw** adapter that calls the
  official `openclaw agent` CLI.
- **A reworked engine** — correct OpenAI `tool_calls` / `role: "tool"` shaping,
  a capability probe that asks the model what it can do instead of guessing
  from its name, chain nudge and step budgets, a text tool-call fallback for
  small models, and runaway-stream guards so a stuck model cannot hang the
  chat for twenty minutes.

---

<h2><sub><img src="https://raw.githubusercontent.com/Tarikul-Islam-Anik/Animated-Fluent-Emojis/master/Emojis/Objects/Desktop%20Computer.png" alt="Desktop Computer" width="28" height="28" /></sub> Compositor panel & monitors</h2>

- The compositor settings menu shows **only what the running compositor
  supports**. On niri that is the Ambxst TOML sections plus monitors; on
  Hyprland the 73 extra NothingLess settings appear and write through
  `hyprctl keyword`. On niri there is no keyword interface, so those are hidden
  rather than shown dead.
- A monitor manager with a logical-pixel drag canvas, edge snapping, overlap
  resolution and per-output error reporting. Writes go straight to the
  compositor's own IPC (`niri msg output`, `hyprctl keyword monitor`), runtime
  only — nothing writes a compositor config file.
- Positions are **remembered across compositor restarts** and re-applied at
  startup, per output, for whatever compositor is running.

---

<h2><sub><img src="https://raw.githubusercontent.com/Tarikul-Islam-Anik/Animated-Fluent-Emojis/master/Emojis/Activities/Sparkles.png" alt="Sparkles" width="28" height="28" /></sub> Video wallpaper engine</h2>

- **GPU frame interpolation.** A `Video` element is decoded through a
  shader-based interpolator that synthesises the frames the source never had,
  using the motion vectors the decoder already produces. A Go helper
  (`axvideo`) can pre-render an interpolated clip for heavy sources, and
  `axprobe` reads the real frame rate so the blend interval matches the source.
- **Crossfade transitions.** Changing the wallpaper crossfades between old and
  new with a gentle zoom, ported from NothingLess's two-layer design: each layer
  holds its own source and the fade only starts once the incoming layer reports
  its content is ready — so it works for images, GIFs and video alike, with a
  safety timeout for formats that never signal readiness.
- A toggle and an **x2 – x5 multiplier** in the wallpapers tab drive the
  interpolator.

---

<h2><sub><img src="https://raw.githubusercontent.com/Tarikul-Islam-Anik/Animated-Fluent-Emojis/master/Emojis/Objects/Magnifying%20Glass%20Tilted%20Left.png" alt="Launcher" width="28" height="28" /></sub> Hax launcher</h2>

The launcher can be the stock notch launcher or **Hax**, chosen from
**Settings → Shell → Notch**. Hax is NothingLess's own `SpotlightView.qml`,
ported essentially unchanged: a spotlight pill that grows from the top of the
screen, opened by the same keybind.

It brings application search, an inline calculator, `>` command mode, custom
shortcuts, system actions, the plugin system, file search, quick look,
clipboard / OCR / dictionary modes, timers and alarms, and a weather lookup.
Its animations follow Ambxst's own `Config.animDuration` and easing, so it moves
like the rest of the shell.

<details>
<summary>What changed in the port</summary>

Only the differences Ambxst forces: the per-screen `Visibilities.spotlight`
module does not exist, so visibility rides on `GlobalStates.haxVisible`; the
standalone self-quit was removed; a `Config.hax` section was added; `CloseButton`
was ported with its animation references translated; the plugin directory moved
under `~/.config/ambxst`. The package manager was **not** ported — the original
ships a hardcoded sudo password.

</details>

---

<h2><sub><img src="https://raw.githubusercontent.com/Tarikul-Islam-Anik/Animated-Fluent-Emojis/master/Emojis/Objects/Gear.png" alt="Gear" width="28" height="28" /></sub> Smaller pieces</h2>

- **Dashboard task board** — a fourth dashboard tab (F5) with a kanban board and
  a calendar view, backed by `TodoBoard.qml`.
- **Per-monitor shell positions** — the bar, dock and notch remember their
  position per monitor.
- **Translations** — every key the mod uses resolves in English, Spanish and
  Russian.

---

<h2><sub><img src="https://raw.githubusercontent.com/Tarikul-Islam-Anik/Animated-Fluent-Emojis/master/Emojis/Objects/Package.png" alt="Package" width="28" height="28" /></sub> Installation</h2>

```bash
for p in packages/*/; do ambxst mods install "$(realpath "$p")"; done
for id in $(ls packages); do ambxst mods enable "$id"; done
ambxst reload
```

The optional pre-rendered interpolation path uses `ffmpeg` and a Go toolchain to
rebuild `axvideo`; prebuilt binaries ship in the mod, so neither is required for
the default engine.

> **Note:** every `ambxst mods update` builds a new generation and removes the
> previous one. Nothing to do by hand — the mod resolves its own paths to the
> live generation — but it is why a reload is needed to pick up a new build.

---

<h2><sub><img src="https://raw.githubusercontent.com/Tarikul-Islam-Anik/Animated-Fluent-Emojis/master/Emojis/Objects/Scroll.png" alt="Scroll" width="28" height="28" /></sub> Conventions</h2>

The rules this repo follows, kept here so contributions land in the same shape.

<details>
<summary>Expand</summary>

- One package. Everything ships together, so a feature cannot be enabled on its
  own; gate it on its own config key instead.
- Prefer **patches** that only insert lines over `replace` overlays. Two mods
  inserting at the same anchor both survive; two mods rewriting the same base
  lines stop the build. `SettingsTab.qml` indexes `panelComponents` by section
  id, so a new section must claim the next free id and be appended — never
  renumber.
- Declare `author`, `authorUrl`, `homepage` and `license`. The install prompt is
  where a user decides whether to trust the code.
- Pin `compatibility.ambxst` to the range you tested and list
  `testedBaseCommits`.
- Do not ship `expectedSha256` for a payload file identical to the base; it is a
  no-op overlay that fails the first time upstream touches it.

</details>

---

<h2><sub><img src="https://raw.githubusercontent.com/Tarikul-Islam-Anik/Animated-Fluent-Emojis/master/Emojis/Hand%20gestures/Handshake.png" alt="Handshake" width="28" height="28" /></sub> Credits</h2>

This exists because of the people who built the pieces it ports and the shell it
runs on.

- **Axenide** — creator of [Ambxst](https://github.com/Axenide/Ambxst).
  Everything here is a mod for that shell, and most of it ports features Ambxst
  had not implemented.
- **Fabio** ([@fabiolopezperez-hue](https://github.com/fabiolopezperez-hue)) —
  author of the **Hax** spotlight launcher, ported here essentially unchanged.
  The plugin system, the calculator, the quick actions and the whole spotlight
  are his work.
- **outfoxxed** — creator of
  [Quickshell](https://git.outfoxxed.me/outfoxxed/quickshell), the toolkit both
  Ambxst and NothingLess are written against.

NothingLess reimplements a number of services Ambxst provides natively; those
are deliberately **not** ported here, and their credit belongs to whoever wrote
the Ambxst implementation.

---

<h2><sub><img src="https://raw.githubusercontent.com/Tarikul-Islam-Anik/Animated-Fluent-Emojis/master/Emojis/Objects/Bookmark%20Tabs.png" alt="License" width="28" height="28" /></sub> License</h2>

AGPL-3.0, matching both upstreams ([Ambxst](https://github.com/Axenide/Ambxst)
and NothingLess). See [LICENSE](LICENSE).

Ambxst and the Ambxst logo are trademarks of Adriano Tisera (Axenide).
