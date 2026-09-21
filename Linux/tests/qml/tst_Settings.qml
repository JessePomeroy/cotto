import QtQuick
import QtQuick.Controls.Basic
import QtTest
import "../../qml" as Cotto

TestCase {
    id: test
    name: "Settings"
    when: app.visible
    QtObject {
        id: dictionary
        property string text: ""
        property string error: ""
        property bool rejectSave: false
        function save(value) {
            if (rejectSave) { error = "Could not save."; return false }
            error = ""; text = value; return true
        }
    }
    QtObject {
        id: capture
        property bool recording: false
        property bool testing: false
        property var devices: [{id: "", name: "System default"}]
        property string selectedDevice: ""
        property int selectedChannel: 0
        property int channelCount: 2
        property real level: 0
        property string status: "Microphone is closed."
        function startTest() { testing = true; recording = true }
        function stopTest() { testing = false; recording = false }
    }
    QtObject {
        id: dictation
        property bool active: false
        property string status: "Ready to connect."
        property string transcript: ""
        property string deliveryStatus: "Paste unconfirmed. Check the destination before copying."
        signal changed()
        property bool deferCancellation: false
        property int cancellations: 0
        function cancel() {
            cancellations += 1
            if (deferCancellation) return
            active = false; capture.recording = false; changed()
        }
        function stop() { capture.recording = false }
        property int copies: 0
        function copyTranscript() { copies += 1 }
    }
    property QtObject lifecycle: QtObject {
        id: windowController
        property bool available: true
        property int quits: 0
        signal quitRequested()
        function finishQuit() { quits += 1 }
    }
    Cotto.Main {
        id: app
        windowController: test.lifecycle
        dictionaryController: dictionary
        captureController: capture
        dictationController: dictation
        serverStatus: ({ ready: false, checking: false, message: "Server unavailable.", endpoint: "http://127.0.0.1:8392", refresh: function() {} })
        pasteController: ({ ready: false, busy: false, status: "Paste disabled.", setup: function() {}, disconnectPaste: function() {} })
        shortcutsController: ({ enabled: false, busy: false, bindings: [], status: "Shortcuts disconnected.", setup: function() {}, disconnectShortcuts: function() {} })
    }
    function initTestCase() {
        app.requestActivate()
        wait(200)
    }
    function init() {
        app.show()
        windowController.available = true
        dictation.deferCancellation = false
        app.currentPage = -1
        app.width = 340; app.height = 380
        dictation.active = false; dictation.transcript = ""; dictation.status = "Ready to connect."
        capture.recording = false; capture.testing = false
    }
    function test_closeHidesWithoutCancellingDictation() {
        dictation.active = true; capture.recording = true
        const quits = windowController.quits
        const cancellations = dictation.cancellations
        app.close()
        verify(!app.visible)
        verify(dictation.active && capture.recording)
        compare(windowController.quits, quits)
        compare(dictation.cancellations, cancellations)
        app.show()
        verify(app.visible)
    }
    function test_closeStopsMicrophoneTestOnly() {
        capture.startTest()
        app.close()
        verify(!app.visible)
        verify(!capture.recording && !capture.testing)
        app.show()
    }
    function test_quitWaitsForCancellation() {
        app.height = 500
        dictation.active = true; capture.recording = true
        dictation.deferCancellation = true
        wait(50)
        const quits = windowController.quits
        const cancellations = dictation.cancellations
        mouseClick(findChild(app.contentItem, "quitCotto"))
        compare(dictation.cancellations, cancellations + 1)
        compare(windowController.quits, quits)
        dictation.active = false; capture.recording = false; dictation.changed()
        compare(windowController.quits, quits + 1)
    }
    function test_trayQuitWorksWhileHidden() {
        app.close()
        const quits = windowController.quits
        windowController.quitRequested()
        compare(windowController.quits, quits + 1)
        app.show()
    }
    function test_withoutTrayCloseQuitsRatherThanStrandingApp() {
        windowController.available = false
        const quits = windowController.quits
        app.close()
        compare(windowController.quits, quits + 1)
    }
    function test_defaultMenu() {
        compare(app.currentPage, -1)
        compare(app.width, 340)
        compare(app.height, 380)
        verify(findChild(app.contentItem, "mainMenu").visible)
        verify(!findChild(app.contentItem, "dictionaryWords").visible)
        const copy = findChild(app.contentItem, "copyLastMessage")
        verify(!copy.enabled)
        dictation.transcript = "Recovered words."
        verify(copy.enabled)
        const previous = dictation.copies
        mouseClick(copy)
        compare(dictation.copies, previous + 1)
        dictation.active = true
        verify(!copy.enabled)
    }
    function test_dictionaryKeyboardSave() {
        mouseClick(findChild(app.contentItem, "nav0"))
        const field = findChild(app.contentItem, "dictionaryWords")
        verify(field !== null)
        mouseClick(field)
        field.forceActiveFocus()
        tryCompare(field, "activeFocus", true)
        keyClick("H")
        keyClick(Qt.Key_E)
        keyClick(Qt.Key_R)
        keyClick(Qt.Key_D)
        keyClick(Qt.Key_R)
        compare(field.text, "Herdr")
        mouseClick(findChild(app.contentItem, "backToMenu"))
        mouseClick(findChild(app.contentItem, "nav0"))
        compare(field.text, "Herdr")
        const save = findChild(app.contentItem, "saveDictionary")
        verify(save.enabled)
        dictionary.rejectSave = true
        mouseClick(save)
        compare(field.text, "Herdr")
        compare(dictionary.text, "")
        compare(findChild(app.contentItem, "dictionaryMessage").text, "Could not save.")
        dictionary.rejectSave = false
        mouseClick(save)
        compare(dictionary.text, "Herdr")
        verify(!save.enabled)
        compare(findChild(app.contentItem, "dictionaryMessage").text, "Saved. Applies to your next recording.")
    }
    function test_recordingControlsAtMinimumSize() {
        app.width = 320; app.height = 340
        dictation.active = true
        dictation.transcript = "Previous take."
        dictation.status = "Recording. Release the shortcut to finish."
        capture.recording = true
        wait(50)
        const stop = findChild(app.footer, "stopRecording")
        const cancel = findChild(app.footer, "cancelRecording")
        verify(!findChild(app.footer, "latestTranscript").visible)
        for (const button of [stop, cancel]) {
            verify(button.visible)
            const position = button.mapToItem(app.footer, 0, 0)
            verify(position.x >= 0 && position.x + button.width <= app.width)
            verify(position.y >= 0 && position.y + button.height <= app.footer.height)
        }
        grabImage(app.contentItem.parent).save("menu-recording.png")
        mouseClick(stop)
        verify(!capture.recording)
        verify(dictation.active)
        mouseClick(cancel)
        verify(!dictation.active)
    }
    function test_recoveryAndError() {
        dictation.transcript = "A transcript to recover."
        dictation.status = "Transcript saved."
        wait(50)
        verify(app.footer.visible)
        mouseClick(findChild(app.footer, "latestTranscript"))
        const dialog = findChild(app, "transcriptDialog")
        tryCompare(dialog, "opened", true)
        verify(dialog.y >= 16)
        verify(dialog.y + dialog.height <= app.height - 16)
        grabImage(app.contentItem.parent).save("settings-recovery.png")
        const previous = dictation.copies
        mouseClick(findChild(dialog.contentItem, "copyTranscript"))
        compare(dictation.copies, previous + 1)
        keyClick(Qt.Key_Escape)
        tryCompare(dialog, "opened", false)
        dictation.transcript = ""
        dictation.status = "The local inference request failed."
        verify(app.footer.visible)
    }
    function test_navigationAndSizes() {
        for (const size of [[340, 380], [320, 340], [420, 460]]) {
            app.width = size[0]; app.height = size[1]
            wait(50)
            grabImage(app.contentItem.parent).save("menu-" + size[0] + ".png")
            for (let i = 0; i < 4; ++i) {
                const nav = findChild(app.contentItem, "nav" + i)
                mouseClick(nav)
                compare(app.currentPage, i)
                mouseClick(findChild(app.contentItem, "backToMenu"))
                compare(app.currentPage, -1)
                verify(nav.activeFocus)
                keyClick(Qt.Key_Space)
                compare(app.currentPage, i)
                compare(findChild(app.contentItem, "pageTitle").text, app.pageTitles[i])
                wait(50)
                const field = i === 0 ? findChild(app.contentItem, "dictionaryWords") : i === 1 ? findChild(app.contentItem, "inputDevice") : findChild(app.contentItem, "backToMenu")
                const position = field.mapToItem(app.contentItem, 0, 0)
                verify(position.x >= 0 && position.x + field.width <= app.width + 1)
                verify(field.height > 0)
                verify(position.y >= 0 && position.y + field.height <= app.contentItem.height + 1)
                grabImage(app.contentItem.parent).save("settings-" + size[0] + "-" + i + ".png")
                mouseClick(findChild(app.contentItem, "backToMenu"))
            }
        }
    }
}
