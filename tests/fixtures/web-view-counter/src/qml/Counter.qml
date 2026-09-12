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
// AND A TEXT FIELD AND A LIST, which slice 28 asks for. A `web` variant's
// keyboard input and list scrolling cannot be shown against a view that has
// neither, and this is the only `web` variant in existence -- so the two
// controls live here, report what reached them, and every container's check
// drives the same document.
//
// The console lines are the browser end-to-end check's only window into a
// canvas -- see wasm/browser-e2e/run.mjs.
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

        // WHAT A KEY EVENT LANDS IN. A container drives a real DOM key event at
        // the page; what it can then read is this, because a canvas has no DOM
        // node holding the text. Reported on every change rather than on
        // editingFinished: the interesting failure is a key that arrived and
        // produced the WRONG character, which a final-value check would hide.
        LogosTextField {
            id: field
            objectName: "field"
            Layout.alignment: Qt.AlignHCenter
            Layout.preferredWidth: 220
            placeholderText: qsTr("type here")
            onTextChanged: console.log("logos-view: typed " + field.text)
        }

        // THE FOCUS, SAID OUT LOUD, and it is the EDITOR's rather than the
        // field's: `activeFocus` is true only of the item that actually holds
        // it, and what holds it inside a LogosTextField is the TextInput.
        // Watched from outside rather than declared on the field, because a
        // handler written there would replace the one LogosTextField itself
        // uses to hand focus on to that editor.
        //
        // Worth a line of its own: a key event that reaches Qt and lands on
        // nothing looks exactly like one that never arrived, and the two have
        // different causes.
        Connections {
            target: field.textInput
            function onActiveFocusChanged() {
                console.log("logos-view: field-focus " + field.textInput.activeFocus)
            }
        }

        // WHAT A SCROLL GESTURE MOVES. Longer than its viewport by design -- a
        // list that fits cannot be scrolled, and a check that drove one would
        // pass against a frozen view.
        LogosListView {
            id: list
            objectName: "list"
            Layout.alignment: Qt.AlignHCenter
            Layout.preferredWidth: 220
            Layout.preferredHeight: 120
            model: 60
            delegate: LogosText {
                required property int index
                width: ListView.view ? ListView.view.width : 0
                text: "row " + index
            }
            // contentY, AND the row it puts at the top. The offset alone would
            // be satisfied by a list that moved its content without rebinding a
            // delegate, and what a user calls scrolling is the row changing.
            onContentYChanged: console.log("logos-view: scrolled contentY="
                                           + Math.round(list.contentY)
                                           + " first=" + list.indexAt(2, list.contentY + 2))
        }
    }

    // Where the things a test must aim at ARE, in window coordinates. Qt draws
    // into a canvas and a test has no DOM to query; this is the only honest way
    // to put a pointer or a key on what a user would touch.
    Timer {
        interval: 250
        running: true
        repeat: true
        onTriggered: {
            var report = function (label, item) {
                var p = item.mapToItem(null, item.width / 2, item.height / 2)
                console.log("logos-view: " + label + " " + Math.round(p.x) + " " + Math.round(p.y))
            }
            report("button-at", incrementButton)
            report("field-at", field)
            report("list-at", list)
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
}
