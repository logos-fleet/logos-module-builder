import QtQuick
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// THE COUNTER VIEW, and the same document in both containers. On the desktop
// `logos` is LogosQmlBridge over a ui-host socket; inside the Web container it
// is LogosWebBridge over a MessagePort to this module's own wasm image. Nothing
// below knows which.
//
// TWO THINGS IT DOES THAT THE DESKTOP FIXTURE DOES NOT, because they are what
// slice 27 asks for:
//
//   * it takes its backend on an EDGE. `logos.module()` answers null until the
//     backend's source metadata has arrived, and a dynamic replica handed to
//     QML before that is cached with the wrong metaobject for the life of the
//     page (ADR 0004). So the view asks again on viewModuleReadyChanged, which
//     both containers' bridges emit under that one name.
//   * it calls a NATIVE module by name through `logos.callModuleAsync`, which
//     inside the Web container leaves the page entirely: the runtime remotes it
//     to this module's wasm host, which makes a real logos-protocol call.
//
// The console lines are the browser end-to-end check's only window into a
// canvas — see wasm/browser-e2e/run.mjs.
Rectangle {
    id: root

    property var backend: null
    property int seen: -1
    property string callResult: ""

    color: Theme.palette.background

    function takeBackend() {
        root.backend = logos.module(logosModuleName)
        if (root.backend) {
            root.seen = root.backend.count
            console.log("logos-view: ready " + logosModuleName + " count=" + root.backend.count)
        }
    }

    Component.onCompleted: {
        takeBackend()
        logos.viewModuleReadyChanged.connect(function (name, ready) {
            if (name === logosModuleName && ready)
                root.takeBackend()
        })
    }

    Connections {
        target: root.backend
        function onCountChanged() {
            root.seen = root.backend.count
            console.log("logos-view: changed " + logosModuleName + " count=" + root.seen)
        }
    }

    ColumnLayout {
        anchors.centerIn: parent
        spacing: 16

        LogosText {
            objectName: "value"
            Layout.alignment: Qt.AlignHCenter
            text: root.seen >= 0 ? String(root.seen) : "—"
        }

        LogosButton {
            id: incrementButton
            objectName: "increment"
            Layout.alignment: Qt.AlignHCenter
            text: qsTr("Increment")
            onClicked: if (root.backend) root.backend.increment()
        }

        LogosText {
            objectName: "callResult"
            Layout.alignment: Qt.AlignHCenter
            text: root.callResult
        }
    }

    // A call to ANOTHER module, made from the view. Driven by a timer rather
    // than a button because what it proves is the route, and the route is the
    // same whoever starts it.
    Timer {
        interval: 400
        running: true
        repeat: false
        onTriggered: logos.callModuleAsync("greeter", "greet", ["logos"], function (payload) {
            root.callResult = payload
            console.log("logos-view: callModuleAsync -> " + payload)
        }, 5000)
    }

    // Where the button is, in window coordinates, so a browser test can put a
    // real pointer event on it. Qt draws into a canvas and a test has no DOM to
    // query; this is the only honest way to click what a user would click.
    Timer {
        interval: 250
        running: true
        repeat: true
        onTriggered: {
            var p = incrementButton.mapToItem(null,
                                              incrementButton.width / 2,
                                              incrementButton.height / 2)
            console.log("logos-view: button-at " + Math.round(p.x) + " " + Math.round(p.y))
        }
    }
}
