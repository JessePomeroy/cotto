import AppKit
import SottoCore
import SwiftUI

@MainActor
final class HistoryBrowser: ObservableObject {
    @Published private(set) var entries: [DictationHistoryEntry] = []
    @Published private(set) var isLoading = false
    @Published private(set) var hasMore = false
    @Published private(set) var message: String?
    private let reader: DictationArchiveReader
    private var limit = 200
    private var refreshPending = false

    init(directory: URL) { reader = DictationArchiveReader(directory: directory) }

    func refresh(more: Bool = false) async {
        guard !isLoading else { refreshPending = true; return }
        isLoading = true
        defer { isLoading = false }
        if more { limit += 200 }
        repeat {
            refreshPending = false
            let result = await reader.read(limit: limit)
            guard !Task.isCancelled else { return }
            switch result {
            case .success(let page):
                entries = page.entries
                hasMore = page.hasMore
                message = page.skippedCount > 0 ? "\(page.skippedCount) unreadable entries were skipped. Their files are unchanged." : nil
            case .failure(let error): message = error.localizedDescription
            }
        } while refreshPending
    }
}

struct HistoryPage: View {
    @Environment(\.colorSchemeContrast) private var contrast
    @ObservedObject private var history: DictationHistoryStore
    @StateObject private var browser: HistoryBrowser
    @State private var selectedID: URL?
    @State private var actionError: String?
    @State private var copiedID: URL?

    init(controller: SottoController) {
        history = controller.history
        _browser = StateObject(wrappedValue: HistoryBrowser(directory: controller.history.directory))
    }

    private var selected: DictationHistoryEntry? {
        browser.entries.first { $0.id == selectedID } ?? browser.entries.first
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top) {
                    SottoPageHeading(title: "History")
                    Spacer()
                    Button { Task { await browser.refresh() } } label: { SottoControlIcon(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                        .disabled(browser.isLoading)
                        .accessibilityLabel("Refresh history")
                    Button { history.openFolder() } label: { SottoControlIcon(systemName: "folder") }
                        .buttonStyle(.borderless)
                        .help(history.directory.path)
                        .accessibilityLabel("Open history folder")
                }

                Group {
                    if browser.entries.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "clock.arrow.circlepath").font(.system(size: 25, weight: .light))
                            Text(browser.isLoading ? "Reading your history…" : "No saved dictations yet.")
                                .font(.callout)
                            Text(history.isEnabled ? "Completed takes will appear here." : "History is turned off in General.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 210)
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(browser.entries) { entry in
                                    Button {
                                        selectedID = entry.id
                                        actionError = nil
                                        copiedID = nil
                                    } label: {
                                        historyRow(entry)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityAddTraits(selected?.id == entry.id ? .isSelected : [])
                                    .contextMenu {
                                        Button("Reveal in Finder") {
                                            NSWorkspace.shared.activateFileViewerSelecting([entry.folder])
                                        }
                                    }
                                }
                            }
                            .padding(1)
                        }
                        .frame(height: 210)
                    }
                }
                .accessibilityIdentifier("history.entries")

                if let selected { detail(selected) }

                HStack(spacing: 8) {
                    if browser.isLoading { ProgressView().controlSize(.mini) }
                    Text(actionError ?? browser.message ?? "\(browser.entries.count) saved dictations")
                        .font(.caption).foregroundStyle(actionError != nil || browser.message != nil ? SottoPalette.warning : SottoPalette.muted)
                    Spacer()
                    if browser.hasMore {
                        Button("Load more") { Task { await browser.refresh(more: true) } }
                            .disabled(browser.isLoading)
                    }
                }
                .frame(minHeight: 26)
            }
            .padding(28)
            .frame(maxWidth: 700, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .task { await browser.refresh() }
        .onChange(of: history.lastSavedAt) { _, _ in Task { await browser.refresh() } }
        .tint(SottoPalette.accentInk)
    }

    private func historyRow(_ entry: DictationHistoryEntry) -> some View {
        let isSelected = selected?.id == entry.id
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return HStack(spacing: 14) {
            Image(systemName: entry.record.outcome == .failed ? "exclamationmark.circle" : "waveform")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(SottoPalette.accentInk)
                .frame(width: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(entry.record.transcriptText.isEmpty ? emptyTitle(entry.record) : entry.record.transcriptText)
                    .font(.system(size: 13, weight: .medium)).lineLimit(1)
                    .foregroundStyle(SottoPalette.ink)
                Text(entry.record.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption).foregroundStyle(SottoPalette.muted)
            }
            Spacer(minLength: 8)
            Text(duration(entry.record.audio.original.durationSeconds))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .frame(height: 66)
        .background(isSelected ? SottoPalette.tint : .clear, in: shape)
        .overlay {
            if isSelected {
                shape.strokeBorder(SottoPalette.line, lineWidth: contrast == .increased ? 1 : 0.5)
            }
        }
        .overlay(alignment: .bottom) {
            if !isSelected && entry.id != browser.entries.last?.id {
                Rectangle().fill(SottoPalette.line)
                    .frame(height: 0.5).padding(.horizontal, 14)
            }
        }
        .contentShape(shape)
        .accessibilityElement(children: .combine)
    }

    private func detail(_ entry: DictationHistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            SottoSettingsGroup {
                VStack(spacing: 0) {
                    ScrollView {
                        Text(entry.record.transcriptText.isEmpty ? entry.record.errorMessage ?? emptyTitle(entry.record) : entry.record.transcriptText)
                            .font(.system(size: 16)).lineSpacing(5).textSelection(.enabled)
                            .foregroundStyle(SottoPalette.ink)
                            .frame(maxWidth: .infinity, alignment: .topLeading).padding(20)
                    }
                    .frame(height: 150)
                    .id(entry.id)
                    Divider().padding(.horizontal, 20)
                    HStack(spacing: 8) {
                        Label("Saved on this Mac", systemImage: "internaldrive")
                            .foregroundStyle(SottoPalette.muted)
                        Spacer()
                        Button {
                            actionError = nil
                            copiedID = nil
                            switch DictationClipboard.copy(entry.record.transcriptText, to: .general) {
                            case .success: copiedID = entry.id
                            case .failure(let error): actionError = error.localizedDescription
                            }
                        } label: {
                            Label(copiedID == entry.id ? "Copied" : "Copy",
                                  systemImage: copiedID == entry.id ? "checkmark" : "doc.on.doc")
                                .frame(width: 70, alignment: .trailing)
                                .frame(height: 30)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .disabled(entry.record.transcriptText.isEmpty)
                        .accessibilityLabel(copiedID == entry.id ? "Transcript copied" : "Copy selected transcript")
                    }
                    .font(.caption)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 7)
                }
            }

            VStack(spacing: 5) {
                Button {
                    actionError = nil
                    if !NSWorkspace.shared.open(entry.audioURL) { actionError = "The original recording could not be opened." }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "play.circle")
                            .font(.system(size: 22, weight: .light))
                            .accessibilityHidden(true)
                        Text("Open recording")
                        Spacer()
                        Text(duration(entry.record.audio.original.durationSeconds))
                            .font(.caption.monospacedDigit())
                        Image(systemName: "arrow.up.right")
                            .font(.caption)
                            .accessibilityHidden(true)
                    }
                    .foregroundStyle(entry.hasOriginalAudio ? SottoPalette.accentInk : SottoPalette.muted)
                    .padding(.horizontal, 2)
                    .frame(height: 36)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!entry.hasOriginalAudio)
                .help("Open the original WAV in your default audio player")

                HStack(spacing: 8) {
                    Label(entry.record.microphone.name ?? "Audio file",
                          systemImage: entry.record.microphone.name == nil ? "waveform" : "mic")
                        .lineLimit(1).truncationMode(.middle)
                    Text("·").accessibilityHidden(true)
                    Text(entry.record.model.name).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    Menu {
                        Text(entry.record.startedAt.formatted(date: .complete, time: .standard))
                        if entry.record.mode == .test { Text("Microphone test") }
                        Text("Microphone: \(entry.record.microphone.name ?? "Audio file")")
                        Text("Speech model: \(entry.record.model.name)")
                        if let model = entry.record.textProcessing?.modelID { Text("Text model: \(model)") }
                        Text("\(duration(entry.record.timing.releaseToResultSeconds)) to result")
                        Divider()
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([entry.folder])
                        }
                    } label: {
                        SottoControlIcon(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel("Selected dictation details")
                }
                .font(.caption).foregroundStyle(SottoPalette.muted)
                .frame(height: 28)
            }
        }
    }

    private func emptyTitle(_ record: DictationArchiveRecord) -> String {
        record.outcome == .noSpeech ? "No speech detected" : record.outcome == .failed ? "Dictation couldn’t finish" : "Empty dictation"
    }

    private func duration(_ seconds: Double) -> String {
        String(format: "%.1f s", seconds.isFinite ? max(0, seconds) : 0)
    }
}
