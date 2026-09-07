import SottoCore
import SwiftUI

struct MicrophonePage: View {
    @ObservedObject var controller: SottoController

    var body: some View {
        MicrophoneSettingsView(controller: controller, store: controller.microphones,
                               recordingInputName: controller.recordingInputName)
    }
}

private struct MicrophoneSettingsView: View {
    @ObservedObject var controller: SottoController
    @ObservedObject var store: MicrophonePreferencesStore
    var recordingInputName: String?
    @State private var editingProfile: ProfileEdit?
    @State private var confirmingRemoval = false

    var body: some View {
        let profile = store.activeProfile
        let resolution = store.resolution
        let devices = store.availableDevices
        let connected = Dictionary(devices.map { ($0.uid, $0) }, uniquingKeysWith: { first, _ in first })
        let preferredUIDs = Set(profile.priority.map(\.uid))
        let otherDevices = devices.filter { !preferredUIDs.contains($0.uid) }

        ScrollView {
            VStack(alignment: .leading, spacing: 25) {
                SottoPageHeading(title: "Microphone")
                inputSection(profile: profile, resolution: resolution, devices: devices)
                VStack(alignment: .leading, spacing: 10) {
                    Text("Input priority")
                        .font(.headline)
                        .padding(.horizontal, 10)

                    SottoSettingsGroup {
                        VStack(spacing: 0) {
                            profileToolbar(profile)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 9)
                            Divider().padding(.horizontal, 10)
                            priorityList(profile: profile, connected: connected, otherDevices: otherDevices,
                                         selectedUID: store.preferences.selection == .automatic ? resolution.device?.uid : nil)
                        }
                    }

                    footer
                        .padding(.horizontal, 10)
                }
                SottoMicrophoneTestButton(controller: controller, identifier: "microphone.test")
            }
            .padding(.horizontal, 28)
            .padding(.top, 30)
            .padding(.bottom, 24)
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(item: $editingProfile) { edit in
            ProfileNameSheet(edit: edit, store: store)
        }
        .confirmationDialog("Delete “\(store.activeProfile.name)”?", isPresented: $confirmingRemoval) {
            Button("Delete list", role: .destructive) { _ = store.removeProfile(store.activeProfile.id) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only this saved order is removed. Your microphones and other lists are unchanged.")
        }
    }

    private func inputSection(profile: MicrophoneProfile, resolution: MicrophoneResolution,
                              devices: [AudioInputDevice]) -> some View {
        let detail = selectionDetail(profile: profile, resolution: resolution)
        return VStack(alignment: .leading, spacing: 8) {
            SottoSettingsGroup {
                VStack(spacing: 0) {
                    HStack {
                        Text("Choose input")
                        Spacer(minLength: 16)
                        Picker("Input", selection: inputChoice) {
                            Text("Automatic · priority list").tag(MicrophoneChoice.automatic)
                            Text("System default").tag(MicrophoneChoice.systemDefault)
                            Divider()
                            ForEach(devices) { device in
                                Text(device.name).tag(MicrophoneChoice.device(device.uid))
                            }
                            if case .fixed(let device) = store.preferences.selection,
                               !devices.contains(where: { $0.uid == device.uid }) {
                                Text("\(device.name) (disconnected)").tag(MicrophoneChoice.device(device.uid))
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 350, alignment: .trailing)
                        .accessibilityIdentifier("microphone.input")
                    }
                    .frame(height: 48)

                    Divider()

                    HStack {
                        Text("Next dictation")
                        Spacer(minLength: 16)
                        Text(resolution.device?.name ?? "No microphone available")
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                            .help(resolution.device?.name ?? "Connect an audio input to record.")
                    }
                    .frame(height: 48)
                    .accessibilityIdentifier("microphone.resolved")
                }
                .padding(.horizontal, 16)
            }

            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: 30, maxHeight: 30, alignment: .topLeading)
                .padding(.horizontal, 10)
                .help(detail)
        }
    }

    private func profileToolbar(_ profile: MicrophoneProfile) -> some View {
        HStack(spacing: 10) {
            Picker("List", selection: Binding(get: { store.preferences.activeProfileID }, set: store.selectProfile)) {
                ForEach(store.preferences.profiles) { item in
                    Text(item.name).tag(item.id)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("Priority list")
            .accessibilityIdentifier("microphone.profile")

            Button { store.select(.automatic) } label: {
                Text(store.preferences.selection == .automatic ? "In use" : "Use list")
                    .frame(width: 56)
            }
            .disabled(store.preferences.selection == .automatic)
            .help("Automatically use the first connected microphone in this list")
            .accessibilityIdentifier("microphone.profile.use")

            Button {
                editingProfile = ProfileEdit(profileID: nil, name: "")
            } label: {
                SottoControlIcon(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("New priority list")
            .accessibilityLabel("New priority list")
            .accessibilityIdentifier("microphone.profile.add")

            Menu {
                Button("Rename list…") {
                    editingProfile = ProfileEdit(profileID: profile.id, name: profile.name)
                }
                Button("Delete list…", role: .destructive) { confirmingRemoval = true }
                    .disabled(store.preferences.profiles.count == 1)
            } label: {
                SottoControlIcon(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 28, height: 28)
            .help("Priority list options")
            .accessibilityLabel("Priority list options")
        }
        .controlSize(.regular)
        .frame(height: 30)
    }

    private func priorityList(profile: MicrophoneProfile, connected: [String: AudioInputDevice],
                              otherDevices: [AudioInputDevice], selectedUID: String?) -> some View {
        List {
            if profile.priority.isEmpty && connected.isEmpty {
                ContentUnavailableView("No microphones connected", systemImage: "mic.slash",
                                       description: Text("Connect an audio input to add it to this list."))
                    .frame(maxWidth: .infinity, minHeight: 160)
                    .listRowSeparator(.hidden)
            } else {
                Section {
                    if profile.priority.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("No priorities yet")
                            Text("Add a microphone from the connected inputs below.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(minHeight: 50, alignment: .leading)
                    }
                    ForEach(Array(profile.priority.enumerated()), id: \.element.uid) { position, device in
                        preferredRow(device, position: position, count: profile.priority.count,
                                     connected: connected[device.uid], isSelected: selectedUID == device.uid)
                    }
                    .onMove(perform: store.movePriority)
                } header: {
                    Text("Preferred order").textCase(nil)
                }

                Section {
                    if otherDevices.isEmpty {
                        Text(connected.isEmpty ? "No inputs connected." : "All connected inputs are in this list.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(minHeight: 50, alignment: .leading)
                    }
                    ForEach(otherDevices) { device in
                        HStack(spacing: 12) {
                            deviceLabel(device, available: true)
                            Spacer(minLength: 8)
                            Button { store.addToPriority(device) } label: {
                                SottoControlIcon(systemName: "plus.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("Add \(device.name) to \(profile.name)")
                            .accessibilityLabel("Add \(device.name) to priority list")
                        }
                        .frame(minHeight: 50)
                    }
                } header: {
                    Text("Connected inputs").textCase(nil)
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .frame(height: 270)
        .accessibilityIdentifier("microphone.priorities")
    }

    private var footer: some View {
        HStack(alignment: .top, spacing: 7) {
            if store.storageError != nil {
                Image(systemName: "exclamationmark.circle")
                    .frame(width: 14)
            }
            Text(store.storageError ?? "Drag to reorder. Disconnected microphones keep their place.")
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.caption)
        .foregroundStyle(store.storageError == nil ? .secondary : Color.orange)
        .frame(height: 32, alignment: .topLeading)
        .help(store.storageError ?? "In Automatic mode, the first connected microphone in the selected list is used.")
    }

    // Device names can change (or be normalized) without changing the selection.
    // Only the stable HAL UID belongs in a Picker tag.
    private var inputChoice: Binding<MicrophoneChoice> {
        Binding {
            switch store.preferences.selection {
            case .automatic: .automatic
            case .systemDefault: .systemDefault
            case .fixed(let device): .device(device.uid)
            }
        } set: { choice in
            switch choice {
            case .automatic: store.select(.automatic)
            case .systemDefault: store.select(.systemDefault)
            case .device(let uid):
                if let device = store.connectedDevice(uid: uid) { store.select(.fixed(device)) }
            }
        }
    }

    private func selectionDetail(profile: MicrophoneProfile, resolution: MicrophoneResolution) -> String {
        if let recordingInputName { return "Current take: \(recordingInputName). Changes apply to your next dictation." }
        switch resolution.reason {
        case .fallback(let requested):
            if let requested { return "\(requested.name) is disconnected. It will be used again when it reconnects." }
            return "The system input is unavailable. Using the first available microphone."
        case .unavailable: return "Connect an audio input to start dictating."
        case .priority: return "The first connected microphone in “\(profile.name)” is used."
        case .fixed: return "This microphone is preferred whenever it is connected."
        case .systemDefault:
            return store.preferences.selection == .systemDefault
                ? "Follows the macOS input. Your system settings stay unchanged."
                : "Using the macOS input until a preferred microphone is connected."
        }
    }

    private func preferredRow(_ device: AudioInputDevice, position: Int, count: Int,
                              connected: AudioInputDevice?, isSelected: Bool) -> some View {
        HStack(spacing: 12) {
            Text("\(position + 1)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 18, alignment: .trailing)
            deviceLabel(connected ?? device, available: connected != nil, isSelected: isSelected)
            Spacer(minLength: 6)
            HStack(spacing: 2) {
                Button { store.movePriority(uid: device.uid, by: -1) } label: {
                    SottoControlIcon(systemName: "chevron.up")
                }
                    .disabled(position == 0)
                    .help("Move up")
                    .accessibilityLabel("Move \(device.name) up")
                Button { store.movePriority(uid: device.uid, by: 1) } label: {
                    SottoControlIcon(systemName: "chevron.down")
                }
                    .disabled(position == count - 1)
                    .help("Move down")
                    .accessibilityLabel("Move \(device.name) down")
                Button { store.removeFromPriority(uid: device.uid) } label: {
                    SottoControlIcon(systemName: "minus.circle")
                }
                    .help("Remove from this priority list")
                    .accessibilityLabel("Remove \(device.name) from priority list")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
        .frame(minHeight: 56)
        .contextMenu {
            Button("Move to top") {
                store.movePriority(fromOffsets: IndexSet(integer: position), toOffset: 0)
            }
            .disabled(position == 0)
            Button("Remove from priority list") { store.removeFromPriority(uid: device.uid) }
        }
    }

    private func deviceLabel(_ device: AudioInputDevice, available: Bool, isSelected: Bool = false) -> some View {
        HStack(spacing: 10) {
            Image(systemName: device.transport.symbol)
                .font(.system(size: 15))
                .foregroundStyle(available ? SottoPalette.ink : SottoPalette.muted)
                .frame(width: 30, height: 30)
                .background(SottoPalette.canvas, in: RoundedRectangle(cornerRadius: 7))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(device.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(available ? .primary : .secondary)
                HStack(spacing: 5) {
                    if isSelected {
                        Circle().fill(SottoPalette.accent).frame(width: 5, height: 5)
                            .accessibilityHidden(true)
                    }
                    Text(isSelected ? "In use" : available ? device.transport.label : "Disconnected")
                        .font(.caption)
                        .foregroundStyle(SottoPalette.muted)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private enum MicrophoneChoice: Hashable {
    case automatic
    case systemDefault
    case device(String)
}

private struct ProfileEdit: Identifiable {
    let id = UUID()
    let profileID: String?
    let name: String
}

private struct ProfileNameSheet: View {
    let edit: ProfileEdit
    @ObservedObject var store: MicrophonePreferencesStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(edit.profileID == nil ? "New priority list" : "Rename priority list")
                .font(.headline)
            TextField("Name", text: $name, prompt: Text("Desk, travel…"))
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(save)
                .accessibilityIdentifier("microphone.profile.name")
                .onChange(of: name) { _, _ in error = nil }
            Text(error ?? "Each list remembers its own microphone order.")
                .font(.caption)
                .foregroundStyle(error == nil ? .secondary : Color.orange)
                .frame(height: 30, alignment: .topLeading)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(edit.profileID == nil ? "Create" : "Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 350)
        .onAppear {
            name = edit.name
            focused = true
        }
    }

    private func save() {
        let result = edit.profileID.map { store.renameProfile($0, to: name) } ?? store.addProfile(named: name)
        switch result {
        case .success: dismiss()
        case .failure(let failure): error = failure.localizedDescription
        }
    }
}

private extension AudioInputTransport {
    var symbol: String {
        switch self {
        case .builtIn: "laptopcomputer"
        case .usb: "cable.connector"
        case .bluetooth: "headphones"
        case .virtual: "waveform.path"
        case .aggregate: "square.stack.3d.up"
        case .other: "mic"
        }
    }

    var label: String {
        switch self {
        case .builtIn: "Built-in microphone"
        case .usb: "USB audio"
        case .bluetooth: "Bluetooth audio"
        case .virtual: "Virtual input"
        case .aggregate: "Aggregate device"
        case .other: "Audio input"
        }
    }
}
