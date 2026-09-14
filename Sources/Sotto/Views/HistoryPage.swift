import AppKit
import SottoAPI
import SwiftUI

struct HistoryPage: View {
    @ObservedObject var controller: SottoController
    @State private var selectedID: UUID?
    @State private var deviceID = "all"
    @State private var confirmingDelete = false
    @State private var copiedID: UUID?

    private var devices: [DeviceIdentity] {
        var seen = Set<String>()
        return controller.generations.map(\.device).filter { seen.insert($0.id).inserted }.sorted { $0.name < $1.name }
    }
    private var filtered: [GenerationRecord] {
        controller.generations.filter { deviceID == "all" || $0.device.id == deviceID }
    }
    private var selected: GenerationRecord? {
        filtered.first { $0.id == selectedID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                SottoPageHeading(title: "History")
                Picker("Device", selection: $deviceID) {
                    Text("All devices").tag("all")
                    ForEach(devices, id: \.id) { device in Text(device.name).tag(device.id) }
                }
                .labelsHidden()
                .frame(width: 180)
                Button {
                    controller.errorMessage = nil
                    controller.refreshHistory()
                } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh shared history")
                    .accessibilityLabel("Refresh shared history")
            }
            VStack(spacing: 4) {
                ServerConnectionStatus(controller: controller)
                SottoActionMessage(message: controller.errorMessage)
            }

            HSplitView {
                historyList.frame(minWidth: 220, idealWidth: 255, maxWidth: 320)
                detail.frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .layoutPriority(1)

            HStack {
                Text("\(filtered.count) dictations\(controller.hasMoreHistory ? " loaded" : "")")
                    .font(.caption)
                    .foregroundStyle(SottoPalette.muted)
                Spacer()
                if controller.isLoadingHistory { ProgressView().controlSize(.mini) }
                Button("Load older") {
                    controller.errorMessage = nil
                    controller.loadMoreHistory()
                }
                .opacity(controller.hasMoreHistory ? 1 : 0)
                .disabled(!controller.hasMoreHistory || controller.isLoadingHistory)
            }
            .frame(height: 28)
        }
        .padding(26)
        .onAppear { controller.refreshHistory() }
        .confirmationDialog("Delete this dictation from the server?", isPresented: $confirmingDelete) {
            if let selected {
                Button("Delete dictation", role: .destructive) {
                    controller.errorMessage = nil
                    controller.deleteGeneration(selected.id)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its audio and transcript will be removed from every device’s history.")
        }
    }

    private var historyList: some View {
        List(selection: $selectedID) {
            ForEach(filtered) { generation in
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text(generation.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                            .font(.caption)
                        Spacer(minLength: 4)
                        if generation.status != .completed {
                            Image(systemName: generation.status == .failed ? "exclamationmark.circle" : "clock")
                                .foregroundStyle(SottoPalette.warning)
                        }
                    }
                    Text(generation.finalText.isEmpty ? statusLabel(generation.status) : generation.finalText)
                        .font(.callout)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, minHeight: 34, alignment: .topLeading)
                    Label(generation.device.name, systemImage: "laptopcomputer")
                        .font(.caption2)
                        .foregroundStyle(SottoPalette.muted)
                        .lineLimit(1)
                }
                .padding(.vertical, 8)
                .tag(generation.id)
                .accessibilityLabel("\(generation.device.name), \(generation.finalText.isEmpty ? statusLabel(generation.status) : generation.finalText)")
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .overlay {
            if filtered.isEmpty {
                ContentUnavailableView("No dictations", systemImage: "waveform",
                                       description: Text("Record while connected to add a dictation."))
            }
        }
        .accessibilityIdentifier("history.list")
    }

    @ViewBuilder private var detail: some View {
        if let selected {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(selected.createdAt, format: .dateTime.month(.wide).day().hour().minute()).font(.headline)
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        if NSPasteboard.general.setString(selected.finalText, forType: .string) { copiedID = selected.id }
                    } label: { Image(systemName: copiedID == selected.id ? "checkmark" : "doc.on.doc") }
                        .disabled(selected.finalText.isEmpty)
                        .help("Copy transcript")
                        .accessibilityLabel("Copy transcript")
                    Button { confirmingDelete = true } label: { Image(systemName: "trash") }
                        .disabled(!selected.status.isTerminal || controller.serverHealth == nil)
                        .help("Delete from server")
                        .accessibilityLabel("Delete dictation")
                }
                HStack(spacing: 12) {
                    Label(selected.device.name, systemImage: "laptopcomputer")
                    Text(statusLabel(selected.status))
                    if selected.audioSeconds > 0 { Text(sottoDuration(selected.audioSeconds)).monospacedDigit() }
                }
                .font(.caption)
                .foregroundStyle(SottoPalette.muted)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if let error = selected.error {
                            Text(error).foregroundStyle(SottoPalette.warning)
                        }
                        Text(selected.finalText.isEmpty ? "No transcript available." : selected.finalText)
                            .font(.body)
                            .lineSpacing(4)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if !selected.rawText.isEmpty && selected.rawText != selected.finalText {
                            DisclosureGroup("Original transcript") {
                                Text(selected.rawText)
                                    .font(.callout)
                                    .foregroundStyle(SottoPalette.muted)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.top, 8)
                            }
                        }
                        if let reason = selected.formattingRejectionReason {
                            Text(reason).font(.caption).foregroundStyle(SottoPalette.warning)
                        }
                        if let processing = selected.textProcessing {
                            if let reason = processing.reason {
                                Text(reason).font(.caption).foregroundStyle(SottoPalette.warning)
                            }
                            if processing.status == .rejected, let proposed = processing.proposedText {
                                DisclosureGroup("Rejected cleanup") {
                                    Text(proposed).font(.callout).textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                        if let hints = selected.recognitionHints, !hints.omittedTerms.isEmpty {
                            hintDetails("Voice vocabulary", hints: hints)
                        }
                        if let hints = selected.proofreadingHints, !hints.omittedTerms.isEmpty {
                            hintDetails("Cleanup vocabulary", hints: hints)
                        }
                    }
                }
                .frame(maxHeight: .infinity)
                Divider()
                HStack {
                    if selected.inferenceAudio != nil {
                        Button("Open audio") {
                            controller.errorMessage = nil
                            controller.openGenerationAudio(selected, kind: .inference)
                        }
                    }
                    if selected.originalAudio != nil {
                        Button("Open original") {
                            controller.errorMessage = nil
                            controller.openGenerationAudio(selected, kind: .original)
                        }
                    }
                    Spacer()
                }
                .frame(height: 28)
                .disabled(controller.serverHealth == nil)
                if let speech = selected.speech {
                    Text("\(speech.modelID) · \(speech.backend)")
                        .font(.caption2)
                        .foregroundStyle(SottoPalette.muted)
                        .lineLimit(1)
                }
            }
            .padding(.leading, 20)
            .padding(.top, 8)
            .accessibilityIdentifier("history.detail")
        } else {
            ContentUnavailableView("Select a dictation", systemImage: "text.alignleft")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func statusLabel(_ status: GenerationStatus) -> String {
        switch status {
        case .receiving: "Recording"
        case .queued: "Queued"
        case .transcribing: "Transcribing"
        case .proofreading: "Proofreading"
        case .completed: "Completed"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }

    private func hintDetails(_ title: String, hints: ModelHintUsage) -> some View {
        DisclosureGroup("\(title): \(hints.omittedTerms.count) terms did not fit") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Used: \(hints.includedTerms.isEmpty ? "None" : hints.includedTerms.joined(separator: ", "))")
                Text("Did not fit: \(hints.omittedTerms.joined(separator: ", "))")
            }
            .font(.caption)
            .foregroundStyle(SottoPalette.muted)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
