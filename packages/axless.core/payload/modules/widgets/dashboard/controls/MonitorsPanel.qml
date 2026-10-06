pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import qs.modules.theme
import qs.modules.components
import qs.modules.globals
import qs.modules.services
import qs.config

/*
    MonitorsPanel.qml

    Output configuration driven through each compositor's own IPC, never
    through axctl. axctl is the wrong layer for this: its vocabulary is
    fixed, output configuration is not in it at all, and a mod cannot widen
    it because the Go backend and the axctl binary are both compiled.

        niri       niri msg --json outputs
                   niri msg output <name> {off|on|mode|scale|transform
                                          |position|vrr} ...
        hyprland   hyprctl monitors -j
                   hyprctl keyword monitor <name>,<key>,<value>
        mango      sway-style IPC over $MANGO_INSTANCE_SIGNATURE

    Per-compositor notes that shaped the code
    -----------------------------------------
    * An output that is off is still listed, but niri reports
      `current_mode: null` and `logical: null` for it. That pair is the only
      reliable "is on" signal, so `enabled` is derived from it rather than
      assumed.

    * niri reports `logical.width`/`logical.height` as the mode's pixel size,
      and positions in that same space: with a 1536-wide panel at scale 1.25
      the next output lands at x=1536, not 1229. Hyprland is the opposite -
      `hyprctl` reports pixel dimensions plus a separate scale and positions
      in already-divided logical units. So logicalWidth/logicalHeight divide by
      scale for Hyprland and Mango, and not at all for niri. Using one rule for
      both misplaces every box on the canvas.

    * Data is read from the compositor, not from AxctlService.monitors, because
      AxctlService.qml does `id: parseInt(mon.id) || 0` and niri's monitor ids
      are names like "eDP-1", so parseInt yields NaN and every monitor reads
      back as id 0.

    * AxctlService.compositorName is not trusted verbatim either: Ambxst's
      probe assigns stdout without checking whether the call failed, so with
      axctl down it captures the client's error text as the name.

    Changes are runtime-only. Nothing here writes a compositor config file, so
    values reset when the compositor restarts.
*/
Item {
    id: root

    property int maxContentWidth: 640
    readonly property int contentWidth: Math.min(width, maxContentWidth)

    // False when hosted as a subsection of the compositor panel, which
    // already renders its own PanelTitlebar; keeping both would show the same
    // title twice.
    property bool showHeader: true

    // Set by the compositor panel when embedded there. Sections are toggled
    // with `visible`, so root.visible stays true while another subsection
    // shows; this is what lets the poll timer stand down.
    property bool embedded: false
    property string currentSection: ""

    // ── Backend ─────────────────────────────────────────────────────────
    readonly property var knownCompositors: ["hyprland", "niri", "mango"]

    readonly property string reported: {
        const n = (AxctlService.compositorName || "").toLowerCase();
        return knownCompositors.indexOf(n) >= 0 ? n : "";
    }

    property string _detected: ""
    readonly property string compositor: reported !== "" ? reported : _detected
    readonly property bool resolved: reported !== "" || _detected !== ""

    readonly property bool niri: compositor === "niri"
    readonly property bool hyprland: compositor === "hyprland"
    readonly property bool mango: compositor === "mango"
    readonly property bool supported: niri || hyprland || mango

    /*
        Whether `logical.width`/`logical.height` are already in the space the
        compositor positions outputs in. True for niri, false for Hyprland and
        Mango, whose clients report pixel dimensions plus a scale.
    */
    readonly property bool pixelsAreLogical: niri

    // ── State ───────────────────────────────────────────────────────────
    property var outputs: []
    property int selectedIndex: 0
    property string errorText: ""
    property bool loading: false

    // Per-output write state, keyed by output name: { busy: bool, error: "" }.
    // Without this the only feedback is one shared title, so a rejected change
    // on one output looks like it belongs to another.
    property var perOutput: ({})

    // Collapsed state per output, so a long mode list does not bury the
    // controls of the other outputs. NothingLess' MonitorCard collapses the
    // same way.
    property var collapsed: ({})

    // Highlighted output for the Identify action, as a name rather than an
    // index so it survives the list being re-read.
    property string identifyTarget: ""

    readonly property var scaleOptions: [1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]

    function busyFor(id) {
        const s = perOutput[id];
        return !!(s && s.busy);
    }

    function errorFor(id) {
        const s = perOutput[id];
        return (s && s.error) ? s.error : "";
    }

    function isCollapsed(id) {
        return collapsed[id] === true;
    }

    function setPerOutput(id, patch) {
        const next = Object.assign({}, perOutput);
        next[id] = Object.assign({}, next[id] || {}, patch);
        perOutput = next;
    }

    function clearPerOutput(id) {
        if (perOutput[id] === undefined)
            return;
        const next = Object.assign({}, perOutput);
        delete next[id];
        perOutput = next;
    }

    function isIdentifying(id) {
        return identifyTarget === id;
    }

    // ═══════════════════════════════════════════════════════════════════
    // Process plumbing
    // ═══════════════════════════════════════════════════════════════════
    //
    // Each call needs its import on its own line; the QML parser rejects
    // "import A; import B; Process {". Quickshell's Process emits
    // `exited(code, status)` - `finished` is not a signal.

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
                root, "monProc");
        } catch (e) {
            console.warn("MonitorsPanel: could not spawn", argv.join(" "), e);
            root.errorText = I18n.t("mp.spawn_failed");
            if (onDone)
                onDone(false, "", "");
            return null;
        }
        proc.exited.connect(function (exitCode) {
            let out = "";
            let err = "";
            try {
                out = proc.stdout ? proc.stdout.text : "";
                err = proc.stderr ? proc.stderr.text : "";
            } catch (e) {
                out = "";
                err = "";
            }
            proc.destroy();
            if (onDone)
                onDone(exitCode === 0, out, err);
        });
        proc.running = true;
        return proc;
    }

    // ═══════════════════════════════════════════════════════════════════
    // Read
    // ═══════════════════════════════════════════════════════════════════

    function refresh() {
        root.errorText = "";
        if (root.reported === "" && root._detected === "") {
            // Ambxst has not named the compositor yet, or named it with
            // axctl's error text. Probe the clients instead.
            root._probeFrom(0);
            root._probeTimer.restart();
            return;
        }
        if (!root.supported) {
            root.outputs = [];
            return;
        }
        root.loading = true;
        if (root.niri)
            _readNiri();
        else if (root.hyprland)
            _readHyprland();
        else if (root.mango)
            _readMango();
    }

    function _finishRead(list, err, fallback) {
        root.loading = false;
        if (err) {
            root.errorText = err;
            root.outputs = [];
            return;
        }
        root.outputs = list;
        // Keep the selection on a real row: the list can shrink when an
        // output disappears, and an out-of-range index would silently
        // deselect everything.
        if (root.selectedIndex >= list.length)
            root.selectedIndex = Math.max(0, list.length - 1);
        // Drop per-output state for outputs that are gone, so a re-plugged
        // monitor does not inherit a stale error.
        const present = {};
        for (let i = 0; i < list.length; i++)
            present[list[i].id] = true;
        const nextPer = {};
        for (const k in root.perOutput) {
            if (present[k])
                nextPer[k] = root.perOutput[k];
        }
        if (Object.keys(nextPer).length !== Object.keys(root.perOutput).length)
            root.perOutput = nextPer;
    }

    function _readNiri() {
        _run(["niri", "msg", "--json", "outputs"], (ok, out, err) => {
            if (!ok) {
                root._finishRead([], (err || "").trim() || I18n.t("mp.read_failed"));
                return;
            }
            let data;
            try {
                data = JSON.parse(out);
            } catch (e) {
                root._finishRead([], I18n.t("mp.bad_payload"));
                return;
            }
            const list = [];
            for (const key in data) {
                const o = data[key];
                if (!o)
                    continue;
                // An output that is off still appears in the list, but with
                // current_mode and logical set to null. That is the signal.
                const live = o.logical !== null && o.logical !== undefined;
                const modeIndex = (o.current_mode === null || o.current_mode === undefined)
                    ? -1 : o.current_mode;
                const current = (modeIndex >= 0 && o.modes && o.modes[modeIndex]) ? o.modes[modeIndex] : null;
                list.push({
                    id: o.name || key,
                    make: o.make || "",
                    model: o.model || "",
                    serial: o.serial || "",
                    enabled: live,
                    width: live ? (o.logical.width || 0) : 0,
                    height: live ? (o.logical.height || 0) : 0,
                    refreshRate: current ? current.refresh_rate / 1000 : 0,
                    modes: (o.modes || []).map(m => ({
                        width: m.width,
                        height: m.height,
                        refresh: m.refresh_rate / 1000,
                        preferred: !!m.is_preferred
                    })),
                    scale: live ? (o.logical.scale || 1) : 1,
                    transform: live ? (o.logical.transform || "Normal") : "normal",
                    x: live ? (o.logical.x || 0) : 0,
                    y: live ? (o.logical.y || 0) : 0,
                    vrrSupported: !!o.vrr_supported,
                    vrrEnabled: !!o.vrr_enabled,
                    physicalW: (o.physical_size && o.physical_size[0]) || 0,
                    physicalH: (o.physical_size && o.physical_size[1]) || 0
                });
            }
            list.sort((a, b) => (a.id < b.id ? -1 : (a.id > b.id ? 1 : 0)));
            root._finishRead(list, "");
        });
    }

    function _readHyprland() {
        _run(["hyprctl", "monitors", "-j"], (ok, out, err) => {
            if (!ok) {
                root._finishRead([], (err || "").trim() || I18n.t("mp.read_failed"));
                return;
            }
            let data;
            try {
                data = JSON.parse(out);
            } catch (e) {
                root._finishRead([], I18n.t("mp.bad_payload"));
                return;
            }
            root._finishRead((data || []).map(o => ({
                id: o.name,
                make: o.make || "",
                model: o.model || "",
                serial: o.serial || "",
                enabled: o.disabled !== true,
                width: o.width || 0,
                height: o.height || 0,
                refreshRate: o.refreshRate || 0,
                modes: (o.modes || []).map(m => ({
                    width: m.width,
                    height: m.height,
                    refresh: m.refresh || 0,
                    preferred: !!m.preferred
                })),
                scale: o.scale || 1,
                transform: o.transform || 0,
                x: o.x || 0,
                y: o.y || 0,
                vrrSupported: !!o.vrr,
                // hyprctl reports whether VRR is supported but not whether it
                // is currently on, so keep whatever we last asked for rather
                // than pretending to read it back.
                vrrEnabled: !!o.vrr && (root.perOutput[o.name] ? root.perOutput[o.name].vrrRequested === true : false),
                physicalW: 0,
                physicalH: 0
            })), "");
        });
    }

    function _readMango() {
        // Mango speaks the sway IPC protocol over a socket named after
        // $MANGO_INSTANCE_SIGNATURE. Not verifiable on this machine: Mango is
        // not installed. Report that instead of pretending the read worked.
        const sig = Quickshell.env("MANGO_INSTANCE_SIGNATURE");
        if (!sig || sig === "") {
            root._finishRead([], I18n.t("mp.mango_no_signature"));
            return;
        }
        _run(["mangoctl", "-j", "get_outputs"], (ok, out, err) => {
            if (!ok) {
                root._finishRead([], (err || "").trim() || I18n.t("mp.read_failed"));
                return;
            }
            let data;
            try {
                data = JSON.parse(out);
            } catch (e) {
                root._finishRead([], I18n.t("mp.bad_payload"));
                return;
            }
            root._finishRead((data || []).map(o => ({
                id: o.name,
                make: o.make || "",
                model: o.model || "",
                serial: o.serial || "",
                enabled: o.active !== false,
                width: o.width || 0,
                height: o.height || 0,
                refreshRate: o.refresh || 0,
                modes: (o.modes || []).map(m => ({
                    width: m.width,
                    height: m.height,
                    refresh: m.refresh || 0,
                    preferred: !!m.preferred
                })),
                scale: o.scale || 1,
                transform: o.transform || 0,
                x: o.x || 0,
                y: o.y || 0,
                vrrSupported: false,
                vrrEnabled: false,
                physicalW: 0,
                physicalH: 0
            })), "");
        });
    }

    // ═══════════════════════════════════════════════════════════════════
    // Write
    // ═══════════════════════════════════════════════════════════════════

    // Guards against a second write while one is in flight for the same
    // output. The canvas can emit a release per drag, and two concurrent
    // position writes would race and land wherever the compositor felt like.
    property var inFlight: ({})

    function apply(id, action, value) {
        if (root.inFlight[id]) {
            // The newest request wins: remember it and drop the old one.
            root.clearPerOutput(id);
        }
        root.inFlight = Object.assign({}, root.inFlight, (function () {
            const o = {};
            o[id] = true;
            return o;
        })());
        root.setPerOutput(id, { busy: true, error: "" });

        const done = (ok, out, err) => {
            const o = Object.assign({}, root.inFlight);
            delete o[id];
            root.inFlight = o;
            if (!ok) {
                const msg = (err || out || "").trim() || I18n.t("mp.write_failed");
                root.setPerOutput(id, { busy: false, error: msg });
                root.errorText = id + ": " + msg;
            } else {
                root.clearPerOutput(id);
            }
            // The compositor owns its state; re-read rather than guessing.
            Qt.callLater(root.refresh);
        };

        if (root.niri)
            _applyNiri(id, action, value, done);
        else if (root.hyprland)
            _applyHyprland(id, action, value, done);
        else if (root.mango)
            _applyMango(id, action, value, done);
        else
            done(false, "", I18n.t("mp.unsupported_compositor"));
    }

    function _modeString(m) {
        return m.width + "x" + m.height + "@" + Number(m.refresh).toFixed(3);
    }

    function _applyNiri(id, action, value, done) {
        let argv;
        switch (action) {
        case "off":
            argv = ["niri", "msg", "output", id, "off"];
            break;
        case "on":
            argv = ["niri", "msg", "output", id, "on"];
            break;
        case "mode":
            argv = ["niri", "msg", "output", id, "mode", String(value)];
            break;
        case "modeAuto":
            argv = ["niri", "msg", "output", id, "mode", "auto"];
            break;
        case "scale":
            argv = ["niri", "msg", "output", id, "scale", String(value)];
            break;
        case "scaleAuto":
            argv = ["niri", "msg", "output", id, "scale", "auto"];
            break;
        case "transform":
            argv = ["niri", "msg", "output", id, "transform", String(value)];
            break;
        case "position":
            argv = ["niri", "msg", "output", id, "position", "set", String(value.x), String(value.y)];
            break;
        case "positionAuto":
            argv = ["niri", "msg", "output", id, "position", "auto"];
            break;
        case "vrr":
            // Remembered because the Hyprland path cannot read it back; for
            // niri it is simply redundant with what the next read reports.
            root.setPerOutput(id, { vrrRequested: !!value });
            argv = ["niri", "msg", "output", id, "vrr", value ? "on" : "off"];
            break;
        default:
            done(false, "", I18n.t("mp.unknown_action"));
            return;
        }
        _run(argv, done);
    }

    function _applyHyprland(id, action, value, done) {
        // hyprctl takes `keyword monitor <name>,<keyword>,<value>`. Keyword
        // names differ from niri's verbs, so the mapping lives here and the UI
        // never branches on compositor.
        let spec;
        switch (action) {
        case "off": spec = "disable,1"; break;
        case "on": spec = "disable,0"; break;
        case "mode": spec = "resolution," + String(value); break;
        case "modeAuto": spec = "resolution,auto"; break;
        case "scale": spec = "scale," + String(value); break;
        case "scaleAuto": spec = "scale,auto"; break;
        case "transform": spec = "transform," + String(value); break;
        case "position": spec = "position," + String(value.x) + "," + String(value.y); break;
        case "positionAuto": spec = "position,auto"; break;
        case "vrr":
            root.setPerOutput(id, { vrrRequested: !!value });
            spec = "vrr," + (value ? "1" : "0");
            break;
        default:
            done(false, "", I18n.t("mp.unknown_action"));
            return;
        }
        _run(["hyprctl", "keyword", "monitor", id + "," + spec], done);
    }

    function _applyMango(id, action, value, done) {
        const map = {
            off: "POWER off",
            on: "POWER on",
            mode: "MODE " + String(value),
            modeAuto: "MODE auto",
            scale: "SCALE " + String(value),
            scaleAuto: "SCALE auto",
            transform: "TRANSFORM " + String(value),
            position: "POSITION " + String(value.x) + " " + String(value.y),
            positionAuto: "POSITION auto",
            vrr: "VRR " + (value ? "on" : "off")
        };
        const cmd = map[action];
        if (!cmd) {
            done(false, "", I18n.t("mp.unknown_action"));
            return;
        }
        root.setPerOutput(id, { vrrRequested: action === "vrr" ? !!value : false });
        _run(["mangoctl", "output", id, cmd], done);
    }

    // ═══════════════════════════════════════════════════════════════════
    // Identify
    // ═══════════════════════════════════════════════════════════════════

    // Neither niri nor hyprctl expose a "flash this output" verb, so
    // Identify highlights the output on the arrangement canvas for a couple of
    // seconds instead. That is honest and it is the thing you actually want
    // when two monitors look alike.
    property Timer _identifyTimer: Timer {
        interval: 2200
        onTriggered: root.identifyTarget = ""
    }

    function identify(id) {
        root.selectedIndex = Math.max(0, root.outputs.findIndex(o => o.id === id));
        root.identifyTarget = id;
        root._identifyTimer.restart();
    }

    // ═══════════════════════════════════════════════════════════════════
    // Lifecycle
    // ═══════════════════════════════════════════════════════════════════

    Component.onCompleted: {
        if (root.embedded && root.currentSection !== "" && root.currentSection !== "monitors")
            return;
        root.refresh();
    }

    Timer {
        id: _probeTimer
        interval: 1500
        repeat: true
        onTriggered: {
            if (root.resolved) {
                _probeTimer.stop();
                root.refresh();
            }
        }
    }

    readonly property var probeTable: [
        { name: "niri", argv: ["niri", "msg", "--json", "outputs"] },
        { name: "hyprland", argv: ["hyprctl", "monitors", "-j"] },
        { name: "mango", argv: ["mangoctl", "-j", "get_outputs"] }
    ]

    // Sequential on purpose: launching all three at once would race on
    // root._detected and report whichever answers last, not first.
    function _probeFrom(index) {
        if (root._detected !== "" || root.reported !== "")
            return;
        if (index >= root.probeTable.length)
            return;
        const p = root.probeTable[index];
        _run(p.argv, (ok) => {
            if (ok)
                root._detected = p.name;
            else
                root._probeFrom(index + 1);
        });
    }

    Connections {
        target: AxctlService
        function onCompositorNameChanged() {
            if (root.reported !== "")
                Qt.callLater(root.refresh);
        }
    }

    // Outputs change on their own - a lid opens, a cable is plugged in - so a
    // poll keeps the list honest without a subscription on every backend. It
    // stands down when the panel is not the visible subsection.
    Timer {
        interval: 4000
        repeat: true
        running: root.supported && root.visible
            && (!root.embedded || root.currentSection === "monitors")
        onTriggered: {
            // Do not re-read while a write is in flight: the read can land
            // between the compositor applying a change and our own
            // bookkeeping, and flicker the controls back to the old value.
            if (Object.keys(root.inFlight).length === 0)
                root.refresh();
        }
    }

    // ── Arrangement canvas ───────────────────────────────────────────────
    //
    // Appearance and interaction taken from NothingLess's
    // MonitorArrangementView. Kept as a separate component because it is
    // self-contained geometry and it keeps this file's card layout readable.
    component ArrangementView: StyledRect {
        id: av
        required property var monitors
        property int selectedIndex: 0

        // Output name currently flashed by the Identify action. The others
        // dim so the identified one is unambiguous.
        property string identifying: ""

        signal monitorMoved(int idx, int newX, int newY)
        signal monitorSelected(int idx)

        variant: "pane"
        radius: Styling.radius(0)
        enableShadow: true
        Layout.preferredHeight: Math.max(150, Math.min(320, canvasArea.implicitHeight + 16))

        // Logical size of an output, accounting for rotation and scale.
        function logicalWidth(m) {
            if (!m)
                return 1920;
            const rot = isRotated(m.transform);
            const px = rot ? (m.height || 1080) : (m.width || 1920);
            return px / (av.pixelsAreLogical ? 1 : (m.scale || 1.0));
        }

        function logicalHeight(m) {
            if (!m)
                return 1080;
            const rot = isRotated(m.transform);
            const px = rot ? (m.width || 1920) : (m.height || 1080);
            return px / (av.pixelsAreLogical ? 1 : (m.scale || 1.0));
        }

        // niri reports the transform as a name ("Normal", "90", "flipped-90"),
        // Hyprland as a number (0, 1, 3...). Treat both the same way.
        function isRotated(t) {
            if (t === undefined || t === null)
                return false;
            const s = String(t).toLowerCase();
            if (s === "90" || s === "270" || s === "180")
                return true;
            if (s.indexOf("flipped-") === 0)
                return true;
            if (typeof t === "number")
                return t === 1 || t === 3 || t === 5 || t === 7;
            return false;
        }

        property var viewBounds: ({ minX: -100, minY: -100, maxX: 100, maxY: 100, spanW: 200, spanH: 200 })
        property real viewScale: 0.1

        /*
            Whether logical.width/height are already in the space the
            compositor positions outputs in.

            niri: yes. It reports logical.width in pixels and positions in
            that same space, so a 1536 px panel at scale 1.25 puts the next
            output at x=1536. Dividing by scale here would draw that panel
            1229 px wide and, worse, aim the snap targets at the wrong
            edges - dropping a monitor "next to" it would land inside it
            and the overlap resolution would shove it away again.

            Hyprland and Mango: no. Their clients report pixel dimensions
            plus a separate scale and position in already-divided logical
            units, so the division is required.
        */
        required property bool pixelsAreLogical


        // Height follows width; width also drives the scale. Both are done in
        // the single onWidthChanged handler further down.

        /*
            Snap thresholds, in logical pixels.

            NothingLess states them in canvas pixels and divides by
            viewScale, which makes the threshold grow without bound as the
            canvas zooms out. On a 3656 px wide desktop the canvas lands
            near 0.11, so 15 / 0.11 = 132 logical px while dragging and 220
            on release. Any monitor dropped within 220 px of a neighbour was
            yanked flush against it, which is why two screens could not be
            left a few pixels apart - and the yank got worse the larger the
            desktop.

            So the canvas-pixel figure is converted to logical units and then
            capped. 24 px is a little under two steps of the 10 px grid,
            which is enough to feel magnetic without taking the placement over.
        */
        // Kept deliberately tight. A wide release threshold swallows small
        // deliberate gaps - drop a monitor 30 px away from its neighbour and
        // a 40 px threshold snaps it flush, which reads as "it won't let me
        // place them". 16 px while dragging is enough to feel magnetic, and
        // 24 px on release locks a near-edge drop without overruling it.
        readonly property int snapDragLogical: 16
        readonly property int snapReleaseLogical: 24

        function snapDistance(canvasPx, capLogical) {
            return Math.max(2, Math.min(canvasPx / av.viewScale, capLogical));
        }

        function recalcBounds() {
            const list = av.monitors || [];
            if (list.length === 0)
                return;
            let minX = Infinity;
            let minY = Infinity;
            let maxX = -Infinity;
            let maxY = -Infinity;
            for (let i = 0; i < list.length; i++) {
                const m = list[i];
                const w = av.logicalWidth(m);
                const h = av.logicalHeight(m);
                const x = m.x || 0;
                const y = m.y || 0;
                minX = Math.min(minX, x);
                minY = Math.min(minY, y);
                maxX = Math.max(maxX, x + w);
                maxY = Math.max(maxY, y + h);
            }
            const margin = 100;
            av.viewBounds = {
                minX: minX - margin,
                minY: minY - margin,
                maxX: maxX + margin,
                maxY: maxY + margin,
                spanW: Math.max((maxX + margin) - (minX - margin), 1),
                spanH: Math.max((maxY + margin) - (minY - margin), 1)
            };
            av.recalcScale();
        }

        function recalcScale() {
            const cw = canvasArea.width;
            const ch = canvasArea.height;
            if (cw <= 0 || ch <= 0)
                return;
            const vb = av.viewBounds;
            av.viewScale = Math.min((cw - 20) / vb.spanW, (ch - 20) / vb.spanH);
        }

        /*
            Horizontal limits for a drag.

            A monitor may sit entirely to the left of everything or entirely
            to the right of everything, but it cannot be flung out into empty
            space beyond the arrangement: a single flick would throw it
            hundreds of pixels off with nothing to scroll back to.

            Vertical placement is deliberately unbounded. Desktops are wide
            and short, lining one monitor up under another is a normal thing
            to want, and the canvas scrolls to follow.
        */
        function xBounds(idx, ownW) {
            let lo = Infinity;
            let hi = -Infinity;
            const list = av.monitors || [];
            for (let k = 0; k < list.length; k++) {
                if (k === idx || !list[k].enabled)
                    continue;
                lo = Math.min(lo, list[k].x);
                hi = Math.max(hi, list[k].x + av.logicalWidth(list[k]));
            }
            if (!isFinite(lo) || !isFinite(hi)) {
                // A single output has no neighbours to be relative to.
                return { min: -ownW * 4, max: ownW * 4 };
            }
            return { min: lo - ownW, max: hi };
        }

        function realToCanvasX(rx) { return (rx - av.viewBounds.minX) * av.viewScale + 10; }
        function realToCanvasY(ry) { return (ry - av.viewBounds.minY) * av.viewScale + 10; }

        onMonitorsChanged: recalcBounds()

        Component.onCompleted: recalcBounds()

        // One handler only: two onWidthChanged assignments in the same
        // component are rejected with "Property value set multiple times".
        onWidthChanged: recalcScale()
        onHeightChanged: recalcScale()

        Item {
            id: canvasArea
            anchors.fill: parent
            anchors.margins: 8
            implicitHeight: 250
            clip: true

            StyledRect {
                anchors.fill: parent
                variant: "internalbg"
                radius: Styling.radius(-2)
            }

            Item {
                id: scrollBox
                width: Math.max(parent.width, av.viewBounds.spanW * av.viewScale + 20)
                height: Math.max(parent.height, av.viewBounds.spanH * av.viewScale + 20)

                Repeater {
                    id: gridWRep
                    model: Math.floor(av.viewBounds.spanW / 500) + 2
                    delegate: Rectangle {
                        required property int index
                        x: av.realToCanvasX(av.viewBounds.minX + index * 500)
                        y: 0
                        width: 1
                        height: scrollBox.height
                        color: Qt.rgba(Colors.outlineVariant.r, Colors.outlineVariant.g, Colors.outlineVariant.b, 0.06)
                    }
                }

                Repeater {
                    id: gridHRep
                    model: Math.floor(av.viewBounds.spanH / 500) + 2
                    delegate: Rectangle {
                        required property int index
                        x: 0
                        y: av.realToCanvasY(av.viewBounds.minY + index * 500)
                        width: scrollBox.width
                        height: 1
                        color: Qt.rgba(Colors.outlineVariant.r, Colors.outlineVariant.g, Colors.outlineVariant.b, 0.06)
                    }
                }

                // Origin marker, so relative placement is readable.
                StyledRect {
                    x: av.realToCanvasX(0) - 4
                    y: av.realToCanvasY(0) - 4
                    width: 8
                    height: 8
                    radius: 4
                    variant: "primary"
                    opacity: 0.6
                }

                Repeater {
                    model: av.monitors
                    delegate: Item {
                        id: monItem
                        required property int index
                        required property var modelData

                        property bool dragging: false
                        property real dragX: modelData.x
                        property real dragY: modelData.y

                        readonly property real rx: dragging ? dragX : modelData.x
                        readonly property real ry: dragging ? dragY : modelData.y
                        readonly property bool isSelected: av.selectedIndex === index

                        readonly property real logicalW: av.logicalWidth(modelData)
                        readonly property real logicalH: av.logicalHeight(modelData)

                        x: av.realToCanvasX(rx)
                        y: av.realToCanvasY(ry)
                        width: Math.max(50, logicalW * av.viewScale)
                        height: Math.max(35, logicalH * av.viewScale)
                        opacity: modelData.enabled ? 1.0 : 0.45

                        StyledRect {
                            anchors.fill: parent
                            variant: {
                                if (!monItem.modelData.enabled)
                                    return monItem.isSelected ? "focus" : "transparent";
                                return monItem.isSelected ? "primary" : "common";
                            }
                            radius: Styling.radius(-2)
                            enableShadow: monItem.modelData.enabled
                            border.width: monItem.isSelected ? 2 : 1
                            border.color: monItem.isSelected ? Styling.srItem("primary") : Colors.outlineVariant
                            // Dim the others while an output is being
                            // identified, so it is unambiguous which one the
                            // Identify button refers to.
                            opacity: {
                                if (!monItem.modelData.enabled)
                                    return 0.7;
                                if (av.identifying !== "" && av.identifying !== monItem.modelData.id)
                                    return 0.35;
                                return 1.0;
                            }
                        }

                        StyledRect {
                            anchors.top: parent.top
                            anchors.left: parent.left
                            anchors.margins: 4
                            width: indexBadge.implicitWidth + 8
                            height: 16
                            radius: 8
                            variant: monItem.isSelected ? "primary" : "internalbg"

                            Text {
                                id: indexBadge
                                anchors.centerIn: parent
                                text: (monItem.index + 1).toString()
                                font.family: Config.theme.font
                                font.pixelSize: Math.max(7, Math.min(10, Styling.fontSize(-4)))
                                font.bold: true
                                color: monItem.isSelected ? Styling.srItem("primary") : Colors.outline
                            }
                        }

                        Column {
                            anchors.centerIn: parent
                            spacing: 1

                            Text {
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: monItem.modelData.id
                                font.family: Config.theme.font
                                font.pixelSize: Math.max(8, Math.min(11, Styling.fontSize(-3)))
                                font.bold: true
                                color: monItem.isSelected ? Styling.srItem("primary") : Colors.overBackground
                            }
                            Text {
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: Math.round(monItem.logicalW) + "×" + Math.round(monItem.logicalH)
                                      + " @ " + Math.round(monItem.modelData.refreshRate || 60) + "Hz"
                                font.family: Config.theme.font
                                font.pixelSize: Math.max(7, Math.min(10, Styling.fontSize(-4)))
                                color: Colors.outline
                            }
                            Text {
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: Math.round(monItem.rx) + "," + Math.round(monItem.ry)
                                      + " · " + (monItem.modelData.scale || 1.0).toFixed(2) + "×"
                                font.family: Config.theme.font
                                font.pixelSize: Math.max(7, Math.min(10, Styling.fontSize(-4)))
                                color: Colors.outline
                            }
                        }

                        StyledRect {
                            anchors.right: parent.right
                            anchors.bottom: parent.bottom
                            anchors.margins: 4
                            width: 18
                            height: 18
                            radius: 4
                            variant: monItem.isSelected ? "primary" : "internalbg"
                            visible: monItem.modelData.enabled

                            Text {
                                anchors.centerIn: parent
                                text: Icons.arrowsOutCardinal
                                font.family: Icons.font
                                font.pixelSize: 10
                                color: monItem.isSelected ? Styling.srItem("primary") : Colors.outline
                            }
                        }

                        MouseArea {
                            id: dragArea
                            anchors.fill: parent
                            cursorShape: Qt.SizeAllCursor
                            hoverEnabled: true
                            enabled: monItem.modelData.enabled

                            property real pcx: 0
                            property real pcy: 0
                            property real srx: 0
                            property real sry: 0

                            onPressed: function (mouse) {
                                monItem.z = 100;
                                monItem.dragging = true;
                                pcx = mouse.x + monItem.x;
                                pcy = mouse.y + monItem.y;
                                srx = monItem.modelData.x;
                                sry = monItem.modelData.y;
                                av.monitorSelected(monItem.index);
                            }
                            onPositionChanged: function (mouse) {
                                if (!monItem.dragging)
                                    return;
                                const dRX = ((mouse.x + monItem.x) - pcx) / av.viewScale;
                                const dRY = ((mouse.y + monItem.y) - pcy) / av.viewScale;
                                let newX = Math.round((srx + dRX) / 10) * 10;
                                let newY = Math.round((sry + dRY) / 10) * 10;
                                const mw = monItem.logicalW;
                                const mh = monItem.logicalH;
                                const snapPx = av.snapDistance(15, av.snapDragLogical);

                                const list = av.monitors || [];
                                // X is clamped to the arrangement; Y is free.
                                const bounds = av.xBounds(monItem.index, mw);
                                for (let k = 0; k < list.length; k++) {
                                    if (k === monItem.index || !list[k].enabled)
                                        continue;
                                    const o = list[k];
                                    const ox = o.x;
                                    const oy = o.y;
                                    const ow = av.logicalWidth(o);
                                    const oh = av.logicalHeight(o);
                                    if (Math.abs(newX - (ox + ow)) < snapPx) newX = ox + ow;
                                    if (Math.abs((newX + mw) - ox) < snapPx) newX = ox - mw;
                                    if (Math.abs(newY - (oy + oh)) < snapPx) newY = oy + oh;
                                    if (Math.abs((newY + mh) - oy) < snapPx) newY = oy - mh;
                                    if (Math.abs(newX - ox) < snapPx) newX = ox;
                                    if (Math.abs(newY - oy) < snapPx) newY = oy;
                                }
                                monItem.dragX = Math.max(bounds.min, Math.min(bounds.max, newX));
                                // No vertical clamp: stacking a monitor under another is
                                monItem.dragY = newY;
                            }
                            onReleased: function () {
                                if (!monItem.dragging)
                                    return;
                                monItem.dragging = false;
                                monItem.z = 1;
                                let rx = monItem.dragX;
                                let ry = monItem.dragY;
                                const mw = monItem.logicalW;
                                const mh = monItem.logicalH;
                                const snapPx = av.snapDistance(25, av.snapReleaseLogical);
                                const list = av.monitors || [];

                                for (let k = 0; k < list.length; k++) {
                                    if (k === monItem.index || !list[k].enabled)
                                        continue;
                                    const o = list[k];
                                    const ox = o.x;
                                    const oy = o.y;
                                    const ow = av.logicalWidth(o);
                                    const oh = av.logicalHeight(o);
                                    if (Math.abs(rx - (ox + ow)) < snapPx) rx = ox + ow;
                                    if (Math.abs((rx + mw) - ox) < snapPx) rx = ox - mw;
                                    if (Math.abs(ry - (oy + oh)) < snapPx) ry = oy + oh;
                                    if (Math.abs((ry + mh) - oy) < snapPx) ry = oy - mh;
                                    if (Math.abs(rx - ox) < snapPx) rx = ox;
                                    if (Math.abs(ry - oy) < snapPx) ry = oy;
                                }

                                // Resolve overlaps by pushing along the
                                // smallest penetration axis, so a drop that
                                // lands on another output never leaves two
                                // monitors fighting for the same pixels.
                                for (let j = 0; j < list.length; j++) {
                                    if (j === monItem.index || !list[j].enabled)
                                        continue;
                                    const o2 = list[j];
                                    const o2w = av.logicalWidth(o2);
                                    const o2h = av.logicalHeight(o2);
                                    if (rx < o2.x + o2w && rx + mw > o2.x && ry < o2.y + o2h && ry + mh > o2.y) {
                                        const dL = rx + mw - o2.x;
                                        const dR = o2.x + o2w - rx;
                                        const dU = ry + mh - o2.y;
                                        const dD = o2.y + o2h - ry;
                                        const d = Math.min(dL, dR, dU, dD);
                                        if (d === dL) rx = o2.x - mw;
                                        else if (d === dR) rx = o2.x + o2w;
                                        else if (d === dU) ry = o2.y - mh;
                                        else ry = o2.y + o2h;
                                    }
                                }

                                const finalBounds = av.xBounds(monItem.index, mw);
                                rx = Math.round(Math.max(finalBounds.min, Math.min(finalBounds.max, rx)) / 10) * 10;
                                // Rounded to the 10 px grid, never clamped on Y.
                                ry = Math.round(ry / 10) * 10;
                                av.monitorMoved(monItem.index, rx, ry);
                            }
                        }
                    }
                }
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    // Reusable components
    // ═══════════════════════════════════════════════════════════════════

    component Label: Text {
        font.family: Config.theme.font
        font.pixelSize: Styling.fontSize(-1)
        color: Colors.overSurfaceVariant
    }

    component SmallButton: StyledRect {
        id: btn
        required property string text
        property bool active: false
        property bool enabled: true
        property real horizontalPadding: 24
        signal clicked()

        visible: enabled
        opacity: enabled ? 1.0 : 0.45
        variant: active ? "primaryfocus" : (hover.hovered ? "focus" : "pane")
        radius: Styling.radius(2)
        implicitWidth: Math.max(48, label.implicitWidth + horizontalPadding)
        implicitHeight: 32

        Text {
            id: label
            anchors.centerIn: parent
            text: btn.text
            font.family: Config.theme.font
            font.pixelSize: Styling.fontSize(-1)
            color: btn.active ? Colors.overBackground : Colors.overBackground
        }

        HoverHandler {
            id: hover
            enabled: btn.enabled
            cursorShape: Qt.PointingHandCursor
        }
        TapHandler {
            enabled: btn.enabled
            onTapped: btn.clicked()
        }
    }

    component IntField: StyledRect {
        id: fld
        required property string label
        property int value: 0
        property int minValue: -100000
        property int maxValue: 100000
        property bool enabled: true
        signal edited(int newValue)

        opacity: enabled ? 1.0 : 0.5
        variant: "pane"
        radius: Styling.radius(2)
        Layout.preferredWidth: 150
        implicitHeight: 34

        RowLayout {
            anchors.fill: parent
            anchors.margins: 8
            spacing: 8

            Label {
                text: fld.label
                Layout.fillWidth: true
            }

            TextInput {
                id: ti
                enabled: fld.enabled
                text: String(fld.value)
                color: Colors.overBackground
                font.family: Config.theme.font
                font.pixelSize: Styling.fontSize(0)
                selectByMouse: true
                horizontalAlignment: Text.AlignRight
                validator: IntValidator {
                    bottom: fld.minValue
                    top: fld.maxValue
                }
                onEditingFinished: fld.edited(parseInt(text))
                Keys.onEscapePressed: text = String(fld.value)
            }
        }
    }

    component ScaleField: StyledRect {
        id: fld
        property real value: 1.0
        property var options: [1.0, 1.25, 1.5, 1.75, 2.0]
        signal picked(real newValue)

        variant: "pane"
        radius: Styling.radius(2)
        Layout.fillWidth: true
        implicitHeight: 34

        RowLayout {
            anchors.fill: parent
            anchors.margins: 6
            spacing: 6

            Repeater {
                model: fld.options
                delegate: SmallButton {
                    required property var modelData
                    text: String(modelData)
                    active: Math.abs(modelData - fld.value) < 0.001
                    horizontalPadding: 16
                    implicitWidth: 48
                    implicitHeight: 26
                    onClicked: fld.picked(modelData)
                }
            }
        }
    }

    /*
        One output. Collapsed it shows identity, size, refresh, scale and the
        on/off state; expanded it shows mode, transform, position and VRR.

        Collapsing matters with this data: a 27" panel exposes 39 modes, and
        with every mode rendered as a chip the list becomes unusable.
    */
    component OutputCard: StyledRect {
        id: card
        required property var output
        required property var root_

        readonly property bool open: !card.root_.isCollapsed(card.output.id)
        readonly property bool busy: card.root_.busyFor(card.output.id)
        readonly property string err: card.root_.errorFor(card.output.id)
        readonly property bool identifying: card.root_.isIdentifying(card.output.id)

        variant: identifying ? "focus" : "pane"
        radius: Styling.radius(0)
        enableShadow: true
        Layout.fillWidth: true
        Layout.preferredHeight: body.implicitHeight + 24

        // Header: click to expand/collapse.
        MouseArea {
            id: headerTap
            anchors.fill: parent
            anchors.bottomMargin: body.height + 12
            cursorShape: Qt.PointingHandCursor
            onClicked: {
                const next = Object.assign({}, card.root_.collapsed);
                if (card.open)
                    next[card.output.id] = true;
                else
                    delete next[card.output.id];
                card.root_.collapsed = next;
            }
        }

        ColumnLayout {
            id: body
            anchors.fill: parent
            anchors.margins: 12
            spacing: 10

            // ── Header row ──────────────────────────────────────────
            RowLayout {
                Layout.fillWidth: true
                spacing: 12

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 1

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 8

                        Label {
                            text: card.identifying ? I18n.t("mp.identifying") : (card.output.make + " " + card.output.model)
                            font.pixelSize: Styling.fontSize(0)
                            color: Colors.overBackground
                        }

                        Label {
                            text: card.output.id
                            Layout.fillWidth: true
                        }
                    }

                    Label {
                        Layout.fillWidth: true
                        text: (card.output.enabled
                               ? card.output.width + "×" + card.output.height
                                 + " @ " + Number(card.output.refreshRate).toFixed(0) + " Hz"
                                 + "  ·  " + card.output.scale.toFixed(2) + "×"
                                 + "  ·  " + card.output.x + "," + card.output.y
                               : I18n.t("mp.off_state"))
                    }
                }

                SmallButton {
                    text: card.output.enabled ? I18n.t("mp.off") : I18n.t("mp.on")
                    active: card.output.enabled
                    onClicked: card.root_.apply(card.output.id, card.output.enabled ? "off" : "on")
                }

                SmallButton {
                    text: I18n.t("mp.identify")
                    enabled: card.output.enabled
                    onClicked: card.root_.identify(card.output.id)
                }

                Label {
                    text: card.open ? "▾" : "▸"
                    font.pixelSize: Styling.fontSize(0)
                    color: Colors.overSurfaceVariant
                }
            }

            // ── Per-output status ───────────────────────────────────
            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                visible: card.busy || card.err !== ""

                SmallButton {
                    text: I18n.t("mp.applying")
                    visible: card.busy
                    enabled: false
                }
                Label {
                    Layout.fillWidth: true
                    text: card.err
                    visible: card.err !== ""
                    color: Colors.error
                    wrapMode: Text.WordWrap
                }
            }

            // ── Expanded body ──────────────────────────────────────
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 10
                visible: card.open && card.output.enabled
                enabled: card.open && card.output.enabled && !card.busy

                // Mode
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 4
                    visible: card.output.modes.length > 1

                    Label {
                        text: I18n.t("mp.mode")
                    }
                    Flow {
                        Layout.fillWidth: true
                        spacing: 6

                        Repeater {
                            model: card.output.modes
                            delegate: SmallButton {
                                required property var modelData
                                // Not named `active`: SmallButton already
                                // declares that property, so a same-named
                                // local would both shadow it and bind to
                                // itself.
                                readonly property bool isCurrent: card.output.enabled
                                        && modelData.width === card.output.width
                                        && modelData.height === card.output.height
                                        && Math.abs(modelData.refresh - card.output.refreshRate) < 0.5
                                text: modelData.width + "×" + modelData.height + "@"
                                      + Number(modelData.refresh).toFixed(0)
                                      + (modelData.preferred ? " ★" : "")
                                active: isCurrent
                                onClicked: card.root_.apply(card.output.id, "mode",
                                    card.root_._modeString(modelData))
                            }
                        }

                        SmallButton {
                            text: I18n.t("mp.auto")
                            onClicked: card.root_.apply(card.output.id, "modeAuto")
                        }
                    }
                }

                // Scale
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 4

                    Label {
                        text: I18n.t("mp.scale")
                    }
                    ScaleField {
                        value: card.output.scale
                        options: card.root_.scaleOptions
                        onPicked: v => card.root_.apply(card.output.id, "scale", v)
                    }
                    SmallButton {
                        text: I18n.t("mp.scale_auto")
                        onClicked: card.root_.apply(card.output.id, "scaleAuto")
                    }
                }

                // Transform
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 4

                    Label {
                        text: I18n.t("mp.transform")
                    }
                    Flow {
                        Layout.fillWidth: true
                        spacing: 6

                        Repeater {
                            model: card.root_.niri
                                ? ["normal", "90", "180", "270", "flipped", "flipped-90", "flipped-180", "flipped-270"]
                                : [0, 1, 2, 3, 4, 5, 6, 7]
                            delegate: SmallButton {
                                required property var modelData
                                text: String(modelData)
                                active: String(card.output.transform).toLowerCase() === String(modelData).toLowerCase()
                                onClicked: card.root_.apply(card.output.id, "transform", modelData)
                            }
                        }
                    }
                }

                // Position
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8

                    Label {
                        text: I18n.t("mp.position")
                    }

                    IntField {
                        label: "X"
                        value: card.output.x
                        onEdited: v => card.root_.apply(card.output.id, "position", { x: v, y: card.output.y })
                    }

                    IntField {
                        label: "Y"
                        value: card.output.y
                        onEdited: v => card.root_.apply(card.output.id, "position", { x: card.output.x, y: v })
                    }

                    SmallButton {
                        text: I18n.t("mp.position_auto")
                        onClicked: card.root_.apply(card.output.id, "positionAuto")
                    }
                }

                // VRR
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    visible: card.output.vrrSupported

                    Label {
                        text: I18n.t("mp.vrr")
                        Layout.fillWidth: true
                    }

                    SmallButton {
                        text: card.output.vrrEnabled ? I18n.t("mp.enabled") : I18n.t("mp.disabled")
                        active: card.output.vrrEnabled
                        onClicked: card.root_.apply(card.output.id, "vrr", !card.output.vrrEnabled)
                    }
                }

                // Physical size, when the compositor reports it.
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    visible: card.output.physicalW > 0

                    Label {
                        text: I18n.t("mp.physical")
                    }
                    Label {
                        text: card.output.physicalW + " × " + card.output.physicalH + " mm"
                    }
                }

                Label {
                    Layout.fillWidth: true
                    text: I18n.t("mp.serial") + ": " + (card.output.serial || I18n.t("mp.unknown"))
                }
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    // UI
    // ═══════════════════════════════════════════════════════════════════

    Flickable {
        anchors.fill: parent
        contentHeight: page.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        ColumnLayout {
            id: page
            width: parent.width
            spacing: 12

            Item {
                Layout.fillWidth: true
                Layout.preferredHeight: titlebar.height
                visible: root.showHeader

                PanelTitlebar {
                    id: titlebar
                    width: root.contentWidth
                    anchors.horizontalCenter: parent.horizontalCenter
                    title: I18n.t("mp.title")
                    statusText: root.errorText !== "" ? root.errorText
                        : (root.loading ? I18n.t("mp.loading") : "")
                    statusColor: Colors.error

                    actions: [
                        {
                            icon: Icons.sync,
                            tooltip: I18n.t("ca.refresh"),
                            onClicked: function () {
                                root.refresh();
                            }
                        }
                    ]
                }
            }

            // Backend banner
            ColumnLayout {
                Layout.fillWidth: true
                Layout.leftMargin: 8
                Layout.rightMargin: 8
                spacing: 2

                Text {
                    Layout.fillWidth: true
                    text: root.supported
                        ? I18n.t("mp.backend") + " " + root.compositor
                            + (root.reported === "" ? I18n.t("mp.fallback_note") : "")
                        : (root.resolved ? I18n.t("mp.unsupported_compositor") : I18n.t("mp.detecting"))
                    font.family: Config.theme.font
                    font.pixelSize: Styling.fontSize(-2)
                    color: Colors.overSurfaceVariant
                    wrapMode: Text.WordWrap
                }

                Text {
                    Layout.fillWidth: true
                    text: I18n.t("mp.runtime_only")
                    font.family: Config.theme.font
                    font.pixelSize: Styling.fontSize(-2)
                    color: Colors.overSurfaceVariant
                    wrapMode: Text.WordWrap
                }
            }

            // Arrangement
            ArrangementView {
                Layout.fillWidth: true
                Layout.leftMargin: 8
                Layout.rightMargin: 8
                visible: root.outputs.length > 0
                monitors: root.outputs
                pixelsAreLogical: root.pixelsAreLogical
                selectedIndex: root.selectedIndex
                identifying: root.identifyTarget
                onMonitorSelected: idx => root.selectedIndex = idx
                onMonitorMoved: (idx, x, y) => {
                    const o = root.outputs[idx];
                    if (o)
                        root.apply(o.id, "position", { x: x, y: y });
                }
            }

            // Output cards
            ColumnLayout {
                Layout.fillWidth: true
                Layout.leftMargin: 8
                Layout.rightMargin: 8
                spacing: 12

                Repeater {
                    model: root.outputs
                    delegate: OutputCard {
                        required property var modelData
                        output: modelData
                        root_: root
                    }
                }
            }

            Text {
                Layout.fillWidth: true
                Layout.leftMargin: 8
                Layout.rightMargin: 8
                visible: root.supported && root.outputs.length === 0 && !root.loading
                text: I18n.t("mp.no_outputs")
                font.family: Config.theme.font
                font.pixelSize: Styling.fontSize(0)
                color: Colors.overSurfaceVariant
                wrapMode: Text.WordWrap
            }
        }
    }
}
