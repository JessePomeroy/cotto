import SwiftUI

struct SottoMenuView: View {
    static let width: CGFloat = 300

    @ObservedObject var controller: SottoController
    var openWindow: () -> Void
    var quit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            statusLine
                .padding(.horizontal, 4)
                .padding(.bottom, 4)

            guidance
                .frame(maxWidth: .infinity, minHeight: 44, maxHeight: 44, alignment: .leading)
                .padding(.horizontal, 4)
                .padding(.bottom, 12)

            menuAction
                .frame(height: 40)

            transcriptPreview
                .padding(.top, 14)
                .padding(.bottom, 9)

            menuRow("Open Sotto…", symbol: "sidebar.left", shortcut: ",", action: openWindow)

            SottoRule()
                .padding(.vertical, 5)

            menuRow("Quit Sotto", symbol: "power", shortcut: "q", action: quit)
        }
        .padding(.horizontal, 16)
        .padding(.top, 15)
        .padding(.bottom, 9)
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
        .tint(SottoPalette.accentInk)
        .background { SottoMenuSurface().allowsHitTesting(false) }
    }

    @ViewBuilder
    private var guidance: some View {
        // Status guidance shares the prompt's space rather than reserving an
        // empty subtitle. Warnings stay visible without resizing the popover.
        if menuDetail.isEmpty {
            HStack(spacing: 7) {
                Text("Hold")
                Text(controller.shortcut.symbol)
                    .font(.system(size: 15))
                    .padding(.horizontal, 6)
                    .frame(height: 25)
                    .background(SottoPalette.surface, in: RoundedRectangle(cornerRadius: 5))
                    .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(SottoPalette.line, lineWidth: 0.5) }
                Text("to dictate.")
            }
            .font(.system(size: 20, weight: .medium))
            .tracking(-0.45)
            .foregroundStyle(SottoPalette.ink)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Hold \(controller.shortcut.title) to dictate")
            .help("Hold \(controller.shortcut.title), then release to insert your words")
        } else {
            Text(menuDetail)
                .font(.system(size: 11))
                .foregroundStyle(controller.activity == .failed || needsDeliveryReview
                                 ? SottoPalette.warning : SottoPalette.muted)
                .lineLimit(2)
                .help(menuDetail)
        }
    }

    private var statusLine: some View {
        HStack(spacing: 7) {
            statusIndicator
                .frame(width: 16, height: 20)
            Text(menuStatusLabel)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 0)
            if controller.isRecording {
                RecordingWaveform(feedback: controller.recordingFeedback, height: 20)
                RecordingElapsedTime(feedback: controller.recordingFeedback)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(height: 24)
        .help(menuDetail)
        .accessibilityHint(menuDetail)
    }

    @ViewBuilder
    private var statusIndicator: some View {
        if controller.isRecording {
            Image(systemName: "mic.fill")
                .foregroundStyle(SottoPalette.accentInk)
        } else if controller.isBusy || controller.modelStatus == .downloading ||
            controller.modelStatus == .verifying || controller.engineStatus == .loading {
            ProgressView().controlSize(.mini)
        } else {
            StatusDot(color: menuStatusColor)
        }
    }

    private var transcriptPreview: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(controller.lastTranscript.isEmpty ? "No dictation yet." : controller.lastTranscript)
                .font(.system(size: 12))
                .lineSpacing(2)
                .foregroundStyle(controller.lastTranscript.isEmpty ? .secondary : .primary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, minHeight: 50, maxHeight: 50, alignment: .topLeading)

            Button { controller.copyLastTranscript() } label: {
                SottoControlIcon(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .disabled(controller.lastTranscript.isEmpty || controller.isBusy)
            .accessibilityLabel("Copy last dictation")
            .help("Copy last dictation")
        }
        .padding(11)
        .background(SottoPalette.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(SottoPalette.line, lineWidth: 0.5) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Last dictation")
    }

    @ViewBuilder
    private var menuAction: some View {
        if controller.isCapturing || controller.canTest {
            microphoneTestButton
        } else if controller.isBusy {
            menuRow("Cancel dictation", symbol: "xmark", action: controller.cancelDictation)
        } else if controller.isModelInstalled && controller.permissions.microphone {
            microphoneTestButton
                .disabled(true)
        } else {
            menuRow("Finish setup", symbol: "arrow.right", action: openWindow)
        }
    }

    private var microphoneTestButton: some View {
        let inputName = controller.recordingInputName ?? controller.selectedInputName
        let isHeldFn = controller.isCapturing && !controller.canCancelWithEscape
        return Button(action: controller.toggleTestRecording) {
            MicrophoneTestLabel(inputName: inputName, isCapturing: controller.isCapturing, isHeldFn: isHeldFn)
                .font(.system(size: 12))
                .padding(.horizontal, 11)
                .frame(height: 40)
                .background(SottoPalette.surface, in: RoundedRectangle(cornerRadius: 9))
                .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(SottoPalette.line, lineWidth: 0.5) }
                .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .tint(SottoPalette.ink)
        .disabled(isHeldFn)
        .accessibilityLabel(isHeldFn ? "Release fn to finish" : (controller.isCapturing ? "Finish dictation with \(inputName)" : "Start test with \(inputName)"))
        .accessibilityHint(isHeldFn ? "Release fn to finish this recording, or use X to cancel"
                           : (controller.isCapturing ? "Finish this recording" : "Try dictation without pasting text"))
        .help(isHeldFn ? "Release fn to finish this recording, or use X to cancel"
              : (controller.isCapturing ? "Finish recording with \(inputName)" : "Test \(inputName) without pasting text"))
        .accessibilityIdentifier("menu.test")
    }

    @ViewBuilder
    private func menuRow(_ title: String, symbol: String, shortcut: KeyEquivalent? = nil,
                         action: @escaping () -> Void) -> some View {
        let row = Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 12))
                    .frame(width: 16)
                    .foregroundStyle(.secondary)
                Text(title)
                    .lineLimit(1)
                Spacer()
                if let shortcut {
                    Text(shortcut == "q" ? "⌘Q" : "⌘,")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(.primary)
            .padding(.horizontal, 6)
            .frame(height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .tint(SottoPalette.ink)
        if let shortcut { row.keyboardShortcut(shortcut, modifiers: .command) }
        else { row }
    }

    private var menuStatusColor: Color {
        if controller.isBusy { return SottoPalette.accent }
        if needsDeliveryReview { return SottoPalette.warning }
        if controller.engineStatus == .failed || controller.activity == .failed || controller.modelStatus == .failed {
            return SottoPalette.warning
        }
        return controller.canTest && controller.allPermissionsGranted && controller.isHotkeyActive
            ? SottoPalette.success : SottoPalette.faint
    }

    private var menuStatusLabel: String {
        if controller.isBusy {
            switch controller.activity {
            case .starting: return "Starting microphone"
            case .recording: return "Listening"
            case .transcribing: return controller.engineStatus == .loading ? "Loading the model" : "Transcribing"
            case .delivering: return "Delivering your words"
            default: break
            }
        }
        if needsDeliveryReview { return "Check insertion" }
        if controller.activity == .success { return controller.statusMessage }
        if controller.activity == .failed { return "Couldn't finish dictation" }
        switch controller.modelStatus {
        case .missing: return "Model not downloaded"
        case .downloading: return "Downloading model"
        case .verifying: return "Checking model"
        case .failed: return "Download needs attention"
        case .installed:
            if !controller.permissions.microphone { return "Microphone access needed" }
            if !controller.allPermissionsGranted { return "Finish shortcut setup" }
            if !controller.isHotkeyActive { return "Shortcut unavailable" }
            if controller.microphones.resolution.device == nil { return "No microphone connected" }
            if controller.engineStatus == .loading || controller.engineStatus == .failed { return controller.engineStatusLabel }
            return "Ready"
        }
    }

    private var menuDetail: String {
        if needsDeliveryReview { return "Insertion unconfirmed. Check the destination before pasting again." }
        switch controller.activity {
        case .starting: return "Opening your selected microphone."
        case .recording:
            let cancellation = controller.canCancelWithEscape ? "Esc to cancel" : "Release fn to finish · X to cancel"
            if controller.recordingUsesClipboard { return "To clipboard · " + cancellation }
            if let hint = controller.recordingListHint { return hint }
            return controller.isHotkeyActive ? cancellation + " · 3 min max" : "3 min maximum"
        case .transcribing: return "Turning your recording into text on this Mac."
        case .delivering: return controller.statusMessage
        case .success: return controller.lastDelivery
        case .failed: return controller.errorMessage ?? controller.lastDelivery
        case .idle: break
        }
        switch controller.modelStatus {
        case .missing: return "Download your voice model to get started."
        case .downloading: return "\(Int(min(1, max(0, controller.downloadProgress)) * 100))% downloaded · then entirely offline."
        case .verifying: return "Making sure every byte is where it belongs."
        case .failed: return "Open model setup to retry the download."
        case .installed:
            if !controller.permissions.microphone { return "Allow the microphone to try dictation." }
            if !controller.allPermissionsGranted { return "Finish permissions to use the global shortcut." }
            if !controller.isHotkeyActive { return "Open Sotto to check the global shortcut." }
            if controller.microphones.resolution.device == nil { return "Connect a microphone or choose another input." }
            if controller.engineStatus == .failed { return controller.engineMessage }
            return ""
        }
    }

    private var needsDeliveryReview: Bool {
        !controller.isBusy && controller.lastDeliveryStatus == .unconfirmed
    }
}

/// A compact status instrument. Only the two feedback leaves observe meter and
/// elapsed-time changes; the parent redraws for activity transitions and hover.
struct DictationHUD: View {
    static let width: CGFloat = 200
    static let height: CGFloat = 46

    @ObservedObject var controller: SottoController
    /// Deterministic native previews can reveal the cancel affordance without
    /// runtime flags or a synthetic mouse event.
    var previewHover = false
    @State private var isHovered = false
    @FocusState private var cancelHasFocus: Bool
    @AccessibilityFocusState private var cancelHasAccessibilityFocus: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 11) {
            SottoMark(color: SottoPalette.ink, size: 22)
                .frame(width: 36, height: 28)

            indicator
                .frame(width: 68, height: 28)
                .accessibilityHidden(true)

            ZStack {
                RecordingElapsedTime(feedback: controller.recordingFeedback)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(SottoPalette.muted)
                    .opacity(showsCancel ? 0 : 1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)

                // Keep the button itself present and accessible. Only the ink
                // fades, so keyboard and VoiceOver can find it before hover.
                Button(action: dismissOrCancel) {
                    ZStack {
                        Color.clear
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(SottoPalette.muted)
                            .opacity(showsCancel ? 1 : 0)
                    }
                    .frame(width: 36, height: 30)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focused($cancelHasFocus)
                .accessibilityFocused($cancelHasAccessibilityFocus)
                .accessibilityLabel(cancelLabel)
                .accessibilityHint(controller.isBusy ? "Cancels this dictation without inserting text" : "Closes this status")
                .accessibilityIdentifier("hud.cancel")
                .help(controller.isBusy
                      ? (controller.canCancelWithEscape ? "Cancel dictation (Escape)" : "Cancel dictation")
                      : "Dismiss status")
            }
            .frame(width: 36, height: 30)
        }
        .padding(.horizontal, 19)
        .frame(width: Self.width, height: Self.height)
        .modifier(SottoFloatingSurface(cornerRadius: Self.height / 2))
        .contentShape(Capsule())
        .onHover { isHovered = $0 }
        .onExitCommand {
            if controller.canCancelWithEscape { dismissOrCancel() }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.14), value: showsCancel)
        .tint(SottoPalette.accent)
        .help(statusDescription)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sotto dictation")
        .accessibilityValue(statusDescription)
        .accessibilityIdentifier("hud.status")
    }

    private var showsCancel: Bool {
        previewHover || isHovered || cancelHasFocus || cancelHasAccessibilityFocus
    }

    private var cancelLabel: String {
        controller.isBusy ? "Cancel dictation" : "Dismiss dictation status"
    }

    private func dismissOrCancel() {
        if controller.isBusy { controller.cancelDictation() }
        else { controller.dismissFeedback() }
    }

    @ViewBuilder
    private var indicator: some View {
        switch controller.activity {
        case .recording:
            RecordingWaveform(feedback: controller.recordingFeedback, color: SottoPalette.accent, height: 24)
        case .starting, .transcribing, .delivering:
            ProgressView()
                .controlSize(.small)
                .tint(SottoPalette.accentInk)
        case .success:
            Image(systemName: resultSymbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(needsDeliveryReview ? SottoPalette.warning : SottoPalette.accentInk)
        case .failed:
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(SottoPalette.warning)
        case .idle:
            LiveWaveform(levels: [], color: SottoPalette.muted, height: 24)
        }
    }

    private var title: String {
        switch controller.activity {
        case .starting: return "Starting microphone"
        case .recording: return "Listening"
        case .transcribing: return controller.engineStatus == .loading ? "Loading the model" : "Transcribing"
        case .delivering: return controller.statusMessage
        case .success: return needsDeliveryReview ? "Check insertion" : controller.statusMessage
        case .failed: return controller.errorMessage == nil ? "Ready to copy" : "Couldn't finish"
        case .idle: return "Ready"
        }
    }

    private var detail: String {
        if needsDeliveryReview { return "Insertion unconfirmed. Check the destination before pasting again." }
        switch controller.activity {
        case .starting: return controller.recordingInputName ?? "Opening your selected microphone"
        case .recording:
            let cancellation = !controller.canCancelWithEscape ? "Release fn to finish · X to cancel"
                : (controller.isHotkeyActive ? "Esc to cancel" : "Hover to cancel")
            if controller.recordingUsesClipboard { return "To clipboard · " + cancellation }
            if let hint = controller.recordingListHint { return hint + " · " + cancellation }
            if let microphone = controller.recordingInputName { return microphone + " · " + cancellation }
            return cancellation + " · 3 min max"
        case .transcribing, .delivering:
            return controller.isHotkeyActive ? "Esc to cancel" : "Hover to cancel"
        case .success: return controller.lastDelivery
        case .failed: return controller.errorMessage ?? controller.lastDelivery
        case .idle: return "Hold \(controller.shortcut.title) to speak"
        }
    }

    private var statusDescription: String {
        detail.isEmpty ? title : "\(title). \(detail)"
    }

    private var needsDeliveryReview: Bool {
        !controller.isBusy && controller.lastDeliveryStatus == .unconfirmed
    }

    private var resultSymbol: String {
        switch controller.lastDeliveryStatus {
        case .copied: return "doc.on.clipboard"
        case .tested: return "text.alignleft"
        case .listUpdated: return "list.bullet"
        case .unconfirmed: return "questionmark.circle"
        case .failed: return "exclamationmark.circle"
        case .inserted, .none: return "checkmark"
        }
    }
}
