pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Effects
import Quickshell
import qs.modules.theme
import qs.modules.components
import qs.modules.globals
import qs.modules.services
import qs.config

Item {
    id: root

    property int maxContentWidth: 480
    readonly property int contentWidth: Math.min(width, maxContentWidth)
    readonly property real sideMargin: (width - contentWidth) / 2

    property string currentSection: ""

    component SectionButton: StyledRect {
        id: sectionBtn
        required property string text
        required property string sectionId

        property bool isHovered: false

        variant: isHovered ? "focus" : "pane"
        Layout.fillWidth: true
        Layout.preferredHeight: 56
        radius: Styling.radius(0)

        RowLayout {
            anchors.fill: parent
            anchors.margins: 16
            spacing: 16

            Text {
                text: sectionBtn.text
                font.family: Config.theme.font
                font.pixelSize: Styling.fontSize(0)
                font.bold: true
                color: Colors.overBackground
                Layout.fillWidth: true
            }

            Text {
                text: Icons.caretRight
                font.family: Icons.font
                font.pixelSize: 20
                color: Colors.overSurfaceVariant
            }
        }

        MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onEntered: sectionBtn.isHovered = true
            onExited: sectionBtn.isHovered = false
            onClicked: root.currentSection = sectionBtn.sectionId
        }
    }

    // Available color names for color picker
    readonly property var colorNames: Colors.availableColorNames

    // Color picker state
    property bool colorPickerActive: false
    property var colorPickerColorNames: []
    property string colorPickerCurrentColor: ""
    property string colorPickerDialogTitle: ""
    property var colorPickerCallback: null

    function openColorPicker(colorNames, currentColor, dialogTitle, callback) {
        // Ensure colorNames is a valid array for QML
        colorPickerColorNames = colorNames;
        // Ensure currentColor is a string
        colorPickerCurrentColor = currentColor.toString();
        // Ensure dialogTitle is a string
        colorPickerDialogTitle = dialogTitle ? dialogTitle.toString() : "";
        colorPickerCallback = callback;
        colorPickerActive = true;
    }

    function closeColorPicker() {
        colorPickerActive = false;
        colorPickerCallback = null;
    }

    function handleColorSelected(color) {
        if (colorPickerCallback) {
            colorPickerCallback(color);
        }
        colorPickerCurrentColor = color;
    }

    // Inline component for toggle rows
    component ToggleRow: RowLayout {
        id: toggleRowRoot
        property string label: ""
        property bool checked: false
        signal toggled(bool value)

        // Track if we're updating from external binding
        property bool _updating: false

        onCheckedChanged: {
            if (!_updating && toggleSwitch.checked !== checked) {
                _updating = true;
                toggleSwitch.checked = checked;
                _updating = false;
            }
        }

        Layout.fillWidth: true
        spacing: 8

        Text {
            text: toggleRowRoot.label
            font.family: Config.theme.font
            font.pixelSize: Styling.fontSize(0)
            color: Colors.overBackground
            Layout.fillWidth: true
        }

        Switch {
            id: toggleSwitch
            checked: toggleRowRoot.checked

            onCheckedChanged: {
                if (!toggleRowRoot._updating && checked !== toggleRowRoot.checked) {
                    toggleRowRoot.toggled(checked);
                }
            }

            indicator: Rectangle {
                implicitWidth: 40
                implicitHeight: 20
                x: toggleSwitch.leftPadding
                y: parent.height / 2 - height / 2
                radius: height / 2
                color: toggleSwitch.checked ? Styling.srItem("overprimary") : Colors.surfaceBright
                border.color: toggleSwitch.checked ? Styling.srItem("overprimary") : Colors.outline

                Behavior on color {
                    enabled: Config.animDuration > 0
                    ColorAnimation {
                        duration: Config.animDuration / 2
                    }
                }

                Rectangle {
                    x: toggleSwitch.checked ? parent.width - width - 2 : 2
                    y: 2
                    width: parent.height - 4
                    height: width
                    radius: width / 2
                    color: toggleSwitch.checked ? Colors.background : Colors.overSurfaceVariant

                    Behavior on x {
                        enabled: Config.animDuration > 0
                        NumberAnimation {
                            duration: Config.animDuration / 2
                            easing.type: Easing.OutCubic
                        }
                    }
                }
            }
            background: null
        }
    }

    // Inline component for number input rows
    component NumberInputRow: RowLayout {
        id: numberInputRowRoot
        property string label: ""
        property int value: 0
        property int minValue: 0
        property int maxValue: 100
        property string suffix: ""
        signal valueEdited(int newValue)

        Layout.fillWidth: true
        spacing: 8
        opacity: enabled ? 1.0 : 0.5

        Text {
            text: numberInputRowRoot.label
            font.family: Config.theme.font
            font.pixelSize: Styling.fontSize(0)
            color: Colors.overBackground
            Layout.fillWidth: true
        }

        StyledRect {
            variant: "common"
            Layout.preferredWidth: 60
            Layout.preferredHeight: 32
            radius: Styling.radius(-2)

            TextInput {
                id: numberTextInput
                anchors.fill: parent
                anchors.margins: 8
                font.family: Config.theme.font
                font.pixelSize: Styling.fontSize(0)
                color: Colors.overBackground
                selectByMouse: true
                clip: true
                verticalAlignment: TextInput.AlignVCenter
                horizontalAlignment: TextInput.AlignHCenter
                validator: IntValidator {
                    bottom: numberInputRowRoot.minValue
                    top: numberInputRowRoot.maxValue
                }

                // Sync text when external value changes
                readonly property int configValue: numberInputRowRoot.value
                onConfigValueChanged: {
                    if (!activeFocus && text !== configValue.toString()) {
                        text = configValue.toString();
                    }
                }
                Component.onCompleted: text = configValue.toString()

                onEditingFinished: {
                    let newVal = parseInt(text);
                    if (!isNaN(newVal)) {
                        newVal = Math.max(numberInputRowRoot.minValue, Math.min(numberInputRowRoot.maxValue, newVal));
                        numberInputRowRoot.valueEdited(newVal);
                    }
                }
            }
        }

        Text {
            text: numberInputRowRoot.suffix
            font.family: Config.theme.font
            font.pixelSize: Styling.fontSize(0)
            color: Colors.overSurfaceVariant
            visible: suffix !== ""
        }
    }

    // Inline component for decimal input rows
    component DecimalInputRow: RowLayout {
        id: decimalInputRowRoot
        property string label: ""
        property real value: 0.0
        property real minValue: 0.0
        property real maxValue: 1.0
        property string suffix: ""
        signal valueEdited(real newValue)

        Layout.fillWidth: true
        spacing: 8
        opacity: enabled ? 1.0 : 0.5

        Text {
            text: decimalInputRowRoot.label
            font.family: Config.theme.font
            font.pixelSize: Styling.fontSize(0)
            color: Colors.overBackground
            Layout.fillWidth: true
        }

        StyledRect {
            variant: "common"
            Layout.preferredWidth: 60
            Layout.preferredHeight: 32
            radius: Styling.radius(-2)

            TextInput {
                id: decimalTextInput
                anchors.fill: parent
                anchors.margins: 8
                font.family: Config.theme.font
                font.pixelSize: Styling.fontSize(0)
                color: Colors.overBackground
                selectByMouse: true
                clip: true
                verticalAlignment: TextInput.AlignVCenter
                horizontalAlignment: TextInput.AlignHCenter
                validator: DoubleValidator {
                    bottom: decimalInputRowRoot.minValue
                    top: decimalInputRowRoot.maxValue
                    decimals: 2
                }

                // Sync text when external value changes
                readonly property real configValue: decimalInputRowRoot.value
                onConfigValueChanged: {
                    if (!activeFocus) {
                        // Check if roughly equal to avoid formatting loops
                        if (Math.abs(parseFloat(text) - configValue) > 0.001 || text === "")
                            text = configValue.toFixed(1); // Default format
                    }
                }
                Component.onCompleted: text = configValue.toFixed(1)

                onEditingFinished: {
                    let newVal = parseFloat(text);
                    if (!isNaN(newVal)) {
                        newVal = Math.max(decimalInputRowRoot.minValue, Math.min(decimalInputRowRoot.maxValue, newVal));
                        decimalInputRowRoot.valueEdited(newVal);
                    }
                }
            }
        }

        Text {
            text: decimalInputRowRoot.suffix
            font.family: Config.theme.font
            font.pixelSize: Styling.fontSize(0)
            color: Colors.overSurfaceVariant
            visible: suffix !== ""
        }
    }

    // Inline component for Border Gradients (Multi-color list)
    component BorderGradientRow: ColumnLayout {
        id: gradientRow
        property string label: ""
        property var colors: []
        property string dialogTitle: ""
        property bool enabled: true
        signal colorsEdited(var newColors)

        spacing: 8
        Layout.fillWidth: true
        opacity: enabled ? 1.0 : 0.5

        // Header
        RowLayout {
            Layout.fillWidth: true
            Text {
                text: gradientRow.label
                font.family: Config.theme.font
                font.pixelSize: Styling.fontSize(0)
                color: Colors.overBackground
                Layout.fillWidth: true
            }
            Text {
                text: I18n.t("compositor.right_click_remove")
                font.family: Config.theme.font
                font.pixelSize: Styling.fontSize(-2)
                color: Colors.overSurfaceVariant
                visible: gradientRow.colors.length > 1
            }
        }

        // Color List
        Flow {
            Layout.fillWidth: true
            spacing: 8

            Repeater {
                id: colorsRepeater
                model: gradientRow.colors
                delegate: MouseArea {
                    width: 32
                    height: 32
                    hoverEnabled: true
                    acceptedButtons: Qt.LeftButton | Qt.RightButton

                    required property int index
                    required property var modelData

                    // Swatch
                    Rectangle {
                        anchors.fill: parent
                        radius: width / 2
                        color: Config.resolveColor(parent.modelData)
                        border.width: 2
                        border.color: parent.containsMouse ? Styling.srItem("overprimary") : Colors.outline

                        // Inner check for visual depth
                        Rectangle {
                            anchors.centerIn: parent
                            width: parent.width - 4
                            height: width
                            radius: width / 2
                            color: "transparent"
                            border.width: 1
                            border.color: Colors.surface
                            opacity: 0.3
                        }
                    }

                    // Tooltip
                    StyledToolTip {
                        text: parent.modelData.toString()
                        visible: parent.containsMouse && !contextMenu.visible
                    }

                    onClicked: mouse => {
                        if (mouse.button === Qt.RightButton) {
                            // Remove color (if more than 1)
                            if (gradientRow.colors.length > 1) {
                                let newColors = [...gradientRow.colors];
                                newColors.splice(index, 1);
                                gradientRow.colorsEdited(newColors);
                            }
                        } else {
                            // Edit color
                            root.openColorPicker(root.colorNames, modelData, gradientRow.dialogTitle, function (selectedColor) {
                                let newColors = [...gradientRow.colors];
                                newColors[index] = selectedColor;
                                gradientRow.colorsEdited(newColors);
                            });
                        }
                    }
                }
            }
            StyledRect {
                width: 32
                height: 32
                radius: 16
                variant: "common"
                color: mouseAreaAdd.containsMouse ? Colors.surfaceBright : Colors.surface
                border.width: 1
                border.color: Colors.outline

                Text {
                    anchors.centerIn: parent
                    text: Icons.plus
                    font.family: Icons.font
                    font.pixelSize: 16
                    color: Colors.overSurfaceVariant
                }

                MouseArea {
                    id: mouseAreaAdd
                    anchors.fill: parent
                    hoverEnabled: true
                    onClicked: {
                        let newColors = [...gradientRow.colors];
                        // Duplicate last color or default to primary
                        let colorToAdd = newColors.length > 0 ? newColors[newColors.length - 1] : "primary";
                        newColors.push(colorToAdd);
                        gradientRow.colorsEdited(newColors);
                    }
                }
            }
        }
    }

    // Inline component for Compositor Tabs

    // ── axless.core: rows that write through hyprctl keyword ─────────────
    //
    // The four rows above are Ambxst's: they assign to Config.compositor and
    // Ambxst's TOML writer persists them for every compositor. These four
    // instead push a keyword to the running compositor, which is the only
    // way to reach settings outside Ambxst's fixed axctl vocabulary. The
    // caller is responsible for gating on CompositorKeywords.supports().
    component KeywordTextRow: RowLayout {
        id: row
        required property string label
        required property string value
        signal valueEdited(string newValue)

        Layout.fillWidth: true
        spacing: 12

        Text {
            text: row.label
            font.family: Config.theme.font
            font.pixelSize: Styling.fontSize(0)
            color: Colors.overBackground
            Layout.preferredWidth: 220
        }

        StyledRect {
            variant: "focus"
            radius: Styling.radius(2)
            Layout.fillWidth: true
            implicitHeight: 34

            TextInput {
                id: ti
                anchors.fill: parent
                anchors.margins: 8
                color: Colors.overBackground
                font.family: Config.theme.font
                font.pixelSize: Styling.fontSize(0)
                selectByMouse: true
                text: row.value
                onEditingFinished: row.valueEdited(text)
                Keys.onEscapePressed: text = row.value
            }
        }
    }

    component CompositorTabButton: StyledRect {
        id: tabBtn
        property string label: ""
        property string icon: ""
        property string image: ""
        property bool isSelected: false
        signal clicked

        variant: isSelected ? "primary" : (hoverHandler.hovered ? "focus" : "common")
        Layout.preferredWidth: 140
        Layout.preferredHeight: 36
        radius: isSelected ? Styling.radius(0) / 2 : Styling.radius(0)
        enableShadow: true

        HoverHandler {
            id: hoverHandler
        }
        TapHandler {
            onTapped: tabBtn.clicked()
        }

        RowLayout {
            anchors.centerIn: parent
            spacing: 8

            // Image Icon (with effect)
            Image {
                mipmap: true
                visible: tabBtn.image !== ""
                source: tabBtn.image
                Layout.preferredWidth: 16
                Layout.preferredHeight: 16
                sourceSize: Qt.size(32, 32)
                fillMode: Image.PreserveAspectFit
                smooth: true

                layer.enabled: true
                layer.effect: MultiEffect {
                    colorization: 1.0
                    colorizationColor: tabBtn.item
                }
            }

            // Font Icon
            Text {
                visible: tabBtn.icon !== "" && tabBtn.image === ""
                text: tabBtn.icon
                font.family: Icons.font
                font.pixelSize: 14
                color: tabBtn.item
            }

            // Label
            Text {
                text: tabBtn.label
                font.family: Config.theme.font
                font.pixelSize: Styling.fontSize(0)
                font.bold: true
                color: tabBtn.item
            }
        }
    }

    // Main content
    Flickable {
        id: mainFlickable
        anchors.fill: parent
        contentHeight: mainColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: !root.colorPickerActive

        // Horizontal slide + fade animation
        opacity: root.colorPickerActive ? 0 : 1
        transform: Translate {
            x: root.colorPickerActive ? -30 : 0

            Behavior on x {
                enabled: Config.animDuration > 0
                NumberAnimation {
                    duration: Config.animDuration / 2
                    easing.type: Easing.OutQuart
                }
            }
        }

        Behavior on opacity {
            enabled: Config.animDuration > 0
            NumberAnimation {
                duration: Config.animDuration / 2
                easing.type: Easing.OutQuart
            }
        }

        ColumnLayout {
            id: mainColumn
            width: mainFlickable.width
            spacing: 8

            // Header wrapper
            Item {
                Layout.fillWidth: true
                Layout.preferredHeight: titlebar.height

                PanelTitlebar {
                    id: titlebar
                    width: root.contentWidth
                    anchors.horizontalCenter: parent.horizontalCenter
                    title: root.currentSection === "" ? I18n.t("settings.compositor") : I18n.t("compositor." + root.currentSection)
                    statusText: GlobalStates.compositorHasChanges ? "Unsaved changes" : ""
                    statusColor: Colors.error

                    actions: {
                        let baseActions = [
                            {
                                icon: Icons.arrowCounterClockwise,
                                tooltip: I18n.t("compositor.discard"),
                                enabled: GlobalStates.compositorHasChanges,
                                onClicked: function () {
                                    GlobalStates.discardCompositorChanges();
                                }
                            },
                            {
                                icon: Icons.disk,
                                tooltip: I18n.t("compositor.apply"),
                                enabled: GlobalStates.compositorHasChanges,
                                onClicked: function () {
                                    GlobalStates.applyCompositorChanges();
                                }
                            }
                        ];

                        if (root.currentSection !== "") {
                            return [
                                {
                                    icon: Icons.arrowLeft,
                                    tooltip: I18n.t("compositor.back"),
                                    onClicked: function () {
                                        root.currentSection = "";
                                    }
                                }
                            ].concat(baseActions);
                        }

                        return baseActions;
                    }
                }
            }

            // Tabs Switch
            Item {
                visible: root.currentSection === ""
                Layout.fillWidth: true
                Layout.preferredHeight: 40

                RowLayout {
                    anchors.centerIn: parent
                    spacing: 8

                    CompositorTabButton {
                        label: I18n.t("settings.compositor.axctl")
                        image: "../../../../assets/compositors/hyprland.svg"
                        isSelected: stackLayout.currentIndex === 0
                        onClicked: stackLayout.currentIndex = 0
                    }

                    CompositorTabButton {
                        label: I18n.t("common.coming_soon")
                        icon: Icons.clock
                        isSelected: stackLayout.currentIndex === 1
                        onClicked: stackLayout.currentIndex = 1
                    }
                }
            }

            // Stack for content
            Item {
                Layout.fillWidth: true
                Layout.preferredHeight: stackLayout.height

                StackLayout {
                    id: stackLayout
                    width: root.contentWidth
                    anchors.horizontalCenter: parent.horizontalCenter
                    height: currentIndex === 0 ? compositorPage.implicitHeight : placeholderPage.implicitHeight
                    currentIndex: 0

                    // ═══════════════════════════════════════════════════════════════
                    // COMPOSITOR TAB
                    // ═══════════════════════════════════════════════════════════════
                    ColumnLayout {
                        id: compositorPage
                        Layout.fillWidth: true
                        spacing: 16

                        // Menu Section
                        ColumnLayout {
                            visible: root.currentSection === ""
                            Layout.fillWidth: true
                            spacing: 8

                            SectionButton {
                                objectName: "sect_general"
                                text: I18n.t("compositor.general")
                                sectionId: "general"
                            }
                            SectionButton {
                                objectName: "sect_colors"
                                text: I18n.t("compositor.colors")
                                sectionId: "colors"
                            }
                            SectionButton {
                                objectName: "sect_shadows"
                                text: I18n.t("compositor.shadows")
                                sectionId: "shadows"
                            }
                            SectionButton {
                                objectName: "sect_blur"
                                text: I18n.t("compositor.blur")
                                sectionId: "blur"
                            }

                                                    SectionButton {
                                                    objectName: "sect_opacity"
                                                    text: I18n.t("compositor.opacity")
                                                    sectionId: "opacity"
                                                    visible: CompositorKeywords.supports("opacity")
                                                    }
                                                    SectionButton {
                                                    objectName: "sect_snap"
                                                    text: I18n.t("compositor.snap")
                                                    sectionId: "snap"
                                                    visible: CompositorKeywords.supports("snap")
                                                    }
                                                    SectionButton {
                                                    objectName: "sect_input"
                                                    text: I18n.t("compositor.input")
                                                    sectionId: "input"
                                                    visible: CompositorKeywords.supports("input")
                                                    }
                                                    SectionButton {
                                                    objectName: "sect_cursor"
                                                    text: I18n.t("compositor.cursor")
                                                    sectionId: "cursor"
                                                    visible: CompositorKeywords.supports("cursor")
                                                    }
                                                    SectionButton {
                                                    objectName: "sect_gestures"
                                                    text: I18n.t("compositor.gestures")
                                                    sectionId: "gestures"
                                                    visible: CompositorKeywords.supports("gestures")
                                                    }
                                                    SectionButton {
                                                    objectName: "sect_layouts"
                                                    text: I18n.t("compositor.layouts")
                                                    sectionId: "layouts"
                                                    visible: CompositorKeywords.supports("layouts")
                                                    }
                                                    SectionButton {
                                                    objectName: "sect_advanced"
                                                    text: I18n.t("compositor.advanced")
                                                    sectionId: "advanced"
                                                    visible: CompositorKeywords.supports("advanced")
                                                    }

                                                    // Output configuration. Always offered:
                                                    // every supported compositor exposes a
                                                    // runtime output API, even though niri has
                                                    // no keyword interface for the rest.
                                                    SectionButton {
                                                        objectName: "sect_monitors"
                                                        text: I18n.t("mp.title")
                                                        sectionId: "monitors"
                                                    }
                        }

                        // General Section
                        ColumnLayout {
                            visible: root.currentSection === "general"
                            Layout.fillWidth: true
                            spacing: 8

                            Text {
                                text: I18n.t("compositor.general")
                                font.family: Config.theme.font
                                font.pixelSize: Styling.fontSize(-1)
                                font.weight: Font.Medium
                                color: Colors.overSurfaceVariant
                                Layout.bottomMargin: -4
                            }

                            ToggleRow {
                                label: I18n.t("compositor.sync_border_size")
                                checked: Config.compositor.syncBorderWidth ?? false
                                onToggled: value => {
                                    GlobalStates.markCompositorChanged();
                                    Config.compositor.syncBorderWidth = value;
                                }
                            }

                            NumberInputRow {
                                label: I18n.t("settings.compositor.border_size")
                                value: Config.compositor.borderSize ?? 2
                                minValue: 0
                                maxValue: 999
                                suffix: "px"
                                enabled: !Config.compositor.syncBorderWidth
                                onValueEdited: newValue => {
                                    GlobalStates.markCompositorChanged();
                                    Config.compositor.borderSize = newValue;
                                }
                            }

                            ToggleRow {
                                label: I18n.t("compositor.sync_rounding")
                                checked: Config.compositor.syncRoundness ?? true
                                onToggled: value => {
                                    GlobalStates.markCompositorChanged();
                                    Config.compositor.syncRoundness = value;
                                }
                            }

                            NumberInputRow {
                                label: I18n.t("compositor.rounding")
                                value: Config.compositor.rounding ?? 16
                                minValue: 0
                                maxValue: 999
                                suffix: "px"
                                enabled: !Config.compositor.syncRoundness
                                onValueEdited: newValue => {
                                    GlobalStates.markCompositorChanged();
                                    Config.compositor.rounding = newValue;
                                }
                            }

                            NumberInputRow {
                                label: I18n.t("compositor.gaps_in")
                                value: Config.compositor.gapsIn ?? 5
                                minValue: 0
                                maxValue: 50
                                suffix: "px"
                                onValueEdited: newValue => {
                                    GlobalStates.markCompositorChanged();
                                    Config.compositor.gapsIn = newValue;
                                }
                            }

                            NumberInputRow {
                                label: I18n.t("compositor.gaps_out")
                                value: Config.compositor.gapsOut ?? 10
                                minValue: 0
                                maxValue: 50
                                suffix: "px"
                                onValueEdited: newValue => {
                                    GlobalStates.markCompositorChanged();
                                    Config.compositor.gapsOut = newValue;
                                }
                            }

                            NumberInputRow {
                                label: I18n.t("compositor.border_angle")
                                value: Config.compositor.borderAngle ?? 45
                                minValue: 0
                                maxValue: 360
                                suffix: "deg"
                                onValueEdited: newValue => {
                                    GlobalStates.markCompositorChanged();
                                    Config.compositor.borderAngle = newValue;
                                }
                            }

                            NumberInputRow {
                                label: I18n.t("compositor.inactive_angle")
                                value: Config.compositor.inactiveBorderAngle ?? 45
                                minValue: 0
                                maxValue: 360
                                suffix: "deg"
                                onValueEdited: newValue => {
                                    GlobalStates.markCompositorChanged();
                                    Config.compositor.inactiveBorderAngle = newValue;
                                }
                            }
                        }

                        Separator {
                            Layout.fillWidth: true
                            visible: false
                        }

                        // Colors Section
                        ColumnLayout {
                            visible: root.currentSection === "colors"
                            Layout.fillWidth: true
                            spacing: 8

                            Text {
                                text: I18n.t("compositor.colors")
                                font.family: Config.theme.font
                                font.pixelSize: Styling.fontSize(-1)
                                font.weight: Font.Medium
                                color: Colors.overSurfaceVariant
                                Layout.bottomMargin: -4
                            }

                            ToggleRow {
                                label: I18n.t("compositor.sync_border_color")
                                checked: Config.compositor.syncBorderColor ?? false
                                onToggled: value => {
                                    GlobalStates.markCompositorChanged();
                                    Config.compositor.syncBorderColor = value;
                                }
                            }

                            // Active Border Color
                            BorderGradientRow {
                                label: I18n.t("compositor.active_border")
                                colors: Config.compositor.activeBorderColor || ["primary"]
                                dialogTitle: "Edit Active Border Color"
                                enabled: !Config.compositor.syncBorderColor
                                onColorsEdited: newColors => {
                                    GlobalStates.markCompositorChanged();
                                    Config.compositor.activeBorderColor = newColors;
                                }
                            }

                            // Inactive Border Color
                            BorderGradientRow {
                                label: I18n.t("compositor.inactive_border")
                                colors: Config.compositor.inactiveBorderColor || ["surface"]
                                dialogTitle: "Edit Inactive Border Color"
                                onColorsEdited: newColors => {
                                    GlobalStates.markCompositorChanged();
                                    Config.compositor.inactiveBorderColor = newColors;
                                }
                            }
                        }

                        Separator {
                            Layout.fillWidth: true
                            visible: false
                        }

                        // Shadows Section
                        ColumnLayout {
                            visible: root.currentSection === "shadows"
                            Layout.fillWidth: true
                            spacing: 8

                            Text {
                                text: I18n.t("compositor.shadows")
                                font.family: Config.theme.font
                                font.pixelSize: Styling.fontSize(-1)
                                font.weight: Font.Medium
                                color: Colors.overSurfaceVariant
                                Layout.bottomMargin: -4
                            }

                            ToggleRow {
                                label: I18n.t("settings.compositor.shadows_enabled")
                                checked: Config.compositor.shadowEnabled ?? true
                                onToggled: value => {
                                    GlobalStates.markCompositorChanged();
                                    Config.compositor.shadowEnabled = value;
                                }
                            }

                            ToggleRow {
                                label: I18n.t("settings.compositor.sync_shadow_color")
                                checked: Config.compositor.syncShadowColor ?? false
                                onToggled: value => {
                                    GlobalStates.markCompositorChanged();
                                    Config.compositor.syncShadowColor = value;
                                }
                            }

                            ToggleRow {
                                label: I18n.t("settings.compositor.sync_shadow_opacity")
                                checked: Config.compositor.syncShadowOpacity ?? false
                                onToggled: value => {
                                    GlobalStates.markCompositorChanged();
                                    Config.compositor.syncShadowOpacity = value;
                                }
                            }

                            NumberInputRow {
                                label: I18n.t("settings.compositor.shadow_range")
                                value: Config.compositor.shadowRange ?? 4
                                minValue: 0
                                maxValue: 100
                                suffix: "px"
                                onValueEdited: newValue => {
                                    GlobalStates.markCompositorChanged();
                                    Config.compositor.shadowRange = newValue;
                                }
                            }

                            NumberInputRow {
                                label: I18n.t("compositor.offset_x")
                                value: parseInt((Config.compositor.shadowOffset ?? "0 0").split(" ")[0]) || 0
                                minValue: -50
                                maxValue: 50
                                suffix: "px"
                                onValueEdited: newValue => {
                                    GlobalStates.markCompositorChanged();
                                    let parts = (Config.compositor.shadowOffset ?? "0 0").split(" ");
                                    let y = parts.length > 1 ? parts[1] : "0";
                                    Config.compositor.shadowOffset = newValue + " " + y;
                                }
                            }

                            NumberInputRow {
                                label: I18n.t("compositor.offset_y")
                                value: parseInt((Config.compositor.shadowOffset ?? "0 0").split(" ")[1]) || 0
                                minValue: -50
                                maxValue: 50
                                suffix: "px"
                                onValueEdited: newValue => {
                                    GlobalStates.markCompositorChanged();
                                    let parts = (Config.compositor.shadowOffset ?? "0 0").split(" ");
                                    let x = parts.length > 0 ? parts[0] : "0";
                                    Config.compositor.shadowOffset = x + " " + newValue;
                                }
                            }

                            NumberInputRow {
                                label: I18n.t("settings.compositor.shadow_power")
                                value: Config.compositor.shadowRenderPower ?? 3
                                minValue: 1
                                maxValue: 4
                                onValueEdited: newValue => {
                                    GlobalStates.markCompositorChanged();
                                    Config.compositor.shadowRenderPower = newValue;
                                }
                            }

                            DecimalInputRow {
                                label: I18n.t("settings.compositor.shadow_scale")
                                value: Config.compositor.shadowScale ?? 1.0
                                minValue: 0.0
                                maxValue: 1.0
                                onValueEdited: newValue => {
                                    GlobalStates.markCompositorChanged();
                                    Config.compositor.shadowScale = newValue;
                                }
                            }

                            DecimalInputRow {
                                label: I18n.t("compositor.opacity")
                                value: Config.compositor.shadowOpacity ?? 0.5
                                minValue: 0.0
                                maxValue: 1.0
                                enabled: !Config.compositor.syncShadowOpacity
                                onValueEdited: newValue => {
                                    GlobalStates.markCompositorChanged();
                                    Config.compositor.shadowOpacity = newValue;
                                }
                            }

                            ToggleRow {
                                label: I18n.t("compositor.sharp")
                                checked: Config.compositor.shadowSharp ?? false
                                onToggled: value => {
                                    GlobalStates.markCompositorChanged();
                                    Config.compositor.shadowSharp = value;
                                }
                            }

                            ToggleRow {
                                label: I18n.t("compositor.ignore_window")
                                checked: Config.compositor.shadowIgnoreWindow ?? true
                                onToggled: value => {
                                    GlobalStates.markCompositorChanged();
                                    Config.compositor.shadowIgnoreWindow = value;
                                }
                            }
                        }

                        Separator {
                            Layout.fillWidth: true
                            visible: false
                        }

                        // Blur Section
                        ColumnLayout {
                            visible: root.currentSection === "blur"
                            Layout.fillWidth: true
                            spacing: 8

                            Text {
                                text: I18n.t("compositor.blur")
                                font.family: Config.theme.font
                                font.pixelSize: Styling.fontSize(-1)
                                font.weight: Font.Medium
                                color: Colors.overSurfaceVariant
                                Layout.bottomMargin: -4
                            }

                            ToggleRow {
                                label: I18n.t("settings.compositor.blur_enabled")
                                checked: Config.compositor.blurEnabled ?? true
                                onToggled: value => {
                                    GlobalStates.markCompositorChanged();
                                    Config.compositor.blurEnabled = value;
                                }
                            }

                            NumberInputRow {
                                label: I18n.t("settings.compositor.blur_size")
                                value: Config.compositor.blurSize ?? 8
                                minValue: 0
                                maxValue: 20
                                onValueEdited: newValue => {
                                    GlobalStates.markCompositorChanged();
                                    Config.compositor.blurSize = newValue;
                                }
                            }

                            NumberInputRow {
                                label: I18n.t("settings.compositor.blur_passes")
                                value: Config.compositor.blurPasses ?? 1
                                minValue: 0
                                maxValue: 4
                                onValueEdited: newValue => {
                                    GlobalStates.markCompositorChanged();
                                    Config.compositor.blurPasses = newValue;
                                }
                            }

                            ToggleRow {
                                label: I18n.t("settings.compositor.blur_xray")
                                checked: Config.compositor.blurXray ?? false
                                onToggled: value => {
                                    GlobalStates.markCompositorChanged();
                                    Config.compositor.blurXray = value;
                                }
                            }

                            ToggleRow {
                                label: I18n.t("settings.compositor.blur_new_optimizations")
                                checked: Config.compositor.blurNewOptimizations ?? true
                                onToggled: value => {
                                    GlobalStates.markCompositorChanged();
                                    Config.compositor.blurNewOptimizations = value;
                                }
                            }

                            ToggleRow {
                                label: I18n.t("settings.compositor.blur_ignore_opacity")
                                checked: Config.compositor.blurIgnoreOpacity ?? true
                                onToggled: value => {
                                    GlobalStates.markCompositorChanged();
                                    Config.compositor.blurIgnoreOpacity = value;
                                }
                            }

                            ToggleRow {
                                label: I18n.t("settings.compositor.blur_ignorealpha")
                                checked: Config.compositor.blurExplicitIgnoreAlpha ?? false
                                onToggled: value => {
                                    GlobalStates.markCompositorChanged();
                                    Config.compositor.blurExplicitIgnoreAlpha = value;
                                }
                            }

                            DecimalInputRow {
                                label: I18n.t("settings.compositor.blur_ignorealpha_value")
                                value: Config.compositor.blurIgnoreAlphaValue ?? 0.2
                                minValue: 0.0
                                maxValue: 1.0
                                enabled: Config.compositor.blurExplicitIgnoreAlpha
                                onValueEdited: newValue => {
                                    GlobalStates.markCompositorChanged();
                                    Config.compositor.blurIgnoreAlphaValue = newValue;
                                }
                            }

                            DecimalInputRow {
                                label: I18n.t("settings.compositor.blur_noise")
                                value: Config.compositor.blurNoise ?? 0.01
                                minValue: 0.0
                                maxValue: 1.0
                                onValueEdited: newValue => {
                                    GlobalStates.markCompositorChanged();
                                    Config.compositor.blurNoise = newValue;
                                }
                            }

                            DecimalInputRow {
                                label: I18n.t("settings.compositor.blur_contrast")
                                value: Config.compositor.blurContrast ?? 0.89
                                minValue: 0.0
                                maxValue: 2.0
                                onValueEdited: newValue => {
                                    GlobalStates.markCompositorChanged();
                                    Config.compositor.blurContrast = newValue;
                                }
                            }

                            DecimalInputRow {
                                label: I18n.t("settings.compositor.blur_brightness")
                                value: Config.compositor.blurBrightness ?? 0.81
                                minValue: 0.0
                                maxValue: 2.0
                                onValueEdited: newValue => {
                                    GlobalStates.markCompositorChanged();
                                    Config.compositor.blurBrightness = newValue;
                                }
                            }

                            DecimalInputRow {
                                label: I18n.t("settings.compositor.blur_vibrancy")
                                value: Config.compositor.blurVibrancy ?? 0.17
                                minValue: 0.0
                                maxValue: 1.0
                                onValueEdited: newValue => {
                                    GlobalStates.markCompositorChanged();
                                    Config.compositor.blurVibrancy = newValue;
                                }
                            }
                        }

                        // Bottom Padding
                        Item {
                            Layout.fillWidth: true
                            Layout.preferredHeight: 16
                        }

                            // ============================================================
                            // OPACITY  (axless.core, NothingLess settings)
                            // ============================================================
                            ColumnLayout {
                                visible: root.currentSection === "opacity"
                                Layout.fillWidth: true
                                spacing: 8

                                Text {
                                    text: I18n.t("compositor.opacity")
                                    font.family: Config.theme.font
                                    font.pixelSize: Styling.fontSize(-1)
                                    font.weight: Font.Medium
                                    color: Colors.overSurfaceVariant
                                    Layout.bottomMargin: -4
                                }
                            DecimalInputRow {
                                label: I18n.t("op.active_opacity")
                                value: Config.compositor.activeOpacity
                                minValue: 0.0
                                maxValue: 100.0
                                onValueEdited: v => {
                                    GlobalStates.markCompositorChanged();
                                    Config.compositor.activeOpacity = v;
                                    CompositorKeywords.setKeyword("decoration:active_opacity", v);
                                }
                            }
                            DecimalInputRow {
                                label: I18n.t("op.inactive_opacity")
                                value: Config.compositor.inactiveOpacity
                                minValue: 0.0
                                maxValue: 100.0
                                onValueEdited: v => {
                                    GlobalStates.markCompositorChanged();
                                    Config.compositor.inactiveOpacity = v;
                                    CompositorKeywords.setKeyword("decoration:inactive_opacity", v);
                                }
                            }
                            DecimalInputRow {
                                label: I18n.t("op.fullscreen_opacity")
                                value: Config.compositor.fullscreenOpacity
                                minValue: 0.0
                                maxValue: 100.0
                                onValueEdited: v => {
                                    GlobalStates.markCompositorChanged();
                                    Config.compositor.fullscreenOpacity = v;
                                    CompositorKeywords.setKeyword("decoration:fullscreen_opacity", v);
                                }
                            }
                            }

                            // ============================================================
                            // SNAPPING  (axless.core, NothingLess settings)
                            // ============================================================
                            ColumnLayout {
                                visible: root.currentSection === "snap"
                                Layout.fillWidth: true
                                spacing: 8

                                Text {
                                    text: I18n.t("compositor.snap")
                                    font.family: Config.theme.font
                                    font.pixelSize: Styling.fontSize(-1)
                                    font.weight: Font.Medium
                                    color: Colors.overSurfaceVariant
                                    Layout.bottomMargin: -4
                                }
                            ToggleRow {
                                label: I18n.t("snap.enabled")
                                checked: Config.compositor.snapEnabled
                                onToggled: v => {
                                    GlobalStates.markCompositorChanged();
                                    Config.compositor.snapEnabled = v;
                                    CompositorKeywords.setKeyword("group:smart_resize", v);
                                }
                            }
                            ToggleRow {
                                label: I18n.t("snap.respect_gaps")
                                checked: Config.compositor.snapRespectGaps
                                onToggled: v => {
                                    GlobalStates.markCompositorChanged();
                                    Config.compositor.snapRespectGaps = v;
                                    CompositorKeywords.setKeyword("group:special", v);
                                }
                            }
                            NumberInputRow {
                                label: I18n.t("snap.window_gap")
                                value: Config.compositor.snapWindowGap
                                minValue: 0
                                maxValue: 100000
                                onValueEdited: v => {
                                    GlobalStates.markCompositorChanged();
                                    Config.compositor.snapWindowGap = v;
                                    CompositorKeywords.setKeyword("snap:window_gap", v);
                                }
                            }
                            NumberInputRow {
                                label: I18n.t("snap.monitor_gap")
                                value: Config.compositor.snapMonitorGap
                                minValue: 0
                                maxValue: 100000
                                onValueEdited: v => {
                                    GlobalStates.markCompositorChanged();
                                    Config.compositor.snapMonitorGap = v;
                                    CompositorKeywords.setKeyword("snap:monitor_gap", v);
                                }
                            }
                            ToggleRow {
                                label: I18n.t("snap.border_overlap")
                                checked: Config.compositor.snapBorderOverlap
                                onToggled: v => {
                                    GlobalStates.markCompositorChanged();
                                    Config.compositor.snapBorderOverlap = v;
                                    CompositorKeywords.setKeyword("snap:border_overlap", v);
                                }
                            }
                            }

                            // ============================================================
                            // INPUT  (axless.core, NothingLess settings)
                            // ============================================================
                            ColumnLayout {
                                visible: root.currentSection === "input"
                                Layout.fillWidth: true
                                spacing: 8

                                Text {
                                    text: I18n.t("compositor.input")
                                    font.family: Config.theme.font
                                    font.pixelSize: Styling.fontSize(-1)
                                    font.weight: Font.Medium
                                    color: Colors.overSurfaceVariant
                                    Layout.bottomMargin: -4
                                }
                            KeywordTextRow {
                                label: I18n.t("input.kb_layout")
                                value: Config.compositor.kbLayout
                                onValueEdited: v => {
                                    GlobalStates.markCompositorChanged();
                                    Config.compositor.kbLayout = v;
                                    CompositorKeywords.setKeyword("input:kb_layout", v);
                                }
                            }
                            KeywordTextRow {
                                label: I18n.t("input.kb_variant")
                                value: Config.compositor.kbVariant
                                onValueEdited: v => {
                                    GlobalStates.markCompositorChanged();
                                    Config.compositor.kbVariant = v;
                                    CompositorKeywords.setKeyword("input:kb_variant", v);
                                }
                            }
                            KeywordTextRow {
                                label: I18n.t("input.kb_options")
                                value: Config.compositor.kbOptions
                                onValueEdited: v => {
                                    GlobalStates.markCompositorChanged();
                                    Config.compositor.kbOptions = v;
                                    CompositorKeywords.setKeyword("input:kb_options", v);
                                }
                            }
                            ToggleRow {
                                label: I18n.t("input.numlock")
                                checked: Config.compositor.numlockByDefault
                                onToggled: v => {
                                    GlobalStates.markCompositorChanged();
                                    Config.compositor.numlockByDefault = v;
                                    CompositorKeywords.setKeyword("input:numlock_by_default", v);
                                }
                            }
                            NumberInputRow {
                                label: I18n.t("input.repeat_rate")
                                value: Config.compositor.repeatRate
                                minValue: 0
                                maxValue: 100000
                                onValueEdited: v => {
                                    GlobalStates.markCompositorChanged();
                                    Config.compositor.repeatRate = v;
                                    CompositorKeywords.setKeyword("input:repeat_rate", v);
                                }
                            }
                            NumberInputRow {
                                label: I18n.t("input.repeat_delay")
                                value: Config.compositor.repeatDelay
                                minValue: 0
                                maxValue: 100000
                                onValueEdited: v => {
                                    GlobalStates.markCompositorChanged();
                                    Config.compositor.repeatDelay = v;
                                    CompositorKeywords.setKeyword("input:repeat_delay", v);
                                }
                            }
                            DecimalInputRow {
                                label: I18n.t("input.sensitivity")
                                value: Config.compositor.mouseSensitivity
                                minValue: 0.0
                                maxValue: 100.0
                                onValueEdited: v => {
                                    GlobalStates.markCompositorChanged();
                                    Config.compositor.mouseSensitivity = v;
                                    CompositorKeywords.setKeyword("input:sensitivity", v);
                                }
                            }
                            KeywordTextRow {
                                label: I18n.t("input.accel_profile")
                                value: Config.compositor.mouseAccelProfile
                                onValueEdited: v => {
                                    GlobalStates.markCompositorChanged();
                                    Config.compositor.mouseAccelProfile = v;
                                    CompositorKeywords.setKeyword("input:accel_profile", v);
                                }
                            }
                            NumberInputRow {
                                label: I18n.t("input.follow_mouse")
                                value: Config.compositor.followMouse
                                minValue: 0
                                maxValue: 100000
                                onValueEdited: v => {
                                    GlobalStates.markCompositorChanged();
                                    Config.compositor.followMouse = v;
                                    CompositorKeywords.setKeyword("input:follow_mouse", v);
                                }
                            }
                            ToggleRow {
                                label: I18n.t("input.natural_scroll")
                                checked: Config.compositor.mouseNaturalScroll
                                onToggled: v => {
                                    GlobalStates.markCompositorChanged();
                                    Config.compositor.mouseNaturalScroll = v;
                                    CompositorKeywords.setKeyword("input:natural_scroll", v);
                                }
                            }
                            DecimalInputRow {
                                label: I18n.t("input.scroll_factor")
                                value: Config.compositor.mouseScrollFactor
                                minValue: 0.0
                                maxValue: 100.0
                                onValueEdited: v => {
                                    GlobalStates.markCompositorChanged();
                                    Config.compositor.mouseScrollFactor = v;
                                    CompositorKeywords.setKeyword("input:scroll_factor", v);
                                }
                            }
                            ToggleRow {
                                label: I18n.t("input.left_handed")
                                checked: Config.compositor.mouseLeftHanded
                                onToggled: v => {
                                    GlobalStates.markCompositorChanged();
                                    Config.compositor.mouseLeftHanded = v;
                                    CompositorKeywords.setKeyword("input:left_handed", v);
                                }
                            }
                            ToggleRow {
                                label: I18n.t("input.refocus")
                                checked: Config.compositor.mouseRefocus
                                onToggled: v => {
                                    GlobalStates.markCompositorChanged();
                                    Config.compositor.mouseRefocus = v;
                                    CompositorKeywords.setKeyword("input:refocus", v);
                                }
                            }
                            NumberInputRow {
                                label: I18n.t("input.float_switch_focus")
                                value: Config.compositor.floatSwitchOverrideFocus
                                minValue: 0
                                maxValue: 100000
                                onValueEdited: v => {
                                    GlobalStates.markCompositorChanged();
                                    Config.compositor.floatSwitchOverrideFocus = v;
                                    CompositorKeywords.setKeyword("input:float_switch_override_focus", v);
                                }
                            }
                            ToggleRow {
                                label: I18n.t("input.tp_disable_typing")
                                checked: Config.compositor.touchpadDisableWhileTyping
                                onToggled: v => {
                                    GlobalStates.markCompositorChanged();
                                    Config.compositor.touchpadDisableWhileTyping = v;
                                    CompositorKeywords.setKeyword("input:touchpad:disable_while_typing", v);
                                }
                            }
                            ToggleRow {
                                label: I18n.t("input.tp_natural_scroll")
                                checked: Config.compositor.touchpadNaturalScroll
                                onToggled: v => {
                                    GlobalStates.markCompositorChanged();
                                    Config.compositor.touchpadNaturalScroll = v;
                                    CompositorKeywords.setKeyword("input:touchpad:natural_scroll", v);
                                }
                            }
                            ToggleRow {
                                label: I18n.t("input.tp_tap_to_click")
                                checked: Config.compositor.touchpadTapToClick
                                onToggled: v => {
                                    GlobalStates.markCompositorChanged();
                                    Config.compositor.touchpadTapToClick = v;
                                    CompositorKeywords.setKeyword("input:touchpad:tap_to_click", v);
                                }
                            }
                            ToggleRow {
                                label: I18n.t("input.tp_clickfinger")
                                checked: Config.compositor.touchpadClickfingerBehavior
                                onToggled: v => {
                                    GlobalStates.markCompositorChanged();
                                    Config.compositor.touchpadClickfingerBehavior = v;
                                    CompositorKeywords.setKeyword("input:touchpad:clickfinger_behavior", v);
                                }
                            }
                            KeywordTextRow {
                                label: I18n.t("input.tp_tap_button_map")
                                value: Config.compositor.touchpadTapButtonMap
                                onValueEdited: v => {
                                    GlobalStates.markCompositorChanged();
                                    Config.compositor.touchpadTapButtonMap = v;
                                    CompositorKeywords.setKeyword("input:touchpad:tap_button_map", v);
                                }
                            }
                            ToggleRow {
                                label: I18n.t("input.tp_middle_emulation")
                                checked: Config.compositor.touchpadMiddleButtonEmulation
                                onToggled: v => {
                                    GlobalStates.markCompositorChanged();
                                    Config.compositor.touchpadMiddleButtonEmulation = v;
                                    CompositorKeywords.setKeyword("input:touchpad:middle_button_emulation", v);
                                }
                            }
                            KeywordTextRow {
                                label: I18n.t("input.tp_drag_lock")
                                value: Config.compositor.touchpadDragLock
                                onValueEdited: v => {
                                    GlobalStates.markCompositorChanged();
                                    Config.compositor.touchpadDragLock = v;
                                    CompositorKeywords.setKeyword("input:touchpad:drag_lock", v);
                                }
                            }
                            DecimalInputRow {
                                label: I18n.t("input.tp_scroll_factor")
                                value: Config.compositor.touchpadScrollFactor
                                minValue: 0.0
                                maxValue: 100.0
                                onValueEdited: v => {
                                    GlobalStates.markCompositorChanged();
                                    Config.compositor.touchpadScrollFactor = v;
                                    CompositorKeywords.setKeyword("input:touchpad:scroll_factor", v);
                                }
                            }
                            }

                            // ============================================================
                            // CURSOR  (axless.core, NothingLess settings)
                            // ============================================================
                            ColumnLayout {
                                visible: root.currentSection === "cursor"
                                Layout.fillWidth: true
                                spacing: 8

                                Text {
                                    text: I18n.t("compositor.cursor")
                                    font.family: Config.theme.font
                                    font.pixelSize: Styling.fontSize(-1)
                                    font.weight: Font.Medium
                                    color: Colors.overSurfaceVariant
                                    Layout.bottomMargin: -4
                                }
                            ToggleRow {
                                label: I18n.t("cursor.no_hardware")
                                checked: Config.compositor.noHardwareCursors
                                onToggled: v => {
                                    GlobalStates.markCompositorChanged();
                                    Config.compositor.noHardwareCursors = v;
                                    CompositorKeywords.setKeyword("cursor:no_hardware_cursors", v);
                                }
                            }
                            ToggleRow {
                                label: I18n.t("cursor.hyprcursor")
                                checked: Config.compositor.enableHyprcursor
                                onToggled: v => {
                                    GlobalStates.markCompositorChanged();
                                    Config.compositor.enableHyprcursor = v;
                                    CompositorKeywords.setKeyword("cursor:enable_hyprcursor", v);
                                }
                            }
                            ToggleRow {
                                label: I18n.t("cursor.no_warps")
                                checked: Config.compositor.noWarps
                                onToggled: v => {
                                    GlobalStates.markCompositorChanged();
                                    Config.compositor.noWarps = v;
                                    CompositorKeywords.setKeyword("cursor:no_warps", v);
                                }
                            }
                            ToggleRow {
                                label: I18n.t("cursor.persistent_warps")
                                checked: Config.compositor.persistentWarps
                                onToggled: v => {
                                    GlobalStates.markCompositorChanged();
                                    Config.compositor.persistentWarps = v;
                                    CompositorKeywords.setKeyword("cursor:persistent_warps", v);
                                }
                            }
                            ToggleRow {
                                label: I18n.t("cursor.warp_on_change")
                                checked: Config.compositor.warpOnChangeWorkspace
                                onToggled: v => {
                                    GlobalStates.markCompositorChanged();
                                    Config.compositor.warpOnChangeWorkspace = v;
                                    CompositorKeywords.setKeyword("cursor:warp_on_change_workspace", v);
                                }
                            }
                            DecimalInputRow {
                                label: I18n.t("cursor.zoom_factor")
                                value: Config.compositor.cursorZoomFactor
                                minValue: 0.0
                                maxValue: 100.0
                                onValueEdited: v => {
                                    GlobalStates.markCompositorChanged();
                                    Config.compositor.cursorZoomFactor = v;
                                    CompositorKeywords.setKeyword("cursor:zoom_factor", v);
                                }
                            }
                            NumberInputRow {
                                label: I18n.t("cursor.inactive_timeout")
                                value: Config.compositor.cursorInactiveTimeout
                                minValue: 0
                                maxValue: 100000
                                onValueEdited: v => {
                                    GlobalStates.markCompositorChanged();
                                    Config.compositor.cursorInactiveTimeout = v;
                                    CompositorKeywords.setKeyword("cursor:inactive_timeout", v);
                                }
                            }
                            ToggleRow {
                                label: I18n.t("cursor.hide_on_key")
                                checked: Config.compositor.cursorHideOnKeyPress
                                onToggled: v => {
                                    GlobalStates.markCompositorChanged();
                                    Config.compositor.cursorHideOnKeyPress = v;
                                    CompositorKeywords.setKeyword("cursor:hide_on_key_press", v);
                                }
                            }
                            ToggleRow {
                                label: I18n.t("cursor.hide_on_touch")
                                checked: Config.compositor.cursorHideOnTouch
                                onToggled: v => {
                                    GlobalStates.markCompositorChanged();
                                    Config.compositor.cursorHideOnTouch = v;
                                    CompositorKeywords.setKeyword("cursor:hide_on_touch", v);
                                }
                            }
                            ToggleRow {
                                label: I18n.t("cursor.hide_on_tablet")
                                checked: Config.compositor.cursorHideOnTablet
                                onToggled: v => {
                                    GlobalStates.markCompositorChanged();
                                    Config.compositor.cursorHideOnTablet = v;
                                    CompositorKeywords.setKeyword("cursor:hide_on_tablet", v);
                                }
                            }
                            }

                            // ============================================================
                            // GESTURES  (axless.core, NothingLess settings)
                            // ============================================================
                            ColumnLayout {
                                visible: root.currentSection === "gestures"
                                Layout.fillWidth: true
                                spacing: 8

                                Text {
                                    text: I18n.t("compositor.gestures")
                                    font.family: Config.theme.font
                                    font.pixelSize: Styling.fontSize(-1)
                                    font.weight: Font.Medium
                                    color: Colors.overSurfaceVariant
                                    Layout.bottomMargin: -4
                                }
                            ToggleRow {
                                label: I18n.t("gest.wipe_create")
                                checked: Config.compositor.workspaceSwipeCreateNew
                                onToggled: v => {
                                    GlobalStates.markCompositorChanged();
                                    Config.compositor.workspaceSwipeCreateNew = v;
                                    CompositorKeywords.setKeyword("gestures:workspace_swipe_create_new", v);
                                }
                            }
                            ToggleRow {
                                label: I18n.t("gest.wipe_forever")
                                checked: Config.compositor.workspaceSwipeForever
                                onToggled: v => {
                                    GlobalStates.markCompositorChanged();
                                    Config.compositor.workspaceSwipeForever = v;
                                    CompositorKeywords.setKeyword("gestures:workspace_swipe_forever", v);
                                }
                            }
                            DecimalInputRow {
                                label: I18n.t("gest.wipe_cancel")
                                value: Config.compositor.workspaceSwipeCancelRatio
                                minValue: 0.0
                                maxValue: 100.0
                                onValueEdited: v => {
                                    GlobalStates.markCompositorChanged();
                                    Config.compositor.workspaceSwipeCancelRatio = v;
                                    CompositorKeywords.setKeyword("gestures:workspace_swipe_cancel_ratio", v);
                                }
                            }
                            DecimalInputRow {
                                label: I18n.t("gest.wipe_min_speed")
                                value: Config.compositor.workspaceSwipeMinSpeedToForce
                                minValue: 0.0
                                maxValue: 100.0
                                onValueEdited: v => {
                                    GlobalStates.markCompositorChanged();
                                    Config.compositor.workspaceSwipeMinSpeedToForce = v;
                                    CompositorKeywords.setKeyword("gestures:workspace_swipe_min_speed_to_force", v);
                                }
                            }
                            ToggleRow {
                                label: I18n.t("gest.wipe_lock")
                                checked: Config.compositor.workspaceSwipeDirectionLock
                                onToggled: v => {
                                    GlobalStates.markCompositorChanged();
                                    Config.compositor.workspaceSwipeDirectionLock = v;
                                    CompositorKeywords.setKeyword("gestures:workspace_swipe_direction_lock", v);
                                }
                            }
                            NumberInputRow {
                                label: I18n.t("gest.wipe_distance")
                                value: Config.compositor.workspaceSwipeDistance
                                minValue: 0
                                maxValue: 100000
                                onValueEdited: v => {
                                    GlobalStates.markCompositorChanged();
                                    Config.compositor.workspaceSwipeDistance = v;
                                    CompositorKeywords.setKeyword("gestures:workspace_swipe_distance", v);
                                }
                            }
                            ToggleRow {
                                label: I18n.t("gest.wipe_invert")
                                checked: Config.compositor.workspaceSwipeInvert
                                onToggled: v => {
                                    GlobalStates.markCompositorChanged();
                                    Config.compositor.workspaceSwipeInvert = v;
                                    CompositorKeywords.setKeyword("gestures:workspace_swipe_invert", v);
                                }
                            }
                            NumberInputRow {
                                label: I18n.t("gest.close_timeout")
                                value: Config.compositor.gestureCloseTimeout
                                minValue: 0
                                maxValue: 100000
                                onValueEdited: v => {
                                    GlobalStates.markCompositorChanged();
                                    Config.compositor.gestureCloseTimeout = v;
                                    CompositorKeywords.setKeyword("gestures:gesture_close_timeout", v);
                                }
                            }
                            }

                            // ============================================================
                            // LAYOUTS  (axless.core, NothingLess settings)
                            // ============================================================
                            ColumnLayout {
                                visible: root.currentSection === "layouts"
                                Layout.fillWidth: true
                                spacing: 8

                                Text {
                                    text: I18n.t("compositor.layouts")
                                    font.family: Config.theme.font
                                    font.pixelSize: Styling.fontSize(-1)
                                    font.weight: Font.Medium
                                    color: Colors.overSurfaceVariant
                                    Layout.bottomMargin: -4
                                }
                            ToggleRow {
                                label: I18n.t("lay.dwindle_preserve")
                                checked: Config.compositor.dwindlePreserveSplit
                                onToggled: v => {
                                    GlobalStates.markCompositorChanged();
                                    Config.compositor.dwindlePreserveSplit = v;
                                    CompositorKeywords.setKeyword("dwindle:preserve_split", v);
                                }
                            }
                            ToggleRow {
                                label: I18n.t("lay.pseudotile")
                                checked: Config.compositor.dwindlePseudotile
                                onToggled: v => {
                                    GlobalStates.markCompositorChanged();
                                    Config.compositor.dwindlePseudotile = v;
                                    CompositorKeywords.setKeyword("dwindle:pseudotile", v);
                                }
                            }
                            ToggleRow {
                                label: I18n.t("lay.smart_split")
                                checked: Config.compositor.dwindleSmartSplit
                                onToggled: v => {
                                    GlobalStates.markCompositorChanged();
                                    Config.compositor.dwindleSmartSplit = v;
                                    CompositorKeywords.setKeyword("dwindle:smart_split", v);
                                }
                            }
                            DecimalInputRow {
                                label: I18n.t("lay.default_ratio")
                                value: Config.compositor.dwindleDefaultSplitRatio
                                minValue: 0.0
                                maxValue: 100.0
                                onValueEdited: v => {
                                    GlobalStates.markCompositorChanged();
                                    Config.compositor.dwindleDefaultSplitRatio = v;
                                    CompositorKeywords.setKeyword("dwindle:default_split_ratio", v);
                                }
                            }
                            DecimalInputRow {
                                label: I18n.t("lay.split_width")
                                value: Config.compositor.dwindleSplitWidthMultiplier
                                minValue: 0.0
                                maxValue: 100.0
                                onValueEdited: v => {
                                    GlobalStates.markCompositorChanged();
                                    Config.compositor.dwindleSplitWidthMultiplier = v;
                                    CompositorKeywords.setKeyword("dwindle:split_width_multiplier", v);
                                }
                            }
                            DecimalInputRow {
                                label: I18n.t("lay.special_scale")
                                value: Config.compositor.dwindleSpecialScaleFactor
                                minValue: 0.0
                                maxValue: 100.0
                                onValueEdited: v => {
                                    GlobalStates.markCompositorChanged();
                                    Config.compositor.dwindleSpecialScaleFactor = v;
                                    CompositorKeywords.setKeyword("dwindle:special_scale_factor", v);
                                }
                            }
                            KeywordTextRow {
                                label: I18n.t("lay.master_orientation")
                                value: Config.compositor.masterOrientation
                                onValueEdited: v => {
                                    GlobalStates.markCompositorChanged();
                                    Config.compositor.masterOrientation = v;
                                    CompositorKeywords.setKeyword("master:orientation", v);
                                }
                            }
                            DecimalInputRow {
                                label: I18n.t("lay.mfact")
                                value: Config.compositor.masterMfact
                                minValue: 0.0
                                maxValue: 100.0
                                onValueEdited: v => {
                                    GlobalStates.markCompositorChanged();
                                    Config.compositor.masterMfact = v;
                                    CompositorKeywords.setKeyword("master:mfact", v);
                                }
                            }
                            KeywordTextRow {
                                label: I18n.t("lay.master_new_status")
                                value: Config.compositor.masterNewStatus
                                onValueEdited: v => {
                                    GlobalStates.markCompositorChanged();
                                    Config.compositor.masterNewStatus = v;
                                    CompositorKeywords.setKeyword("master:new_status", v);
                                }
                            }
                            DecimalInputRow {
                                label: I18n.t("lay.scroll_col_width")
                                value: Config.compositor.scrollingColumnWidth
                                minValue: 0.0
                                maxValue: 100.0
                                onValueEdited: v => {
                                    GlobalStates.markCompositorChanged();
                                    Config.compositor.scrollingColumnWidth = v;
                                    CompositorKeywords.setKeyword("scrolling:column_width", v);
                                }
                            }
                            KeywordTextRow {
                                label: I18n.t("lay.scroll_direction")
                                value: Config.compositor.scrollingDirection
                                onValueEdited: v => {
                                    GlobalStates.markCompositorChanged();
                                    Config.compositor.scrollingDirection = v;
                                    CompositorKeywords.setKeyword("scrolling:direction", v);
                                }
                            }
                            ToggleRow {
                                label: I18n.t("lay.scroll_fs_one")
                                checked: Config.compositor.scrollingFullscreenOnOneColumn
                                onToggled: v => {
                                    GlobalStates.markCompositorChanged();
                                    Config.compositor.scrollingFullscreenOnOneColumn = v;
                                    CompositorKeywords.setKeyword("scrolling:fullscreen_on_one_column", v);
                                }
                            }
                            ToggleRow {
                                label: I18n.t("lay.scroll_follow")
                                checked: Config.compositor.scrollingFollowFocus
                                onToggled: v => {
                                    GlobalStates.markCompositorChanged();
                                    Config.compositor.scrollingFollowFocus = v;
                                    CompositorKeywords.setKeyword("scrolling:follow_focus", v);
                                }
                            }
                            }

                            // ============================================================
                            // MONITORS
                            // ============================================================
                            ColumnLayout {
                                visible: root.currentSection === "monitors"
                                Layout.fillWidth: true
                                spacing: 8

                                MonitorsPanel {
                                    Layout.fillWidth: true
                                    Layout.preferredHeight: 720
                                    // MonitorsPanel is a full panel with its own
                                    // titlebar; the compositor panel's own
                                    // titlebar already shows the section, so hide
                                    // its duplicate.
                                    showHeader: false
                                    embedded: true
                                    currentSection: root.currentSection
                                }
                            }

                            // ============================================================
                            // ADVANCED  (axless.core, NothingLess settings)
                            // ============================================================
                            ColumnLayout {
                                visible: root.currentSection === "advanced"
                                Layout.fillWidth: true
                                spacing: 8

                                Text {
                                    text: I18n.t("compositor.advanced")
                                    font.family: Config.theme.font
                                    font.pixelSize: Styling.fontSize(-1)
                                    font.weight: Font.Medium
                                    color: Colors.overSurfaceVariant
                                    Layout.bottomMargin: -4
                                }
                            ToggleRow {
                                label: I18n.t("adv.disable_logo")
                                checked: Config.compositor.disableHyprlandLogo
                                onToggled: v => {
                                    GlobalStates.markCompositorChanged();
                                    Config.compositor.disableHyprlandLogo = v;
                                    CompositorKeywords.setKeyword("misc:disable_hyprland_logo", v);
                                }
                            }
                            ToggleRow {
                                label: I18n.t("adv.disable_splash")
                                checked: Config.compositor.disableSplashRendering
                                onToggled: v => {
                                    GlobalStates.markCompositorChanged();
                                    Config.compositor.disableSplashRendering = v;
                                    CompositorKeywords.setKeyword("misc:disable_splash_rendering", v);
                                }
                            }
                            ToggleRow {
                                label: I18n.t("adv.disable_autoreload")
                                checked: Config.compositor.disableAutoreload
                                onToggled: v => {
                                    GlobalStates.markCompositorChanged();
                                    Config.compositor.disableAutoreload = v;
                                    CompositorKeywords.setKeyword("misc:disable_autoreload", v);
                                }
                            }
                            ToggleRow {
                                label: I18n.t("adv.focus_on_activate")
                                checked: Config.compositor.focusOnActivate
                                onToggled: v => {
                                    GlobalStates.markCompositorChanged();
                                    Config.compositor.focusOnActivate = v;
                                    CompositorKeywords.setKeyword("misc:focus_on_activate", v);
                                }
                            }
                            ToggleRow {
                                label: I18n.t("adv.animate_manual")
                                checked: Config.compositor.animateManualResizes
                                onToggled: v => {
                                    GlobalStates.markCompositorChanged();
                                    Config.compositor.animateManualResizes = v;
                                    CompositorKeywords.setKeyword("misc:animate_manual_resizes", v);
                                }
                            }
                            ToggleRow {
                                label: I18n.t("adv.animate_drag")
                                checked: Config.compositor.animateMouseWindowdragging
                                onToggled: v => {
                                    GlobalStates.markCompositorChanged();
                                    Config.compositor.animateMouseWindowdragging = v;
                                    CompositorKeywords.setKeyword("misc:animate_mouse_windowdragging", v);
                                }
                            }
                            ToggleRow {
                                label: I18n.t("adv.no_update_news")
                                checked: Config.compositor.noUpdateNews
                                onToggled: v => {
                                    GlobalStates.markCompositorChanged();
                                    Config.compositor.noUpdateNews = v;
                                    CompositorKeywords.setKeyword("misc:no_update_news", v);
                                }
                            }
                            ToggleRow {
                                label: I18n.t("adv.xwayland")
                                checked: Config.compositor.xwaylandEnabled
                                onToggled: v => {
                                    GlobalStates.markCompositorChanged();
                                    Config.compositor.xwaylandEnabled = v;
                                    CompositorKeywords.setKeyword("xwayland:enabled", v);
                                }
                            }
                            ToggleRow {
                                label: I18n.t("adv.xwayland_zero")
                                checked: Config.compositor.xwaylandForceZeroScaling
                                onToggled: v => {
                                    GlobalStates.markCompositorChanged();
                                    Config.compositor.xwaylandForceZeroScaling = v;
                                    CompositorKeywords.setKeyword("xwayland:force_zero_scaling", v);
                                }
                            }
                            ToggleRow {
                                label: I18n.t("adv.xwayland_nearest")
                                checked: Config.compositor.xwaylandUseNearestNeighbor
                                onToggled: v => {
                                    GlobalStates.markCompositorChanged();
                                    Config.compositor.xwaylandUseNearestNeighbor = v;
                                    CompositorKeywords.setKeyword("xwayland:use_nearest_neighbor", v);
                                }
                            }
                            NumberInputRow {
                                label: I18n.t("adv.vrr")
                                value: Config.compositor.vrr
                                minValue: 0
                                maxValue: 100000
                                onValueEdited: v => {
                                    GlobalStates.markCompositorChanged();
                                    Config.compositor.vrr = v;
                                    CompositorKeywords.setKeyword("render:vrr", v);
                                }
                            }
                            ToggleRow {
                                label: I18n.t("adv.vfr")
                                checked: Config.compositor.vfr
                                onToggled: v => {
                                    GlobalStates.markCompositorChanged();
                                    Config.compositor.vfr = v;
                                    CompositorKeywords.setKeyword("render:vfr", v);
                                }
                            }
                            }
                    }

                    // ═══════════════════════════════════════════════════════════════
                    // COMING SOON TAB
                    // ═══════════════════════════════════════════════════════════════
                    Item {
                        id: placeholderPage
                        Layout.fillWidth: true
                        implicitHeight: 300

                        ColumnLayout {
                            anchors.centerIn: parent
                            spacing: 16

                            Text {
                                text: Icons.clock
                                font.family: Icons.font
                                font.pixelSize: 64
                                color: Colors.surfaceVariant
                                Layout.alignment: Qt.AlignHCenter
                            }

                            Text {
                                text: I18n.t("common.coming_soon")
                                font.family: Config.theme.font
                                font.pixelSize: Styling.fontSize(2)
                                font.bold: true
                                color: Colors.overBackground
                                Layout.alignment: Qt.AlignHCenter
                            }

                            Text {
                                text: I18n.t("compositor.coming_soon_text")
                                font.family: Config.theme.font
                                font.pixelSize: Styling.fontSize(0)
                                color: Colors.overSurfaceVariant
                                horizontalAlignment: Text.AlignHCenter
                                Layout.alignment: Qt.AlignHCenter
                            }
                        }
                    }
                }
            }
        }
    }

    // Color picker view (shown when colorPickerActive)
    Item {
        id: colorPickerContainer
        anchors.fill: parent
        clip: true

        // Horizontal slide + fade animation (enters from right)
        opacity: root.colorPickerActive ? 1 : 0
        transform: Translate {
            x: root.colorPickerActive ? 0 : 30

            Behavior on x {
                enabled: Config.animDuration > 0
                NumberAnimation {
                    duration: Config.animDuration / 2
                    easing.type: Easing.OutQuart
                }
            }
        }

        Behavior on opacity {
            enabled: Config.animDuration > 0
            NumberAnimation {
                duration: Config.animDuration / 2
                easing.type: Easing.OutQuart
            }
        }

        // Prevent interaction when hidden
        enabled: root.colorPickerActive

        // Block interaction with elements behind when active
        MouseArea {
            anchors.fill: parent
            enabled: root.colorPickerActive
            hoverEnabled: true
            acceptedButtons: Qt.AllButtons
            onPressed: event => event.accepted = true
            onReleased: event => event.accepted = true
            onWheel: event => event.accepted = true
        }

        ColorPickerView {
            id: colorPickerContent
            anchors.fill: parent
            anchors.leftMargin: root.sideMargin
            anchors.rightMargin: root.sideMargin
            colorNames: root.colorPickerColorNames
            currentColor: root.colorPickerCurrentColor
            dialogTitle: root.colorPickerDialogTitle

            onColorSelected: color => root.handleColorSelected(color)
            onClosed: root.closeColorPicker()
        }
    }
}
