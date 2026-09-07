import SwiftUI

struct ConfigurationPreferencesSection: View {
    @ObservedObject var configuration: ConfigurationStore

    var body: some View {
        Section {
            HStack(spacing: 12) {
                Text("~/.murmur/config.json")
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .help(configuration.url.path)
                Spacer(minLength: 8)
                Button("Show in Finder") { configuration.revealFile() }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("preferences.configuration.reveal")
            }
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: configuration.errorMessage == nil ? "doc.text" : "exclamationmark.triangle")
                    .frame(width: 14, height: 14)
                    .accessibilityHidden(true)
                Text(status)
                    .lineLimit(2, reservesSpace: true)
                    .frame(maxWidth: .infinity, minHeight: 30, maxHeight: 30, alignment: .topLeading)
            }
            .font(.caption)
            .foregroundStyle(configuration.errorMessage == nil ? .secondary : Color.orange)
            .help(status)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("preferences.configuration.status")
        } header: {
            Text("Settings file").textCase(nil)
        } footer: {
            Text("Changes save automatically. File edits apply to the next dictation.")
        }
    }

    private var status: String {
        if let error = configuration.errorMessage { return error }
        return configuration.pendingWriteCount > 0 ? "Saving settings…" : "Settings are up to date."
    }
}

struct ConfigurationNotice: View {
    @ObservedObject var configuration: ConfigurationStore
    var showPreferences: () -> Void

    var body: some View {
        Group {
            if let error = configuration.errorMessage {
                Button(action: showPreferences) {
                    Label("Configuration needs attention", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
                .help(error)
            }
        }
        .font(.caption2)
        .lineLimit(1)
        .frame(height: 14)
        .accessibilityIdentifier("configuration.status")
    }
}
