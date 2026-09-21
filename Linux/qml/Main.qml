pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts

ApplicationWindow {
    id: root
    required property var captureController
    required property var serverStatus
    required property var dictationController
    required property var pasteController
    required property var shortcutsController
    required property var dictionaryController
    required property var windowController
    property bool closingAfterCancellation: false
    property int currentPage: -1
    readonly property var pageTitles: ["Dictionary", "Microphone", "Shortcuts", "Engine"]
    property string dictionaryFeedback: ""
    readonly property color textColor: "#f2e8ed"
    readonly property color secondary: "#bd9daf"
    readonly property color edge: "#985961"

    width: 340
    height: 380
    minimumWidth: 320
    minimumHeight: 340
    visible: true
    title: "cotto"
    color: "#16121c"
    font.family: "Noto Sans"
    font.pixelSize: 14
    palette.window: "#16121c"
    palette.windowText: textColor
    palette.base: "#211722"
    palette.alternateBase: "#2c1e28"
    palette.text: textColor
    palette.button: "#2c1e28"
    palette.buttonText: textColor
    palette.highlight: "#5d2f38"
    palette.highlightedText: textColor
    palette.placeholderText: secondary
    palette.mid: edge
    palette.dark: edge
    palette.light: secondary

    onClosing: function(close) {
        close.accepted = false
        if (windowController.available) {
            if (captureController.testing) captureController.stopTest()
            root.hide()
        } else root.quitCotto()
    }
    function finishQuitIfIdle() {
        if (closingAfterCancellation && !dictationController.active) {
            closingAfterCancellation = false
            windowController.finishQuit()
        }
    }
    function quitCotto() {
        closingAfterCancellation = true
        if (captureController.testing) captureController.stopTest()
        if (dictationController.active) dictationController.cancel()
        finishQuitIfIdle()
    }
    Connections {
        target: root.dictationController
        function onChanged() { root.finishQuitIfIdle() }
    }
    Connections {
        target: root.windowController
        function onQuitRequested() { root.quitCotto() }
    }

    component Action: Button {
        id: action
        property bool primary: false
        implicitHeight: 38
        leftPadding: 16
        rightPadding: 16
        contentItem: Text {
            text: action.text
            font: action.font
            color: root.textColor
            opacity: action.enabled ? 1 : 0.45
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
        }
        background: Rectangle {
            color: action.down ? "#985961" : action.primary || action.hovered ? "#5d2f38" : "#2c1e28"
            opacity: action.enabled ? 1 : 0.5
            border.width: action.visualFocus ? 2 : 1
            border.color: action.visualFocus ? root.textColor : root.edge
        }
    }
    component MenuLink: Button {
        id: link
        Layout.fillWidth: true
        implicitHeight: 34
        leftPadding: 8
        rightPadding: 8
        contentItem: Text {
            text: link.text
            font: link.font
            color: link.enabled ? root.textColor : root.secondary
            opacity: link.enabled ? 1 : 0.5
            verticalAlignment: Text.AlignVCenter
            elide: Text.ElideRight
        }
        background: Rectangle {
            color: link.down ? root.edge : link.hovered ? "#5d2f38" : "transparent"
            border.width: link.visualFocus ? 2 : 0
            border.color: root.textColor
        }
    }
    component Note: Label {
        color: root.secondary
        wrapMode: Text.WordWrap
        Layout.fillWidth: true
    }
    component Heading: Label {
        font.pixelSize: 20
        font.weight: Font.DemiBold
        color: root.textColor
        Layout.bottomMargin: 6
    }
    component Field: ComboBox {
        id: field
        Layout.fillWidth: true
        implicitHeight: 40
        background: Rectangle {
            color: "#211722"
            border.width: field.visualFocus ? 2 : 1
            border.color: field.visualFocus ? root.textColor : root.edge
        }
    }
    component Page: ScrollView {
        id: page
        default property alias content: column.data
        contentWidth: availableWidth
        clip: true
        ColumnLayout {
            id: column
            width: page.availableWidth
            spacing: 10
        }
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 16
        spacing: 12
        RowLayout {
            visible: root.currentPage >= 0
            MenuLink {
                id: backButton
                objectName: "backToMenu"
                text: "‹ Menu"
                Layout.fillWidth: false
                onClicked: {
                    const page = root.currentPage
                    root.currentPage = -1
                    menuEntries.itemAt(page).forceActiveFocus()
                }
            }
            Heading {
                objectName: "pageTitle"
                text: root.currentPage >= 0 ? root.pageTitles[root.currentPage] : ""
                Layout.fillWidth: true
                Layout.bottomMargin: 0
            }
        }
        Page {
            objectName: "mainMenu"
            visible: root.currentPage < 0
            Layout.fillWidth: true
            Layout.fillHeight: true
            RowLayout {
                Layout.fillWidth: true
                Heading { text: "cotto"; Layout.fillWidth: true; Layout.bottomMargin: 0 }
                MenuLink {
                    text: root.serverStatus.checking ? "Checking…" : root.serverStatus.ready ? "Ready" : "Check engine"
                    Layout.fillWidth: false
                    onClicked: root.openPage(3)
                }
            }
            Note {
                text: {
                    const hold = root.shortcutsController.bindings.find(binding => binding.id === "hold")
                    return root.shortcutsController.enabled && hold
                        ? "Hold " + hold.trigger + " to dictate"
                        : "Set up dictation in Shortcuts."
                }
            }
            MenuLink {
                objectName: "copyLastMessage"
                text: "Copy last message"
                enabled: root.dictationController.transcript.length > 0 && !root.dictationController.active
                onClicked: root.dictationController.copyTranscript()
            }
            Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: "#2c1e28" }
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 0
                Repeater {
                    id: menuEntries
                    model: root.pageTitles
                    delegate: MenuLink {
                        required property int index
                        required property string modelData
                        objectName: "nav" + index
                        text: modelData + "…"
                        onClicked: root.openPage(index)
                    }
                }
            }
            Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: "#2c1e28" }
            MenuLink { objectName: "quitCotto"; text: "Quit cotto"; onClicked: root.quitCotto() }
        }
        StackLayout {
            id: settingsPages
            visible: root.currentPage >= 0
            Layout.fillWidth: true
            Layout.fillHeight: true
            currentIndex: Math.max(0, root.currentPage)

                ColumnLayout {
                    spacing: 10
                    Note { text: "Your words and names. One per line." }
                    ScrollView {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        clip: true
                        TextArea {
                            id: words
                            objectName: "dictionaryWords"
                            Component.onCompleted: text = root.dictionaryController.text
                            color: root.textColor
                            placeholderTextColor: root.secondary
                            placeholderText: "Add a word or phrase"
                            selectByMouse: true
                            wrapMode: TextEdit.Wrap
                            padding: 14
                            Accessible.name: "Personal dictionary words, one per line"
                            onTextChanged: root.dictionaryFeedback = ""
                            background: Rectangle {
                                color: "#211722"
                                border.width: words.activeFocus ? 2 : 1
                                border.color: words.activeFocus ? root.textColor : root.edge
                            }
                        }
                    }
                    Note {
                        objectName: "dictionaryMessage"
                        text: root.dictionaryController.error || root.dictionaryFeedback
                        visible: text.length > 0
                        color: root.dictionaryController.error ? "#f2cd91" : root.secondary
                    }
                    RowLayout {
                        Layout.fillWidth: true
                        Action {
                            objectName: "saveDictionary"
                            text: "Save"
                            primary: true
                            enabled: words.text !== root.dictionaryController.text || root.dictionaryController.error.length > 0
                            onClicked: {
                                if (root.dictionaryController.save(words.text)) {
                                    words.text = root.dictionaryController.text
                                    root.dictionaryFeedback = "Saved. Applies to your next recording."
                                }
                            }
                        }
                        Note { text: "Only for your user."; horizontalAlignment: Text.AlignRight }
                    }
                }

                Page {
                    Label { text: "Input" }
                    Field {
                        objectName: "inputDevice"
                        model: root.captureController.devices
                        textRole: "name"
                        valueRole: "id"
                        enabled: !root.captureController.recording && !root.dictationController.active
                        Accessible.name: "Microphone input"
                        currentIndex: {
                            for (let i = 0; i < model.length; ++i)
                                if (model[i].id === root.captureController.selectedDevice) return i
                            return -1
                        }
                        onActivated: root.captureController.selectedDevice = currentValue
                    }
                    Label { text: "Channel" }
                    Field {
                        model: root.captureController.channelCount
                        currentIndex: root.captureController.selectedChannel < count ? root.captureController.selectedChannel : -1
                        displayText: currentIndex >= 0 ? "Channel " + (currentIndex + 1) : "Unavailable"
                        delegate: ItemDelegate {
                            required property int index
                            text: "Channel " + (index + 1)
                            width: ListView.view.width
                        }
                        enabled: !root.captureController.recording && !root.dictationController.active && count > 0
                        Accessible.name: "Input channel"
                        onActivated: root.captureController.selectedChannel = currentIndex
                    }
                    ProgressBar {
                        id: meter
                        Layout.fillWidth: true
                        from: 0; to: 1; value: root.captureController.level
                        Accessible.name: "Microphone level"
                        background: Rectangle { implicitHeight: 6; color: "#2c1e28" }
                        contentItem: Item {
                            implicitHeight: 6
                            Rectangle { width: meter.visualPosition * parent.width; height: parent.height; color: root.secondary }
                        }
                    }
                    RowLayout {
                        Action {
                            text: root.captureController.testing ? "Stop test" : "Test microphone"
                            enabled: !root.dictationController.active && root.captureController.channelCount > root.captureController.selectedChannel
                            onClicked: root.captureController.testing ? root.captureController.stopTest() : root.captureController.startTest()
                        }
                        Note { text: root.captureController.testing ? "Stops after 10 seconds." : "" }
                    }
                    Note { text: root.captureController.status }
                }

                Page {
                    Repeater {
                        model: root.shortcutsController.bindings
                        delegate: RowLayout {
                            required property var modelData
                            Layout.fillWidth: true
                            Label { text: modelData.name; Layout.fillWidth: true; wrapMode: Text.WordWrap }
                            Label { text: modelData.trigger; color: root.secondary }
                        }
                    }
                    Note { text: root.shortcutsController.status }
                    Flow {
                        Layout.fillWidth: true
                        spacing: 8
                        Action {
                            text: root.shortcutsController.busy ? "Waiting for KDE…" : root.shortcutsController.enabled ? "Configure…" : "Connect shortcuts…"
                            enabled: !root.shortcutsController.busy && !root.dictationController.active
                            onClicked: root.shortcutsController.setup()
                        }
                        Action {
                            text: "Disconnect"
                            visible: root.shortcutsController.enabled || root.shortcutsController.busy
                            onClicked: root.shortcutsController.disconnectShortcuts()
                        }
                    }
                    Label { text: "Paste into focused app"; font.weight: Font.DemiBold; Layout.topMargin: 16 }
                    Note { text: root.pasteController.status }
                    Flow {
                        Layout.fillWidth: true
                        spacing: 8
                        Action {
                            text: root.pasteController.busy ? "Waiting for KDE…" : "Enable paste…"
                            visible: !root.pasteController.ready
                            enabled: !root.pasteController.busy && !root.dictationController.active
                            onClicked: root.pasteController.setup()
                        }
                        Action {
                            text: "Disable paste"
                            visible: root.pasteController.ready || root.pasteController.busy
                            onClicked: root.pasteController.disconnectPaste()
                        }
                    }
                }

                Page {
                    Label {
                        text: root.serverStatus.checking ? "Checking…" : root.serverStatus.ready ? "Ready" : "Not ready"
                        font.weight: Font.DemiBold
                    }
                    Note { text: root.serverStatus.message }
                    Note { text: root.serverStatus.endpoint }
                    Action {
                        text: "Check connection"
                        enabled: !root.serverStatus.checking
                        onClicked: root.serverStatus.refresh()
                    }
                }
        }
    }
    function openPage(index) {
        root.currentPage = index
        if (index === 0) words.forceActiveFocus()
        else backButton.forceActiveFocus()
    }
    footer: ToolBar {
        visible: root.dictationController.active || root.dictationController.transcript.length > 0
            || root.dictationController.status !== "Ready to connect."
        height: visible ? footerContent.implicitHeight + 16 : 0
        background: Rectangle { color: "#2c1e28" }
        ColumnLayout {
            id: footerContent
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: 8
            spacing: 6
            Note { text: root.dictationController.status }
            RowLayout {
                visible: root.dictationController.active || root.dictationController.transcript.length > 0
            Action {
                objectName: "stopRecording"
                text: "Stop"
                visible: root.captureController.recording && !root.captureController.testing
                onClicked: root.dictationController.stop()
            }
            Action {
                objectName: "cancelRecording"
                text: "Cancel"
                visible: root.dictationController.active
                onClicked: root.dictationController.cancel()
            }
            Action {
                objectName: "latestTranscript"
                text: "Review message…"
                visible: root.dictationController.transcript.length > 0 && !root.dictationController.active
                onClicked: transcript.open()
            }
            }
        }
    }
    Dialog {
        id: transcript
        objectName: "transcriptDialog"
        title: "Latest transcript"
        parent: Overlay.overlay
        anchors.centerIn: parent
        width: Math.min(root.width - 48, 620)
        height: Math.min(root.height - 48, 430)
        modal: true
        standardButtons: Dialog.Close
        ColumnLayout {
            anchors.fill: parent
            Note { text: root.dictationController.deliveryStatus }
            ScrollView {
                Layout.fillWidth: true
                Layout.fillHeight: true
                TextArea {
                    text: root.dictationController.transcript
                    readOnly: true
                    selectByMouse: true
                    wrapMode: TextEdit.Wrap
                    Accessible.name: "Latest transcript"
                }
            }
            Action { objectName: "copyTranscript"; text: "Copy"; onClicked: root.dictationController.copyTranscript() }
        }
    }
}
