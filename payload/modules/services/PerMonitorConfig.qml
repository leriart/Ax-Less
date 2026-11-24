pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import qs.config
import qs.modules.services

/*!
    PerMonitorConfig.qml — Per-monitor configuration overrides, plus a
    remembered monitor layout.

    Part 1 — overrides. Reads ~/.config/ambxst/config/monitors.json for
    monitor-specific overrides of global config values. Currently supports:
    - bar.position
    - notch.position
    - dock.position

    Example monitors.json:
    {
      "DP-1": {
        "bar": { "position": "bottom" },
        "notch": { "position": "bottom" }
      },
      "HDMI-A-1": {
        "bar": { "position": "left" }
      }
    }

    Part 2 — remembered layout. Compositor output positions are runtime-only:
    niri, Hyprland and Mango all reset them when the compositor restarts. This
    singleton polls the compositor's own IPC on a slow timer while the shell
    runs and keeps the last seen arrangement in
    ~/.local/share/ambxst/monitor-layout.json. On startup (and when a
    previously-seen output reappears, e.g. a re-plugged cable) it re-applies
    the remembered position to any output whose live position differs. Only
    x/y are restored; mode, scale and transform are never touched.

    The read/write argv shapes are the ones MonitorsPanel already verified
    against the live compositors: niri msg, hyprctl keyword monitor, mangoctl.
*/
Singleton {
    id: root

    property string configPath: (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")) + "/ambxst/config/monitors.json"

    // Internal cache of the parsed JSON
    property var _data: ({})
    property bool _ready: false

    FileView {
        id: loader
        path: root.configPath
        watchChanges: true
        // blockLoading makes text() available as soon as the FileView is
        // constructed. Without it the read is async and the first parse
        // races the load - which is what NothingLess's onLoaded +
        // Component.onCompleted pair was doing.
        blockLoading: true
        onFileChanged: {
            root._parse(loader.text());
        }
    }

    // Deterministic initial parse. A zero-interval Timer is used instead of
    // Component.onCompleted because the latter was observed not firing on
    // this singleton under Ambxst: _ready stayed false and every resolve()
    // silently returned the global default, which looks exactly like "my
    // per-monitor file is being ignored".
    Timer {
        interval: 0
        running: true
        onTriggered: {
            if (!root._ready) {
                root._parse(loader.text());
            }
        }
    }

    function _parse(text) {
        if (!text || text.trim().length === 0) {
            root._data = {};
            root._ready = true;
            return;
        }
        try {
            root._data = JSON.parse(text);
            root._ready = true;
        } catch (e) {
            console.warn("PerMonitorConfig: Failed to parse monitors.json:", e);
            root._data = {};
            root._ready = true;
        }
    }

    /*! Resolve a per-monitor override.
        @param screenName  Monitor name (e.g. "DP-1")
        @param domain      Config domain (e.g. "bar", "notch", "dock")
        @param key         Property key (e.g. "position")
        @param defaultValue Fallback value if no override exists
        @return The override value, or defaultValue if none exists.
    */
    function resolve(screenName, domain, key, defaultValue) {
        if (!root._ready || !screenName) return defaultValue;
        const monitor = root._data[screenName];
        if (!monitor) return defaultValue;
        const dom = monitor[domain];
        if (!dom) return defaultValue;
        const val = dom[key];
        return val !== undefined ? val : defaultValue;
    }

    // ═══════════════════════════════════════════════════════════════════
    // Remembered monitor layout
    // ═══════════════════════════════════════════════════════════════════

    readonly property string layoutDir: (Quickshell.env("XDG_DATA_HOME") || (Quickshell.env("HOME") + "/.local/share")) + "/ambxst"
    readonly property string layoutPath: layoutDir + "/monitor-layout.json"

    readonly property var _knownCompositors: ["hyprland", "niri", "mango"]
    readonly property var _probeTable: [
        { name: "niri", argv: ["niri", "msg", "--json", "outputs"] },
        { name: "hyprland", argv: ["hyprctl", "monitors", "-j"] },
        { name: "mango", argv: ["mangoctl", "-j", "get_outputs"] }
    ]

    // Remembered layout from disk: { compositor, outputs: { id: {x,y} } }.
    property var _remembered: null
    // Live snapshot from the last poll: { id: {x,y} }.
    property var _live: ({})
    // Names present in the previous poll, to tell "moved" from "appeared".
    property var _seenIds: ({})
    // Restores already issued but not confirmed by a later poll:
    // { id: {x,y} }. Retried until the compositor reports the new position.
    property var _pendingRestore: ({})
    property bool _restoredAtBoot: false
    property bool _layoutLoaded: false
    property string _savedJson: ""

    readonly property string _reported: {
        const n = (AxctlService.compositorName || "").toLowerCase();
        return _knownCompositors.indexOf(n) >= 0 ? n : "";
    }
    property string _detected: ""

    // blockLoading makes text() available synchronously, so the first poll
    // cannot run before the remembered layout has been read. The previous
    // implementation raced a `cat` Process against the compositor probe; on
    // a cold boot the probe could win, and the live fallback layout was then
    // written over the remembered one.
    FileView {
        id: layoutLoader
        path: root.layoutPath
        printErrors: false
        blockLoading: true
    }

    Timer {
        // Startup grace period: the compositor and the Ambxst daemon need a
        // moment before their IPC answers. 2.5 s, then the slow poll takes
        // over and performs the first restore.
        interval: 2500
        running: true
        onTriggered: {
            root._ensureLayoutLoaded();
            layoutTimer.restart();
            // Poll right away so the boot restore lands ~2.5 s after shell
            // start instead of a full interval later.
            root._pollLayout();
        }
    }

    // Slow poll. 20 s is cheap (three possible JSON reads, only one of which
    // spawns per cycle) and fast enough that a re-plugged monitor is put
    // back within seconds.
    Timer {
        id: layoutTimer
        interval: 20000
        repeat: true
        onTriggered: root._pollLayout()
    }

    // Sequential probe, same trick as MonitorsPanel: one client at a time so
    // they cannot race on _detected.
    function _probeFrom(index) {
        if (root._detected !== "" || root._reported !== "")
            return;
        if (index >= root._probeTable.length)
            return;
        const p = root._probeTable[index];
        _spawn(p.argv, ok => {
            if (ok) {
                root._detected = p.name;
                // Do not wait for the 20 s timer after a successful probe:
                // the first restore belongs to the boot path.
                root._pollLayout();
            } else {
                root._probeFrom(index + 1);
            }
        });
    }

    function _parseLayout(text) {
        root._layoutLoaded = true;
        if (!text || text.trim().length === 0) {
            root._remembered = null;
            return;
        }
        try {
            const data = JSON.parse(text);
            root._remembered = (data && data.outputs) ? data : null;
        } catch (e) {
            console.warn("PerMonitorConfig: bad monitor-layout.json:", e);
            root._remembered = null;
        }
    }

    function _ensureLayoutLoaded() {
        if (!root._layoutLoaded)
            root._parseLayout(layoutLoader.text());
    }

    function _pollLayout() {
        root._ensureLayoutLoaded();
        if (root._reported === "" && root._detected === "") {
            root._probeFrom(0);
            return;
        }
        const comp = root._reported !== "" ? root._reported : root._detected;
        const argv = comp === "niri" ? ["niri", "msg", "--json", "outputs"]
            : comp === "hyprland" ? ["hyprctl", "monitors", "-j"]
            : ["mangoctl", "-j", "get_outputs"];
        _spawn(argv, (ok, out, err) => {
            if (!ok) {
                console.warn("PerMonitorConfig: layout read failed:", (err || "").trim());
                return;
            }
            const live = root._extract(comp, out);
            if (live === null) {
                console.warn("PerMonitorConfig: unparseable layout payload");
                return;
            }
            root._onLiveSnapshot(comp, live);
        });
    }

    // Returns { id: {x, y} } for enabled outputs, or null on a bad payload.
    function _extract(comp, out) {
        let data;
        try {
            data = JSON.parse(out);
        } catch (e) {
            return null;
        }
        const snap = {};
        if (comp === "niri") {
            for (const key in data) {
                const o = data[key];
                if (!o || o.logical === null || o.logical === undefined)
                    continue;
                snap[o.name || key] = { x: o.logical.x || 0, y: o.logical.y || 0 };
            }
        } else {
            // hyprctl monitors -j and mangoctl get_outputs both expose a flat
            // list with x/y at the top level; disabled entries read 0x0.
            const list = Array.isArray(data) ? data : [];
            for (const o of list) {
                if (!o || !o.name)
                    continue;
                if (comp === "hyprland" && o.disabled)
                    continue;
                snap[o.name] = { x: o.x || 0, y: o.y || 0 };
            }
        }
        return snap;
    }

    function _onLiveSnapshot(comp, live) {
        const remembered = (root._remembered && root._remembered.compositor === comp)
            ? root._remembered : null;
        const seen = root._seenIds;
        let pending = Object.assign({}, root._pendingRestore);
        let restoring = false;

        for (const id in live) {
            const want = remembered ? remembered.outputs[id] : null;
            const isPending = pending[id] !== undefined;
            if (!want) {
                if (isPending)
                    delete pending[id];
                continue;
            }
            const differs = live[id].x !== want.x || live[id].y !== want.y;
            if (!differs) {
                if (isPending)
                    delete pending[id];
                continue;
            }
            const appeared = seen[id] !== true;
            // Restore only while the layout is settling: at boot for every
            // output present from the start, for outputs that reappear
            // (re-plugged cable), and while a previous restore has not been
            // confirmed yet. An output that is present and merely moved
            // keeps its new position - the next save adopts it as memory.
            if (appeared || !root._restoredAtBoot || isPending) {
                pending[id] = { x: want.x, y: want.y };
                root._restorePosition(comp, id, want);
                restoring = true;
            }
        }

        root._pendingRestore = pending;
        root._restoredAtBoot = true;
        root._seenIds = (() => { const s = {}; for (const id in live) s[id] = true; return s; })();
        root._live = live;

        // Do not overwrite the remembered layout while a restore is still in
        // flight: the live snapshot still holds the old positions. The next
        // poll confirms the new arrangement and saves it.
        if (restoring)
            return;

        // Keep entries for outputs that are currently unplugged, so a
        // re-plugged cable can still be restored.
        const outputs = Object.assign({}, live);
        if (remembered) {
            for (const id in remembered.outputs) {
                if (outputs[id] === undefined)
                    outputs[id] = remembered.outputs[id];
            }
        }
        root._saveLayout(comp, outputs);
    }

    // Called by MonitorsPanel after a successful position write. Treats the
    // new live position as intentional so a boot restore cannot undo it, and
    // refreshes immediately instead of waiting for the 20 s poll.
    function noteUserMove(id) {
        root._restoredAtBoot = true;
        if (root._pendingRestore[id] !== undefined) {
            const pending = Object.assign({}, root._pendingRestore);
            delete pending[id];
            root._pendingRestore = pending;
        }
        const seen = Object.assign({}, root._seenIds);
        seen[id] = true;
        root._seenIds = seen;
    }

    function refreshNow() {
        root._ensureLayoutLoaded();
        root._pollLayout();
    }

    function _restorePosition(comp, id, pos) {
        let argv;
        if (comp === "niri") {
            // The "--" is required: niri parses a leading "-" as an option,
            // so negative coordinates fail without it.
            argv = ["niri", "msg", "output", id, "position", "set", "--",
                String(pos.x), String(pos.y)];
        } else if (comp === "hyprland") {
            argv = ["hyprctl", "keyword", "monitor",
                id + ",position," + pos.x + "," + pos.y];
        } else {
            // Same shape MonitorsPanel verified: cmd is a single token.
            argv = ["mangoctl", "output", id, "POSITION " + pos.x + " " + pos.y];
        }
        console.log("PerMonitorConfig: restoring", id, "to", pos.x + "," + pos.y);
        _spawn(argv, null);
    }

    // Persist the snapshot. Skips the write when nothing changed, so the
    // 20 s poll does not hammer the disk. Atomic via tmp + rename, same
    // pattern AgentStore uses for profiles.
    function _saveLayout(comp, live) {
        const json = JSON.stringify({ compositor: comp, outputs: live }, null, 2);
        if (json === root._savedJson)
            return;
        const script =
            "mkdir -p '" + layoutDir.replace(/'/g, "'\\''") + "' && " +
            "printf '%s' '" + json.replace(/'/g, "'\\''") + "' > '" +
            layoutPath.replace(/'/g, "'\\''") + ".tmp' && " +
            "mv '" + layoutPath.replace(/'/g, "'\\''") + ".tmp' '" +
            layoutPath.replace(/'/g, "'\\''") + "'";
        _spawn(["bash", "-c", script], ok => {
            // Only remember the serialized value after a successful write;
            // otherwise a failed save would never be retried.
            if (ok) {
                root._savedJson = json;
                // Keep the in-memory memory in sync: a cable re-plug later
                // in this session must restore the newest arrangement, not
                // the one from before the user moved anything.
                root._remembered = {
                    compositor: comp,
                    outputs: JSON.parse(JSON.stringify(live))
                };
            } else {
                console.warn("PerMonitorConfig: could not save", layoutPath);
            }
        });
    }

    // Fresh Process per call: Quickshell 0.3.0 does not reliably restart an
    // already-running Process, and the 20 s poll would otherwise collide
    // with a slow restore write. A Component factory instead of
    // Qt.createQmlObject: the inline-string version never fired its onExited
    // when spawned from this singleton, for reasons that were not worth
    // chasing once the factory worked.
    Component {
        id: procFactory
        Process {
            property var _onDone: null
            stdout: StdioCollector {}
            stderr: StdioCollector {}
            onExited: (code) => {
                let out = "", err = "";
                try { out = stdout ? stdout.text : ""; err = stderr ? stderr.text : ""; } catch (e) {}
                const cb = _onDone;
                _onDone = null;
                if (cb)
                    cb(code === 0, out, err);
                destroy();
            }
        }
    }

    function _spawn(argv, onDone) {
        const proc = procFactory.createObject(root, { _onDone: onDone });
        if (!proc) {
            console.warn("PerMonitorConfig: could not spawn", argv.join(" "));
            if (onDone)
                onDone(false, "", "");
            return null;
        }
        proc.command = argv;
        proc.running = true;
        return proc;
    }
}
