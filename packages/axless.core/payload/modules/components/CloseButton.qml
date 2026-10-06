import QtQuick
import QtQuick.Controls
import qs.modules.theme
import qs.modules.components
import qs.config

// axless.core: ported from NothingLess for the Hax launcher. Ambxst has no
// CloseButton, and the original depended on NothingLess's Anim singleton;
// the two references are translated to Ambxst's Config.animDuration.
Button {
    id: root

    implicitWidth: 28
    implicitHeight: 28
    flat: true
    hoverEnabled: true

    contentItem: Text {
        text: "\u2715"
        font.family: Config.theme.font
        font.pixelSize: Styling.fontSize(-1)
        color: parent.hovered ? Styling.srItem("primary") : Colors.outline
        anchors.centerIn: parent
        Behavior on color {
            enabled: Config.animDuration > 0
            ColorAnimation { duration: Config.animDuration }
        }
    }

    background: StyledRect {
        variant: root.hovered ? "focus" : "transparent"
        radius: Styling.radius(-6)
    }
}
