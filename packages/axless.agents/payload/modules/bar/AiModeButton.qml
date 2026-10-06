pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.modules.services
import qs.modules.components
import qs.modules.theme
import qs.config

// AI mode selector for the bar.
// Shows a quick icon indicating the current chat/agent mode and opens a
// popup with the mode toggle + agent picker. Mirrors the selector inside the
// AI sidebar so the user can flip modes without opening the sidebar.
Item {
    id: root

    required property var bar

    property bool vertical: bar.orientation === "vertical"
    property bool isHovered: false
    property bool layerEnabled: true

    property real radius: 0
    property real startRadius: radius
    property real endRadius: radius

    property bool popupOpen: aiModePopup.isOpen

    readonly property string currentMode: Ai.currentMode || "agent"
    readonly property string currentAgentId: Ai.currentAgentId || ""
    readonly property int toolCount: Ai.activeTools ? Ai.activeTools.length : 0
    readonly property int agentCount: Ai.agentManager ? Ai.agentManager.connections.length : 0

    // Whether the popup should show the agent selector
    readonly property bool showAgentSection: currentMode === "agent"

    Layout.preferredWidth: 36
    Layout.preferredHeight: 36
    Layout.fillWidth: vertical
    Layout.fillHeight: !vertical

    StyledToolTip {
        show: root.isHovered && !root.popupOpen
        tooltipText: {
            let base = "AI: " + (root.currentMode === "agent" ? "Agent" : "Chat");
            if (root.currentMode === "agent") {
                if (root.currentAgentId === "")
                    base += " · all (" + root.toolCount + " tools)";
                else
                    base += " · " + root._agentName(root.currentAgentId);
            }
            return base + " — click to switch";
        }
    }

    HoverHandler {
        onHoveredChanged: root.isHovered = hovered
    }

    StyledRect {
        id: buttonBg
        variant: root.popupOpen ? "primary" : (root.currentMode === "agent" ? "bg" : "common")
        anchors.fill: parent
        enableShadow: root.layerEnabled

        topLeftRadius: root.vertical ? root.startRadius : root.startRadius
        topRightRadius: root.vertical ? root.startRadius : root.endRadius
        bottomLeftRadius: root.vertical ? root.endRadius : root.startRadius
        bottomRightRadius: root.vertical ? root.endRadius : root.endRadius

        Rectangle {
            anchors.fill: parent
            color: Styling.srItem("overprimary")
            opacity: root.popupOpen ? 0 : (root.isHovered ? 0.25 : 0)
            radius: parent.radius ?? 0

            Behavior on opacity {
                enabled: Anim.animationsEnabled
                NumberAnimation {
                    duration: Anim.standardSmall
                }
            }
        }

        // Mode icon
        Text {
            anchors.centerIn: parent
            text: root.currentMode === "agent" ? Icons.robot : Icons.user
            font.family: Icons.font
            font.pixelSize: 18
            color: root.popupOpen ? buttonBg.item : (root.currentMode === "agent" ? Styling.srItem("overprimary") : Colors.outline)
        }

        // Small badge showing connected-agent count or "tools" count
        Rectangle {
            visible: root.currentMode === "agent" && root.toolCount > 0
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.rightMargin: -3
            anchors.topMargin: -3
            width: badgeLabel.implicitWidth + 6
            height: badgeLabel.implicitHeight + 2
            radius: height / 2
            color: Styling.srItem("overprimary")

            Text {
                id: badgeLabel
                anchors.centerIn: parent
                text: root.toolCount.toString()
                font.family: Config.theme.font
                font.pixelSize: 9
                font.weight: Font.Bold
                color: Colors.background
            }
        }

        MouseArea {
            anchors.fill: parent
            hoverEnabled: false
            cursorShape: Qt.PointingHandCursor
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            onClicked: mouse => {
                if (mouse.button === Qt.RightButton) {
                    // Right-click: jump to the AI sidebar (or toggle it)
                    if (typeof GlobalShortcuts !== "undefined" && GlobalShortcuts.toggleAssistant) {
                        GlobalShortcuts.toggleAssistant();
                    }
                    return;
                }
                aiModePopup.toggle();
            }
        }
    }

    // Mode + agent picker popup
    BarPopup {
        id: aiModePopup
        anchorItem: buttonBg
        bar: root.bar
        popupPadding: 12

        contentWidth: 240
        contentHeight: popupContent.implicitHeight + popupPadding * 2

        ColumnLayout {
            id: popupContent
            anchors.fill: parent
            spacing: 8

            // Mode toggle (segmented)
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 4

                Text {
                    text: "AI mode"
                    font.family: Config.theme.font
                    font.pixelSize: 11
                    color: Colors.outline
                }

                // Two rounded pill buttons side by side
                Row {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 30
                    spacing: 6

                    Repeater {
                        model: [
                            { id: "chat", label: "Chat", icon: Icons.user },
                            { id: "agent", label: "Agent", icon: Icons.robot }
                        ]

                        delegate: Item {
                            required property var modelData
                            width: (parent.width - 6) / 2
                            height: 30

                            property bool isSelected: root.currentMode === modelData.id

                            StyledRect {
                                anchors.fill: parent
                                radius: Styling.radius(0) / 2
                                variant: parent.isSelected ? "primary" : "common"
                                enableShadow: parent.isSelected

                                Behavior on variant {
                                    enabled: Anim.animationsEnabled
                                    ColorAnimation {
                                        duration: Anim.standardSmall
                                        easing.type: Anim.easing("standard").type
                                        easing.bezierCurve: Anim.easing("standard").bezierCurve
                                    }
                                }
                            }

                            Row {
                                anchors.centerIn: parent
                                spacing: 4

                                Text {
                                    text: modelData.icon
                                    font.family: Icons.font
                                    font.pixelSize: 12
                                    color: parent.parent.isSelected ? Colors.overPrimary : Colors.overSurface
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                                Text {
                                    text: modelData.label
                                    font.family: Config.theme.font
                                    font.pixelSize: 12
                                    font.weight: parent.parent.isSelected ? Font.Bold : Font.Normal
                                    color: parent.parent.isSelected ? Colors.overPrimary : Colors.overSurface
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                            }

                            MouseArea {
                                id: modeMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    Ai.setMode(modelData.id);
                                }
                            }
                        }
                    }
                }
            }

            // Agent picker (only visible in agent mode)
            ColumnLayout {
                visible: root.showAgentSection
                Layout.fillWidth: true
                spacing: 4

                Text {
                    text: "Agent"
                    font.family: Config.theme.font
                    font.pixelSize: 11
                    color: Colors.outline
                }

                StyledRect {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 30
                    radius: Styling.radius(2)
                    variant: "common"

                    Text {
                        anchors.left: parent.left
                        anchors.right: agentMenuMouse.right
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.leftMargin: 8
                        text: {
                            if (root.currentAgentId === "")
                                return "All agents (" + root.toolCount + " tools)";
                            return root._agentName(root.currentAgentId);
                        }
                        font.family: Config.theme.font
                        font.pixelSize: 12
                        color: Colors.overSurface
                        elide: Text.ElideRight
                    }

                    MouseArea {
                        id: agentMenuMouse
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.rightMargin: 8
                        width: 16
                        height: 16
                        cursorShape: Qt.PointingHandCursor
                        hoverEnabled: true
                        onClicked: root._toggleAgentMenu()
                    }

                    Text {
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.rightMargin: 8
                        text: Icons.caretDown
                        font.family: Icons.font
                        font.pixelSize: 10
                        color: Colors.outline
                    }
                }

                // Agent dropdown list
                Item {
                    Layout.fillWidth: true
                    Layout.preferredHeight: root._agentMenuOpen ? agentListColumn.implicitHeight + 8 : 0
                    visible: root._agentMenuOpen

                    StyledRect {
                        anchors.fill: parent
                        radius: Styling.radius(2)
                        variant: "internalbg"
                    }

                    Column {
                        id: agentListColumn
                        anchors.fill: parent
                        anchors.margins: 4
                        spacing: 0

                        Item {
                            width: parent.width
                            height: 26
                            visible: root.agentCount > 0

                            Row {
                                anchors.fill: parent
                                anchors.leftMargin: 8
                                anchors.rightMargin: 8
                                spacing: 6

                                Text {
                                    text: Icons.list
                                    font.family: Icons.font
                                    font.pixelSize: 10
                                    color: root.currentAgentId === "" ? Styling.srItem("overprimary") : Colors.overSurface
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                                Text {
                                    text: "All agents"
                                    font.family: Config.theme.font
                                    font.pixelSize: 11
                                    font.weight: root.currentAgentId === "" ? Font.Bold : Font.Normal
                                    color: root.currentAgentId === "" ? Styling.srItem("overprimary") : Colors.overSurface
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                            }
                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    Ai.setAgent("");
                                    root._agentMenuOpen = false;
                                }
                            }
                        }

                        Repeater {
                            model: Ai.agentManager ? Ai.agentManager.connections : []
                            delegate: Item {
                                required property var modelData
                                width: parent.width
                                height: 26

                                // Background highlight for the active agent.
                                Rectangle {
                                    anchors.fill: parent
                                    anchors.margins: 2
                                    radius: Styling.radius(-3)
                                    color: modelData.id === root.currentAgentId
                                        ? Qt.rgba(Colors.primary.r, Colors.primary.g, Colors.primary.b, _pulseAnim.running ? 0.35 : 0.18)
                                        : (rowMa.containsMouse
                                            ? Qt.rgba(Colors.outline.r, Colors.outline.g, Colors.outline.b, 0.12)
                                            : "transparent")
                                }

                                // Brief pulse on the active row when the
                                // selection changes — gives the user
                                // visible feedback that their click
                                // registered (the popup stays open so
                                // they can also see the highlight
                                // settle).
                                SequentialAnimation {
                                    id: _pulseAnim
                                    running: false
                                    NumberAnimation {
                                        target: parent
                                        property: "opacity"
                                        from: 1.0; to: 1.0
                                        duration: 600
                                    }
                                }

                                Row {
                                    anchors.fill: parent
                                    anchors.leftMargin: 8
                                    anchors.rightMargin: 8
                                    spacing: 6

                                    Text {
                                        text: modelData.status === "connected" ? Icons.accept : Icons.circle
                                        font.family: Icons.font
                                        font.pixelSize: 9
                                        color: modelData.status === "connected" ? Colors.success : Colors.outline
                                        anchors.verticalCenter: parent.verticalCenter
                                    }
                                    Text {
                                        text: modelData.name
                                        font.family: Config.theme.font
                                        font.pixelSize: 11
                                        font.weight: modelData.id === root.currentAgentId ? Font.Bold : Font.Normal
                                        color: modelData.id === root.currentAgentId ? Styling.srItem("overprimary") : Colors.overSurface
                                        anchors.verticalCenter: parent.verticalCenter
                                        elide: Text.ElideRight
                                    }
                                }
                                MouseArea {
                                    id: rowMa
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        Ai.setAgent(modelData.id);
                                        // Visual feedback: pulse the row.
                                        _pulseAnim.restart();
                                        // Keep the popup open so the
                                        // user can see the highlight
                                        // settle and pick a different
                                        // one. They close it by
                                        // clicking outside or pressing
                                        // the trigger button again.
                                    }
                                }
                            }
                        }

                        // "Manage profiles" link at the bottom of the
                        // popup — opens the new Agent profiles tab in
                        // Settings where the user can add / edit /
                        // delete profiles and edit the raw JSON.
                        Item {
                            width: parent.width
                            height: 24
                            visible: root.agentCount > 0
                            Rectangle {
                                anchors.fill: parent
                                anchors.margins: 2
                                radius: Styling.radius(-3)
                                color: manageMa.containsMouse
                                    ? Qt.rgba(Colors.outline.r, Colors.outline.g, Colors.outline.b, 0.12)
                                    : "transparent"
                            }
                            Row {
                                anchors.fill: parent
                                anchors.leftMargin: 8
                                anchors.rightMargin: 8
                                spacing: 6
                                Text {
                                    text: Icons.gear
                                    font.family: Icons.font
                                    font.pixelSize: 10
                                    color: Colors.outline
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                                Text {
                                    text: "Manage agent profiles…"
                                    font.family: Config.theme.font
                                    font.pixelSize: 11
                                    color: Colors.outline
                                    anchors.verticalCenter: parent.verticalCenter
                                    elide: Text.ElideRight
                                }
                            }
                            MouseArea {
                                id: manageMa
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    root._agentMenuOpen = false;
                                    GlobalStates.settingsCurrentTab = 9;  // Agent profiles tab
                                    GlobalStates.settingsWindowVisible = true;
                                }
                            }
                        }

                        Text {
                            visible: root.agentCount === 0
                            width: parent.width
                            height: 26
                            text: "No agents configured"
                            font.family: Config.theme.font
                            font.pixelSize: 11
                            color: Colors.outline
                            font.italic: true
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                        }
                    }
                }
            }

            // Shortcut hint
            Text {
                Layout.fillWidth: true
                text: "Right-click → open AI sidebar · /mode, /agent in chat"
                font.family: Config.theme.font
                font.pixelSize: 9
                color: Colors.outline
                wrapMode: Text.WordWrap
            }
        }
    }

    // Internal state for the agent dropdown inside the popup
    property bool _agentMenuOpen: false

    function _toggleAgentMenu() {
        _agentMenuOpen = !_agentMenuOpen;
    }

    function _agentName(agentId) {
        if (!Ai.agentManager) return agentId;
        let conns = Ai.agentManager.connections;
        for (let i = 0; i < conns.length; i++) {
            if (conns[i] && conns[i].id === agentId) {
                return conns[i].name;
            }
        }
        return agentId;
    }
}
