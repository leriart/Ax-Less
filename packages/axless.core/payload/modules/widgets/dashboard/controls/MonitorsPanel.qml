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

    Monitor configuration driven through each compositor's own IPC, not
    through axctl.

    axctl is the wrong layer for this. Its vocabulary is fixed: it accepts
    nine appearance keys, rejects anything else with "unsupported config
    key", and silently drops keys it does not recognise when rendering
    axctl.toml. Output configuration is not part of that vocabulary at all.

    Every supported compositor does expose its own complete output API, and
    that is what this panel talks to:

        niri       niri msg --json outputs
                   niri msg output <name> {off|on|mode|scale|transform
                                          |position|vrr} ...
        hyprland   hyprctl monitors -j
                   hyprctl keyword monitor <name>,<key>,<value>
        mango      sway-style IPC over $MANGO_INSTANCE_SIGNATURE

    Data is queried live rather than read from AxctlService.monitors, because
    that mapping is broken on niri: AxctlService.qml does
    `id: parseInt(mon.id) || 0`, and niri's monitor id is a string name
    ("eDP-1"), so every monitor comes back with id 0. Anything that compares
    monitor ids by equality is unreliable there.

    Changes are applied at runtime only. Nothing in this panel writes a
    compositor config file, and `niri msg output` states plainly that its
    changes are "temporary and not saved into the config file". Values reset
    when the compositor restarts.
*/
Item {
    id: root

    property int maxContentWidth: 640
    readonly property int contentWidth: Math.min(width, maxContentWidth)

    // ── Backend ─────────────────────────────────────────────────────────
    //
    // Normally taken from AxctlService.compositorName, which Ambxst probes
    // with `axctl system get-compositor`. That value is not trusted blindly:
    // the probe does `stdout.trim()` without checking whether the call
    // errored, so when axctl is not up it captures the client's error text
    // ("error connecting to daemon: ...") as the compositor name. Only the
    // three names Ambxst actually installs for are accepted.
    //
    // When the name is empty or unrecognised, one fallback probe tries each
    // client's own read command. That keeps the panel usable while axctl is
    // still starting, which is the common case on a cold boot.
    readonly property var knownCompositors: ["hyprland", "niri", "mango"]

    readonly property string reportedCompositor: {
        const n = (AxctlService.compositorName || "").toLowerCase();
        return knownCompositors.indexOf(n) >= 0 ? n : "";
    }

    property string _detected: ""
    readonly property string compositor: reportedCompositor !== "" ? reportedCompositor : _detected

    readonly property bool niri: compositor === "niri"
    readonly property bool hyprland: compositor === "hyprland"
    readonly property bool mango: compositor === "mango"
    readonly property bool supported: niri || hyprland || mango
    readonly property bool resolved: reportedCompositor !== "" || _detected !== ""

    readonly property var probeTable: [
        { name: "niri", argv: ["niri", "msg", "--json", "outputs"] },
        { name: "hyprland", argv: ["hyprctl", "monitors", "-j"] },
        { name: "mango", argv: ["mangoctl", "-j", "get_outputs"] }
    ]

    // Sequential on purpose: launching all three at once would race on
    // root._detected and report whichever answers last, not first.
    function _probeFrom(index) {
        if (root._detected !== "" || root.reportedCompositor !== "")
            return;
        if (index >= root.probeTable.length)
            return; // nothing answered; the retry timer will try again
        const p = root.probeTable[index];
        _run(p.argv, (ok) => {
            if (ok)
                root._detected = p.name;
            else
                root._probeFrom(index + 1);
        });
    }

    // ── Normalised output list ──────────────────────────────────────────
    //
    // One shape for every compositor, so the UI never branches on backend.
    // `id` is the compositor's own output name, which is what every write
    // path expects back.
    property var outputs: []
    property int selectedIndex: 0
    property string errorText: ""
    property bool loading: false

    // False when hosted as a subsection of the compositor panel, which
    // already renders its own PanelTitlebar with the section name; keeping
    // both would show the same title twice.
    property bool showHeader: true

    // Set by the compositor panel when this is embedded there. Sections are
    // toggled with `visible`, so root.visible stays true even while another
    // subsection is showing; this is what lets the poll timer stand down.
    property bool embedded: false
    property string currentSection: ""

    readonly property var scaleOptions: [1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]

    // ═══════════════════════════════════════════════════════════════════
    // Process plumbing
    // ═══════════════════════════════════════════════════════════════════
    //
    // Each call needs its import on its own line; the QML parser rejects
    // "import A; import B; Process {". Quickshell's Process emits
    // `exited(code, status)` — `finished` is not a signal.

    function _run(argv, onDone, env) {
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
            root.errorText = I18n.t("mp.spawn_failed");
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
        return proc;
    }

    // ═══════════════════════════════════════════════════════════════════
    // Read
    // ═══════════════════════════════════════════════════════════════════

    function refresh() {
        root.errorText = "";
        if (root.reportedCompositor === "" && root._detected === "") {
            // Ambxst has not named the compositor yet (or named it with
            // axctl's error text). Fall back to probing the clients.
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

    function _readNiri() {
        _run(["niri", "msg", "--json", "outputs"], (ok, out, err) => {
            root.loading = false;
            if (!ok) {
                root.errorText = (err || "").trim() || I18n.t("mp.read_failed");
                root.outputs = [];
                return;
            }
            let data;
            try {
                data = JSON.parse(out);
            } catch (e) {
                root.errorText = I18n.t("mp.bad_payload");
                root.outputs = [];
                return;
            }
            // niri returns an object keyed by output name.
            const list = [];
            for (const key in data) {
                const o = data[key];
                if (!o)
                    continue;
                list.push({
                    id: o.name || key,
                    make: o.make || "",
                    model: o.model || "",
                    serial: o.serial || "",
                    enabled: true,
                    width: (o.logical && o.logical.width) || 0,
                    height: (o.logical && o.logical.height) || 0,
                    // niri reports the refresh rate in milli-hertz.
                    refreshRate: o.modes && o.modes.length ? o.modes[o.current_mode || 0].refresh_rate / 1000 : 0,
                    modes: (o.modes || []).map(m => ({
                        width: m.width,
                        height: m.height,
                        refresh: m.refresh_rate / 1000,
                        preferred: !!m.is_preferred
                    })),
                    scale: (o.logical && o.logical.scale) || 1,
                    transform: (o.logical && o.logical.transform) || "Normal",
                    x: (o.logical && o.logical.x) || 0,
                    y: (o.logical && o.logical.y) || 0,
                    vrrSupported: !!o.vrr_supported,
                    vrrEnabled: !!o.vrr_enabled,
                    vrrOff: false,
                    physicalW: (o.physical_size && o.physical_size[0]) || 0,
                    physicalH: (o.physical_size && o.physical_size[1]) || 0
                });
            }
            root.outputs = list;
        });
    }

    function _readHyprland() {
        _run(["hyprctl", "monitors", "-j"], (ok, out, err) => {
            root.loading = false;
            if (!ok) {
                root.errorText = (err || "").trim() || I18n.t("mp.read_failed");
                root.outputs = [];
                return;
            }
            let data;
            try {
                data = JSON.parse(out);
            } catch (e) {
                root.errorText = I18n.t("mp.bad_payload");
                root.outputs = [];
                return;
            }
            root.outputs = (data || []).map(o => ({
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
                vrrEnabled: !!o.vrr && o.active !== undefined ? !!o.vrr : false,
                vrrOff: false,
                physicalW: 0,
                physicalH: 0
            }));
        });
    }

    function _readMango() {
        // Mango speaks the sway IPC protocol, reached through a socket named
        // after $MANGO_INSTANCE_SIGNATURE. Not verifiable on this machine
        // (Mango is not installed), so the panel reports honestly rather
        // than pretending the read succeeded.
        const sig = Quickshell.env("MANGO_INSTANCE_SIGNATURE");
        if (!sig || sig === "") {
            root.loading = false;
            root.errorText = I18n.t("mp.mango_no_signature");
            root.outputs = [];
            return;
        }
        _run(["mangoctl", "-j", "get_outputs"], (ok, out, err) => {
            root.loading = false;
            if (!ok) {
                root.errorText = (err || "").trim() || I18n.t("mp.read_failed");
                root.outputs = [];
                return;
            }
            let data;
            try {
                data = JSON.parse(out);
            } catch (e) {
                root.errorText = I18n.t("mp.bad_payload");
                root.outputs = [];
                return;
            }
            root.outputs = (data || []).map(o => ({
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
                vrrOff: false,
                physicalW: 0,
                physicalH: 0
            }));
        });
    }

    // ═══════════════════════════════════════════════════════════════════
    // Write
    // ═══════════════════════════════════════════════════════════════════

    function apply(id, action, value) {
        root.errorText = "";
        const done = (ok, out, err) => {
            if (!ok) {
                root.errorText = (err || "").trim() || I18n.t("mp.write_failed");
            }
            // The compositor reports its own state; re-read rather than
            // guessing what it did with the request.
            Qt.callLater(root.refresh);
        };

        if (root.niri)
            _applyNiri(id, action, value, done);
        else if (root.hyprland)
            _applyHyprland(id, action, value, done);
        else if (root.mango)
            _applyMango(id, action, value, done);
        else
            root.errorText = I18n.t("mp.unsupported_compositor");
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
        case "scale":
            argv = ["niri", "msg", "output", id, "scale", String(value)];
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
            argv = ["niri", "msg", "output", id, "vrr", value ? "on" : "off"];
            break;
        default:
            done(false, "", I18n.t("mp.unknown_action"));
            return;
        }
        _run(argv, done);
    }

    function _applyHyprland(id, action, value, done) {
        // hyprctl takes `monitor <name>,<keyword>,<value>` for dynamic
        // per-output settings. Keyword names differ from niri's verbs, so the
        // mapping happens here rather than in the UI.
        const map = {
            off: "disable,1",
            on: "disable,0",
            mode: "resolution," + String(value),
            scale: "scale," + String(value),
            transform: "transform," + String(value),
            position: "position," + String(value.x) + "," + String(value.y),
            vrr: "vrr," + (value ? "1" : "0")
        };
        const spec = map[action];
        if (!spec) {
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
            scale: "SCALE " + String(value),
            transform: "TRANSFORM " + String(value),
            position: "POSITION " + String(value.x) + " " + String(value.y),
            vrr: "VRR " + (value ? "on" : "off")
        };
        const cmd = map[action];
        if (!cmd) {
            done(false, "", I18n.t("mp.unknown_action"));
            return;
        }
        _run(["mangoctl", "output", id, cmd], done);
    }

    // ═══════════════════════════════════════════════════════════════════
    // Lifecycle
    // ═══════════════════════════════════════════════════════════════════

    Component.onCompleted: {
        if (root.embedded && root.currentSection !== "" && root.currentSection !== "monitors")
            return;
        root.refresh();
    }

    // Stops itself as soon as either source names the compositor.
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

    Connections {
        target: AxctlService
        function onCompositorNameChanged() {
            if (root.reportedCompositor !== "")
                Qt.callLater(root.refresh);
        }
    }

    // The compositor pushes monitor changes too (a lid opening, a cable
    // being plugged in), so a poll keeps the list honest without a
    // subscription on every backend.
    Timer {
        interval: 4000
        repeat: true
        running: root.supported && root.visible
            && (!root.embedded || root.currentSection === "monitors")
        onTriggered: root.refresh()
    }


    // ═══════════════════════════════════════════════════════════════════
    // Reusable components
    // ═══════════════════════════════════════════════════════════════════

    component Label: Text {
        font.family: Config.theme.font
        font.pixelSize: Styling.fontSize(-1)
        color: Colors.overSurfaceVariant
    }

    component ValueText: Text {
        font.family: Config.theme.font
        font.pixelSize: Styling.fontSize(0)
        color: Colors.overBackground
    }

    component SmallButton: StyledRect {
        id: btn
        required property string text
        property bool active: false
        signal clicked()

        variant: active ? "primaryfocus" : (hover.hovered ? "focus" : "pane")
        radius: Styling.radius(2)
        implicitWidth: Math.max(48, label.implicitWidth + 24)
        implicitHeight: 32

        Text {
            id: label
            anchors.centerIn: parent
            text: btn.text
            font.family: Config.theme.font
            font.pixelSize: Styling.fontSize(-1)
            color: Colors.overBackground
        }

        HoverHandler {
            id: hover
            cursorShape: Qt.PointingHandCursor
        }
        TapHandler {
            onTapped: btn.clicked()
        }
    }

    component IntField: StyledRect {
        id: fld
        required property string label
        property int value: 0
        property int minValue: -100000
        property int maxValue: 100000
        signal edited(int newValue)

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
                    implicitWidth: 48
                    implicitHeight: 26
                    onClicked: fld.picked(modelData)
                }
            }
        }
    }

    component OutputCard: StyledRect {
        id: card
        required property var output
        required property var root_

        variant: "pane"
        radius: Styling.radius(2)
        Layout.fillWidth: true
        Layout.preferredHeight: body.implicitHeight + 24

        ColumnLayout {
            id: body
            anchors.fill: parent
            anchors.margins: 12
            spacing: 10

            // Header: identity + on/off
            RowLayout {
                Layout.fillWidth: true
                spacing: 12

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 0

                    ValueText {
                        text: card.output.make + " " + card.output.model
                        font.bold: true
                    }
                    Label {
                        text: card.output.id
                          + "  " + card.output.width + "×" + card.output.height
                          + " @ " + Number(card.output.refreshRate).toFixed(0) + " Hz"
                        Layout.fillWidth: true
                    }
                }

                SmallButton {
                    text: card.output.enabled ? I18n.t("mp.on") : I18n.t("mp.off")
                    active: card.output.enabled
                    onClicked: card.root_.apply(card.output.id, card.output.enabled ? "off" : "on")
                }
            }

            // Everything below is meaningless on a disabled output.
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 10
                visible: card.output.enabled
                enabled: card.output.enabled

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
                                // itself ("Property value set multiple
                                // times").
                                readonly property bool isCurrent: modelData.width === card.output.width
                                        && modelData.height === card.output.height
                                        && Math.abs(modelData.refresh - card.output.refreshRate) < 0.5
                                text: modelData.width + "×" + modelData.height + "@"
                                      + Number(modelData.refresh).toFixed(0)
                                active: isCurrent
                                onClicked: card.root_.apply(card.output.id, "mode",
                                    modelData.width + "x" + modelData.height + "@" + Number(modelData.refresh).toFixed(3))
                            }
                        }
                    }
                }

                // Scale
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 4

                    Label {
                        text: I18n.t("mp.scale") + "  " + card.output.scale
                    }
                    ScaleField {
                        value: card.output.scale
                        options: card.root_.scaleOptions
                        onPicked: v => card.root_.apply(card.output.id, "scale", v)
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
                                : [0, 90, 180, 270, 180 + 90, 270 + 90, -90, 90]
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
            }
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

        signal monitorMoved(int idx, int newX, int newY)
        signal monitorSelected(int idx)

        variant: "pane"
        radius: Styling.radius(0)
        enableShadow: true
        Layout.preferredHeight: canvasArea.implicitHeight + 16

        // Logical size of an output, accounting for rotation and scale.
        function logicalWidth(m) {
            if (!m)
                return 1920;
            const rot = isRotated(m.transform);
            return (rot ? (m.height || 1080) : (m.width || 1920)) / (m.scale || 1.0);
        }

        function logicalHeight(m) {
            if (!m)
                return 1080;
            const rot = isRotated(m.transform);
            return (rot ? (m.width || 1920) : (m.height || 1080)) / (m.scale || 1.0);
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

        function realToCanvasX(rx) { return (rx - av.viewBounds.minX) * av.viewScale + 10; }
        function realToCanvasY(ry) { return (ry - av.viewBounds.minY) * av.viewScale + 10; }

        onMonitorsChanged: recalcBounds()

        Component.onCompleted: recalcBounds()

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
                            opacity: monItem.modelData.enabled ? 1.0 : 0.7
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
                                const snapPx = 15 / av.viewScale;

                                const list = av.monitors || [];
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
                                monItem.dragX = newX;
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
                                const snapPx = 25 / av.viewScale;
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

                                rx = Math.round(rx / 10) * 10;
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
            Text {
                Layout.fillWidth: true
                Layout.leftMargin: 8
                Layout.rightMargin: 8
                text: root.supported
                    ? I18n.t("mp.backend") + " " + root.compositor
                        + (root.reportedCompositor === "" ? I18n.t("mp.fallback_note") : "")
                    : (root.resolved ? I18n.t("mp.unsupported_compositor") : I18n.t("mp.detecting"))
                font.family: Config.theme.font
                font.pixelSize: Styling.fontSize(-2)
                color: Colors.overSurfaceVariant
                wrapMode: Text.WordWrap
            }

            Text {
                Layout.fillWidth: true
                Layout.leftMargin: 8
                Layout.rightMargin: 8
                text: I18n.t("mp.runtime_only")
                font.family: Config.theme.font
                font.pixelSize: Styling.fontSize(-2)
                color: Colors.overSurfaceVariant
                wrapMode: Text.WordWrap
            }

            // ── Arrangement ────────────────────────────────────────────
            //
            // Ported from NothingLess MonitorArrangementView: a logical-pixel
            // canvas with a 500 px grid, an origin marker, per-output boxes
            // scaled to their real logical size, a numbered badge, three
            // centered readout lines, and drag-to-move with edge snapping
            // (15 px while dragging, 25 px on release) plus overlap
            // resolution.
            //
            // The drag maths is NothingLess's. What differs is the write:
            // a release calls root.apply(id, "position", {x, y}), which goes
            // to the compositor's own runtime output API, instead of staging a
            // change for MonitorsWriter to write into a config file.
            ArrangementView {
                Layout.fillWidth: true
                Layout.leftMargin: 8
                Layout.rightMargin: 8
                visible: root.outputs.length > 0
                monitors: root.outputs
                selectedIndex: root.selectedIndex
                onMonitorSelected: idx => root.selectedIndex = idx
                onMonitorMoved: (idx, x, y) => {
                    const o = root.outputs[idx];
                    if (o)
                        root.apply(o.id, "position", { x: x, y: y });
                }
            }

            // Output list
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
