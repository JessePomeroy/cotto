import AppKit
import Foundation
import SottoCore
import SwiftUI
import XCTest
@testable import Sotto

/// Opt-in native view previews, not screenshots of the user's running app.
/// Run scripts/native-ui-snapshots.sh; normal `swift test` skips this test.
/// WindowServer-only sidebar vibrancy is not faithfully composited offscreen;
/// use a live screenshot for final full-window appearance/glass verification.
@MainActor
final class ViewSnapshotTests: XCTestCase {
    func testGenerateNativePreviewsWhenRequested() async throws {
        guard let outputPath = ProcessInfo.processInfo.environment["SOTTO_SNAPSHOT_DIR"],
              outputPath.hasPrefix("/") else {
            throw XCTSkip("Set SOTTO_SNAPSHOT_DIR to an absolute output folder to render native previews.")
        }
        let files = FileManager.default
        let output = URL(fileURLWithPath: outputPath, isDirectory: true)
        try files.createDirectory(at: output, withIntermediateDirectories: true)
        let fixtureRoot = files.temporaryDirectory.appendingPathComponent("Sotto-native-preview-\(UUID())", isDirectory: true)
        try files.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
        let suite = "Sotto-native-preview-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? files.removeItem(at: fixtureRoot)
        }
        defaults.set("fn", forKey: "holdKey")
        let configuration = ConfigurationStore(
            file: ConfigurationFile(url: fixtureRoot.appendingPathComponent("settings/config.json")),
            legacyDefaults: defaults
        )
        await configuration.start()
        configuration.stopWatching()
        XCTAssertNil(configuration.errorMessage)
        let controller = SottoController(configuration: configuration, startServices: false)
        controller.permissions = PermissionSnapshot(microphone: true, accessibility: true, inputMonitoring: true)
        controller.isHotkeyActive = true
        controller.modelStatus = .installed
        controller.engineStatus = .unloaded
        controller.microphones.update(devices: [
            AudioInputDevice(uid: "synthetic-input", name: "MacBook Pro Microphone", transport: .builtIn),
        ], systemDefaultUID: "synthetic-input")
        defer { controller.shutdown() }

        let app = NSApplication.shared
        let priorAppearance = app.appearance
        defer { app.appearance = priorAppearance }
        var measurements: [[String: Any]] = []
        for (appearanceName, colorScheme, label) in [
            (NSAppearance.Name.aqua, ColorScheme.light, "light"),
            (NSAppearance.Name.darkAqua, ColorScheme.dark, "dark"),
        ] {
            let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            app.appearance = appearance
            measurements.append(try await renderModelActions(
                output: output, appearance: appearance, colorScheme: colorScheme, label: label
            ))
            var expectedMenuHeight: CGFloat?
            for state in PreviewState.allCases {
                state.apply(to: controller)
                let dashboard = try await render(
                    SottoWindowView(controller: controller), size: NSSize(width: 940, height: 700),
                    appearance: appearance, colorScheme: colorScheme,
                    file: output.appendingPathComponent("native-preview-dashboard-\(state.rawValue)-\(label).png")
                )
                measurements.append(dashboard)
                measurements.append(try await render(
                    DictationPage(controller: controller, showModel: {}, showPreferences: {})
                        .tint(SottoPalette.accent)
                        .background(SottoPalette.canvas),
                    size: NSSize(width: 700, height: 600), appearance: appearance, colorScheme: colorScheme,
                    file: output.appendingPathComponent("native-preview-dashboard-detail-\(state.rawValue)-\(label).png")
                ))
                let menu = SottoMenuView(controller: controller, openWindow: {}, quit: {})
                let host = NSHostingController(rootView: menu.environment(\.colorScheme, colorScheme))
                let fitted = host.sizeThatFits(in: NSSize(width: SottoMenuView.width, height: 10_000))
                XCTAssertEqual(fitted.width, SottoMenuView.width, accuracy: 1)
                XCTAssertGreaterThan(fitted.height, 150)
                XCTAssertLessThan(fitted.height, 600, "The menu must fit below a normal macOS menu bar")
                if let expectedMenuHeight {
                    XCTAssertEqual(fitted.height, expectedMenuHeight, accuracy: 1,
                                   "Changing dictation state must not resize the open menu")
                } else {
                    expectedMenuHeight = fitted.height
                }
                measurements.append(try await render(
                    menu, size: NSSize(width: SottoMenuView.width, height: ceil(fitted.height)),
                    appearance: appearance, colorScheme: colorScheme,
                    file: output.appendingPathComponent("native-preview-menu-\(state.rawValue)-\(label).png")
                ))
                for hovered in [false, true] {
                    let hud = DictationHUD(controller: controller, previewHover: hovered)
                    let hudHost = NSHostingController(rootView: hud.environment(\.colorScheme, colorScheme))
                    let hudSize = hudHost.sizeThatFits(in: NSSize(width: 1_000, height: 1_000))
                    XCTAssertEqual(hudSize.width, DictationHUD.width, accuracy: 0.5,
                                   "The compact HUD must retain its width in every state")
                    XCTAssertEqual(hudSize.height, DictationHUD.height, accuracy: 0.5,
                                   "Hover and status transitions must not move the HUD")
                    measurements.append(try await render(
                        hud.padding(14), size: NSSize(width: DictationHUD.width + 28, height: DictationHUD.height + 28),
                        appearance: appearance, colorScheme: colorScheme,
                        file: output.appendingPathComponent("native-preview-hud-\(state.rawValue)-\(hovered ? "hover" : "rest")-\(label).png"),
                        expectedHUDCancelLabel: controller.isBusy ? "Cancel dictation" : "Dismiss dictation status"
                    ))
                }
                if state == .ready {
                    measurements.append(try await render(
                        ModelPage(controller: controller, showPreferences: {})
                            .tint(SottoPalette.accent).background(SottoPalette.canvas),
                        size: NSSize(width: 700, height: 1_020), appearance: appearance, colorScheme: colorScheme,
                        file: output.appendingPathComponent("native-preview-models-complete-\(label).png")
                    ))
                    let pages: [(String, AnyView)] = [
                        ("microphone", AnyView(MicrophonePage(controller: controller))),
                        ("dictionary", AnyView(DictionaryPage(controller: controller))),
                        ("models", AnyView(ModelPage(controller: controller, showPreferences: {}))),
                        ("general", AnyView(PreferencesPage(controller: controller))),
                        ("history-empty", AnyView(HistoryPage(controller: controller))),
                    ]
                    for (name, page) in pages {
                        measurements.append(try await render(
                            page.tint(SottoPalette.accent).background(SottoPalette.canvas),
                            size: NSSize(width: 700, height: 620), appearance: appearance, colorScheme: colorScheme,
                            file: output.appendingPathComponent("native-preview-\(name)-\(label).png")
                        ))
                    }
                }
                for key in HoldKey.allCases where key != .fn {
                    controller.shortcut = key
                    let alternate = SottoMenuView(controller: controller, openWindow: {}, quit: {})
                    let alternateHost = NSHostingController(rootView: alternate.environment(\.colorScheme, colorScheme))
                    let alternateSize = alternateHost.sizeThatFits(in: NSSize(width: SottoMenuView.width, height: 10_000))
                    XCTAssertEqual(alternateSize.width, SottoMenuView.width, accuracy: 1)
                    XCTAssertEqual(alternateSize.height, fitted.height, accuracy: 1,
                                   "\(key.title) must fit without resizing the menu")
                    if state == .ready {
                        measurements.append(try await render(
                            alternate, size: NSSize(width: SottoMenuView.width, height: ceil(alternateSize.height)),
                            appearance: appearance, colorScheme: colorScheme,
                            file: output.appendingPathComponent("native-preview-menu-ready-\(key.rawValue)-\(label).png")
                        ))
                    }
                }
                controller.shortcut = .fn
            }
        }
        PreviewState.ready.apply(to: controller)
        let originalMicrophones = controller.microphones.preferences
        let originalDevices = controller.microphones.availableDevices
        let originalDefault = controller.microphones.systemDefaultUID
        let deskMicrophone = AudioInputDevice(uid: "preview-usb", name: "USB microphone", transport: .usb)
        let builtInMicrophone = AudioInputDevice(uid: "synthetic-input", name: "MacBook microphone", transport: .builtIn)
        let travelMicrophone = AudioInputDevice(uid: "preview-headset", name: "Travel headset", transport: .bluetooth)
        controller.microphones.update(devices: [deskMicrophone, builtInMicrophone], systemDefaultUID: builtInMicrophone.uid)
        _ = controller.microphones.addProfile(named: "Desk")
        for device in [deskMicrophone, builtInMicrophone, travelMicrophone] {
            controller.microphones.addToPriority(device)
        }
        controller.microphones.select(.automatic)
        for (appearanceName, colorScheme, label) in [
            (NSAppearance.Name.aqua, ColorScheme.light, "light"),
            (NSAppearance.Name.darkAqua, ColorScheme.dark, "dark"),
        ] {
            let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            app.appearance = appearance
            for width in [700, 520] {
                measurements.append(try await render(
                    MicrophonePage(controller: controller).tint(SottoPalette.accent).background(SottoPalette.canvas),
                    size: NSSize(width: width, height: 620), appearance: appearance, colorScheme: colorScheme,
                    file: output.appendingPathComponent("native-preview-microphone-priorities-\(width)-\(label).png")
                ))
            }
        }
        configuration.update { $0.microphones = originalMicrophones }
        controller.microphones.update(devices: originalDevices, systemDefaultUID: originalDefault)
        try await seedHistoryPreview(controller: controller, fixtureRoot: fixtureRoot)
        for (appearanceName, colorScheme, label) in [
            (NSAppearance.Name.aqua, ColorScheme.light, "light"),
            (NSAppearance.Name.darkAqua, ColorScheme.dark, "dark"),
        ] {
            let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            app.appearance = appearance
            measurements.append(try await render(
                HistoryPage(controller: controller).tint(SottoPalette.accent).background(SottoPalette.canvas),
                size: NSSize(width: 700, height: 620), appearance: appearance, colorScheme: colorScheme,
                file: output.appendingPathComponent("native-preview-history-populated-\(label).png")
            ))
        }
        await configuration.flush()
        XCTAssertEqual(controller.history.pendingSaveCount, 0)
        let manifest = try JSONSerialization.data(withJSONObject: [
            "kind": "offscreen native SwiftUI previews",
            "syntheticContentOnly": true,
            "includesWindowChrome": false,
            "limitations": ["Native sidebar vibrancy needs a live WindowServer screenshot.",
                            "Menu previews use an opaque native window background, not a desktop glass backdrop.",
                            "Hidden SwiftUI hosts may not expose AX children; each HUD measurement records whether its accessibility check ran."],
            "views": measurements,
        ], options: [.prettyPrinted, .sortedKeys])
        try manifest.write(to: output.appendingPathComponent("native-preview-manifest.json"), options: .atomic)
    }

    private func renderModelActions(output: URL, appearance: NSAppearance,
                                    colorScheme: ColorScheme, label: String) async throws -> [String: Any] {
        let states: [(title: String, action: String, progress: Double?, verifying: Bool, error: Bool)] = [
            ("Model file", "Show in Finder", nil, false, false),
            ("Memory", "Load into memory", nil, false, false),
            ("Memory", "Unload from memory", nil, false, false),
            ("1.1 GB of 2.27 GB", "Cancel", 0.48, false, false),
            ("Checking the model…", "Checking integrity", nil, true, false),
            ("The model could not be loaded. Free some memory and try again.", "Retry loading", nil, false, true),
        ]
        let rows = states.map { state in
            ModelActionRow(title: state.title, help: state.title, hasError: state.error,
                           progress: state.progress, isVerifying: state.verifying) {
                Button(state.action) {}.buttonStyle(.bordered)
                    .disabled(state.verifying)
            }
        }
        for row in rows {
            let host = NSHostingController(rootView: row.environment(\.colorScheme, colorScheme))
            let size = host.sizeThatFits(in: NSSize(width: 560, height: 1_000))
            XCTAssertEqual(size.height, 32, accuracy: 0.5,
                           "Model actions must keep their compact height during state changes")
        }
        return try await render(
            VStack(spacing: 0) {
                ForEach(rows.indices, id: \.self) { index in
                    rows[index].padding(.horizontal, 16).padding(.vertical, 8)
                    if index < rows.count - 1 { Divider().padding(.horizontal, 16) }
                }
            }.tint(SottoPalette.accent).background(SottoPalette.surface),
            size: NSSize(width: 600, height: 298), appearance: appearance, colorScheme: colorScheme,
            file: output.appendingPathComponent("native-preview-model-actions-\(label).png")
        )
    }

    private func seedHistoryPreview(controller: SottoController, fixtureRoot: URL) async throws {
        XCTAssertTrue(controller.history.directory.path.hasPrefix(fixtureRoot.path + "/"),
                      "History previews must never read or write the real archive")
        let writer = DictationArchiveWriter(root: controller.history.directory.deletingLastPathComponent())
        let audioURL = fixtureRoot.appendingPathComponent("synthetic-silence.wav")
        var audio = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ number: T) {
            var value = number.littleEndian
            withUnsafeBytes(of: &value) { audio.append(contentsOf: $0) }
        }
        append(UInt32(32_036))
        audio.append(Data("WAVEfmt ".utf8))
        append(UInt32(16)); append(UInt16(1)); append(UInt16(1)); append(UInt32(16_000))
        append(UInt32(32_000)); append(UInt16(2)); append(UInt16(16))
        audio.append(Data("data".utf8)); append(UInt32(32_000))
        audio.append(Data(repeating: 0, count: 32_000))
        try audio.write(to: audioURL)
        let start = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-05T16:38:00Z"))
        let texts = [
            "Let's give Sotto a little room to breathe.\n\n1. Keep the interface quiet.\n2. Make the shortcut feel instant.\n3. Let the words take the lead.",
            "I want to try MiniMax with Codex. Then send the notes to Raycast.",
            "A little less typing. A little more room to think.",
        ]
        for (index, text) in texts.enumerated() {
            let date = start.addingTimeInterval(Double(index) * -720)
            let format = DictationArchiveRecord.AudioFormat(sampleRate: 16_000, channels: 1,
                                                            sampleFormat: "pcm_s16le", frameCount: 16_000, durationSeconds: 1)
            let record = DictationArchiveRecord(
                id: UUID(), startedAt: date, releasedAt: date.addingTimeInterval(1), completedAt: date.addingTimeInterval(1.3),
                mode: .hotkey, outcome: .transcribed, rawText: text, transcriptText: text,
                model: .init(id: "large-v3-turbo", name: "Whisper large-v3-turbo", sha256: "synthetic-fixture",
                             engine: "whisper.cpp", engineVersion: "preview"),
                options: .init(requestedLanguage: "en", detectedLanguage: "en", removeFillers: true, vocabularyPrompt: "Sotto"),
                microphone: .init(uid: "synthetic-input", name: "MacBook Pro Microphone"),
                audio: .init(original: format, transcription: format),
                timing: .init(engineProcessingSeconds: 0.1, transcriptionWallSeconds: 0.15, releaseToResultSeconds: 0.3),
                appVersion: "preview", deliveryStatus: "inserted",
                textProcessing: .init(dictionaryTerms: ["Sotto"], dictionaryChangedText: false, inputText: text, outputText: text,
                                      enabled: true, status: .unchanged, modelID: "qwen3-4b-instruct-2507-mlx-4bit",
                                      engineVersion: "mlx-swift-preview", processingSeconds: 0.15, wallSeconds: 0.15)
            )
            _ = try await writer.save(record: record, originalAudio: audioURL, transcriptionAudio: audioURL).get()
        }
    }

    private func accessibilityElements(from root: Any, depth: Int = 0) -> [any NSAccessibilityProtocol] {
        guard depth < 30, let element = root as? any NSAccessibilityProtocol else { return [] }
        return [element] + (element.accessibilityChildren() ?? []).flatMap {
            accessibilityElements(from: $0, depth: depth + 1)
        }
    }

    private func render<Content: View>(_ content: Content, size: NSSize,
                                      appearance: NSAppearance, colorScheme: ColorScheme,
                                      file: URL, expectedHUDCancelLabel: String? = nil) async throws -> [String: Any] {
        let root = content
            .environment(\.colorScheme, colorScheme)
            .environment(\.locale, Locale(identifier: "en_US"))
            .environment(\.controlActiveState, .active)
            .transaction { $0.disablesAnimations = true }
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor))
        let hosting = NSHostingController(rootView: root)
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        hosting.view.appearance = appearance
        window.backgroundColor = .windowBackgroundColor
        window.contentViewController = hosting
        window.setContentSize(size)
        hosting.view.setFrameSize(size)
        defer { window.close() }
        // No orderFront/key activation. Give SwiftUI's layout transaction a turn
        // before caching the offscreen AppKit hierarchy, including native controls.
        await Task.yield()
        hosting.view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        hosting.view.layoutSubtreeIfNeeded()
        XCTAssertFalse(window.isVisible, "Preview generation must not present a native window")
        XCTAssertEqual(hosting.view.bounds.width, size.width, accuracy: 1)
        XCTAssertEqual(hosting.view.bounds.height, size.height, accuracy: 1)
        var accessibilityCheck = "not requested"
        if let expectedHUDCancelLabel {
            let elements = accessibilityElements(from: hosting.view)
            // A hidden NSHostingView can render pixels without constructing
            // its SwiftUI AX children. Do not report that as a VoiceOver pass.
            if (hosting.view.accessibilityChildren() ?? []).isEmpty {
                accessibilityCheck = "unavailable: hidden NSHostingView returned no AX children"
            } else {
                let button = elements.first { $0.accessibilityRole() == .button && $0.accessibilityLabel() == expectedHUDCancelLabel }
                XCTAssertNotNil(button, "Cancel must remain available to accessibility before hover as well as after it")
                let status = elements.first { $0.accessibilityLabel() == "Sotto dictation" }
                XCTAssertFalse((status?.accessibilityValue() as? String ?? "").isEmpty,
                               "The compact HUD must convey activity and safety detail without visible labels")
                accessibilityCheck = "verified cancel button and status value"
            }
        }
        let scale = 2
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        bitmap.size = size
        appearance.performAsCurrentDrawingAppearance {
            hosting.view.cacheDisplay(in: hosting.view.bounds, to: bitmap)
        }
        if expectedHUDCancelLabel != nil, colorScheme == .dark {
            // A glass compositor can produce a valid PNG of just its backing
            // store. Check actual foreground inside the pill, away from rims.
            var foregroundPixels = 0
            for y in stride(from: 25 * scale, to: bitmap.pixelsHigh - 25 * scale, by: 2) {
                for x in stride(from: 28 * scale, to: bitmap.pixelsWide - 28 * scale, by: 2) {
                    guard let pixel = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                    if pixel.alphaComponent > 0.8,
                       pixel.redComponent + pixel.greenComponent + pixel.blueComponent > 2.1 {
                        foregroundPixels += 1
                    }
                }
            }
            XCTAssertGreaterThan(foregroundPixels, 20, "Dark HUD foreground must remain visible through glass compositing")
        }
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(data.count, size.width < 250 ? 500 : 4_000,
                             "A blank backing store is not a valid view preview")
        try data.write(to: file, options: .atomic)
        return ["file": file.lastPathComponent, "width": size.width, "height": size.height,
                "pixelWidth": bitmap.pixelsWide, "pixelHeight": bitmap.pixelsHigh,
                "accessibilityCheck": accessibilityCheck]
    }
}

private enum PreviewState: String, CaseIterable {
    case ready, empty, setup, starting, recording, processing, delivering, success, failure

    @MainActor
    func apply(to controller: SottoController) {
        controller.activity = .idle
        controller.modelStatus = .installed
        controller.permissions = PermissionSnapshot(microphone: true, accessibility: true, inputMonitoring: true)
        controller.engineStatus = .unloaded
        controller.errorMessage = nil
        controller.lastTranscript = "Let's keep the first release focused on three things:\n\n1. Fast, local dictation\n2. A clear microphone indicator\n3. Reliable text insertion\n\nWe can review the details tomorrow."
        controller.lastAudioSeconds = 12.4
        controller.lastTranscriptionSeconds = 0.8
        controller.lastDelivery = "Inserted at your cursor"
        controller.statusMessage = "Ready when you are"
        controller.recordingFeedback.reset()
        switch self {
        case .ready: break
        case .empty:
            controller.lastTranscript = ""
            controller.lastAudioSeconds = nil
            controller.lastTranscriptionSeconds = nil
            controller.lastDelivery = ""
        case .setup:
            controller.modelStatus = .missing
            controller.permissions = PermissionSnapshot(microphone: false, accessibility: false, inputMonitoring: false)
        case .starting:
            controller.activity = .starting
            controller.statusMessage = "Starting microphone"
        case .recording:
            controller.activity = .recording
            controller.statusMessage = "Listening"
            controller.recordingFeedback.updateElapsed(8)
            [Float(0.15), 0.35, 0.7, 0.45, 0.95, 0.6, 0.3, 0.55, 0.2].forEach(controller.recordingFeedback.append)
        case .processing:
            controller.activity = .transcribing
            controller.engineStatus = .transcribing
            controller.statusMessage = "Turning speech into text…"
            controller.recordingFeedback.updateElapsed(8)
        case .delivering:
            controller.activity = .delivering
            controller.statusMessage = "Inserting your words"
            controller.recordingFeedback.updateElapsed(8)
        case .success:
            controller.activity = .success
            controller.statusMessage = "Inserted at your cursor"
            controller.recordingFeedback.updateElapsed(8)
        case .failure:
            controller.activity = .failed
            controller.statusMessage = "Microphone disconnected"
            controller.errorMessage = "The microphone was disconnected. Connect it again or choose another input."
        }
    }
}
