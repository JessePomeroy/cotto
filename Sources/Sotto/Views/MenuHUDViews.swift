import SottoCore
import SwiftUI

struct SottoMenuView: View {
    static let width: CGFloat = 310
    @ObservedObject var controller: SottoController
    var openWindow: () -> Void
    var quit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                SottoMark(size: 20)
                Text("Sotto").font(.headline)
                DevBadge()
                Spacer(minLength: 8)
                HStack(spacing: 6) {
                    StatusDot(color: controller.isServerReady ? SottoPalette.success : SottoPalette.warning)
                    Text(controller.serverStatusMessage)
                        .font(.caption)
                        .foregroundStyle(SottoPalette.muted)
                        .lineLimit(1)
                }
                .frame(width: 112, alignment: .trailing)
                .help(controller.serverStatusMessage)
                .accessibilityIdentifier("server.status")
            }
            .frame(height: 28)

            SottoMicrophoneTestButton(controller: controller, identifier: "menu.test",
                idleTitle: "Press \(controller.shortcut == .fn ? "fn" : controller.shortcut.title) to dictate")
            Button { controller.copyLastTranscript() } label: {
                Label("Copy last message", systemImage: "doc.on.doc")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 26)
            }
            .disabled(controller.lastTranscript.isEmpty || controller.isBusy)
            .accessibilityIdentifier("menu.copy-last")

            Button("Open \(SottoBuild.current.displayName)…", action: openWindow)
                .keyboardShortcut(",", modifiers: .command)
            Divider()
            Button("Quit \(SottoBuild.current.displayName)", action: quit)
                .keyboardShortcut("q", modifiers: .command)
        }
        .buttonStyle(.borderless)
        .padding(18)
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
        .tint(SottoPalette.accentInk)
        .background { SottoMenuSurface() }
    }
}

struct DictationHUD: View {
    static let width: CGFloat = SottoBuild.current.isDevelopment ? 200 : 160
    static let height: CGFloat = 44
    static let noticeHeight: CGFloat = 30
    @ObservedObject var controller: SottoController
    var previewHover = false

    var body: some View {
        VStack(spacing: 0) {
            capsule
            RecordingLimitNote(feedback: controller.recordingFeedback)
                .frame(width: Self.width, height: Self.noticeHeight)
        }
    }

    private var capsule: some View {
        HStack(spacing: 10) {
            DevBadge()
            HStack(spacing: 8) {
                if controller.isRecording {
                    RecordingWaveform(feedback: controller.recordingFeedback, height: 23)
                    RecordingElapsedTime(feedback: controller.recordingFeedback)
                } else {
                    statusIcon.frame(width: 18, height: 22)
                    Text(hudLabel).lineLimit(1)
                }
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(SottoPalette.muted)
            Button {
                if controller.isBusy { controller.cancelDictation() }
                else { controller.dismissFeedback() }
            } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                    .frame(width: 22, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(controller.isBusy ? "Cancel dictation" : "Dismiss status")
            .accessibilityLabel(controller.isBusy ? "Cancel dictation" : "Dismiss status")
            .accessibilityIdentifier("hud.cancel")
        }
        .padding(.horizontal, 12)
        .frame(width: Self.width, height: Self.height)
        .modifier(SottoFloatingSurface(cornerRadius: Self.height / 2))
        .onExitCommand {
            if controller.canCancelWithEscape { controller.cancelDictation() }
        }
        .help(controller.errorMessage ?? controller.statusMessage)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(SottoBuild.current.displayName) dictation")
        .accessibilityValue(controller.errorMessage ?? controller.statusMessage)
        .accessibilityIdentifier("hud.status")
    }

    @ViewBuilder private var statusIcon: some View {
        switch controller.activity {
        case .starting, .transcribing, .delivering:
            ProgressView().controlSize(.small)
        case .success:
            Image(systemName: controller.lastDeliveryStatus == .unconfirmed ? "questionmark.circle" : "checkmark")
                .foregroundStyle(SottoPalette.accentInk)
        case .failed:
            Image(systemName: "exclamationmark.circle").foregroundStyle(SottoPalette.warning)
        case .idle, .recording:
            SottoMark(size: 18)
        }
    }

    private var hudLabel: String {
        switch controller.activity {
        case .idle: "Ready"
        case .starting: "Starting"
        case .recording: "Listening"
        case .transcribing: "Processing"
        case .delivering: "Inserting"
        case .success: controller.lastDeliveryStatus == .unconfirmed ? "Check text" : "Done"
        case .failed: "Failed"
        }
    }
}

/// Observe only the notice's whole-second changes, independently of the meter.
struct RecordingLimitNote: View {
    let feedback: RecordingFeedback
    @State private var notice: RecordingLimitNotice?

    var body: some View {
        Text(notice?.text ?? "Recording limit in 0:30")
            .font(.system(size: 11, weight: .medium))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .foregroundStyle(SottoPalette.ink)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(.regularMaterial, in: Capsule())
            .opacity(notice == nil ? 0 : 1)
            .accessibilityHidden(notice == nil)
            .accessibilityLabel(notice?.accessibilityLabel ?? "")
            .accessibilityIdentifier("hud.recording-limit")
            .onReceive(feedback.$limitNotice.removeDuplicates()) { notice = $0 }
    }
}
