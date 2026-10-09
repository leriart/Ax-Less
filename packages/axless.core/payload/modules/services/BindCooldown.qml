pragma Singleton

import QtQuick
import Quickshell
import qs.modules.services

/*
    BindCooldown.qml

    A single, global cooldown shared by every shell action reached through
    `GlobalShortcuts.run()`.

    Why here
    --------
    A keybind ultimately becomes one of two things:

      * a compositor-native action (focus, move, workspace, resize) that the
        compositor handles itself and the shell never sees, or
      * `ambxst run <action>`, which the daemon forwards to the shell over IPC
        and lands in `GlobalShortcuts.run()`.

    Only the second kind can be gated from QML. That is most of Ambxst's binds
    (the launcher, the dashboard, the assistant, media, brightness, the
    clipboard, and so on), and it is exactly the set where a repeat or a double
    tap is annoying - the compositor-native ones are idempotent and cost
    nothing to repeat.

    Gating at `run()` rather than at the keybind generation is also what keeps
    it honest: a shell action can be triggered from the IPC socket, from
    another keybind, or from inside the shell, and all of those go through the
    same function, so they all obey the same cooldown.

    The value comes from the mod's own settings (settings.json, key
    `bindCooldown`, default 25 ms) so it has a UI in the mods panel without
    touching any of the base shell's config files.
*/
QtObject {
    id: root

    // Milliseconds. 0 disables the gate entirely.
    property int cooldownMs: 25

    // Last accepted invocation per command, so two different actions never
    // interfere with each other.
    property var _lastAccepted: ({})

    // ModsService is the source of truth: read once at startup, then follow
    // its signal. Assigned to a property rather than declared as a child,
    // because this root is a QtObject, which has no default property.
    property Connections modsConn: Connections {
        target: ModsService
        function onSettingChanged(modId, key, value) {
            if (modId !== "axless.core" || key !== "bindCooldown")
                return;
            const n = Number(value);
            if (!isNaN(n))
                root.cooldownMs = n;
        }
    }

    // Read the persisted value. Called from GlobalShortcuts' own
    // Component.onCompleted, because this singleton's does not fire reliably
    // here - which is why a reload used to drop the value back to 25.
    function refresh() {
        ModsService.getSettings("axless.core", function (settings, error) {
            if (error || !settings || !settings.values)
                return;
            const v = settings.values.bindCooldown;
            if (v === undefined || v === null)
                return;
            const n = Number(v);
            if (!isNaN(n))
                root.cooldownMs = n;
        });
    }

    Component.onCompleted: root.refresh()

    /*
        Returns true when `command` may run now, false when it is still within
        its cooldown window.

        Keyed by the command string, so pressing "dashboard" twice quickly is
        throttled without throttling "dashboard" and "brightness-up" against
        each other.
    */
    function gate(command) {
        const ms = Math.max(0, Math.round(cooldownMs));

        if (ms <= 0)
            return true;

        const now = Date.now();
        const key = String(command);
        const last = root._lastAccepted[key];
        if (last !== undefined && (now - last) < ms) {
            return false;
        }

        // Copy-on-write on a plain object: `property var` only notifies when
        // the reference changes, and this map stays tiny (one entry per
        // distinct command ever used).
        let next = {};
        for (const k in root._lastAccepted)
            next[k] = root._lastAccepted[k];
        next[key] = now;
        root._lastAccepted = next;
        return true;
    }

    // The panel calls these, not ModsService directly. Writing only the
    // setting was the bug: `cooldownMs` then depended on a setting-changed
    // signal and a Component.onCompleted read, neither of which fires
    // reliably on a singleton here, so the value stayed at its default and
    // the cooldown appeared to do nothing. Setting the property first makes
    // it take effect in this process immediately; persisting keeps it across
    // restarts.
    function setMs(v) {
        let n = Math.round(Number(v));
        if (isNaN(n))
            return;
        n = Math.max(0, Math.min(1000, n));
        root.cooldownMs = n;
        ModsService.setSetting("axless.core", "bindCooldown", n);
    }

    // Toggling off remembers nothing but the convention value; toggling on
    // restores the default when it was left at 0.
    function setEnabled(on) {
        if (on)
            setMs(root.cooldownMs > 0 ? root.cooldownMs : 25);
        else
            setMs(0);
    }

    // Exposed for the settings UI: forget the history so the next press is
    // always accepted. Not normally needed; useful when testing the value.
    function reset() {
        root._lastAccepted = ({});
    }
}
