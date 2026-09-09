import SwiftUI

struct ModelPage: View {
    @ObservedObject var controller: SottoController
    var showPreferences: () -> Void
    @State private var confirmingRemoval = false

    var body: some View {
        Form {
            Section {
                SottoPageHeading(title: "Models")
                    .padding(.vertical, 8)
            }
            .listRowBackground(Color.clear)

            Section {
                LabeledContent {
                    Text(installationTitle).foregroundStyle(SottoPalette.muted)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Whisper large-v3-turbo")
                            .fontWeight(.medium)
                        Text("Turns your voice into text.")
                            .font(.caption)
                            .foregroundStyle(SottoPalette.muted)
                    }
                }
                LabeledContent("Model size", value: controller.modelSizeLabel)
                installationSection
                LabeledContent("Status", value: memoryTitle)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Model status")
                    .accessibilityValue(memoryTitle)
                    .accessibilityIdentifier("model.status")
                ModelActionRow(title: controller.engineStatus == .failed ? memoryDescription : "Memory",
                               help: memoryDescription, hasError: controller.engineStatus == .failed) {
                    memoryControl
                }

                LabeledContent("Unload when idle") {
                    HStack(spacing: 10) {
                        Text(idleDescription)
                            .foregroundStyle(.secondary)
                        Button(action: showPreferences) {
                            SottoControlIcon(systemName: "info.circle")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Memory settings")
                        .help("Change when the model unloads")
                    }
                }
                DisclosureGroup("Model details") {
                    LabeledContent("Precision", value: "Original F16 weights")
                    LabeledContent("Acceleration", value: "Apple GPU · Metal")
                }
            } header: {
                Text("Speech recognition").textCase(nil)
            }
            .listRowBackground(SottoPalette.surface)

            TextCorrectionSection(service: controller.textCorrection, isBusy: controller.isBusy)
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .controlSize(.regular)
        .foregroundStyle(SottoPalette.ink)
        .frame(maxWidth: 700)
        .frame(maxWidth: .infinity)
        .alert("Remove the local model?", isPresented: $confirmingRemoval) {
            Button("Keep model", role: .cancel) {}
            Button("Remove model", role: .destructive) { controller.removeModel() }
        } message: {
            Text("This frees \(controller.modelSizeLabel) of storage. You'll need to download the model again before dictating. Your preferences stay as they are.")
        }
    }

    private var installationSection: some View {
        ModelActionRow(title: controller.modelStatus == .installed ? "Model file" : installationDetail,
                       help: installationDetail, hasError: controller.modelError != nil,
                       progress: controller.modelStatus == .downloading ? controller.downloadProgress : nil,
                       isVerifying: controller.modelStatus == .verifying) {
            installationControls
        }
        .accessibilityIdentifier("model.installation")
    }

    @ViewBuilder
    private var installationControls: some View {
        switch controller.modelStatus {
        case .downloading:
            Button("Cancel") { controller.cancelDownload() }
                .buttonStyle(.bordered)
                .accessibilityLabel("Cancel model download")
        case .verifying:
            Text("Checking integrity")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .installed:
            HStack(spacing: 12) {
                Button("Show in Finder") { controller.revealModel() }
                    .buttonStyle(.bordered)
                Button(role: .destructive) { confirmingRemoval = true } label: {
                    SottoControlIcon(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .disabled(controller.isBusy || controller.engineStatus == .loading)
                .accessibilityLabel("Remove downloaded model")
                .help("Remove downloaded model…")
            }
        case .missing, .failed:
            Button(controller.modelStatus == .failed ? "Retry download" : "Download model") {
                controller.downloadModel()
            }
            .buttonStyle(.borderedProminent)
            .disabled(controller.isBusy)
            .accessibilityIdentifier("model.download")
        }
    }

    private var installationTitle: String {
        switch controller.modelStatus {
        case .downloading: return "Downloading…"
        case .verifying: return "Verifying download…"
        case .installed: return "Installed"
        case .missing: return "Not downloaded"
        case .failed: return "Download interrupted"
        }
    }

    private var installationDetail: String {
        if let error = controller.modelError, !error.isEmpty { return error }
        switch controller.modelStatus {
        case .downloading:
            return "\(ByteCountFormatter.string(fromByteCount: controller.downloadedBytes, countStyle: .file)) of \(controller.modelSizeLabel)"
        case .verifying: return "Checking the complete model before using it."
        case .installed: return "Available for offline dictation."
        case .missing: return "Download once from Hugging Face to dictate offline."
        case .failed: return "The download did not finish. You can try again."
        }
    }

    private var memoryControl: some View {
        Button {
            if controller.engineStatus == .ready { controller.unloadModel() }
            else { controller.warmModel() }
        } label: {
            Text(memoryActionTitle)
                .frame(width: 150)
                .overlay(alignment: .leading) {
                    if controller.engineStatus == .loading {
                        ProgressView()
                            .controlSize(.mini)
                            .frame(width: 14, height: 14)
                            .accessibilityHidden(true)
                    }
                }
        }
        .buttonStyle(.bordered)
        .disabled(!controller.isModelInstalled || controller.isBusy || controller.engineStatus == .loading)
        .accessibilityIdentifier("model.memory")
    }

    private var memoryActionTitle: String {
        switch controller.engineStatus {
        case .ready, .transcribing: return "Unload from memory"
        case .loading: return "Loading model…"
        case .failed: return "Retry loading"
        case .unloaded: return "Load into memory"
        }
    }

    private var memoryTitle: String {
        switch controller.engineStatus {
        case .unloaded: return "Not loaded"
        case .loading: return "Loading…"
        case .ready: return "Loaded"
        case .transcribing: return "In use"
        case .failed: return "Load failed"
        }
    }

    private var memoryDescription: String {
        if controller.engineStatus == .failed || controller.engineStatus == .loading {
            return controller.engineMessage
        }
        if controller.engineStatus == .unloaded { return "Loads automatically for your next dictation." }
        if controller.engineStatus == .transcribing { return "Processing the current recording." }
        return "Ready for your next dictation."
    }

    private var idleDescription: String {
        switch controller.idleMinutes {
        case 0: return "After each dictation"
        case -1: return "When Sotto quits"
        default: return "After \(controller.idleMinutes) minutes"
        }
    }
}

struct PreferencesPage: View {
    @ObservedObject var controller: SottoController
    @State private var showingShortcutDiagnostics = false

    private let languages = [
        ("English", "en"), ("Detect automatically", "auto"),
        ("Spanish", "es"), ("French", "fr"), ("German", "de"),
        ("Italian", "it"), ("Portuguese", "pt"), ("Dutch", "nl"),
        ("Japanese", "ja"), ("Chinese", "zh"), ("Korean", "ko"),
        ("Hindi", "hi"), ("Arabic", "ar"), ("Polish", "pl"),
        ("Russian", "ru"), ("Ukrainian", "uk"), ("Swedish", "sv")
    ]

    var body: some View {
        Form {
            Section {
                SottoPageHeading(title: "General")
                    .padding(.vertical, 8)
            }
            .listRowBackground(Color.clear)

            Section {
                Picker("Hold to dictate", selection: $controller.shortcut) {
                    ForEach(HoldKey.allCases) { key in
                        Text(key == .fn ? key.title : "\(key.symbol)  \(key.title)").tag(key)
                    }
                }
                .help("Hold to record. Release to transcribe.")
                .accessibilityIdentifier("preferences.shortcut")

                LabeledContent {
                    shortcutCheckButton
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Shortcut check")
                        Text(shortcutInstruction)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2, reservesSpace: true)
                            .frame(height: 30, alignment: .topLeading)
                            .help(shortcutInstruction)
                    }
                }

                if !controller.shortcutCheckText.isEmpty {
                    DisclosureGroup("Diagnostic details", isExpanded: $showingShortcutDiagnostics) {
                        shortcutDiagnostics
                            .padding(.top, 8)
                    }
                }
            } header: {
                Text("Shortcut").textCase(nil)
            }
            .disabled(controller.isBusy)
            .listRowBackground(SottoPalette.surface)

            Section {
                Picker("Language", selection: $controller.language) {
                    ForEach(languages, id: \.1) { label, code in
                        Text(label).tag(code)
                    }
                }
                .help("Choosing a language can improve accuracy.")
                .accessibilityIdentifier("preferences.language")

                Toggle(isOn: $controller.cleanText) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Light cleanup")
                        Text("Remove fillers such as “um” and “uh”.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .help("Remove ‘um’ and ‘uh’ before words. No rewriting.")
                .accessibilityLabel("Light cleanup")
            } header: {
                Text("Dictation")
                    .textCase(nil)
            }
            .disabled(controller.isBusy)
            .listRowBackground(SottoPalette.surface)

            Section {
                Picker("Keep model in memory", selection: $controller.idleMinutes) {
                    Text("After each dictation").tag(0)
                    Text("5 minutes idle").tag(5)
                    Text("15 minutes idle").tag(15)
                    Text("Until Sotto quits").tag(-1)
                }
                .help("A warm model starts your next dictation faster.")

                Toggle(isOn: $controller.launchAtLogin) {
                    HStack(spacing: 6) {
                        Text("Start Sotto at login")
                        if let error = controller.loginItemError {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                                .help(error)
                        }
                    }
                }
                .help(controller.loginItemError ?? "Start quietly in the menu bar.")
                .accessibilityLabel("Start Sotto at login")
                .accessibilityHint(controller.loginItemError ?? "Start quietly in the menu bar.")
            } header: {
                Text("Startup and memory")
                    .textCase(nil)
            }
            .disabled(controller.isBusy)
            .listRowBackground(SottoPalette.surface)

            HistoryPreferencesSection(history: controller.history)
                .disabled(controller.isBusy)
                .listRowBackground(SottoPalette.surface)

            ConfigurationPreferencesSection(configuration: controller.configuration)
                .listRowBackground(SottoPalette.surface)

            Section {
                PermissionRow(title: "Microphone", detail: "Only used while recording.", granted: controller.permissions.microphone, reviewGranted: true, action: controller.requestMicrophone)
                PermissionRow(title: "Accessibility", detail: "Recognize your hold key and insert text.", granted: controller.permissions.accessibility, reviewGranted: true, action: controller.requestAccessibility)
                HStack {
                    PermissionHelpButton()
                    Spacer()
                    Button("Check again") { controller.refreshPermissions() }
                        .buttonStyle(.bordered)
                }
            } header: {
                Text("Permissions")
                    .textCase(nil)
            }
            .disabled(controller.isBusy)
            .listRowBackground(SottoPalette.surface)

            if let error = controller.errorMessage, !error.isEmpty {
                Section {
                    InlineNotice(message: error, isError: true)
                }
            }

            Section {
                VStack(spacing: 7) {
                    Text("Sotto")
                        .font(.system(size: 26, weight: .regular, design: .serif))
                        .tracking(-0.7)
                        .foregroundStyle(SottoPalette.ink)
                    Text("Thought, softly spoken.")
                        .font(.caption)
                        .foregroundStyle(SottoPalette.muted)
                    Label("Private and on-device", systemImage: "lock")
                        .font(.caption2)
                        .foregroundStyle(SottoPalette.muted)
                        .padding(.top, 5)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .listRowBackground(Color.clear)
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .toggleStyle(.switch)
        .controlSize(.regular)
        .foregroundStyle(SottoPalette.ink)
        .frame(maxWidth: 700)
        .frame(maxWidth: .infinity)
        .onChange(of: controller.isCheckingShortcut, initial: true) { _, checking in
            if checking { showingShortcutDiagnostics = true }
        }
    }

    private var shortcutCheckButton: some View {
        Button {
            if controller.isCheckingShortcut {
                controller.stopShortcutCheck()
            } else {
                controller.startShortcutCheck()
            }
        } label: {
            Text(controller.isCheckingShortcut ? "Stop checking" : "Check shortcut")
                .frame(width: 104)
        }
        .buttonStyle(.bordered)
        .disabled(controller.isBusy)
        .accessibilityIdentifier("shortcut.check")
    }

    private var shortcutInstruction: String {
        if controller.isCheckingShortcut {
            return "Hold \(controller.shortcut.title) for a second. No audio is recorded."
        }
        return controller.shortcut.note ?? "Hold to dictate. Release to transcribe."
    }

    private var shortcutDiagnostics: some View {
        ScrollView(.vertical) {
            Text(controller.shortcutCheckText)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("shortcut.diagnostics")
        }
        .frame(height: 108)
    }

}
