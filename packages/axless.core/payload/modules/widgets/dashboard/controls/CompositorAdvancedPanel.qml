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
    CompositorAdvancedPanel.qml

    An honest view of what the running compositor can actually be told to do.

    The write path for compositor settings ends outside the shell:

        Panel QML -> Config.qml -> IPC "compositor.write" -> Go backend
        -> ~/.local/share/ambxst/axctl.toml -> axctl binary
        -> hyprland.lua / niri.kdl / mango.conf

    A mod can add QML but cannot recompile the Go backend or extend the axctl
    binary, and axctl has a fixed vocabulary: a key it does not know is
    silently dropped from the generated config, and `axctl config set` rejects
    it outright ("unsupported config key"). Verified live against niri:

        axctl config set cursor.size 1   -> Error: unsupported config key
        an invented [zztest.foo] in axctl.toml -> absent from the output

    Worse, even the nine accepted keys do not all apply. The generated
    niri.kdl says so itself:

        // Not supported in niri static config: outer gaps (use inner gaps
        // in niri); opacity (niri uses per-app window-rule opacity); blur
        // (configure via blur {} block at top level in niri); shadow
        // (configure per-app via window-rule shadow {})

    So this panel does not offer window opacity or blur or shadow controls
    even though `axctl config set` accepts those keys: they would appear to
    work and change nothing. The Settings surface for appearance stays the
    stock Compositor panel, which drives the TOML path where it does work.

    What remains here is genuinely real on every supported compositor:
    the capability report, and layout selection.
*/
Item {
    id: root

    property int maxContentWidth: 480
    readonly property int contentWidth: Math.min(width, maxContentWidth)

    // AxctlService.compositorName and the capabilities payload both stay
    // empty until the axctl daemon answers, which can take ~30 s at startup.
    // The panel renders "detecting..." during that window rather than hiding
    // rows and popping them in later.
    property var capabilities: ({})

    readonly property bool capsKnown: Object.keys(root.capabilities).length > 0
    readonly property bool compositorKnown: AxctlService.compositorName !== ""

    function capSupported(key) {
        if (!root.capsKnown)
            return null;
        return root.capabilities[key] === true;
    }

    // ── Layout state ────────────────────────────────────────────────────
    property var layoutItems: []
    readonly property string activeLayout: {
        const active = root.layoutItems.find(i => i.current === true);
        return active ? active.name : "";
    }

    property string statusText: ""
    property bool busy: false

    // ═══════════════════════════════════════════════════════════════════
    // Process plumbing
    // ═══════════════════════════════════════════════════════════════════

    // Processes are created dynamically rather than declared as children:
    // each interaction fires one short-lived axctl call, and a fixed pool of
    // Process items would cap concurrent refreshes for no benefit. Same
    // pattern Config.qml uses for handleMissingConfig.
    //
    // Each import needs its own line: the QML parser does not accept
    // "import A; import B; Process {" on one line.
    function _run(argv, onDone) {
        const args = argv.map(a => JSON.stringify(String(a))).join(", ");
        const proc = Qt.createQmlObject(
            "import Quickshell\n"
            + "import Quickshell.Io\n"
            + "Process {\n"
            + "    command: [" + args + "]\n"
            + "    stdout: StdioCollector {}\n"
            + "    stderr: StdioCollector {}\n"
            + "}",
            root, "axctlProc");

        // `exited`, not `finished`: Quickshell's Process declares
        // `exited(code, status)`. `finished` is not a signal, so
        // proc.finished is undefined and proc.finished.connect() throws.
        proc.exited.connect(function (exitCode, exitStatus) {
            let out = "";
            try {
                out = proc.stdout ? proc.stdout.text : "";
            } catch (e) {
                out = "";
            }
            proc.destroy();
            if (onDone)
                onDone(exitCode === 0, out);
        });
        proc.running = true;
        return proc;
    }

    // ═══════════════════════════════════════════════════════════════════
    // Data loading
    // ═══════════════════════════════════════════════════════════════════

    function refreshCapabilities() {
        _run(["axctl", "system", "get-capabilities"], (ok, out) => {
            if (!ok) {
                root.capabilities = ({});
                return;
            }
            try {
                const parsed = JSON.parse(out);
                if (parsed && typeof parsed === "object")
                    root.capabilities = parsed;
            } catch (e) {
                console.warn("CompositorAdvancedPanel: bad capabilities payload:", e);
                root.capabilities = ({});
            }
        });
    }

    function refreshLayouts() {
        _run(["axctl", "layout", "list"], (ok, out) => {
            if (!ok) {
                root.layoutItems = [];
                return;
            }
            try {
                const parsed = JSON.parse(out);
                root.layoutItems = Array.isArray(parsed.items) ? parsed.items : [];
            } catch (e) {
                console.warn("CompositorAdvancedPanel: bad layout payload:", e);
                root.layoutItems = [];
            }
        });
    }

    function setLayout(name) {
        _run(["axctl", "layout", "set", name], (ok) => {
            root.busy = false;
            if (ok) {
                root.statusText = "";
                Qt.callLater(root.refreshLayouts);
            } else {
                root.statusText = I18n.t("ca.layout_failed");
            }
        });
        root.busy = true;
    }

    function cycleLayout(delta) {
        _run(["axctl", "layout", delta > 0 ? "next" : "prev", "1"], (ok) => {
            root.busy = false;
            if (ok)
                Qt.callLater(root.refreshLayouts);
            else
                root.statusText = I18n.t("ca.layout_failed");
        });
        root.busy = true;
    }

    // ═══════════════════════════════════════════════════════════════════
    // Lifecycle
    // ═══════════════════════════════════════════════════════════════════

    Component.onCompleted: {
        refreshCapabilities();
        refreshLayouts();
        // axctl's daemon can still be coming up at shell start, so retry a
        // bounded number of times and then settle into "detecting" state
        // rather than hammering the socket.
        retryProbe.restart();
    }

    Timer {
        id: retryProbe
        interval: 1200
        repeat: true
        onTriggered: {
            if (root.capsKnown) {
                retryProbe.stop();
                return;
            }
            root.refreshCapabilities();
            root.refreshLayouts();
        }
    }

    onCapsKnownChanged: {
        if (capsKnown)
            retryProbe.stop();
    }

    Connections {
        target: AxctlService
        function onCompositorNameChanged() {
            if (AxctlService.compositorName === "")
                return;
            root.refreshCapabilities();
            root.refreshLayouts();
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    // Reusable rows (same idiom as CompositorPanel)
    // ═══════════════════════════════════════════════════════════════════

    component InfoRow: RowLayout {
        id: row
        required property string label
        required property string value

        Layout.fillWidth: true
        spacing: 12

        Text {
            text: row.label
            font.family: Config.theme.font
            font.pixelSize: Styling.fontSize(0)
            color: Colors.overBackground
            Layout.fillWidth: true
        }

        Text {
            text: row.value
            font.family: Config.theme.font
            font.pixelSize: Styling.fontSize(-1)
            color: Colors.overSurfaceVariant
        }
    }

    component SmallButton: StyledRect {
        id: btn
        required property string text
        signal clicked()

        variant: hover.hovered ? "primaryfocus" : "pane"
        radius: Styling.radius(2)
        implicitWidth: Math.max(72, label.implicitWidth + 32)
        implicitHeight: 36

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
            spacing: 8

            Item {
                Layout.fillWidth: true
                Layout.preferredHeight: titlebar.height

                PanelTitlebar {
                    id: titlebar
                    width: root.contentWidth
                    anchors.horizontalCenter: parent.horizontalCenter
                    title: I18n.t("ca.title")
                    statusText: root.statusText
                    statusColor: Colors.error

                    actions: [
                        {
                            icon: Icons.sync,
                            tooltip: I18n.t("ca.refresh"),
                            onClicked: function () {
                                root.refreshCapabilities();
                                root.refreshLayouts();
                            }
                        }
                    ]
                }
            }

            // ── Environment ───────────────────────────────────────────────
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 8

                Text {
                    text: I18n.t("ca.environment")
                    font.family: Config.theme.font
                    font.pixelSize: Styling.fontSize(-1)
                    font.weight: Font.Medium
                    color: Colors.overSurfaceVariant
                    Layout.bottomMargin: -4
                }

                InfoRow {
                    label: I18n.t("ca.compositor")
                    value: root.compositorKnown ? AxctlService.compositorName : I18n.t("ca.detecting")
                }

                Repeater {
                    model: ["animations", "blur", "rounded_corners", "shadows", "windows_supported", "workspaces_supported"]

                    delegate: InfoRow {
                        required property string modelData
                        label: I18n.t("ca.cap_" + modelData)
                        value: !root.capsKnown
                            ? I18n.t("ca.detecting")
                            : (root.capabilities[modelData] === true ? I18n.t("ca.yes") : I18n.t("ca.no"))
                    }
                }
            }

            // ── Layout ──────────────────────────────────────────────────
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 8

                Text {
                    text: I18n.t("ca.layout")
                    font.family: Config.theme.font
                    font.pixelSize: Styling.fontSize(-1)
                    font.weight: Font.Medium
                    color: Colors.overSurfaceVariant
                    Layout.bottomMargin: -4
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8

                    SmallButton {
                        text: I18n.t("ca.prev")
                        onClicked: root.cycleLayout(-1)
                    }

                    SmallButton {
                        text: I18n.t("ca.next")
                        onClicked: root.cycleLayout(1)
                    }

                    Item {
                        Layout.fillWidth: true
                    }
                }

                Repeater {
                    model: root.layoutItems

                    delegate: StyledRect {
                        id: layoutRow
                        required property var modelData
                        readonly property bool isActive: layoutRow.modelData.name === root.activeLayout

                        Layout.fillWidth: true
                        Layout.preferredHeight: 44
                        radius: Styling.radius(2)
                        variant: layoutRow.isActive ? "primaryfocus" : "pane"

                        RowLayout {
                            anchors.fill: parent
                            anchors.margins: 12
                            spacing: 12

                            Text {
                                text: layoutRow.modelData.name
                                font.family: Config.theme.font
                                font.pixelSize: Styling.fontSize(0)
                                color: Colors.overBackground
                                Layout.fillWidth: true
                            }

                            Text {
                                text: layoutRow.modelData.source === "static"
                                    ? I18n.t("ca.fallback")
                                    : I18n.t("ca.compositor")
                                font.family: Config.theme.font
                                font.pixelSize: Styling.fontSize(-2)
                                color: Colors.overSurfaceVariant
                            }
                        }

                        TapHandler {
                            onTapped: root.setLayout(layoutRow.modelData.name)
                        }
                    }
                }

                Text {
                    text: I18n.t("ca.layout_note")
                    font.family: Config.theme.font
                    font.pixelSize: Styling.fontSize(-2)
                    color: Colors.overSurfaceVariant
                    wrapMode: Text.WordWrap
                    Layout.fillWidth: true
                }
            }

            // ── What is not here, and why ────────────────────────────────
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 8

                Text {
                    text: I18n.t("ca.unsupported")
                    font.family: Config.theme.font
                    font.pixelSize: Styling.fontSize(-1)
                    font.weight: Font.Medium
                    color: Colors.overSurfaceVariant
                    Layout.bottomMargin: -4
                }

                Text {
                    text: I18n.t("ca.unsupported_body")
                    font.family: Config.theme.font
                    font.pixelSize: Styling.fontSize(-2)
                    color: Colors.overSurfaceVariant
                    wrapMode: Text.WordWrap
                    Layout.fillWidth: true
                }
            }
        }
    }
}
