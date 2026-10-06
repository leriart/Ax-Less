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
| [`axless.core`](packages/axless.core) | in progress | Everything in one mod: agent platform, advanced compositor panel, and the remaining NothingLess features. |

## Planned

Inside `axless.core`, not yet implemented. Ordered by value per unit of risk.

| Feature | Files | Notes |
|---|---|---|
| Todo board | `TodoTab.qml`, `TodoBoard.qml` | Cleanest port in the set: three append-only insertions in `Dashboard.qml`. |
| Miracast screen sharing | `MiraiService.qml`, `ScreenSharingPanel.qml`, `ScreenReceiver.qml` | Needs Settings `section: 11` (10 is Mods). |
| Multi-monitor editor | `MonitorsPanel.qml` + 4 sub-panels, `monitors_writer.py` | Large. Wants a Go `monitor` service wrapping `axctl` rather than the Python path. |
| Hax spotlight | `SpotlightView.qml` (5227 lines), `PluginManager.qml`, `Calculator.qml` | Runs as a standalone `qs` process, so it barely touches the base tree. Needs a new `ambxst spotlight` subcommand. |
| Bar TaskTray + island mode | `TaskTray.qml`, `IslandContent.qml`, `BarSliderBase.qml` | |
| Notch/desktop metrics + Cava | `MetricsGroup.qml`, `CavaService.qml`, `CavaVisualizer.qml` | Use Ambxst's `SystemResources` for the data, not NothingLess's Python monitors. |
| Focus Mode + DND | `FocusModeService.qml` | DND does not exist in Ambxst at all. |
| Battery charge limit | `ChargeLimitService.qml`, `set-charge-limit.sh` | The one battery feature Ambxst genuinely lacks. |
| Per-monitor shell positions | `PerMonitorConfig.qml` | Touches exclusive-zone maths; moderate risk. |
| `CompositorColors.js` + `free.snap-*` keybinds | | Small dedup plus pure catalog data. |

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
