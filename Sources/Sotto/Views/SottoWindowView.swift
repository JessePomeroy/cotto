import SwiftUI

private enum SottoPage: String, CaseIterable, Identifiable {
    case dictation = "Dictation"
    case microphone = "Microphone"
    case dictionary = "Dictionary"
    case history = "History"
    case model = "Models"
    case preferences = "General"

    var id: Self { self }

    var symbol: String {
        switch self {
        case .dictation: return "waveform"
        case .microphone: return "mic"
        case .dictionary: return "character.book.closed"
        case .history: return "clock.arrow.circlepath"
        case .model: return "cpu"
        case .preferences: return "slider.horizontal.3"
        }
    }
}

struct SottoWindowView: View {
    @ObservedObject var controller: SottoController
    @State private var page: SottoPage? = .dictation

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 224, max: 260)
        } detail: {
            Group {
                switch page ?? .dictation {
                case .dictation:
                    DictationPage(controller: controller, showModel: { page = .model },
                                  showPreferences: { page = .preferences }, showHistory: { page = .history })
                case .microphone:
                    MicrophonePage(controller: controller)
                case .dictionary:
                    DictionaryPage(controller: controller)
                case .history:
                    HistoryPage(controller: controller)
                case .model:
                    ModelPage(controller: controller, showPreferences: { page = .preferences })
                case .preferences:
                    PreferencesPage(controller: controller)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(SottoPalette.canvas)
            .navigationTitle((page ?? .dictation).rawValue)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 820, minHeight: 580)
        .tint(SottoPalette.accent)
        .onExitCommand {
            if controller.isBusy && controller.canCancelWithEscape { controller.cancelDictation() }
        }
    }

    private var sidebar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 11) {
                SottoAppIcon(size: 40)
                Text("Sotto")
                    .font(.system(size: 27, weight: .regular, design: .serif))
                    .tracking(-0.8)
                    .foregroundStyle(SottoPalette.ink)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 17)
            .padding(.top, 18)
            .padding(.bottom, 18)

            List(SottoPage.allCases) { destination in
                Button { page = destination } label: {
                    HStack(spacing: 10) {
                        Image(systemName: destination.symbol)
                            .font(.system(size: 15, weight: .regular))
                            .foregroundStyle(page == destination ? SottoPalette.accentInk : SottoPalette.muted)
                            .frame(width: 20)
                            .accessibilityHidden(true)
                        Text(destination.rawValue)
                            .font(.system(size: 13, weight: page == destination ? .medium : .regular))
                            .foregroundStyle(page == destination ? SottoPalette.ink : SottoPalette.muted)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 36)
                    .background(page == destination ? SottoPalette.tint : .clear,
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowInsets(EdgeInsets(top: 2, leading: 3, bottom: 2, trailing: 3))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .accessibilityAddTraits(page == destination ? .isSelected : [])
                .accessibilityIdentifier("navigation.\(destination.id)")
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .onMoveCommand { direction in
                let pages = SottoPage.allCases
                let index = pages.firstIndex(of: page ?? .dictation) ?? 0
                if direction == .down { page = pages[min(index + 1, pages.count - 1)] }
                if direction == .up { page = pages[max(index - 1, 0)] }
            }
        }
        .navigationTitle("Sotto")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 7) {
                    if controller.isBusy && !controller.isRecording {
                        ProgressView().controlSize(.mini)
                            .frame(width: 12, height: 12)
                    } else {
                        StatusDot(color: sidebarStatusColor)
                    }
                    Text(modelStatusLabel)
                        .font(.caption)
                        .foregroundStyle(SottoPalette.ink)
                        .lineLimit(1)
                    if controller.isRecording {
                        Spacer(minLength: 0)
                        RecordingWaveform(feedback: controller.recordingFeedback, height: 18)
                        RecordingElapsedTime(feedback: controller.recordingFeedback)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(SottoPalette.muted)
                    }
                }
                .frame(height: 20)
                Label("Only on this Mac", systemImage: "lock")
                    .font(.caption)
                    .foregroundStyle(SottoPalette.muted)
                ConfigurationNotice(configuration: controller.configuration, showPreferences: { page = .preferences })
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        .background { SottoSidebarSurface() }
    }

    private var sidebarStatusColor: Color {
        if controller.isBusy { return SottoPalette.accent }
        if controller.activity == .failed { return SottoPalette.warning }
        if controller.modelStatus == .downloading || controller.modelStatus == .verifying { return SottoPalette.accent }
        if controller.modelStatus == .failed { return .orange }
        guard controller.isModelInstalled, controller.allPermissionsGranted,
              controller.isHotkeyActive, controller.microphones.resolution.device != nil else { return .secondary }
        switch controller.engineStatus {
        case .ready, .unloaded: return SottoPalette.success
        case .loading, .transcribing: return SottoPalette.accent
        case .failed: return .orange
        }
    }

    private var modelStatusLabel: String {
        switch controller.activity {
        case .starting: return "Starting microphone"
        case .recording: return "Listening"
        case .transcribing: return "Transcribing"
        case .delivering: return "Delivering"
        case .failed: return "Needs attention"
        default: break
        }
        switch controller.modelStatus {
        case .missing: return "Model not downloaded"
        case .downloading: return "Downloading model"
        case .verifying: return "Checking model"
        case .failed: return "Download needs attention"
        case .installed:
            if !controller.allPermissionsGranted { return "Finish setup" }
            if !controller.isHotkeyActive { return "Shortcut unavailable" }
            if controller.microphones.resolution.device == nil { return "No microphone" }
            if controller.engineStatus == .failed { return "Needs attention" }
            return controller.engineStatus == .loading ? "Loading model" : "Ready"
        }
    }
}

struct DictationPage: View {
    @ObservedObject var controller: SottoController
    var showModel: () -> Void
    var showPreferences: () -> Void
    var showHistory: () -> Void = {}

    var body: some View {
        ScrollView { content }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var needsSetup: Bool {
        !controller.isModelInstalled || !controller.allPermissionsGranted || !controller.isHotkeyActive
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 28) {
            shortcutSection

            if needsSetup {
                setupSection
            }

            transcriptSection

            Button(action: showHistory) {
                HStack(spacing: 7) {
                    Image(systemName: "clock.arrow.circlepath")
                    Text("View history")
                    Image(systemName: "arrow.right").font(.caption)
                }
                .font(.callout)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(SottoPalette.accentInk)
            .accessibilityIdentifier("dictation.history")
        }
        .padding(.horizontal, 28)
        .padding(.top, 30)
        .padding(.bottom, 24)
        .frame(maxWidth: 700, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var setupSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            if !controller.isModelInstalled { modelSetup }

            if !controller.allPermissionsGranted {
                permissionSetup
                    .disabled(controller.isBusy)
            } else if !controller.isHotkeyActive {
                HStack(spacing: 12) {
                    InlineNotice(message: "The hold key is disconnected.")
                    Spacer(minLength: 8)
                    Button("Reconnect") { controller.refreshPermissions() }
                        .buttonStyle(.bordered)
                        .disabled(controller.isBusy)
                }
            }
        }
    }

    private var shortcutSection: some View {
        VStack(spacing: 24) {
            HStack(alignment: .center, spacing: 20) {
                SottoPageHeading(title: "Hold to dictate.")
                Spacer(minLength: 12)
                Button(action: showPreferences) {
                    SottoHoldKeyCap(key: controller.shortcut, isPressed: controller.isCapturing)
                }
                .buttonStyle(.plain)
                .disabled(controller.isBusy)
                .help("Change the hold-to-talk key")
                .accessibilityLabel("Change shortcut: \(controller.shortcut.title)")
                .accessibilityIdentifier("dictation.shortcut")
            }

            SottoMicrophoneTestButton(controller: controller, identifier: "dictation.test")
                .frame(maxWidth: .infinity)
        }
    }

    private var modelSetup: some View {
        HStack(spacing: 13) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(SottoPalette.accentInk)

            VStack(alignment: .leading, spacing: 4) {
                Text(modelSetupTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(SottoPalette.ink)
                Text(modelSetupDetail)
                    .font(.system(size: 12))
                    .foregroundStyle(SottoPalette.muted)
            }

            Spacer(minLength: 8)
            Button("Set up model", action: showModel)
                .buttonStyle(SottoPrimaryButtonStyle(prominent: false))
        }
    }

    private var modelSetupTitle: String {
        switch controller.modelStatus {
        case .downloading: return "Downloading speech model"
        case .verifying: return "Checking speech model"
        case .failed: return "Download needs attention"
        case .missing, .installed: return "Download the speech model"
        }
    }

    private var modelSetupDetail: String {
        switch controller.modelStatus {
        case .downloading: return "\(Int(min(1, max(0, controller.downloadProgress)) * 100))% downloaded · then entirely offline"
        case .verifying: return "Making sure the download is complete."
        case .failed: return "Open model setup to see what happened."
        case .missing, .installed: return "Download once to dictate offline."
        }
    }

    private var permissionSetup: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Allow dictation")
                    .font(.headline)
                    .foregroundStyle(SottoPalette.ink)
                Spacer()
                Button { controller.refreshPermissions() } label: {
                    SottoControlIcon(systemName: "arrow.clockwise")
                }
                .buttonStyle(SottoQuietButtonStyle())
                .help("Check permissions again")
                .accessibilityLabel("Refresh permissions")
            }

            VStack(spacing: 7) {
                PermissionRow(title: "Microphone", detail: "To hear you while you dictate.", granted: controller.permissions.microphone, action: controller.requestMicrophone)
                PermissionRow(title: "Accessibility", detail: "To recognize your hold key and insert text.", granted: controller.permissions.accessibility, action: controller.requestAccessibility)
            }

            PermissionHelpButton()

            Text("macOS may ask you to quit and reopen Sotto after granting access.")
                .font(.system(size: 10))
                .foregroundStyle(SottoPalette.faint)
        }
    }

    private var transcriptSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(controller.isBusy ? "Current dictation" : "Last dictation")
                    .font(.headline)
                    .foregroundStyle(SottoPalette.ink)

                Spacer()

                Button { controller.clearLastTranscript() } label: {
                    SottoControlIcon(systemName: "trash")
                }
                .buttonStyle(SottoQuietButtonStyle())
                .foregroundStyle(.secondary)
                .disabled(controller.isBusy || controller.lastTranscript.isEmpty)
                .help("Clear the transcript and forget pending lists")
                .accessibilityLabel("Clear last dictation")

                Button { controller.copyLastTranscript() } label: {
                    SottoControlIcon(systemName: "doc.on.doc")
                }
                .buttonStyle(SottoQuietButtonStyle())
                .disabled(controller.isBusy || controller.lastTranscript.isEmpty)
                .help("Copy last dictation")
                .accessibilityLabel("Copy last dictation")
            }
            .frame(height: 24)

            SottoSettingsGroup {
                VStack(spacing: 0) {
                    ZStack(alignment: .topLeading) {
                        if controller.isBusy {
                            DictationProgressView(controller: controller)
                        } else if controller.lastTranscript.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Your next thought will appear here.")
                                    .font(.body)
                                    .foregroundStyle(SottoPalette.muted)
                            }
                            .padding(18)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        } else {
                            ScrollView {
                                Text(controller.lastTranscript)
                                    .font(.body)
                                    .lineSpacing(3)
                                    .foregroundStyle(SottoPalette.ink)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(16)
                            }
                        }
                    }
                    // Keep recording, empty, and completed takes in the same
                    // compact slot. Long text scrolls without moving controls.
                    .frame(height: 220)
                    Divider().padding(.horizontal, 16)
                    deliverySummary
                        .padding(.horizontal, 16)
                }
            }
            .accessibilityIdentifier("dictation.transcript")
        }
    }

    private var deliverySummary: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    if !deliveryMessage.isEmpty {
                        Image(systemName: deliverySymbol)
                            .foregroundStyle(deliveryColor)
                            .frame(width: 12)
                            .accessibilityHidden(true)
                    }
                    Text(deliveryMessage)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .help(deliveryMessage)
                .accessibilityIdentifier("dictation.delivery")
                if !controller.isBusy, !controller.lastTranscript.isEmpty,
                   let audio = controller.lastAudioSeconds, let transcription = controller.lastTranscriptionSeconds {
                    Text("\(audio, specifier: "%.1f") s audio · \(transcription, specifier: "%.1f") s processing")
                        .monospacedDigit()
                        .fixedSize()
                }
            }
            .frame(height: 36)
            HStack {
                HistorySaveNotice(history: controller.history, showPreferences: showPreferences)
                Spacer(minLength: 0)
            }
            .frame(height: 14)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.bottom, 6)
        .frame(height: 56, alignment: .topLeading)
    }

    private var deliveryMessage: String {
        guard !controller.isBusy else { return "" }
        if let error = controller.errorMessage, !error.isEmpty { return error }
        return controller.lastDelivery
    }

    private var deliverySymbol: String {
        if controller.errorMessage != nil { return "exclamationmark.circle" }
        switch controller.lastDeliveryStatus {
        case .none: return "info.circle"
        case .inserted: return "checkmark.circle"
        case .copied: return "doc.on.clipboard"
        case .tested: return "waveform"
        case .listUpdated: return "list.bullet"
        case .unconfirmed: return "questionmark.circle"
        case .failed: return "exclamationmark.circle"
        }
    }

    private var deliveryColor: Color {
        if controller.errorMessage != nil { return SottoPalette.warning }
        switch controller.lastDeliveryStatus {
        case .unconfirmed, .failed: return SottoPalette.warning
        default: return .secondary
        }
    }
}

struct SottoPageHeading: View {
    var title: String

    var body: some View {
        Text(title)
            .font(.system(size: 26, weight: .semibold))
            .tracking(-0.7)
            .foregroundStyle(SottoPalette.ink)
            .accessibilityAddTraits(.isHeader)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SottoMicrophoneTestButton: View {
    @ObservedObject var controller: SottoController
    var identifier: String

    private var inputName: String {
        controller.recordingInputName ?? controller.selectedInputName
    }

    private var isHeldFn: Bool {
        controller.isCapturing && !controller.canCancelWithEscape
    }

    var body: some View {
        Button { controller.toggleTestRecording() } label: {
            HStack(spacing: 8) {
                Image(systemName: isHeldFn ? "waveform" : (controller.isCapturing ? "stop.fill" : "mic"))
                    .font(.system(size: 13))
                    .foregroundStyle(SottoPalette.accentInk)
                Text(isHeldFn ? "Release fn to finish" : (controller.isCapturing ? "Finish dictation" : inputName))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 34)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .trailing) {
                Image(systemName: isHeldFn ? "arrow.up" : (controller.isCapturing ? "checkmark" : "play.fill"))
                    .font(.system(size: 10))
                    .padding(.trailing, 16)
                    .accessibilityHidden(true)
            }
            .frame(height: 44)
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(SottoMicrophoneButtonStyle())
        .disabled(isHeldFn || (!controller.canTest && !controller.isCapturing))
        .accessibilityLabel(isHeldFn ? "Release fn to finish" : (controller.isCapturing ? "Finish dictation with \(inputName)" : "Start test with \(inputName)"))
        .accessibilityHint(isHeldFn ? "Release fn to finish this recording, or use X to cancel"
                           : (controller.isCapturing ? "Finish this recording" : "Try dictation without pasting text"))
        .help(isHeldFn ? "Release fn to finish this recording, or use X to cancel"
              : (controller.isCapturing ? "Finish recording with \(inputName)" : "Test \(inputName) without pasting text"))
        .accessibilityIdentifier(identifier)
    }
}

private struct SottoMicrophoneButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(colorScheme == .dark ? SottoPalette.ink : SottoPalette.accentInk)
            .background {
                let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
                if colorScheme == .dark && contrast != .increased {
                    shape.fill(SottoPalette.surface)
                        .overlay {
                            shape.fill(LinearGradient(colors: [.white.opacity(0.025), .clear],
                                                      startPoint: .top, endPoint: .bottom))
                        }
                } else {
                    shape.fill(SottoPalette.tint)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(SottoPalette.line.opacity(configuration.isPressed ? 1 : 0.65), lineWidth: 1)
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
    }
}

private struct DictationProgressView: View {
    @ObservedObject var controller: SottoController

    var body: some View {
        HStack(spacing: 17) {
            Group {
                if controller.isRecording {
                    RecordingWaveform(feedback: controller.recordingFeedback, height: 36)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .frame(width: 51, height: 36)

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(SottoPalette.ink)

                Group {
                    if controller.isRecording {
                        HStack(spacing: 6) {
                            RecordingElapsedTime(feedback: controller.recordingFeedback)
                                .monospacedDigit()
                            if let hint = controller.recordingListHint {
                                Text("· \(hint)")
                            } else if controller.recordingUsesClipboard {
                                Text("· Clipboard")
                            }
                        }
                    } else {
                        Text(detail)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(height: 30, alignment: .topLeading)
            }
            Spacer(minLength: 8)
            Button { controller.cancelDictation() } label: {
                SottoControlIcon(systemName: "xmark")
            }
            .buttonStyle(SottoQuietButtonStyle())
            .accessibilityLabel("Cancel dictation")
            .help(controller.canCancelWithEscape ? "Cancel dictation (Escape)" : "Cancel dictation")
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var title: String {
        switch controller.activity {
        case .starting: return "Starting microphone…"
        case .recording: return "Listening"
        case .delivering: return "Delivering text…"
        default: return "Transcribing…"
        }
    }

    private var detail: String {
        switch controller.activity {
        case .starting: return "Speak when the microphone is ready."
        case .delivering: return "Checking the destination and delivery."
        default: return controller.engineStatus == .loading ? "Loading the local model…" : "Processing on this Mac."
        }
    }
}
