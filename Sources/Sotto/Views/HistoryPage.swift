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
    @ObservedObject private var history: DictationHistoryStore
    @StateObject private var browser: HistoryBrowser
    @State private var selectedID: URL?
    @State private var actionError: String?

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

                SottoSettingsGroup {
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
                                    Button { selectedID = entry.id; actionError = nil } label: {
                                        historyRow(entry)
                                            .background(selected?.id == entry.id ? SottoPalette.tint : .clear)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityAddTraits(selected?.id == entry.id ? .isSelected : [])
                                    if entry.id != browser.entries.last?.id { Divider().padding(.horizontal, 14) }
                                }
                            }
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
        HStack(spacing: 12) {
            Image(systemName: entry.record.outcome == .failed ? "exclamationmark.circle" : "waveform")
                .foregroundStyle(SottoPalette.accentInk)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.record.transcriptText.isEmpty ? emptyTitle(entry.record) : entry.record.transcriptText)
                    .font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(entry.record.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(duration(entry.record.audio.original.durationSeconds))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14).frame(height: 60)
        .contentShape(Rectangle())
    }

    private func detail(_ entry: DictationHistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(entry.record.startedAt.formatted(date: .abbreviated, time: .shortened)).font(.headline)
                Spacer()
                Button {
                    actionError = nil
                    if case .failure(let error) = DictationClipboard.copy(entry.record.transcriptText, to: .general) {
                        actionError = error.localizedDescription
                    }
                } label: { SottoControlIcon(systemName: "doc.on.doc") }
                .buttonStyle(.borderless).disabled(entry.record.transcriptText.isEmpty)
                .accessibilityLabel("Copy selected transcript")
                Button { NSWorkspace.shared.activateFileViewerSelecting([entry.folder]) } label: {
                    SottoControlIcon(systemName: "folder")
                }
                .buttonStyle(.borderless).accessibilityLabel("Reveal selected dictation in Finder")
            }
            SottoSettingsGroup {
                VStack(spacing: 0) {
                    ScrollView {
                        Text(entry.record.transcriptText.isEmpty ? entry.record.errorMessage ?? emptyTitle(entry.record) : entry.record.transcriptText)
                            .font(.body).lineSpacing(4).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading).padding(16)
                    }
                    .frame(height: 150)
                    Divider()
                    HStack(spacing: 8) {
                        Label(entry.record.mode == .test ? "Microphone test" : "Saved on this Mac", systemImage: "internaldrive")
                        Spacer()
                        Text("\(duration(entry.record.audio.original.durationSeconds)) audio · \(duration(entry.record.timing.releaseToResultSeconds)) to result")
                    }
                    .font(.caption2).foregroundStyle(.secondary).padding(10)
                }
            }
            HStack(spacing: 10) {
                Text(entry.record.model.name)
                if let model = entry.record.textProcessing?.modelID { Text(model).lineLimit(1).truncationMode(.middle) }
                Spacer(minLength: 0)
                Button("Open recording") {
                    actionError = nil
                    if !NSWorkspace.shared.open(entry.audioURL) { actionError = "The original recording could not be opened." }
                }
                .buttonStyle(.borderless).disabled(!entry.hasOriginalAudio)
                .help("Open the original WAV in your default audio player")
            }
            .font(.caption).foregroundStyle(.secondary)
            Label(entry.record.microphone.name ?? "Audio file",
                  systemImage: entry.record.microphone.name == nil ? "waveform" : "mic")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1).frame(height: 18)
        }
    }

    private func emptyTitle(_ record: DictationArchiveRecord) -> String {
        record.outcome == .noSpeech ? "No speech detected" : record.outcome == .failed ? "Dictation couldn’t finish" : "Empty dictation"
    }

    private func duration(_ seconds: Double) -> String {
        String(format: "%.1f s", seconds.isFinite ? max(0, seconds) : 0)
    }
}
