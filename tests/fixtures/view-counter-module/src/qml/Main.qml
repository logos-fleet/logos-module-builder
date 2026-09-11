import QtQuick

// The counter view. `logos.module("view_counter")` is a typed replica of the
// .rep on both the desktop (over the ui-host socket) and iOS (over the
// in-process node), so this file is the same on both.
//
// QtQuick and nothing else, deliberately: a statically linked iOS app has to
// import every QML plugin it uses at LINK time, and QtQuick.Controls is a
// dozen more of them for a button this fixture can draw itself.
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
            color: "#1f2328"
        }

        Text {
            objectName: "statusLabel"
            anchors.horizontalCenter: parent.horizontalCenter
            text: root.backend ? root.backend.status : "connecting…"
            color: "#57606a"
        }

        Rectangle {
            objectName: "incrementButton"
            anchors.horizontalCenter: parent.horizontalCenter
            width: 180
            height: 48
            radius: 8
            color: tap.pressed ? "#1a7f37" : "#238636"

            Text {
                anchors.centerIn: parent
                text: "Increment"
                color: "#ffffff"
                font.pixelSize: 16
            }

            MouseArea {
                id: tap
                anchors.fill: parent
                onClicked: if (root.backend) root.backend.increment()
            }
        }
    }
}
