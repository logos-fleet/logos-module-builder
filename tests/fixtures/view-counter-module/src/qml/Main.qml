import QtQuick
import QtQuick.Controls

// The counter view. `logos.module("view_counter")` is a typed replica of the
// .rep on both the desktop (over the ui-host socket) and iOS (over the
// in-process node), so this file is the same on both.
Item {
    id: root
    property var backend: logos.module("view_counter")

    Column {
        anchors.centerIn: parent
        spacing: 12

        Text {
            objectName: "countLabel"
            anchors.horizontalCenter: parent.horizontalCenter
            text: root.backend ? root.backend.count : "-"
            font.pixelSize: 48
        }

        Text {
            objectName: "statusLabel"
            anchors.horizontalCenter: parent.horizontalCenter
            text: root.backend ? root.backend.status : "connecting…"
        }

        Button {
            objectName: "incrementButton"
            anchors.horizontalCenter: parent.horizontalCenter
            text: "Increment"
            onClicked: if (root.backend) root.backend.increment()
        }
    }
}
