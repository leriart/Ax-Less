pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import qs.modules.theme
import qs.modules.components
import qs.modules.services
import qs.modules.globals
import qs.config

/**
 * TodoTab — Single-list table view of pending and done tasks.
 *
 * Inspired by NVitschDEV/ptodo:
 *   Columns: # | Priority | Task | Due | Status
 *   Click row to toggle done; hover for actions.
 *
 * Colors sourced from the shell palette (Colors.* / Styling.*) so contrast
 * is consistent with the rest of NothingLess.
 */
Rectangle {
    id: root
    color: "transparent"
    implicitWidth: 640
    implicitHeight: 430

    // New-task form
    property string newTaskText: ""
    property int newTaskPriority: 0
    property string newTaskDueDate: ""
    property int newTaskTimeH: 12
    property int newTaskTimeM: 0

    // Calendar side-panel state
    property bool showCalendar: true
    property int calYear: new Date().getFullYear()
    property int calMonth: new Date().getMonth()
    property var _filterDay: null

    // Inline edit: id of the task currently being edited inline, -1 = none
    property int editingRowId: -1
    // Stash the pre-edit text so we can revert on Escape
    property string editingRowOriginal: ""

    // Date picker
    property int pickerTaskId: -1
    property int pickerYear: 0
    property int pickerMonth: 0
    property int pickerDay: 0
    property int pickerTimeH: 12
    property int pickerTimeM: 0
    property string pickerBaseDate: ""

    // Range picker (popup) state
    property bool rangePickerOpen: false
    property int rangePickerTaskId: -1  // -1 = new task, otherwise task id being edited
    property int rangeMode: 0  // 0=start, 1=end (toggle inside popup)
    property string pendingStartDate: ""
    property string pendingEndDate: ""

    // Month and weekday names come from the locale rather than a hardcoded
    // English list, so the calendar header reads "julio 2026" in Spanish
    // without needing 19 extra translation keys.
    readonly property var _dowNames: {
        const out = [];
        for (let i = 0; i < 7; i++)          // 2024-01-07 was a Sunday
            out.push(new Date(2024, 0, 7 + i).toLocaleDateString(Qt.locale(), "dd"));
        return out;
    }
    readonly property var _dueChoiceLabels: [
        I18n.t("todo.no_date"), I18n.t("todo.today"),
        I18n.t("todo.tomorrow"), I18n.t("todo.next_week")
    ]

    function _openDatePicker(taskId, existingDue) {
        pickerTaskId = taskId
        var d = existingDue ? new Date(existingDue) : new Date()
        pickerYear = d.getFullYear()
        pickerMonth = d.getMonth()
        pickerDay = existingDue ? d.getDate() : 0
        pickerTimeH = existingDue ? d.getHours() : 12
        pickerTimeM = existingDue ? d.getMinutes() : 0
    }

    function _closeDatePicker() { pickerTaskId = -1 }

    function _saveDatePicker() {
        if (pickerDay === 0) {
            if (pickerTaskId === -1) {
                root.newTaskDueDate = ""
            } else {
                TodoBoard.setDueDate(pickerTaskId, "")
            }
        } else {
            var d = new Date(pickerYear, pickerMonth, pickerDay, pickerTimeH, pickerTimeM)
            if (pickerTaskId === -1) {
                root.newTaskDueDate = d.toISOString()
            } else {
                TodoBoard.setDueDate(pickerTaskId, d.toISOString())
            }
        }
        _closeDatePicker()
    }

    function _buildMonthDays(year, month) {
        var first = new Date(year, month, 1)
        var last = new Date(year, month + 1, 0)
        var startDow = first.getDay()
        var totalDays = last.getDate()
        var days = []
        var prevLast = new Date(year, month, 0).getDate()
        for (var i = startDow - 1; i >= 0; i--) {
            days.push({ n: prevLast - i, cur: false })
        }
        for (var d = 1; d <= totalDays; d++) {
            days.push({ n: d, cur: true })
        }
        while (days.length < 42) {
            days.push({ n: days.length - totalDays - startDow + 1, cur: false })
        }
        return days
    }

    function _dueDateFromChoice(choice) {
        if (choice === 0) return ""
        var d = new Date()
        if (choice === 2) d.setDate(d.getDate() + 1)
        if (choice === 3) d.setDate(d.getDate() + 7)
        return d.toISOString()
    }

    function _submitNew() {
        if (newTaskText.trim() === "") return
        // If a range was selected, treat start as the primary dueDate for backward
        // compat and pass startDate/endDate separately.
        var due = newTaskDueDate || pendingStartDate
        TodoBoard.addTask(
            newTaskText.trim(),
            newTaskPriority,
            due,
            pendingStartDate,
            pendingEndDate
        )
        newTaskText = ""
        newTaskPriority = 0
        newTaskDueDate = ""
        pendingStartDate = ""
        pendingEndDate = ""
    }

    function _applyTimeToDate() {
        if (newTaskDueDate === "") return
        var d = new Date(newTaskDueDate)
        d.setHours(newTaskTimeH, newTaskTimeM, 0, 0)
        newTaskDueDate = d.toISOString()
    }

    function _openRangePicker(taskId, startDate, endDate) {
        rangeMode = 0
        rangePickerTaskId = taskId !== undefined ? taskId : -1
        pendingStartDate = startDate !== undefined ? startDate : ""
        pendingEndDate = endDate !== undefined ? endDate : ""
        rangePickerOpen = true
    }

    function _closeRangePicker() {
        rangePickerOpen = false
        rangePickerTaskId = -1
    }

    function _applyRangeTime(h, m) {
        newTaskTimeH = h
        newTaskTimeM = m
        var target = rangeMode === 0 ? pendingStartDate : pendingEndDate
        if (target !== "") {
            var d = new Date(target)
            d.setHours(h, m, 0, 0)
            if (rangeMode === 0) {
                pendingStartDate = d.toISOString()
            } else {
                pendingEndDate = d.toISOString()
            }
        }
    }

    // Stats
    readonly property int _pendingCount: {
        var c = 0
        for (var i = 0; i < TodoBoard.tasks.length; i++) {
            if (!TodoBoard.tasks[i].done) c++
        }
        return c
    }
    readonly property int _overdueCount: {
        var c = 0
        for (var i = 0; i < TodoBoard.tasks.length; i++) {
            var t = TodoBoard.tasks[i]
            if (!t.done && TodoBoard.isOverdue(t.dueDate)) c++
        }
        return c
    }
    readonly property int _doneCount: TodoBoard.tasks.length - _pendingCount

    ColumnLayout {
        anchors.fill: parent
        spacing: 8

        // ── Header ──
        RowLayout {
            Layout.fillWidth: true
            Layout.preferredHeight: 44
            Layout.minimumHeight: 44
            spacing: 12

            Text {
                text: Icons.todo
                font.family: Icons.font
                font.pixelSize: 22
                color: Styling.srItem("overprimary")
            }
            Text {
                text: I18n.t("todo.title")
                font.family: Config.theme.font
                font.pixelSize: Styling.fontSize(3)
                font.weight: Font.Bold
                color: Colors.overBackground
            }
            Item { Layout.fillWidth: true }

            // Filter chips
            RowLayout {
                spacing: 4
                Repeater {
                    model: [
                        { label: I18n.t("todo.filter_all"), val: -1 },
                        { label: I18n.t("todo.prio_high"), val: TodoBoard.prioHigh },
                        { label: I18n.t("todo.prio_med"), val: TodoBoard.prioMed },
                        { label: I18n.t("todo.prio_low"), val: TodoBoard.prioLow }
                    ]
                    delegate: StyledRect {
                        required property var modelData
                        Layout.preferredHeight: 24
                        Layout.minimumHeight: 24
                        Layout.preferredWidth: 48
                        radius: Styling.radius(-2)
                        variant: TodoBoard.filterPriority === modelData.val ? "primary" : "common"
                        Text {
                            anchors.centerIn: parent
                            text: modelData.label
                            font.family: Config.theme.font
                            font.pixelSize: Styling.fontSize(-3)
                            font.weight: Font.Medium
                            color: TodoBoard.filterPriority === modelData.val
                                ? Styling.srItem("onprimary")
                                : Colors.overBackground
                        }
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: TodoBoard.filterPriority = modelData.val
                        }
                    }
                }
            }

            // Count
            Text {
                text: _pendingCount + " pending" + (_overdueCount > 0 ? " (" + _overdueCount + " overdue)" : "")
                font.family: Config.theme.font
                font.pixelSize: Styling.fontSize(-1)
                color: _overdueCount > 0 ? Colors.error : Colors.overBackground
            }

            // Calendar panel toggle
            StyledRect {
                Layout.preferredHeight: 24
                Layout.minimumHeight: 24
                Layout.preferredWidth: 28
                radius: Styling.radius(-2)
                variant: root.showCalendar ? "primary" : "common"
                Text {
                    anchors.centerIn: parent
                    text: I18n.t("todo.calendar")
                    font.family: Config.theme.font
                    font.pixelSize: Styling.fontSize(-3)
                    font.weight: Font.Medium
                    color: root.showCalendar ? Styling.srItem("onprimary") : Colors.overBackground
                }
                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.showCalendar = !root.showCalendar
                }
            }

            // Hide done toggle
            StyledRect {
                Layout.preferredHeight: 24
                Layout.minimumHeight: 24
                Layout.preferredWidth: 70
                radius: Styling.radius(-2)
                variant: TodoBoard.hideDone ? "primary" : "common"
                Text {
                    anchors.centerIn: parent
                    text: I18n.t("todo.hide_done")
                    font.family: Config.theme.font
                    font.pixelSize: Styling.fontSize(-3)
                    color: TodoBoard.hideDone ? Styling.srItem("onprimary") : Colors.overBackground
                }
                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: TodoBoard.hideDone = !TodoBoard.hideDone
                }
            }

            // Clear done
            StyledRect {
                Layout.preferredHeight: 24
                Layout.minimumHeight: 24
                Layout.preferredWidth: 60
                radius: Styling.radius(-2)
                variant: "common"
                visible: _doneCount > 0
                Text {
                    anchors.centerIn: parent
                    text: I18n.t("todo.clear_done")
                    font.family: Config.theme.font
                    font.pixelSize: Styling.fontSize(-3)
                    color: Colors.outline
                }
                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: TodoBoard.removeAllDone()
                }
            }
        }

        // ── New task input ──
        StyledRect {
            Layout.fillWidth: true
            Layout.preferredHeight: 44
            Layout.minimumHeight: 44
            radius: Styling.radius(-2)
            variant: "pane"

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 10
                anchors.rightMargin: 10
                spacing: 8

                TextField {
                    id: newInput
                    Layout.fillWidth: true
                    placeholderText: I18n.t("todo.add_placeholder")
                    placeholderTextColor: Qt.rgba(Colors.overBackground.r, Colors.overBackground.g, Colors.overBackground.b, 0.4)
                    font.family: Config.theme.font
                    font.pixelSize: Styling.fontSize(0)
                    color: Colors.overBackground
                    background: Rectangle { color: "transparent" }
                    onAccepted: root._submitNew()
                    onTextChanged: { root.newTaskText = text }
                }

                // Quick priority selector (cycle on click)
                StyledRect {
                    id: priorityChip
                    Layout.preferredHeight: 24
                    Layout.minimumHeight: 24
                    Layout.preferredWidth: 56
                    radius: Styling.radius(-2)
                    variant: "bg"
                    color: TodoBoard.priorityBgColor(root.newTaskPriority)
                    border.color: TodoBoard.priorityColor(root.newTaskPriority)
                    border.width: 1
                    Text {
                        anchors.centerIn: parent
                        text: TodoBoard.priorityNames[root.newTaskPriority]
                        font.family: Config.theme.font
                        font.pixelSize: Styling.fontSize(-3)
                        font.weight: Font.Medium
                        color: TodoBoard.priorityColor(root.newTaskPriority)
                    }
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            root.newTaskPriority = (root.newTaskPriority + 1) % 4
                        }
                    }
                }

                // Calendar / range picker button
                StyledRect {
                    id: calButton
                    Layout.preferredHeight: 28
                    Layout.minimumHeight: 28
                    Layout.preferredWidth: 64
                    radius: Styling.radius(-2)
                    variant: (root.newTaskDueDate !== "" || root.pendingStartDate !== "" || root.pendingEndDate !== "")
                        ? "primary" : "common"
                    Text {
                        anchors.centerIn: parent
                        text: I18n.t("todo.range")
                        font.family: Config.theme.font
                        font.pixelSize: Styling.fontSize(-2)
                        font.weight: Font.Medium
                        color: (root.newTaskDueDate !== "" || root.pendingStartDate !== "" || root.pendingEndDate !== "")
                            ? Styling.srItem("primary")
                            : Colors.overBackground
                    }
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root._openRangePicker(-1, root.newTaskDueDate, "")
                    }
                }

                // Show current selection summary
                Text {
                    visible: root.newTaskDueDate !== "" || root.pendingStartDate !== "" || root.pendingEndDate !== ""
                    text: {
                        if (root.newTaskDueDate !== "" && root.pendingStartDate === "" && root.pendingEndDate === "") {
                            return TodoBoard.formatDue(root.newTaskDueDate)
                        }
                        if (root.pendingStartDate !== "" || root.pendingEndDate !== "") {
                            return TodoBoard.formatRange(root.pendingStartDate, root.pendingEndDate)
                        }
                        return ""
                    }
                    font.family: Config.theme.font
                    font.pixelSize: Styling.fontSize(-2)
                    color: Colors.overBackground
                    Layout.preferredWidth: 110
                    elide: Text.ElideRight
                }

                StyledRect {
                    Layout.preferredHeight: 28
                    Layout.minimumHeight: 28
                    Layout.preferredWidth: 36
                    radius: Styling.radius(-2)
                    variant: root.newTaskText.trim() === "" ? "common" : "primary"
                    Text {
                        anchors.centerIn: parent
                        text: Icons.plus
                        font.family: Icons.font
                        font.pixelSize: Styling.fontSize(0)
                        color: root.newTaskText.trim() === ""
                            ? Colors.outline
                            : Styling.srItem("primary")
                    }
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: root.newTaskText.trim() === "" ? Qt.ArrowCursor : Qt.PointingHandCursor
                        enabled: root.newTaskText.trim() !== ""
                        onClicked: root._submitNew()
                    }
                }
            }
         }


        // ── Task list + calendar side panel ──
        RowLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 8

        // ── Task list ──
        StyledRect {
            Layout.fillWidth: true
            Layout.fillHeight: true
            radius: Styling.radius(-2)
            variant: "internalbg"
            clip: true

            Flickable {
                anchors.fill: parent
                contentWidth: width
                contentHeight: tasksColumn.implicitHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds

                ColumnLayout {
                    id: tasksColumn
                    width: parent.width
                    spacing: 0

                    // Column header
                    Item {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 28
                        Layout.minimumHeight: 28
                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 12
                            anchors.rightMargin: 12
                            spacing: 8

                            Text {
                                text: "#"
                                font.family: Config.theme.font
                                font.pixelSize: Styling.fontSize(-2)
                                font.weight: Font.Medium
                                color: Colors.overBackground
                                Layout.preferredWidth: 24
                            }
                            Text {
                                text: I18n.t("todo.priority")
                                font.family: Config.theme.font
                                font.pixelSize: Styling.fontSize(-2)
                                font.weight: Font.Medium
                                color: Colors.overBackground
                                Layout.preferredWidth: 60
                            }
                            Text {
                                text: I18n.t("todo.task")
                                font.family: Config.theme.font
                                font.pixelSize: Styling.fontSize(-2)
                                font.weight: Font.Medium
                                color: Colors.overBackground
                                Layout.fillWidth: true
                            }
                            Text {
                                text: I18n.t("todo.due")
                                font.family: Config.theme.font
                                font.pixelSize: Styling.fontSize(-2)
                                font.weight: Font.Medium
                                color: Colors.overBackground
                                Layout.preferredWidth: 120
                            }
                            Text {
                                text: I18n.t("todo.status")
                                font.family: Config.theme.font
                                font.pixelSize: Styling.fontSize(-2)
                                font.weight: Font.Medium
                                color: Colors.overBackground
                                horizontalAlignment: Text.AlignHCenter
                                Layout.preferredWidth: 70
                            }
                        }
                    }

                    Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 1
                        color: Colors.outline
                        opacity: 0.4
                    }

                    // Empty state
                    Item {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        Layout.preferredHeight: 120
                        visible: TodoBoard.visibleTasks().length === 0
                        Text {
                            anchors.centerIn: parent
                            text: TodoBoard.tasks.length === 0
                                ? "No tasks yet. Add one above to get started."
                                : "All caught up!"
                            font.family: Config.theme.font
                            font.pixelSize: Styling.fontSize(1)
                            color: Colors.overBackground
                            opacity: 0.6
                        }
                    }

                    // Task rows
                    Repeater {
                        model: TodoBoard.visibleTasks()
                        delegate: TodoRow {
                            required property var modelData
                            width: tasksColumn.width
                            task: modelData
                        }
                    }

                    Item {
                        Layout.preferredHeight: 16
                    }
                }
            }
        }

        // ── Calendar side panel (reuses dashboard Calendar) ──
        StyledRect {
            visible: root.showCalendar
            Layout.preferredWidth: 232
            Layout.fillHeight: true
            radius: Styling.radius(4)
            variant: "internalbg"
            clip: true

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 8
                spacing: 8

                TodoCalendar {
                    id: sideCal
                    Layout.fillWidth: true
                    Layout.preferredHeight: width
                    onDayClicked: (year, month, day) => {
                        if (root._filterDay && root._filterDay.year === year
                            && root._filterDay.month === month
                            && root._filterDay.day === day) {
                            root._filterDay = null
                        } else {
                            root._filterDay = { year: year, month: month, day: day }
                        }
                    }
                }

                // Task count summary + filter status
                RowLayout {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 24
                    Layout.minimumHeight: 24
                    spacing: 8

                    Text {
                        text: root._filterDay
                            ? "Tasks on " + root._filterDay.day + "/" + (root._filterDay.month + 1)
                            : "Tap a day to filter"
                        font.family: Config.theme.font
                        font.pixelSize: Styling.fontSize(-2)
                        color: root._filterDay ? Colors.primary : Colors.outline
                        Layout.fillWidth: true
                    }
                    Text {
                        visible: root._filterDay !== null
                        text: I18n.t("todo.clear")
                        font.family: Config.theme.font
                        font.pixelSize: Styling.fontSize(-2)
                        color: Colors.primary
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root._filterDay = null
                        }
                    }
                }
            }
        }
        }
    }

    // ── Date picker overlay ──
    Item {
        anchors.fill: parent
        visible: pickerTaskId !== -1
        z: 10

        Rectangle {
            anchors.fill: parent
            color: "black"
            opacity: 0.4
        }
        MouseArea {
            anchors.fill: parent
            onClicked: _closeDatePicker()
        }

        StyledRect {
            id: datePopup
            anchors.centerIn: parent
            // Fit the tab area instead of assuming a size: the tab is only
            // ~430 px tall, so a fixed height used to overflow and clip the
            // action row (clip: true cut Clear/Cancel/Save in half).
            width: Math.min(320, parent.width - 16)
            height: Math.min(396, parent.height - 16)
            radius: Styling.radius(0)
            variant: "popup"
            clip: true

            // Scrollable: if the tab is shorter than the calendar grid the
            // popup shrinks and the content scrolls instead of being cut.
            Flickable {
                id: dateFlick
                anchors.fill: parent
                contentWidth: width
                contentHeight: dateCol.implicitHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                ScrollBar.vertical: ScrollBar {
                    policy: dateFlick.contentHeight > dateFlick.height ? ScrollBar.AlwaysOn : ScrollBar.AlwaysOff
                }

            ColumnLayout {
                id: dateCol
                width: dateFlick.width
                spacing: 8

                Item { Layout.preferredHeight: 8 }

                Text {
                    text: I18n.t("todo.select_date")
                    font.family: Config.theme.font
                    font.pixelSize: Styling.fontSize(1)
                    font.weight: Font.Medium
                    color: Colors.overBackground
                }

                RowLayout {
                    Layout.fillWidth: true
                    Text {
                        text: "<"
                        font.family: Icons.font
                        font.pixelSize: 16
                        color: Colors.overBackground
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                pickerMonth--
                                if (pickerMonth < 0) { pickerMonth = 11; pickerYear-- }
                            }
                        }
                    }
                    Text {
                        text: new Date(pickerYear, pickerMonth, 1).toLocaleDateString(Qt.locale(), "MMMM yyyy")
                        font.family: Config.theme.font
                        font.pixelSize: Styling.fontSize(0)
                        font.weight: Font.Medium
                        color: Colors.overBackground
                        Layout.fillWidth: true
                        horizontalAlignment: Text.AlignHCenter
                    }
                    Text {
                        text: ">"
                        font.family: Icons.font
                        font.pixelSize: 16
                        color: Colors.overBackground
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                pickerMonth++
                                if (pickerMonth > 11) { pickerMonth = 0; pickerYear++ }
                            }
                        }
                    }
                }

                RowLayout {
                    Layout.fillWidth: true
                    Repeater {
                        model: root._dowNames
                        delegate: Text {
                            // Without the required declaration, modelData is
                            // not in scope here (ReferenceError at runtime,
                            // logged 7x on every picker open). The String()
                            // cast stays as a no-op safety net.
                            required property var modelData
                            text: String(modelData)
                            font.family: Config.theme.font
                            font.pixelSize: Styling.fontSize(-3)
                            color: Colors.outline
                            Layout.fillWidth: true
                            horizontalAlignment: Text.AlignHCenter
                        }
                    }
                }

                GridLayout {
                    Layout.fillWidth: true
                    columns: 7
                    rowSpacing: 2
                    columnSpacing: 2

                    Repeater {
                        model: root._buildMonthDays(pickerYear, pickerMonth)
                        delegate: Rectangle {
                            required property var modelData
                            Layout.fillWidth: true
                            Layout.preferredHeight: 32
                            Layout.minimumHeight: 32
                            Layout.maximumHeight: 32
                            radius: Styling.radius(-2)
                            color: !modelData.cur ? "transparent"
                                : (pickerDay > 0 && new Date(pickerYear, pickerMonth, modelData.n).toDateString()
                                    === new Date(pickerYear, pickerMonth, pickerDay).toDateString())
                                    ? Styling.srItem("primary")
                                    : (mouse.containsMouse ? Colors.surfaceBright : "transparent")
                            border.color: modelData.cur ? Colors.outline : "transparent"
                            border.width: 1
                            Text {
                                anchors.centerIn: parent
                                text: modelData.n
                                font.family: Config.theme.font
                                font.pixelSize: Styling.fontSize(-1)
                                color: !parent.modelData.cur ? Colors.outline
                                    : (parent.color === Styling.srItem("primary")
                                        ? Styling.srItem("onprimary")
                                        : Colors.overBackground)
                            }
                            MouseArea {
                                id: mouse
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: parent.modelData.cur ? Qt.PointingHandCursor : Qt.ArrowCursor
                                enabled: parent.modelData.cur
                                onClicked: pickerDay = parent.modelData.n
                            }
                        }
                    }
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 4
                    Text {
                        text: I18n.t("todo.time")
                        font.family: Config.theme.font
                        font.pixelSize: Styling.fontSize(-1)
                        color: Colors.outline
                    }
                    TextField {
                        text: String(pickerTimeH).padStart(2, '0')
                        Layout.preferredWidth: 44
                        Layout.preferredHeight: 32
                        Layout.minimumHeight: 32
                        inputMask: "99"
                        font.family: Config.theme.font
                        font.pixelSize: Styling.fontSize(-1)
                        color: Colors.overBackground
                        horizontalAlignment: Text.AlignHCenter
                        background: Rectangle {
                            color: "transparent"
                            border.color: Colors.outlineVariant
                            border.width: 1
                            radius: Styling.radius(-3)
                        }
                        validator: IntValidator { bottom: 0; top: 23 }
                        onTextChanged: {
                            var v = parseInt(text)
                            if (!isNaN(v) && v >= 0 && v <= 23) pickerTimeH = v
                        }
                    }
                    Text {
                        text: ":"
                        font.family: Config.theme.font
                        font.pixelSize: Styling.fontSize(0)
                        color: Colors.overBackground
                    }
                    TextField {
                        text: String(pickerTimeM).padStart(2, '0')
                        Layout.preferredWidth: 44
                        Layout.preferredHeight: 32
                        Layout.minimumHeight: 32
                        inputMask: "99"
                        font.family: Config.theme.font
                        font.pixelSize: Styling.fontSize(-1)
                        color: Colors.overBackground
                        horizontalAlignment: Text.AlignHCenter
                        background: Rectangle {
                            color: "transparent"
                            border.color: Colors.outlineVariant
                            border.width: 1
                            radius: Styling.radius(-3)
                        }
                        validator: IntValidator { bottom: 0; top: 59 }
                        onTextChanged: {
                            var v = parseInt(text)
                            if (!isNaN(v) && v >= 0 && v <= 59) pickerTimeM = v
                        }
                    }
                    Item { Layout.fillWidth: true }
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 4
                    StyledRect {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 36
                        Layout.minimumHeight: 36
                        variant: "common"
                        radius: Styling.radius(-2)
                        Text {
                            anchors.centerIn: parent
                            text: I18n.t("todo.clear")
                            font.family: Config.theme.font
                            font.pixelSize: Styling.fontSize(-1)
                            color: Colors.overBackground
                        }
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: { pickerDay = 0; root._saveDatePicker() }
                        }
                    }
                    StyledRect {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 36
                        Layout.minimumHeight: 36
                        variant: "common"
                        radius: Styling.radius(-2)
                        Text {
                            anchors.centerIn: parent
                            text: I18n.t("todo.cancel")
                            font.family: Config.theme.font
                            font.pixelSize: Styling.fontSize(-1)
                            color: Colors.overBackground
                        }
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root._closeDatePicker()
                        }
                    }
                    StyledRect {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 36
                        Layout.minimumHeight: 36
                        variant: "primary"
                        radius: Styling.radius(-2)
                        Text {
                            anchors.centerIn: parent
                            text: I18n.t("todo.save")
                            font.family: Config.theme.font
                            font.pixelSize: Styling.fontSize(-1)
                            color: Styling.srItem("onprimary")
                        }
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root._saveDatePicker()
                        }
                    }
                }
                }
                Item { Layout.preferredHeight: 8 }
            }
        }
    }

    // ── Range picker popup (for new task start/end date selection) ──
    Item {
        anchors.fill: parent
        visible: rangePickerOpen
        z: 11

        Rectangle {
            anchors.fill: parent
            color: "black"
            opacity: 0.4
        }
        MouseArea {
            anchors.fill: parent
            onClicked: root._closeRangePicker()
        }

        StyledRect {
            id: rangePopup
            anchors.centerIn: parent
            width: Math.min(340, parent.width - 16)
            height: Math.min(440, parent.height - 16)
            radius: Styling.radius(0)
            variant: "popup"
            clip: true

            property int monthOffset: 0

            Flickable {
                id: rangeFlick
                anchors.fill: parent
                contentWidth: width
                contentHeight: rangeCol.implicitHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                ScrollBar.vertical: ScrollBar {
                    policy: rangeFlick.contentHeight > rangeFlick.height ? ScrollBar.AlwaysOn : ScrollBar.AlwaysOff
                }

            ColumnLayout {
                id: rangeCol
                width: rangeFlick.width
                spacing: 8

                Item { Layout.preferredHeight: 8 }

                Text {
                    text: I18n.t("todo.select_date_range")
                    font.family: Config.theme.font
                    font.pixelSize: Styling.fontSize(1)
                    font.weight: Font.Medium
                    color: rangePopup.item
                }

                // Selected dates summary + mode toggle
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 6
                    StyledRect {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 26
                        Layout.minimumHeight: 26
                        radius: Styling.radius(-2)
                        variant: rangeMode === 0 ? "primary" : "common"
                        Text {
                            anchors.left: parent.left
                            anchors.leftMargin: 8
                            anchors.verticalCenter: parent.verticalCenter
                            text: pendingStartDate
                                ? TodoBoard.formatDate(pendingStartDate) + " " + TodoBoard.formatTime(pendingStartDate)
                                : "Start…"
                            font.family: Config.theme.font
                            font.pixelSize: Styling.fontSize(-2)
                            font.weight: rangeMode === 0 ? Font.Medium : Font.Normal
                            color: rangeMode === 0 ? Styling.srItem("primary") : (pendingStartDate ? Colors.overBackground : Colors.outline)
                        }
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: rangeMode = 0
                        }
                    }
                    Text {
                        text: "→"
                        font.family: Config.theme.font
                        font.pixelSize: 14
                        color: Colors.outline
                    }
                    StyledRect {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 26
                        Layout.minimumHeight: 26
                        radius: Styling.radius(-2)
                        variant: rangeMode === 1 ? "primary" : "common"
                        Text {
                            anchors.left: parent.left
                            anchors.leftMargin: 8
                            anchors.verticalCenter: parent.verticalCenter
                            text: pendingEndDate
                                ? TodoBoard.formatDate(pendingEndDate) + " " + TodoBoard.formatTime(pendingEndDate)
                                : "End…"
                            font.family: Config.theme.font
                            font.pixelSize: Styling.fontSize(-2)
                            font.weight: rangeMode === 1 ? Font.Medium : Font.Normal
                            color: rangeMode === 1 ? Styling.srItem("primary") : (pendingEndDate ? Colors.overBackground : Colors.outline)
                        }
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: rangeMode = 1
                        }
                    }
                }

                // The calendar (reuses dashboard Calendar component)
                TodoCalendar {
                    id: rangeCal
                    Layout.fillWidth: true
                    Layout.preferredHeight: 260
                    monthShift: rangePopup.monthOffset
                    selectedStartDate: pendingStartDate
                    selectedEndDate: pendingEndDate
                    onDayClicked: (year, month, day) => {
                        var h = newTaskTimeH
                        var m = newTaskTimeM
                        if (rangeMode === 0) {
                            pendingStartDate = new Date(year, month, day, h, m, 0, 0).toISOString()
                            if (pendingEndDate !== "" && new Date(pendingEndDate) < new Date(pendingStartDate)) {
                                pendingEndDate = ""
                            }
                        } else {
                            pendingEndDate = new Date(year, month, day, h, m, 0, 0).toISOString()
                            if (pendingStartDate !== "" && new Date(pendingEndDate) < new Date(pendingStartDate)) {
                                pendingStartDate = pendingEndDate
                            }
                        }
                    }
                }

                // Time pickers (apply to active mode)
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 6
                    Text {
                        text: rangeMode === 0 ? "Start:" : "End:"
                        font.family: Config.theme.font
                        font.pixelSize: Styling.fontSize(-2)
                        color: rangePopup.item
                        Layout.preferredWidth: 44
                    }
                    SpinBox {
                        id: rangeHour
                        from: 0
                        to: 23
                        editable: true
                        value: newTaskTimeH
                        Layout.preferredWidth: 52
                        Layout.preferredHeight: 32
                        Layout.minimumHeight: 32
                        background: Rectangle { color: "transparent"; border.color: Colors.outlineVariant; border.width: 1; radius: Styling.radius(-3) }
                        contentItem: TextInput {
                            text: rangeHour.value
                            font.family: Config.theme.font
                            font.pixelSize: Styling.fontSize(-2)
                            color: Colors.overBackground
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                            selectByMouse: true
                        }
                        onValueModified: root._applyRangeTime(value, newTaskTimeM)
                    }
                    Text {
                        text: ":"
                        font.family: Config.theme.font
                        font.pixelSize: Styling.fontSize(-1)
                        color: Colors.overBackground
                    }
                    SpinBox {
                        id: rangeMin
                        from: 0
                        to: 59
                        editable: true
                        value: newTaskTimeM
                        Layout.preferredWidth: 52
                        Layout.preferredHeight: 32
                        Layout.minimumHeight: 32
                        background: Rectangle { color: "transparent"; border.color: Colors.outlineVariant; border.width: 1; radius: Styling.radius(-3) }
                        contentItem: TextInput {
                            text: rangeMin.value
                            font.family: Config.theme.font
                            font.pixelSize: Styling.fontSize(-2)
                            color: Colors.overBackground
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                            selectByMouse: true
                        }
                        onValueModified: root._applyRangeTime(newTaskTimeH, value)
                    }
                    Item { Layout.fillWidth: true }
                }

                // Action buttons
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 6
                    StyledRect {
                        Layout.preferredHeight: 36
                        Layout.minimumHeight: 36
                        Layout.preferredWidth: 70
                        radius: Styling.radius(-2)
                        variant: "common"
                        Text {
                            anchors.centerIn: parent
                            text: I18n.t("todo.cancel")
                            font.family: Config.theme.font
                            font.pixelSize: Styling.fontSize(-2)
                            color: Colors.overBackground
                        }
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root._closeRangePicker()
                        }
                    }
                    StyledRect {
                        Layout.preferredHeight: 36
                        Layout.minimumHeight: 36
                        Layout.preferredWidth: 60
                        radius: Styling.radius(-2)
                        variant: "common"
                        Text {
                            anchors.centerIn: parent
                            text: I18n.t("todo.clear")
                            font.family: Config.theme.font
                            font.pixelSize: Styling.fontSize(-2)
                            color: Colors.overBackground
                        }
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                pendingStartDate = ""
                                pendingEndDate = ""
                            }
                        }
                    }
                    Item { Layout.fillWidth: true }
                    StyledRect {
                        Layout.preferredHeight: 36
                        Layout.minimumHeight: 36
                        Layout.preferredWidth: 80
                        radius: Styling.radius(-2)
                        variant: "primary"
                        Text {
                            anchors.centerIn: parent
                            text: I18n.t("todo.apply")
                            font.family: Config.theme.font
                            font.pixelSize: Styling.fontSize(-2)
                            color: rangePopup.item
                        }
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                if (root.rangePickerTaskId === -1) {
                                    root.newTaskDueDate = pendingStartDate
                                } else {
                                    TodoBoard.setDateRange(root.rangePickerTaskId, pendingStartDate, pendingEndDate)
                                }
                                root._closeRangePicker()
                            }
                        }
                    }
                }
                Item { Layout.preferredHeight: 8 }
            }
            }
        }
    }

    // ── Task row component ──
    component TodoRow: Item {
        id: row
        required property var task
        implicitHeight: 40

        // Row background — use shell palette: pane by default, focus on hover
        StyledRect {
            anchors.fill: parent
            radius: Styling.radius(-3)
            variant: row.hover.containsMouse ? "focus" : "pane"
            opacity: row.task.done ? 0.55 : 1

            MouseArea {
                id: hover
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                // Only accept clicks that land on bare row background. The
                // edit/delete buttons have their own MouseAreas; without
                // this filter the row's toggleDone handler would steal
                // the click before the button ever saw it.
                propagateComposedEvents: true
                onClicked: function(mouse) {
                    if (mouse.x < width - 80) {
                        TodoBoard.toggleDone(row.task.id)
                        mouse.accepted = true
                    } else {
                        mouse.accepted = false
                    }
                }
            }

            // Left priority bar
            Rectangle {
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                width: 4
                color: TodoBoard.priorityColor(row.task.priority)
                radius: 2
            }

            // Range bar at the bottom of the row, visualizing start→end
            Rectangle {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.margins: 1
                height: 2
                radius: 1
                color: {
                    if (row.task.startDate || row.task.endDate) {
                        if (TodoBoard.rangeIsOverdue(row.task.startDate, row.task.endDate, row.task.done))
                            return Colors.error
                        if (TodoBoard.isInRangeToday(row.task.startDate, row.task.endDate))
                            return Colors.primary
                        return Qt.rgba(Colors.primary.r, Colors.primary.g, Colors.primary.b, 0.45)
                    }
                    return "transparent"
                }
                visible: row.task.startDate !== "" || row.task.endDate !== ""
            }

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 12
                anchors.rightMargin: 12
                spacing: 8

                // # (row number based on sorted index)
                Text {
                    Layout.preferredWidth: 24
                    text: (row.index + 1)
                    font.family: Config.theme.font
                    font.pixelSize: Styling.fontSize(-1)
                    color: Colors.outline
                    horizontalAlignment: Text.AlignRight
                }

                // Priority chip
                StyledRect {
                    Layout.preferredWidth: 56
                    Layout.preferredHeight: 22
                    Layout.minimumHeight: 22
                    radius: Styling.radius(-2)
                    variant: row.task.priority > 0 ? "common" : "transparent"
                    color: TodoBoard.priorityBgColor(row.task.priority)
                    border.color: TodoBoard.priorityColor(row.task.priority)
                    border.width: 1
                    visible: row.task.priority > 0
                    Text {
                        anchors.centerIn: parent
                        text: TodoBoard.priorityNames[row.task.priority]
                        font.family: Config.theme.font
                        font.pixelSize: Styling.fontSize(-3)
                        font.weight: Font.Medium
                        color: TodoBoard.priorityColor(row.task.priority)
                    }
                }
                // Placeholder for empty priority
                Item {
                    Layout.preferredWidth: 56
                    Layout.preferredHeight: 22
                    Layout.minimumHeight: 22
                    visible: row.task.priority === 0
                }

                // Task text — display mode or inline edit mode
                Loader {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 24
                    Layout.minimumHeight: 24
                    sourceComponent: root.editingRowId === row.task.id ? inlineEdit : displayText

                    Component {
                        id: displayText
                        Text {
                            text: row.task.task
                            font.family: Config.theme.font
                            font.pixelSize: Styling.fontSize(0)
                            color: row.task.done ? Colors.outline : Colors.overBackground
                            font.strikeout: row.task.done
                            font.weight: row.task.done ? Font.Normal : Font.Medium
                            opacity: row.task.done ? 0.7 : 1
                            elide: Text.ElideRight
                            verticalAlignment: Text.AlignVCenter
                        }
                    }

                    Component {
                        id: inlineEdit
                        Item {
                            TextField {
                                id: inlineInput
                                anchors.fill: parent
                                anchors.leftMargin: -4
                                anchors.rightMargin: -4
                                text: row.task.task
                                selectByMouse: true
                                font.family: Config.theme.font
                                font.pixelSize: Styling.fontSize(0)
                                font.weight: Font.Medium
                                color: Colors.overBackground
                                background: Rectangle {
                                    color: Colors.surfaceContainer
                                    border.color: inlineInput.activeFocus ? Colors.primary : Colors.outline
                                    border.width: 1
                                    radius: Styling.radius(-2)
                                }
                                Component.onCompleted: {
                                    text = root.editingRowOriginal || row.task.task
                                    forceActiveFocus()
                                    Qt.callLater(() => { selectAll() })
                                }
                                onAccepted: {
                                    var trimmed = text.trim()
                                    if (trimmed !== "") {
                                        TodoBoard.setTask(row.task.id, trimmed)
                                    }
                                    root.editingRowId = -1
                                }
                                Keys.onEscapePressed: function(event) {
                                    // Cancel: revert to original text, exit edit mode.
                                    event.accepted = true
                                    root.editingRowId = -1
                                }
                                onActiveFocusChanged: {
                                    if (!activeFocus && root.editingRowId === row.task.id) {
                                        // Focus lost without Enter/Escape: save and exit.
                                        var trimmed = text.trim()
                                        if (trimmed !== "") {
                                            TodoBoard.setTask(row.task.id, trimmed)
                                        }
                                        root.editingRowId = -1
                                    }
                                }
                            }
                        }
                    }
                }

                // Date range / due date
                Item {
                    Layout.preferredWidth: 130
                    Layout.preferredHeight: 22
                    Layout.minimumHeight: 22
                    Text {
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        text: {
                            if (row.task.startDate || row.task.endDate) {
                                return TodoBoard.formatRange(row.task.startDate, row.task.endDate)
                            }
                            if (row.task.dueDate) {
                                return (TodoBoard.isOverdue(row.task.dueDate) && !row.task.done
                                    ? Icons.clock + " "
                                    : "") + TodoBoard.formatDue(row.task.dueDate)
                            }
                            return ""
                        }
                        font.family: Config.theme.font
                        font.pixelSize: Styling.fontSize(-2)
                        color: {
                            if (row.task.startDate || row.task.endDate) {
                                if (TodoBoard.rangeIsOverdue(row.task.startDate, row.task.endDate, row.task.done))
                                    return Colors.error
                                if (TodoBoard.isInRangeToday(row.task.startDate, row.task.endDate))
                                    return Colors.primary
                                return Colors.outline
                            }
                            if (row.task.dueDate) {
                                return TodoBoard.isOverdue(row.task.dueDate) && !row.task.done
                                    ? Colors.error
                                    : Colors.outline
                            }
                            return "transparent"
                        }
                        elide: Text.ElideRight
                    }
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root._openRangePicker(row.task.id, row.task.startDate, row.task.endDate)
                    }
                }

                // Status badge
                StyledRect {
                    Layout.preferredWidth: 70
                    Layout.preferredHeight: 22
                    Layout.minimumHeight: 22
                    radius: Styling.radius(-2)
                    variant: row.task.done ? "common" : "primary"
                    Text {
                        anchors.centerIn: parent
                        text: row.task.done ? "Done" : "Pending"
                        font.family: Config.theme.font
                        font.pixelSize: Styling.fontSize(-3)
                        font.weight: Font.Medium
                        color: row.task.done ? Colors.outline : Styling.srItem("primary")
                    }
                }

                // Edit button — next to the status badge, inside the layout
                StyledRect {
                    id: editBtn
                    Layout.preferredWidth: 22
                    Layout.preferredHeight: 22
                    Layout.minimumHeight: 22
                    radius: Styling.radius(-2)
                    variant: editMa.containsMouse ? "focus" : "common"
                    visible: !row.task.done && root.editingRowId !== row.task.id
                    Text {
                        anchors.centerIn: parent
                        text: Icons.edit
                        font.family: Icons.font
                        font.pixelSize: Styling.fontSize(-3)
                        color: editMa.containsMouse
                            ? Styling.srItem("primary")
                            : Colors.overBackground
                    }
                    MouseArea {
                        id: editMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            // Enter inline edit mode for this row.
                            root.editingRowOriginal = row.task.task
                            root.editingRowId = row.task.id
                        }
                    }
                }

                // Delete button — right after edit
                StyledRect {
                    id: delBtn
                    Layout.preferredWidth: 22
                    Layout.preferredHeight: 22
                    Layout.minimumHeight: 22
                    Layout.rightMargin: 12
                    radius: Styling.radius(-2)
                    variant: delMa.containsMouse ? "error" : "common"
                    visible: root.editingRowId !== row.task.id
                    Text {
                        anchors.centerIn: parent
                        text: Icons.trash
                        font.family: Icons.font
                        font.pixelSize: Styling.fontSize(-3)
                        color: delMa.containsMouse
                            ? Colors.overError
                            : Colors.error
                    }
                    MouseArea {
                        id: delMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            // If this row was being edited, cancel first.
                            if (root.editingRowId === row.task.id) {
                                root.editingRowId = -1
                            }
                            TodoBoard.removeTask(row.task.id)
                        }
                    }
                }
            }
        }
    }
}
