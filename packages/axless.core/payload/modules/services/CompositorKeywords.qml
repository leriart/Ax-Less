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

    // Sections Ambxst writes for every compositor through its own TOML path.
    // Always offered, whatever the compositor. `general` is here because
    // gaps, border size and rounding reach every compositor that axctl
    // generates a config for, even though a few extra Hyprland-only rows
    // also live in that section.
    readonly property var tomlSections: ["general", "colors", "shadows", "blur"]

    function supports(sectionId) {
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
