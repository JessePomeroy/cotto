import SwiftUI

/// One compact footprint for installed, downloading, and failed model actions.
struct ModelActionRow<Controls: View>: View {
    var title: String
    var help: String
    var hasError = false
    var progress: Double? = nil
    var isVerifying = false
    @ViewBuilder var controls: Controls

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                if let progress {
                    ProgressView(value: min(1, max(0, progress)))
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                        .accessibilityLabel("Model download progress")
                } else if isVerifying {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel("Verifying model")
                }
                Text(title)
                    .lineLimit(2)
                    .foregroundStyle(hasError ? SottoPalette.warning : SottoPalette.ink)
                    .help(help)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            controls
                .fixedSize(horizontal: true, vertical: false)
        }
        .font(.callout)
        .frame(height: 32)
    }
}
