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
| [`axless.core`](packages/axless.core) | in progress | Everything in one mod: agent platform, a single compositor menu that shows only what the running compositor supports, per-compositor monitors, and the remaining NothingLess features. |

## Planned

Inside `axless.core`, not yet implemented. Ordered by value per unit of risk.

| Feature | Files | Notes |
|---|---|---|
| Miracast screen sharing | `MiraiService.qml`, `ScreenSharingPanel.qml`, `ScreenReceiver.qml` | Needs Settings `section: 11` (10 is Mods). |
| Multi-monitor editor | `MonitorsPanel.qml` + 4 sub-panels, `monitors_writer.py` | Large. Wants a Go `monitor` service wrapping `axctl` rather than the Python path. |
| Hax spotlight | `SpotlightView.qml` (5227 lines), `PluginManager.qml`, `Calculator.qml` | Runs as a standalone `qs` process, so it barely touches the base tree. Needs a new `ambxst spotlight` subcommand. |
| Bar TaskTray | `TaskTray.qml`, `BarSliderBase.qml` | The task tray on its own; the island part was cancelled, see below. |
| Cava audio visualizer | `CavaService.qml`, `CavaVisualizer.qml` | Distinct from the cancelled metrics work. |
| Focus Mode + DND | `FocusModeService.qml` | DND does not exist in Ambxst at all. |
| Battery charge limit | `ChargeLimitService.qml`, `set-charge-limit.sh` | The one battery feature Ambxst genuinely lacks. |
| `CompositorColors.js` + `free.snap-*` keybinds | | Small dedup plus pure catalog data. |

### Plan a futuro

Features that were investigated and then deliberately dropped, recorded here so
the reasoning survives and nobody re-opens them by accident. Recoverable from
git if they are ever wanted.

#### Isla dinámica en la barra — cancelada (2026-10-10)

`barMode` (`extended` / `dynamic`) plus `IslandContent.qml` rendering the
notch's `DefaultView` as a pill inside the bar. Cancelled by the user.

Why it was not trivial: `barMode` is not a switch. `BarContent.qml` branches on
it for width, height, x, y, reveal and auto-hide (7 sites in 856 lines), so it
is a refactor of the bar's geometry rather than a component drop-in.

#### Métricas en el notch / isla — descartadas (2026-10-10)

`MetricsGroup.qml`, `MetricsGroupWrapper.qml` and a `NotchMetrics.qml` row in
`DefaultView`, fed from Ambxst's `SystemResources`. It worked — live CPU, GPU,
RAM and disk in the notch on both monitors — and was then removed on request.

Two things worth keeping from the attempt:

- **Ambxst has no power or FPS source.** The Go backend at
  `backend/pkg/svc/systemmonitor` only emits `cpu{usage,temp}`, `ram`,
  `disk{usage}` and `gpu{usages,temps}`. NothingLess also showed watts and
  frame rate; there is no field to read them from, so they would have to be
  invented. That was a permanent limitation, not a porting gap.
- **`ConfigValidator.validate()` rebuilds the config by iterating the defaults
  and copies only the keys it finds there.** Adding a property to `Config.qml`
  alone is inert — the shell strips it back out of the JSON on the next save.
  Any new setting needs its entry in `config/defaults/<section>.js` as well.

#### Launching Ambxst

Not a feature, but the thing most likely to waste an afternoon: the shell must be
started with **`ambxst`**, not `qs -p .../shell.qml`. `BackendService` talks to
the Go daemon over `$XDG_RUNTIME_DIR/ambxst.sock`; launching the shell directly
leaves that socket absent, subscriptions fail with
`BackendService: subscription socket error 2`, and every metric reads as a dash
while `monitoringActive` is still `true`.

### Deliberately excluded

- NothingLess's animation system (`Anim.qml`, `AnimatedBehavior.qml`). Ported
  code is translated to Ambxst's native `Config.animDuration` + `Easing.*`
  instead, so the assistant matches the rest of the shell and there is no second
  source of truth for durations.
- `Surface`, `Speedometer`, `DiskBar`, `StatCard`, `CloseButton` — Ambxst's
  `StyledRect` and `Circular*` already cover them under other names.
- Per-directory `qmldir` files. Ambxst resolves bar siblings with
  `import "." as Bar`; adding a second resolution path risks the five existing
  `Bar.*` references.
- The Hyprland-only `sync-hyprland.py` (1533 lines) and the ~150 extra
  compositor keys it feeds. Ambxst generalises this in
  `backend/pkg/svc/compositor`; porting the translator would regress niri and
  mango.
- NothingLess reimplements of clipboard, OCR/QR, screenshots, system monitor,
  keystore, link preview, weather, night light, game mode, caffeine, power
  profile and recorder. All native in `backend/pkg/svc/*`.
- `ScreenTranslation.qml` and `MusicRecognizer.qml` — orphaned even in
  NothingLess.

## Install

```bash
for p in packages/*/; do ambxst mods install "$(realpath "$p")"; done
for id in $(ls packages); do ambxst mods enable "$id"; done
ambxst reload
```

There is exactly one package. It declares no dependencies and nothing outside
the Ambxst tree is required.

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
