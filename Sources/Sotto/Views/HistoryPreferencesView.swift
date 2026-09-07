import SwiftUI

struct HistoryPreferencesSection: View {
    @ObservedObject var history: DictationHistoryStore

    var body: some View {
        Section {
            Toggle("Save transcripts and recordings", isOn: $history.isEnabled)
                .accessibilityIdentifier("preferences.history.enabled")

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("History folder")
                    Text("~/.murmur/transcripts")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .help(history.directory.path)
                }
                Spacer(minLength: 8)
                Button("Open history folder") { history.openFolder() }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("preferences.history.open")
            }

            HStack(alignment: .top, spacing: 8) {
                Group {
                    if history.lastError != nil {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    } else if history.pendingSaveCount > 0 {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "internaldrive")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 14, height: 14)
                .accessibilityHidden(true)

                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(history.lastError == nil ? .secondary : Color.orange)
                    .lineLimit(2, reservesSpace: true)
                    .frame(maxWidth: .infinity, minHeight: 30, maxHeight: 30, alignment: .topLeading)
                    .help(statusText)

                if history.lastError != nil {
                    Button("Dismiss") { history.dismissError() }
                        .controlSize(.small)
                        .accessibilityIdentifier("preferences.history.dismissError")
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("preferences.history.status")
        } header: {
            Text("History").textCase(nil)
        } footer: {
            Text("Completed takes stay on this Mac until you delete them. Cancelled takes are discarded. Turning this off affects future takes only.")
        }
    }

    private var statusText: String {
        if let error = history.lastError {
            return error
        }
        if history.pendingSaveCount > 0 {
            return history.pendingSaveCount == 1
                ? "Saving dictation…"
                : "Saving \(history.pendingSaveCount) dictations…"
        }
        if !history.isEnabled {
            return "Not saving new dictations. Existing history is unchanged."
        }
        if let date = history.lastSavedAt {
            return "Last saved \(date.formatted(date: .abbreviated, time: .shortened))."
        }
        return "New dictations will be saved locally."
    }
}

/// A failed save must be visible even when Preferences has never been opened.
struct HistorySaveNotice: View {
    @ObservedObject var history: DictationHistoryStore
    var showPreferences: () -> Void

    var body: some View {
        Group {
            if let error = history.lastError {
                Button(action: showPreferences) {
                    Label("History needs attention", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
                .help(error)
            } else if history.pendingSaveCount > 0 {
                Text("Saving history…")
                    .foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .accessibilityIdentifier("dictation.history.status")
    }
}
