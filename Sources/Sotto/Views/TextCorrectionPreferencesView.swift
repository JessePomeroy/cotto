import SwiftUI

struct TextCorrectionSection: View {
    @ObservedObject var service: TextCorrectionService
    var isBusy: Bool
    @State private var confirmingRemoval = false

    var body: some View {
        Section {
            Toggle(isOn: $service.enabled) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Polish your dictation")
                    Text("Punctuation, formatting, and harder words.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .disabled(isBusy)
            .accessibilityLabel("Local text correction")
            .accessibilityIdentifier("correction.enabled")

            LabeledContent("Local model", value: service.modelName)
            LabeledContent("Model size", value: service.modelSizeLabel)
            LabeledContent("Status", value: status)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Text correction model status")
                .accessibilityValue(status)
                .accessibilityIdentifier("correction.status")

            ModelActionRow(title: service.modelStatus == .installed && !hasError ? "Memory" : detail,
                           help: detail, hasError: hasError,
                           progress: service.modelStatus == .downloading ? service.progress : nil,
                           isVerifying: service.modelStatus == .verifying) {
                controls
            }
            .accessibilityIdentifier("correction.installation")

            LabeledContent("Last correction") {
                Text(service.lastOutcome ?? "None yet")
                    .foregroundStyle(.secondary)
                    .lineLimit(2, reservesSpace: true)
                    .frame(maxWidth: 300, minHeight: 34, maxHeight: 34, alignment: .trailing)
                    .help(service.lastOutcome ?? "No transcription has been corrected yet.")
            }
            .accessibilityIdentifier("correction.outcome")
        } header: {
            Text("Text correction").textCase(nil)
        } footer: {
            Text("Optional. Speech recognition and your dictionary also work without this model.")
        }
        .listRowBackground(SottoPalette.surface)
        .alert("Remove the text correction model?", isPresented: $confirmingRemoval) {
            Button("Keep model", role: .cancel) {}
            Button("Remove model", role: .destructive) { service.remove() }
        } message: {
            Text("This frees \(service.modelSizeLabel) of storage. Speech recognition and your dictionary are unchanged.")
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch service.modelStatus {
        case .missing, .failed:
            Button(service.modelStatus == .failed ? "Retry download" : "Download model") {
                service.download()
            }
            .buttonStyle(.bordered)
            .disabled(isBusy)
            .accessibilityIdentifier("correction.download")
        case .downloading:
            Button("Cancel") { service.cancelDownload() }
                .buttonStyle(.bordered)
                .disabled(isBusy)
                .accessibilityLabel("Cancel text correction download")
        case .verifying:
            Text("Checking integrity")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .installed:
            HStack(spacing: 10) {
                Button {
                    if service.engineStatus == .ready { service.unload() }
                    else { service.load() }
                } label: {
                    Text(memoryAction)
                        .frame(width: 150, alignment: .center)
                }
                .buttonStyle(.bordered)
                .disabled(isBusy || isWorking)
                .accessibilityIdentifier("correction.memory")

                Button(role: .destructive) { confirmingRemoval = true } label: {
                    SottoControlIcon(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .disabled(isBusy || isWorking)
                .help("Remove the text correction model…")
                .accessibilityLabel("Remove text correction model")
                .accessibilityIdentifier("correction.remove")
            }
        }
    }

    private var isWorking: Bool {
        service.engineStatus == .loading || service.engineStatus == .transcribing
    }

    private var hasError: Bool {
        service.modelStatus == .failed || service.engineStatus == .failed
    }

    private var status: String {
        switch service.modelStatus {
        case .missing: return "Not downloaded"
        case .failed: return "Download interrupted"
        case .downloading: return "Downloading · \(Int(min(1, max(0, service.progress)) * 100))%"
        case .verifying: return "Verifying download…"
        case .installed:
            switch service.engineStatus {
            case .unloaded: return "Installed · not loaded"
            case .loading: return "Loading…"
            case .ready: return "Loaded"
            case .transcribing: return "Correcting text…"
            case .failed: return "Load failed"
            }
        }
    }

    private var memoryAction: String {
        switch service.engineStatus {
        case .unloaded: return "Load into memory"
        case .loading: return "Loading…"
        case .ready: return "Unload from memory"
        case .transcribing: return "Correcting…"
        case .failed: return "Retry loading"
        }
    }

    private var detail: String {
        if service.modelStatus == .downloading {
            return "\(ByteCountFormatter.string(fromByteCount: service.downloadedBytes, countStyle: .file)) of \(service.modelSizeLabel)"
        }
        if !service.message.isEmpty { return service.message }
        return service.modelStatus == .installed ? "Available for local text correction." : "Download once to use local text correction."
    }
}
