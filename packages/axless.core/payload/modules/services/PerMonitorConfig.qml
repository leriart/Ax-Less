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
    property bool _restoredAtBoot: false
    property string _savedJson: ""

    readonly property string _reported: {
        const n = (AxctlService.compositorName || "").toLowerCase();
        return _knownCompositors.indexOf(n) >= 0 ? n : "";
    }
    property string _detected: ""

    // The remembered layout file is written by this same service, so it is
    // read once at startup with a plain `cat` instead of a FileView: a
    // FileView warns on every cold boot when the file does not exist yet,
    // and a watch would re-parse our own writes.
    function _loadRemembered() {
        _spawn(["bash", "-c", "test -f '" + layoutPath + "' && cat '" + layoutPath + "'"],
            (ok, out) => {
                if (ok)
                    root._parseLayout(out);
            });
    }

    Timer {
        // Startup grace period: the compositor and the Ambxst daemon need a
        // moment before their IPC answers. 2.5 s, then the slow poll takes
        // over and performs the first restore.
        interval: 2500
        running: true
        onTriggered: {
            root._loadRemembered();
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
            if (ok)
                root._detected = p.name;
            else
                root._probeFrom(index + 1);
        });
    }

    function _parseLayout(text) {
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

    function _pollLayout() {
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
        const remembered = root._remembered;
        const seen = root._seenIds;
        for (const id in live) {
            const want = remembered ? remembered.outputs[id] : null;
            if (!want)
                continue;
            const differs = live[id].x !== want.x || live[id].y !== want.y;
            const appeared = seen[id] !== true;
            // Restore only while the layout is settling: at boot for every
            // output present from the start, and later for outputs that
            // reappear (re-plugged cable). An output that is present and
            // merely moved keeps its new position - the next save adopts
            // it as the new memory.
            if (differs && (appeared || !root._restoredAtBoot))
                root._restorePosition(comp, id, want);
        }
        root._restoredAtBoot = true;
        root._seenIds = (() => { const s = {}; for (const id in live) s[id] = true; return s; })();
        root._live = live;
        root._saveLayout(comp, live);
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
        root._savedJson = json;
        const script =
            "mkdir -p '" + layoutDir.replace(/'/g, "'\\''") + "' && " +
            "printf '%s' '" + json.replace(/'/g, "'\\''") + "' > '" + layoutPath + ".tmp' && " +
            "mv '" + layoutPath + ".tmp' '" + layoutPath + "'";
        _spawn(["bash", "-c", script], null);
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
