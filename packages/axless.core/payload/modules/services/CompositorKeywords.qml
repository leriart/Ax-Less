pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import qs.modules.services

/*
    CompositorKeywords.qml

    Per-compositor support table and runtime write path for the settings
    NothingLess exposes but Ambxst does not.

    Why this exists
    ---------------
    Ambxst writes compositor settings through one pipeline: Panel QML ->
    Config.qml -> IPC "compositor.write" -> Go backend -> axctl.toml -> the
    external axctl binary -> hyprland.lua / niri.kdl / mango.conf. That
    pipeline has a fixed vocabulary. axctl accepts nine appearance keys,
    rejects anything else ("unsupported config key"), and silently drops keys
    it does not recognise. Output configuration is not in that vocabulary at
    all. A mod cannot widen it: the Go backend and axctl are both compiled.

    Hyprland, however, has its own runtime config interface:
    `hyprctl keyword <section>:<key> <value>`. That accepts essentially every
    Hyprland keyword, so on Hyprland the NothingLess panel can be wired for
    real without touching either binary.

    niri has no equivalent. Its config is static KDL; `niri msg` exposes no
    config or reload verb at all. The only runtime-configurable thing on niri
    is output configuration, via `niri msg output <name> <action>`, which
    MonitorsPanel handles.

    So the panel asks this singleton what the running compositor can do, and
    hides or disables the rest rather than offering controls that would
    silently do nothing.
*/
QtObject {
    id: root

    // ── Compositor identity ─────────────────────────────────────────────
    //
    // Not AxctlService.compositorName verbatim: Ambxst's probe assigns
    // stdout without checking whether the call failed, so when axctl is
    // down it captures the client's error text as the name. Whitelisted
    // here, with a direct client probe as fallback.
    readonly property var knownCompositors: ["hyprland", "niri", "mango"]

    readonly property string reported: {
        const n = (AxctlService.compositorName || "").toLowerCase();
        return knownCompositors.indexOf(n) >= 0 ? n : "";
    }

    property string _detected: ""
    readonly property string compositor: reported !== "" ? reported : _detected
    readonly property bool resolved: reported !== "" || _detected !== ""

    // ── Support table ───────────────────────────────────────────────────
    //
    // Section id -> the Hyprland keyword paths that implement it. A section
    // is offered on Hyprland only when it has at least one entry, because an
    // empty section in the sidebar is worse than no section.
    //
    // `toml` marks settings that Ambxst already writes for every compositor
    // through its own TOML path; those stay visible everywhere and are not
    // routed through hyprctl.
    // The parentheses are load-bearing. `property var x: { ... }` is a QML
    // binding to an *object declaration*, not a JS object literal, and the
    // parser rejects the array values inside it. Wrap the literal:
    // `({ ... })`. Arrays and statement bodies do not need this.
    readonly property var sections: ({
        hyprland: {
            general: ["general:gaps_in", "general:gaps_out", "general:border_size",
                "general:resize_on_border", "general:extend_border_grab_area",
                "general:layout", "general:allow_tearing", "general:no_border_force_default"],
            opacity: ["decoration:active_opacity", "decoration:inactive_opacity",
                "decoration:fullscreen_opacity"],
            dim: ["dim:enabled", "dim:strength", "dim:around", "dim:special"],
            snap: ["group:special", "group:drag_drop", "group:smart_resize"],
            input: ["input:kb_layout", "input:kb_variant", "input:kb_options",
                "input:numlock_by_default", "input:repeat_rate", "input:repeat_delay",
                "input:sensitivity", "input:accel_profile", "input:follow_mouse",
                "input:natural_scroll", "input:scroll_factor", "input:left_handed",
                "input:refocus", "input:float_switch_override_focus",
                "input:touchpad:disable_while_typing",
                "input:touchpad:natural_scroll",
                "input:touchpad:tap_to_click",
                "input:touchpad:clickfinger_behavior",
                "input:touchpad:tap_button_map",
                "input:touchpad:middle_button_emulation",
                "input:touchpad:drag_lock",
                "input:touchpad:scroll_factor"],
            cursor: ["cursor:no_hardware_cursors", "cursor:no_warps",
                "cursor:persistent_warps", "cursor:warp_on_change_workspace",
                "cursor:zoom_factor", "cursor:inactive_timeout",
                "cursor:hide_on_key_press", "cursor:hide_on_touch",
                "cursor:hide_on_tablet", "cursor:enable_hyprcursor"],
            gestures: ["gestures:workspace_swipe_create_new",
                "gestures:workspace_swipe_forever",
                "gestures:workspace_swipe_cancel_ratio",
                "gestures:workspace_swipe_min_speed_to_force",
                "gestures:workspace_swipe_direction_lock",
                "gestures:workspace_swipe_use_r",
                "gestures:workspace_swipe_distance",
                "gestures:workspace_swipe_invert",
                "gestures:workspace_swipe_touch",
                "gestures:workspace_swipe_touch_invert",
                "gestures:workspace_swipe_direction_lock_threshold",
                "gestures:gesture_close_timeout",
                "gestures:gesture:3fingers", "gestures:gesture:4fingers"],
            layouts: ["dwindle:preserve_split", "dwindle:pseudotile",
                "dwindle:force_split", "dwindle:smart_split",
                "dwindle:default_split_ratio", "dwindle:split_width_multiplier",
                "dwindle:permanent_direction_override",
                "dwindle:special_scale_factor", "dwindle:use_active_for_splits",
                "dwindle:smart_resizing", "master:orientation", "master:mfact",
                "master:new_status", "master:new_on_top", "master:new_on_active",
                "master:smart_resizing", "master:special_scale_factor",
                "master:allow_small_split", "scrolling:column_width",
                "scrolling:explicit_column_widths", "scrolling:direction",
                "scrolling:fullscreen_on_one_column", "scrolling:focus_fit_method",
                "scrolling:follow_focus", "scrolling:follow_min_visible"],
            advanced: ["misc:disable_hyprland_logo",
                "misc:disable_splash_rendering",
                "misc:force_default_wallpaper", "misc:disable_autoreload",
                "misc:focus_on_activate", "misc:animate_manual_resizes",
                "misc:animate_mouse_windowdragging",
                "misc:no_update_news", "misc:enforce_permissions",
                "xwayland:enabled", "xwayland:force_zero_scaling",
                "xwayland:use_nearest_neighbor", "render:vrr", "render:vfr",
                "render:mouse_move_enables_dpms", "render:key_press_enables_dpms"]
        },

        // niri: nothing from the NothingLess panel has a runtime path.
        // Its config is static KDL and `niri msg` exposes no config or
        // reload verb. Output configuration is handled by MonitorsPanel,
        // which uses `niri msg output`.
        niri: {},

        // Mango speaks the sway IPC protocol. Its config is sway-style, so
        // the equivalent of a runtime keyword is a `mangoctl output`/`config`
        // request. Not verified here: Mango is not installed on this
        // machine. Left empty rather than guessed.
        mango: {}
    })

    // ── Runtime actions ─────────────────────────────────────────────────
    //
    // Separate from the config keywords above. A keyword changes how the
    // compositor behaves from now on; an action does something once. These are
    // the useful, no-argument actions each compositor can perform right now,
    // so the panel can offer them regardless of whether the compositor has a
    // runtime *config* interface.
    //
    // That distinction is the reason this table exists: niri has no runtime
    // config at all (its KDL is static), so `sections` is empty for it - but
    // `niri msg action` is a full runtime action interface, and it is what the
    // user is on. Every name below was taken from `niri msg action --help` on
    // this machine, not guessed.
    //
    // Mango speaks the sway IPC protocol through mangoctl, which is not
    // installed here, so its list is left empty rather than invented. The shape
    // is ready for it.
    readonly property var actions: ({
        hyprland: [
            { id: "toggle-floating", group: "floating", label: "compositor.action.toggle_floating", argv: ["hyprctl", "dispatch", "togglefloating"] },
            { id: "fullscreen", group: "window", label: "compositor.action.fullscreen", argv: ["hyprctl", "dispatch", "fullscreen", "0"] },
            { id: "close", group: "window", label: "compositor.action.close", argv: ["hyprctl", "dispatch", "killactive"] },
            { id: "pseudo", group: "layout", label: "compositor.action.pseudo", argv: ["hyprctl", "dispatch", "pseudo"] },
            { id: "split", group: "layout", label: "compositor.action.split", argv: ["hyprctl", "dispatch", "togglesplit"] },
            { id: "cycle", group: "focus", label: "compositor.action.cycle", argv: ["hyprctl", "dispatch", "cyclenext"] },
            { id: "special", group: "session", label: "compositor.action.special", argv: ["hyprctl", "dispatch", "togglespecialworkspace"] },
            { id: "center", group: "layout", label: "compositor.action.center", argv: ["hyprctl", "dispatch", "centerwindow"] },
            { id: "reload", group: "session", label: "compositor.action.reload", argv: ["hyprctl", "reload", "config-only"] }
        ],
        niri: [
            { id: "close-window", group: "window", label: "compositor.action.close_window", argv: ["niri", "msg", "action", "close-window"] },
            { id: "fullscreen-window", group: "window", label: "compositor.action.fullscreen_window", argv: ["niri", "msg", "action", "fullscreen-window"] },
            { id: "debug-toggle-opaque-regions", group: "window", label: "compositor.action.debug_toggle_opaque_regions", argv: ["niri", "msg", "action", "debug-toggle-opaque-regions"] },
            { id: "debug-toggle-damage", group: "window", label: "compositor.action.debug_toggle_damage", argv: ["niri", "msg", "action", "debug-toggle-damage"] },
            { id: "clear-dynamic-cast-target", group: "window", label: "compositor.action.clear_dynamic_cast_target", argv: ["niri", "msg", "action", "clear-dynamic-cast-target"] },
            { id: "unset-window-urgent", group: "window", label: "compositor.action.unset_window_urgent", argv: ["niri", "msg", "action", "unset-window-urgent"] },
            { id: "focus-window-previous", group: "focus", label: "compositor.action.focus_window_previous", argv: ["niri", "msg", "action", "focus-window-previous"] },
            { id: "focus-column-left", group: "focus", label: "compositor.action.focus_column_left", argv: ["niri", "msg", "action", "focus-column-left"] },
            { id: "focus-column-right", group: "focus", label: "compositor.action.focus_column_right", argv: ["niri", "msg", "action", "focus-column-right"] },
            { id: "focus-column-first", group: "focus", label: "compositor.action.focus_column_first", argv: ["niri", "msg", "action", "focus-column-first"] },
            { id: "focus-column-last", group: "focus", label: "compositor.action.focus_column_last", argv: ["niri", "msg", "action", "focus-column-last"] },
            { id: "focus-column-right-or-first", group: "focus", label: "compositor.action.focus_column_right_or_first", argv: ["niri", "msg", "action", "focus-column-right-or-first"] },
            { id: "focus-column-left-or-last", group: "focus", label: "compositor.action.focus_column_left_or_last", argv: ["niri", "msg", "action", "focus-column-left-or-last"] },
            { id: "focus-window-or-monitor-up", group: "focus", label: "compositor.action.focus_window_or_monitor_up", argv: ["niri", "msg", "action", "focus-window-or-monitor-up"] },
            { id: "focus-window-or-monitor-down", group: "focus", label: "compositor.action.focus_window_or_monitor_down", argv: ["niri", "msg", "action", "focus-window-or-monitor-down"] },
            { id: "focus-column-or-monitor-left", group: "focus", label: "compositor.action.focus_column_or_monitor_left", argv: ["niri", "msg", "action", "focus-column-or-monitor-left"] },
            { id: "focus-column-or-monitor-right", group: "focus", label: "compositor.action.focus_column_or_monitor_right", argv: ["niri", "msg", "action", "focus-column-or-monitor-right"] },
            { id: "focus-window-down", group: "focus", label: "compositor.action.focus_window_down", argv: ["niri", "msg", "action", "focus-window-down"] },
            { id: "focus-window-up", group: "focus", label: "compositor.action.focus_window_up", argv: ["niri", "msg", "action", "focus-window-up"] },
            { id: "focus-window-down-or-column-left", group: "focus", label: "compositor.action.focus_window_down_or_column_left", argv: ["niri", "msg", "action", "focus-window-down-or-column-left"] },
            { id: "focus-window-down-or-column-right", group: "focus", label: "compositor.action.focus_window_down_or_column_right", argv: ["niri", "msg", "action", "focus-window-down-or-column-right"] },
            { id: "focus-window-up-or-column-left", group: "focus", label: "compositor.action.focus_window_up_or_column_left", argv: ["niri", "msg", "action", "focus-window-up-or-column-left"] },
            { id: "focus-window-up-or-column-right", group: "focus", label: "compositor.action.focus_window_up_or_column_right", argv: ["niri", "msg", "action", "focus-window-up-or-column-right"] },
            { id: "focus-window-or-workspace-down", group: "focus", label: "compositor.action.focus_window_or_workspace_down", argv: ["niri", "msg", "action", "focus-window-or-workspace-down"] },
            { id: "focus-window-or-workspace-up", group: "focus", label: "compositor.action.focus_window_or_workspace_up", argv: ["niri", "msg", "action", "focus-window-or-workspace-up"] },
            { id: "focus-window-top", group: "focus", label: "compositor.action.focus_window_top", argv: ["niri", "msg", "action", "focus-window-top"] },
            { id: "focus-window-bottom", group: "focus", label: "compositor.action.focus_window_bottom", argv: ["niri", "msg", "action", "focus-window-bottom"] },
            { id: "focus-window-down-or-top", group: "focus", label: "compositor.action.focus_window_down_or_top", argv: ["niri", "msg", "action", "focus-window-down-or-top"] },
            { id: "focus-window-up-or-bottom", group: "focus", label: "compositor.action.focus_window_up_or_bottom", argv: ["niri", "msg", "action", "focus-window-up-or-bottom"] },
            { id: "focus-workspace-down", group: "focus", label: "compositor.action.focus_workspace_down", argv: ["niri", "msg", "action", "focus-workspace-down"] },
            { id: "focus-workspace-up", group: "focus", label: "compositor.action.focus_workspace_up", argv: ["niri", "msg", "action", "focus-workspace-up"] },
            { id: "focus-workspace-previous", group: "focus", label: "compositor.action.focus_workspace_previous", argv: ["niri", "msg", "action", "focus-workspace-previous"] },
            { id: "focus-monitor-left", group: "focus", label: "compositor.action.focus_monitor_left", argv: ["niri", "msg", "action", "focus-monitor-left"] },
            { id: "focus-monitor-right", group: "focus", label: "compositor.action.focus_monitor_right", argv: ["niri", "msg", "action", "focus-monitor-right"] },
            { id: "focus-monitor-down", group: "focus", label: "compositor.action.focus_monitor_down", argv: ["niri", "msg", "action", "focus-monitor-down"] },
            { id: "focus-monitor-up", group: "focus", label: "compositor.action.focus_monitor_up", argv: ["niri", "msg", "action", "focus-monitor-up"] },
            { id: "focus-monitor-previous", group: "focus", label: "compositor.action.focus_monitor_previous", argv: ["niri", "msg", "action", "focus-monitor-previous"] },
            { id: "focus-monitor-next", group: "focus", label: "compositor.action.focus_monitor_next", argv: ["niri", "msg", "action", "focus-monitor-next"] },
            { id: "focus-floating", group: "focus", label: "compositor.action.focus_floating", argv: ["niri", "msg", "action", "focus-floating"] },
            { id: "focus-tiling", group: "focus", label: "compositor.action.focus_tiling", argv: ["niri", "msg", "action", "focus-tiling"] },
            { id: "move-column-left", group: "move", label: "compositor.action.move_column_left", argv: ["niri", "msg", "action", "move-column-left"] },
            { id: "move-column-right", group: "move", label: "compositor.action.move_column_right", argv: ["niri", "msg", "action", "move-column-right"] },
            { id: "move-column-to-first", group: "move", label: "compositor.action.move_column_to_first", argv: ["niri", "msg", "action", "move-column-to-first"] },
            { id: "move-column-to-last", group: "move", label: "compositor.action.move_column_to_last", argv: ["niri", "msg", "action", "move-column-to-last"] },
            { id: "move-column-left-or-to-monitor-left", group: "move", label: "compositor.action.move_column_left_or_to_monitor_left", argv: ["niri", "msg", "action", "move-column-left-or-to-monitor-left"] },
            { id: "move-column-right-or-to-monitor-right", group: "move", label: "compositor.action.move_column_right_or_to_monitor_right", argv: ["niri", "msg", "action", "move-column-right-or-to-monitor-right"] },
            { id: "move-window-down", group: "move", label: "compositor.action.move_window_down", argv: ["niri", "msg", "action", "move-window-down"] },
            { id: "move-window-up", group: "move", label: "compositor.action.move_window_up", argv: ["niri", "msg", "action", "move-window-up"] },
            { id: "move-window-down-or-to-workspace-down", group: "move", label: "compositor.action.move_window_down_or_to_workspace_down", argv: ["niri", "msg", "action", "move-window-down-or-to-workspace-down"] },
            { id: "move-window-up-or-to-workspace-up", group: "move", label: "compositor.action.move_window_up_or_to_workspace_up", argv: ["niri", "msg", "action", "move-window-up-or-to-workspace-up"] },
            { id: "move-window-to-workspace-down", group: "move", label: "compositor.action.move_window_to_workspace_down", argv: ["niri", "msg", "action", "move-window-to-workspace-down"] },
            { id: "move-window-to-workspace-up", group: "move", label: "compositor.action.move_window_to_workspace_up", argv: ["niri", "msg", "action", "move-window-to-workspace-up"] },
            { id: "move-column-to-workspace-down", group: "move", label: "compositor.action.move_column_to_workspace_down", argv: ["niri", "msg", "action", "move-column-to-workspace-down"] },
            { id: "move-column-to-workspace-up", group: "move", label: "compositor.action.move_column_to_workspace_up", argv: ["niri", "msg", "action", "move-column-to-workspace-up"] },
            { id: "move-workspace-down", group: "move", label: "compositor.action.move_workspace_down", argv: ["niri", "msg", "action", "move-workspace-down"] },
            { id: "move-workspace-up", group: "move", label: "compositor.action.move_workspace_up", argv: ["niri", "msg", "action", "move-workspace-up"] },
            { id: "move-window-to-monitor-left", group: "move", label: "compositor.action.move_window_to_monitor_left", argv: ["niri", "msg", "action", "move-window-to-monitor-left"] },
            { id: "move-window-to-monitor-right", group: "move", label: "compositor.action.move_window_to_monitor_right", argv: ["niri", "msg", "action", "move-window-to-monitor-right"] },
            { id: "move-window-to-monitor-down", group: "move", label: "compositor.action.move_window_to_monitor_down", argv: ["niri", "msg", "action", "move-window-to-monitor-down"] },
            { id: "move-window-to-monitor-up", group: "move", label: "compositor.action.move_window_to_monitor_up", argv: ["niri", "msg", "action", "move-window-to-monitor-up"] },
            { id: "move-window-to-monitor-previous", group: "move", label: "compositor.action.move_window_to_monitor_previous", argv: ["niri", "msg", "action", "move-window-to-monitor-previous"] },
            { id: "move-window-to-monitor-next", group: "move", label: "compositor.action.move_window_to_monitor_next", argv: ["niri", "msg", "action", "move-window-to-monitor-next"] },
            { id: "move-column-to-monitor-left", group: "move", label: "compositor.action.move_column_to_monitor_left", argv: ["niri", "msg", "action", "move-column-to-monitor-left"] },
            { id: "move-column-to-monitor-right", group: "move", label: "compositor.action.move_column_to_monitor_right", argv: ["niri", "msg", "action", "move-column-to-monitor-right"] },
            { id: "move-column-to-monitor-down", group: "move", label: "compositor.action.move_column_to_monitor_down", argv: ["niri", "msg", "action", "move-column-to-monitor-down"] },
            { id: "move-column-to-monitor-up", group: "move", label: "compositor.action.move_column_to_monitor_up", argv: ["niri", "msg", "action", "move-column-to-monitor-up"] },
            { id: "move-column-to-monitor-previous", group: "move", label: "compositor.action.move_column_to_monitor_previous", argv: ["niri", "msg", "action", "move-column-to-monitor-previous"] },
            { id: "move-column-to-monitor-next", group: "move", label: "compositor.action.move_column_to_monitor_next", argv: ["niri", "msg", "action", "move-column-to-monitor-next"] },
            { id: "move-workspace-to-monitor-left", group: "move", label: "compositor.action.move_workspace_to_monitor_left", argv: ["niri", "msg", "action", "move-workspace-to-monitor-left"] },
            { id: "move-workspace-to-monitor-right", group: "move", label: "compositor.action.move_workspace_to_monitor_right", argv: ["niri", "msg", "action", "move-workspace-to-monitor-right"] },
            { id: "move-workspace-to-monitor-down", group: "move", label: "compositor.action.move_workspace_to_monitor_down", argv: ["niri", "msg", "action", "move-workspace-to-monitor-down"] },
            { id: "move-workspace-to-monitor-up", group: "move", label: "compositor.action.move_workspace_to_monitor_up", argv: ["niri", "msg", "action", "move-workspace-to-monitor-up"] },
            { id: "move-workspace-to-monitor-previous", group: "move", label: "compositor.action.move_workspace_to_monitor_previous", argv: ["niri", "msg", "action", "move-workspace-to-monitor-previous"] },
            { id: "move-workspace-to-monitor-next", group: "move", label: "compositor.action.move_workspace_to_monitor_next", argv: ["niri", "msg", "action", "move-workspace-to-monitor-next"] },
            { id: "move-window-to-floating", group: "move", label: "compositor.action.move_window_to_floating", argv: ["niri", "msg", "action", "move-window-to-floating"] },
            { id: "move-window-to-tiling", group: "move", label: "compositor.action.move_window_to_tiling", argv: ["niri", "msg", "action", "move-window-to-tiling"] },
            { id: "consume-or-expel-window-left", group: "layout", label: "compositor.action.consume_or_expel_window_left", argv: ["niri", "msg", "action", "consume-or-expel-window-left"] },
            { id: "consume-or-expel-window-right", group: "layout", label: "compositor.action.consume_or_expel_window_right", argv: ["niri", "msg", "action", "consume-or-expel-window-right"] },
            { id: "consume-window-into-column", group: "layout", label: "compositor.action.consume_window_into_column", argv: ["niri", "msg", "action", "consume-window-into-column"] },
            { id: "expel-window-from-column", group: "layout", label: "compositor.action.expel_window_from_column", argv: ["niri", "msg", "action", "expel-window-from-column"] },
            { id: "swap-window-right", group: "layout", label: "compositor.action.swap_window_right", argv: ["niri", "msg", "action", "swap-window-right"] },
            { id: "swap-window-left", group: "layout", label: "compositor.action.swap_window_left", argv: ["niri", "msg", "action", "swap-window-left"] },
            { id: "toggle-column-tabbed-display", group: "layout", label: "compositor.action.toggle_column_tabbed_display", argv: ["niri", "msg", "action", "toggle-column-tabbed-display"] },
            { id: "center-column", group: "layout", label: "compositor.action.center_column", argv: ["niri", "msg", "action", "center-column"] },
            { id: "center-window", group: "layout", label: "compositor.action.center_window", argv: ["niri", "msg", "action", "center-window"] },
            { id: "center-visible-columns", group: "layout", label: "compositor.action.center_visible_columns", argv: ["niri", "msg", "action", "center-visible-columns"] },
            { id: "reset-window-height", group: "layout", label: "compositor.action.reset_window_height", argv: ["niri", "msg", "action", "reset-window-height"] },
            { id: "switch-preset-column-width", group: "layout", label: "compositor.action.switch_preset_column_width", argv: ["niri", "msg", "action", "switch-preset-column-width"] },
            { id: "switch-preset-column-width-back", group: "layout", label: "compositor.action.switch_preset_column_width_back", argv: ["niri", "msg", "action", "switch-preset-column-width-back"] },
            { id: "switch-preset-window-width", group: "layout", label: "compositor.action.switch_preset_window_width", argv: ["niri", "msg", "action", "switch-preset-window-width"] },
            { id: "switch-preset-window-width-back", group: "layout", label: "compositor.action.switch_preset_window_width_back", argv: ["niri", "msg", "action", "switch-preset-window-width-back"] },
            { id: "switch-preset-window-height", group: "layout", label: "compositor.action.switch_preset_window_height", argv: ["niri", "msg", "action", "switch-preset-window-height"] },
            { id: "switch-preset-window-height-back", group: "layout", label: "compositor.action.switch_preset_window_height_back", argv: ["niri", "msg", "action", "switch-preset-window-height-back"] },
            { id: "maximize-column", group: "layout", label: "compositor.action.maximize_column", argv: ["niri", "msg", "action", "maximize-column"] },
            { id: "maximize-window-to-edges", group: "layout", label: "compositor.action.maximize_window_to_edges", argv: ["niri", "msg", "action", "maximize-window-to-edges"] },
            { id: "expand-column-to-available-width", group: "layout", label: "compositor.action.expand_column_to_available_width", argv: ["niri", "msg", "action", "expand-column-to-available-width"] },
            { id: "switch-layout", group: "layout", label: "compositor.action.switch_layout", argv: ["niri", "msg", "action", "switch-layout"] },
            { id: "toggle-window-floating", group: "floating", label: "compositor.action.toggle_window_floating", argv: ["niri", "msg", "action", "toggle-window-floating"] },
            { id: "switch-focus-between-floating-and-tiling", group: "floating", label: "compositor.action.switch_focus_between_floating_and_tiling", argv: ["niri", "msg", "action", "switch-focus-between-floating-and-tiling"] },
            { id: "toggle-keyboard-shortcuts-inhibit", group: "toggle", label: "compositor.action.toggle_keyboard_shortcuts_inhibit", argv: ["niri", "msg", "action", "toggle-keyboard-shortcuts-inhibit"] },
            { id: "toggle-windowed-fullscreen", group: "toggle", label: "compositor.action.toggle_windowed_fullscreen", argv: ["niri", "msg", "action", "toggle-windowed-fullscreen"] },
            { id: "show-hotkey-overlay", group: "toggle", label: "compositor.action.show_hotkey_overlay", argv: ["niri", "msg", "action", "show-hotkey-overlay"] },
            { id: "toggle-debug-tint", group: "toggle", label: "compositor.action.toggle_debug_tint", argv: ["niri", "msg", "action", "toggle-debug-tint"] },
            { id: "toggle-window-rule-opacity", group: "toggle", label: "compositor.action.toggle_window_rule_opacity", argv: ["niri", "msg", "action", "toggle-window-rule-opacity"] },
            { id: "toggle-overview", group: "toggle", label: "compositor.action.toggle_overview", argv: ["niri", "msg", "action", "toggle-overview"] },
            { id: "toggle-window-urgent", group: "toggle", label: "compositor.action.toggle_window_urgent", argv: ["niri", "msg", "action", "toggle-window-urgent"] },
            { id: "screenshot", group: "capture", label: "compositor.action.screenshot", argv: ["niri", "msg", "action", "screenshot"] },
            { id: "screenshot-screen", group: "capture", label: "compositor.action.screenshot_screen", argv: ["niri", "msg", "action", "screenshot-screen"] },
            { id: "screenshot-window", group: "capture", label: "compositor.action.screenshot_window", argv: ["niri", "msg", "action", "screenshot-window"] },
            { id: "power-off-monitors", group: "session", label: "compositor.action.power_off_monitors", argv: ["niri", "msg", "action", "power-off-monitors"] },
            { id: "power-on-monitors", group: "session", label: "compositor.action.power_on_monitors", argv: ["niri", "msg", "action", "power-on-monitors"] },
            { id: "do-screen-transition", group: "session", label: "compositor.action.do_screen_transition", argv: ["niri", "msg", "action", "do-screen-transition"] },
            { id: "stop-cast", group: "session", label: "compositor.action.stop_cast", argv: ["niri", "msg", "action", "stop-cast"] },
            { id: "open-overview", group: "session", label: "compositor.action.open_overview", argv: ["niri", "msg", "action", "open-overview"] },
            { id: "close-overview", group: "session", label: "compositor.action.close_overview", argv: ["niri", "msg", "action", "close-overview"] },
        ],
        mango: []
    })

    // Actions that work identically on Hyprland, niri and mango, because they
    // go through axctl, which is the abstraction Ambxst itself is built on.
    // These are the ones that must not be per-compositor: without them a mango
    // user got an empty Actions section, and a Hyprland user only got the nine
    // hand-written dispatchers.
    //
    // `axctl window ...` / `workspace ...` / `monitor ...` / `layout ...` /
    // `darkmode ...` are the compositor-agnostic verbs (verified against
    // `axctl --help` v0.0.28 and run live on niri). Anything genuinely
    // compositor-specific stays in the `actions` table below.
    readonly property var commonActions: [
        { id: "common.focus-left", group: "focus", label: "compositor.action.focus_left", argv: ["axctl", "window", "focus-dir", "l"] },
        { id: "common.focus-right", group: "focus", label: "compositor.action.focus_right", argv: ["axctl", "window", "focus-dir", "r"] },
        { id: "common.focus-up", group: "focus", label: "compositor.action.focus_up", argv: ["axctl", "window", "focus-dir", "u"] },
        { id: "common.focus-down", group: "focus", label: "compositor.action.focus_down", argv: ["axctl", "window", "focus-dir", "d"] },
        { id: "common.close", group: "window", label: "compositor.action.close", argv: ["axctl", "window", "close"] },
        { id: "common.floating", group: "floating", label: "compositor.action.toggle_floating", argv: ["axctl", "window", "toggle-floating"] },
        { id: "common.fullscreen-on", group: "window", label: "compositor.action.fullscreen_on", argv: ["axctl", "window", "fullscreen", "1"] },
        { id: "common.fullscreen-off", group: "window", label: "compositor.action.fullscreen_off", argv: ["axctl", "window", "fullscreen", "0"] },
        { id: "common.maximize-on", group: "layout", label: "compositor.action.maximize_on", argv: ["axctl", "window", "maximize", "1"] },
        { id: "common.maximize-off", group: "layout", label: "compositor.action.maximize_off", argv: ["axctl", "window", "maximize", "0"] },
        { id: "common.pin-on", group: "window", label: "compositor.action.pin_on", argv: ["axctl", "window", "pin", "1"] },
        { id: "common.pin-off", group: "window", label: "compositor.action.pin_off", argv: ["axctl", "window", "pin", "0"] },
        { id: "common.layout-next", group: "layout", label: "compositor.action.layout_next", argv: ["axctl", "layout", "next"] },
        { id: "common.layout-prev", group: "layout", label: "compositor.action.layout_prev", argv: ["axctl", "layout", "prev"] },
        { id: "common.kbd-next", group: "session", label: "compositor.action.keyboard_next", argv: ["axctl", "system", "switch-keyboard-layout", "next"] },
        { id: "common.kbd-prev", group: "session", label: "compositor.action.keyboard_prev", argv: ["axctl", "system", "switch-keyboard-layout", "prev"] },
        { id: "common.darkmode", group: "session", label: "compositor.action.darkmode", argv: ["axctl", "darkmode", "toggle"] }
    ]

    // The common set first (the useful basics, identical everywhere), then
    // whatever is specific to the running compositor.
    readonly property var actionList: commonActions.concat(actions[compositor] || [])
    readonly property bool hasActions: actionList.length > 0

    // actionList grouped for the panel, preserving first-seen order. Each
    // entry is { id, label, items }, so the UI can render a header per group
    // instead of a flat wall of buttons.
    readonly property var actionGroups: {
        const list = actionList;
        const order = [];
        const by = {};
        for (let i = 0; i < list.length; i++) {
            const it = list[i];
            const g = it.group ? it.group : "other";
            if (!by[g]) {
                by[g] = [];
                order.push(g);
            }
            by[g].push(it);
        }
        const out = [];
        for (let i = 0; i < order.length; i++) {
            out.push({
                id: order[i],
                label: "compositor.group." + order[i],
                items: by[order[i]]
            });
        }
        return out;
    }

    // Run one action by id. Returns false when the id is unknown or there are
    // no actions, so a caller can report honestly.
    function runAction(actionId, onDone) {
        const list = actionList;
        let found = null;
        for (let i = 0; i < list.length; i++) {
            if (list[i].id === actionId) {
                found = list[i];
                break;
            }
        }
        if (!found) {
            root.lastError = qsTr("Unknown compositor action");
            if (onDone)
                onDone(false, "");
            return false;
        }
        root.lastError = "";
        _run(found.argv, (ok, out, err) => {
            if (!ok)
                root.lastError = (err || out || "").trim();
            if (onDone)
                onDone(ok, out);
        });
        return true;
    }

    // Sections Ambxst writes for every compositor through its own TOML path.
    // Always offered, whatever the compositor. `general` is here because
    // gaps, border size and rounding reach every compositor that axctl
    // generates a config for, even though a few extra Hyprland-only rows
    // also live in that section.
    // Which of Ambxst's own appearance sections actually reach each compositor.
    //
    // This is not guesswork and not `axctl system get-capabilities`, which
    // reports blur and shadows as true even on niri. It is read off the config
    // axctl actually generates for each one (~/.local/share/ambxst/niri.kdl,
    // hyprland.lua, mango.conf), where axctl emits an explicit
    // "// Not supported in <compositor>" comment for every key it drops:
    //
    //   niri     emits layout.gaps (inner only), border, geometry-corner-radius
    //            and comments out outer gaps, opacity, blur and shadow as
    //            "not supported in niri static config".
    //   mango    emits gappih/gappiv/gappoh/gappov, borderpx, border_radius,
    //            focused_opacity/unfocused_opacity, blur and shadows.
    //   hyprland drops nothing.
    //
    // So showing Blur on niri is showing a control that writes a value the
    // compositor never reads. Sections absent here are hidden by the panel.
    readonly property var tomlSectionSupport: ({
        hyprland: ["general", "colors", "shadows", "blur", "opacity"],
        niri:     ["general", "colors"],
        mango:    ["general", "colors", "shadows", "blur", "opacity"]
    })

    // A section is offered when either Ambxst writes it for this compositor
    // (tomlSectionSupport) or it has Hyprland runtime keywords behind it.
    function supports(sectionId) {
        const toml = tomlSectionSupport[compositor];
        if (toml && toml.indexOf(sectionId) >= 0)
            return true;

        const forThis = sections[compositor];
        if (!forThis)
            return false;
        return Array.isArray(forThis[sectionId]) && forThis[sectionId].length > 0;
    }

    function hasKeyword(sectionId, keywordPath) {
        const forThis = sections[compositor];
        if (!forThis || !forThis[sectionId])
            return false;
        return forThis[sectionId].indexOf(keywordPath) >= 0;
    }

    // ── Runtime writes ──────────────────────────────────────────────────

    property string lastError: ""

    function _run(argv, onDone) {
        const args = argv.map(a => JSON.stringify(String(a))).join(", ");
        let proc;
        try {
            proc = Qt.createQmlObject(
                "import Quickshell\n"
                + "import Quickshell.Io\n"
                + "Process {\n"
                + "    command: [" + args + "]\n"
                + "    stdout: StdioCollector {}\n"
                + "    stderr: StdioCollector {}\n"
                + "}",
                root, "kwProc");
        } catch (e) {
            root.lastError = qsTr("Could not run the compositor client");
            if (onDone)
                onDone(false, "");
            return;
        }
        proc.exited.connect(function (exitCode) {
            let out = "";
            let err = "";
            try {
                out = proc.stdout ? proc.stdout.text : "";
                err = proc.stderr ? proc.stderr.text : "";
            } catch (e) {
                out = "";
            }
            proc.destroy();
            if (onDone)
                onDone(exitCode === 0, out, err);
        });
        proc.running = true;
    }

    /*
        Apply a keyword. `keywordPath` is the Hyprland path, e.g.
        "input:kb_layout". Returns false immediately on compositors with no
        runtime keyword interface, so a caller can report honestly instead
        of firing a command that cannot work.
    */
    function setKeyword(keywordPath, value, onDone) {
        root.lastError = "";
        if (compositor !== "hyprland") {
            root.lastError = qsTr("This compositor has no runtime keyword interface");
            if (onDone)
                onDone(false, "");
            return false;
        }
        _run(["hyprctl", "keyword", keywordPath, String(value)], (ok, out, err) => {
            if (!ok)
                root.lastError = (err || out || "").trim();
            if (onDone)
                onDone(ok, out);
        });
        return true;
    }

    function reloadConfig(onDone) {
        root.lastError = "";
        if (compositor !== "hyprland") {
            root.lastError = qsTr("This compositor has no runtime keyword interface");
            if (onDone)
                onDone(false, "");
            return false;
        }
        // config-only: do not cycle the monitors, which would black the
        // screen out while the user is adjusting output settings.
        _run(["hyprctl", "reload", "config-only"], (ok, out, err) => {
            if (!ok)
                root.lastError = (err || out || "").trim();
            if (onDone)
                onDone(ok, out);
        });
        return true;
    }

    // ── Fallback detection ──────────────────────────────────────────────

    readonly property var probeTable: [
        { name: "niri", argv: ["niri", "msg", "--json", "outputs"] },
        { name: "hyprland", argv: ["hyprctl", "monitors", "-j"] },
        { name: "mango", argv: ["mangoctl", "-j", "get_outputs"] }
    ]

    function probeFrom(index) {
        if (_detected !== "" || reported !== "")
            return;
        if (index >= probeTable.length)
            return;
        const p = probeTable[index];
        _run(p.argv, (ok) => {
            if (ok)
                root._detected = p.name;
            else
                root.probeFrom(index + 1);
        });
    }

    Component.onCompleted: {
        if (reported === "")
            probeFrom(0);
    }

    // No Connections block on purpose: this root is a QtObject, which has no
    // default property, so it cannot own children and `Connections` as a
    // child throws "Cannot assign to non-existent default property".
    //
    // It is not needed either. `reported` is a binding over
    // AxctlService.compositorName, so it re-evaluates by itself when the
    // compositor is finally named; and probeFrom(0) below covers the window
    // before that happens.
}
