# axless.motion

Motion profiles for Ambxst, ported from the NothingLess animation system.

This is a **foundation mod**. It adds no UI of its own; it exists so that other
Ax-Less mods can animate with named profiles instead of a single
`Config.animDuration` scalar.

## What it adds

| File | Purpose |
|---|---|
| `modules/theme/Anim.qml` | `pragma Singleton`. Four motion types (`standard`, `emphasized`, `spatial`, `spring`) across twelve platform styles (`m3`, `ambxst`, `standard`, `ios`, `xp`, `aero`, `linear`, `aqua`, `natural`, `android`, `material`, `hyprland`). O(1) duration/easing lookups via a pre-flattened table. |
| `modules/components/AnimatedBehavior.qml` | A `NumberAnimation` subclass meant to sit inside a `Behavior` block. Resolves duration and easing from the active profile, and honours the global speed scale. |
| `config/defaults/theme.js` | `animStyle` (profile name) and `animScale` (multiplier). Added as a patch. |
| `config/Config.qml` | Adapter properties for the two new keys. Added as a patch. |

## Usage

```qml
import qs.modules.theme
import qs.modules.components

Behavior on opacity {
    enabled: Anim.animationsEnabled
    AnimatedBehavior { type: "standard"; size: "normal" }
}
```

Direct use:

```qml
NumberAnimation {
    target: someItem; property: "x"
    duration: Anim.duration("emphasized", "large")
    easing.type: Anim.easing("spatial", "enter").type
}
```

## Relationship to `Config.animDuration`

`Config.animDuration` has **1088 call sites** in the Ambxst tree. This mod does
not touch any of them and does not ask you to migrate. Instead:

- `Anim._baseScale` folds `Config.animDuration` into its own durations
  (`userScale * animDuration / 300`), so setting `animDuration: 0` still
  disables everything as before.
- Game mode is read from the native daemon signal `GameModeClient.toggled`
  rather than NothingLess's `GlobalStates.gameModeActive`, which Ambxst does not
  have. This keeps `AnimatedBehavior` and the legacy `Behavior` blocks on a
  single source of truth: both collapse to zero duration in game mode.

## Known inert data

`Anim.qml` still carries a `compositor: { curve, speed, name }` record per
profile, named with the `nl-` prefix. That data is only consumed by NothingLess's
`sync-hyprland.py`, which is not part of this port — Ambxst writes animation
settings through `backend/pkg/svc/compositor`. The records are harmless and were
left untouched to keep the port faithful.
