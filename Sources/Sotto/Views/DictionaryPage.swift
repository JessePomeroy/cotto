import SottoCore
import SwiftUI

struct DictionaryPage: View {
    @ObservedObject var controller: SottoController

    var body: some View {
        DictionarySettingsView(configuration: controller.configuration,
                               vocabulary: $controller.vocabulary, isBusy: controller.isBusy)
    }
}

private struct DictionarySettingsView: View {
    @ObservedObject var configuration: ConfigurationStore
    @Binding var vocabulary: String
    var isBusy: Bool
    @State private var selectedListID: String?
    @State private var editingList: DictionaryListEdit?
    @State private var editingEntry: DictionaryEntryEdit?
    @State private var removal: DictionaryRemoval?
    @State private var error: String?

    private var dictionary: PersonalDictionary { configuration.configuration.dictionary }
    private var selectedList: DictionaryList? {
        dictionary.lists.first(where: { $0.id == selectedListID }) ?? dictionary.lists.first
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 25) {
                SottoPageHeading(title: "Dictionary")

                SottoSettingsGroup {
                    HStack(spacing: 16) {
                        Text("Personal dictionary")
                        Spacer(minLength: 8)
                        Label("Always on", systemImage: "checkmark")
                            .font(.callout)
                            .foregroundStyle(SottoPalette.muted)
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 49)
                }

                SottoSettingsGroup {
                    VStack(spacing: 0) {
                        listToolbar
                            .padding(.horizontal, 12)
                            .frame(height: 46)
                        Divider().padding(.horizontal, 12)
                        entries
                        Divider().padding(.horizontal, 12)
                        entryToolbar
                            .padding(.horizontal, 12)
                            .frame(height: 42)
                    }
                }

                recognitionHints

                Text(status)
                    .font(.caption)
                    .foregroundStyle(error != nil || configuration.errorMessage != nil ? Color.orange : .secondary)
                    .lineLimit(2, reservesSpace: true)
                    .frame(maxWidth: .infinity, minHeight: 30, maxHeight: 30, alignment: .topLeading)
                    .help(status)
                    .accessibilityIdentifier("dictionary.status")
            }
            .padding(.horizontal, 28)
            .padding(.top, 30)
            .padding(.bottom, 24)
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .disabled(isBusy || !configuration.isLoaded)
        .sheet(item: $editingList) { edit in
            DictionaryListSheet(edit: edit, configuration: configuration) { id in
                selectedListID = id
                error = nil
            }
        }
        .sheet(item: $editingEntry) { edit in
            DictionaryEntrySheet(edit: edit, configuration: configuration)
        }
        .alert(removal?.title ?? "Delete from dictionary?", isPresented: Binding(
            get: { removal != nil }, set: { if !$0 { removal = nil } }
        )) {
            Button("Cancel", role: .cancel) { removal = nil }
            Button("Delete", role: .destructive, action: delete)
        } message: {
            Text(removal?.detail ?? "")
        }
    }

    private var listToolbar: some View {
        HStack(spacing: 10) {
            if dictionary.lists.isEmpty {
                Text("Word lists").foregroundStyle(.secondary)
                Spacer(minLength: 8)
            } else {
                Picker("List", selection: Binding(
                    get: { selectedList?.id ?? "" },
                    set: { selectedListID = $0; error = nil }
                )) {
                    ForEach(dictionary.lists, id: \.id) { list in
                        Text(list.name).tag(list.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("Dictionary list")
                .accessibilityIdentifier("dictionary.list")
            }

            Button { editingList = DictionaryListEdit() } label: {
                SottoControlIcon(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("New dictionary list")
            .accessibilityLabel("New dictionary list")
            .accessibilityIdentifier("dictionary.list.add")

            Menu {
                if let list = selectedList {
                    Button("Rename list…") {
                        editingList = DictionaryListEdit(listID: list.id, name: list.name)
                    }
                    Button("Delete list…", role: .destructive) { removal = .list(list) }
                }
            } label: {
                SottoControlIcon(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 28, height: 28)
            .disabled(selectedList == nil)
            .help("Dictionary list options")
            .accessibilityLabel("Dictionary list options")
            .accessibilityIdentifier("dictionary.list.options")
        }
        .controlSize(.regular)
    }

    private var entries: some View {
        List {
            if let list = selectedList {
                if list.entries.isEmpty {
                    ContentUnavailableView("No terms yet", systemImage: "character.book.closed",
                                           description: Text("Add names, products, and other preferred spellings."))
                        .frame(maxWidth: .infinity, minHeight: 140)
                        .listRowSeparator(.hidden)
                }
                ForEach(list.entries, id: \.id) { entry in
                    entryRow(entry, in: list)
                }
            } else {
                ContentUnavailableView("No word lists", systemImage: "character.book.closed",
                                       description: Text("Create a list to collect your preferred spellings."))
                    .frame(maxWidth: .infinity, minHeight: 140)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .frame(height: 240)
        .accessibilityIdentifier("dictionary.entries")
    }

    private func entryRow(_ entry: DictionaryEntry, in list: DictionaryList) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.term)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text(entry.aliases.isEmpty ? "Preferred spelling" : entry.aliases.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .help(entry.aliases.isEmpty ? entry.term : "\(entry.term) — replaces: \(entry.aliases.joined(separator: ", "))")
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            Button {
                editingEntry = DictionaryEntryEdit(listID: list.id, entry: entry)
            } label: {
                SottoControlIcon(systemName: "pencil")
            }
            .help("Edit \(entry.term)")
            .accessibilityLabel("Edit \(entry.term)")
            .accessibilityIdentifier("dictionary.entry.edit.\(entry.id)")
            Button(role: .destructive) { removal = .entry(listID: list.id, entry: entry) } label: {
                SottoControlIcon(systemName: "minus.circle")
            }
            .help("Delete \(entry.term)")
            .accessibilityLabel("Delete \(entry.term)")
            .accessibilityIdentifier("dictionary.entry.delete.\(entry.id)")
        }
        .buttonStyle(.borderless)
        .frame(minHeight: 54)
        .contextMenu {
            Button("Edit…") { editingEntry = DictionaryEntryEdit(listID: list.id, entry: entry) }
            Button("Delete…", role: .destructive) { removal = .entry(listID: list.id, entry: entry) }
        }
    }

    private var entryToolbar: some View {
        HStack {
            Button {
                if let list = selectedList { editingEntry = DictionaryEntryEdit(listID: list.id) }
            } label: {
                Label("Add a word", systemImage: "plus")
            }
            .buttonStyle(.borderless)
            .disabled(selectedList == nil)
            .accessibilityIdentifier("dictionary.entry.add")
            Spacer(minLength: 8)
            let count = selectedList?.entries.count ?? 0
            Text("\(count) \(count == 1 ? "word" : "words")")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private var recognitionHints: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Additional recognition hints")
                .font(.headline)
            SottoSettingsGroup {
                ZStack(alignment: .topLeading) {
                    if vocabulary.isEmpty {
                        Text("Names and technical terms, separated by commas")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 10)
                            .padding(.top, 8)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                    TextEditor(text: $vocabulary)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 5)
                        .accessibilityLabel("Additional recognition hints")
                        .accessibilityIdentifier("preferences.vocabulary")
                }
                .frame(height: 64)
            }
        }
    }

    private var status: String {
        if let error { return error }
        if let error = configuration.errorMessage { return error }
        if !configuration.isLoaded { return "Loading your dictionary…" }
        if configuration.pendingWriteCount > 0 { return "Saving changes…" }
        return "All lists are active. Changes apply to your next dictation."
    }

    private func delete() {
        guard let removal else { return }
        var updated = dictionary
        switch removal {
        case .list(let list):
            updated.lists.removeAll { $0.id == list.id }
        case .entry(let listID, let entry):
            if let index = updated.lists.firstIndex(where: { $0.id == listID }) {
                updated.lists[index].entries.removeAll { $0.id == entry.id }
            }
        }
        self.removal = nil
        if let error = updated.validationError { self.error = error; return }
        configuration.update { $0.dictionary = updated }
        error = nil
    }
}

private struct DictionaryListEdit: Identifiable {
    let id = UUID().uuidString
    var listID: String?
    var name = ""
}

private struct DictionaryEntryEdit: Identifiable {
    let id = UUID().uuidString
    let listID: String
    var entry: DictionaryEntry?
}

private enum DictionaryRemoval {
    case list(DictionaryList)
    case entry(listID: String, entry: DictionaryEntry)

    var title: String {
        switch self {
        case .list(let list): return "Delete “\(list.name)”?"
        case .entry(_, let entry): return "Delete “\(entry.term)”?"
        }
    }

    var detail: String {
        switch self {
        case .list: return "This list and its terms will be removed. Other lists are unchanged."
        case .entry: return "This term and its alternate spellings will be removed from your dictionary."
        }
    }
}

private struct DictionaryListSheet: View {
    let edit: DictionaryListEdit
    @ObservedObject var configuration: ConfigurationStore
    var onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(edit.listID == nil ? "New dictionary list" : "Rename dictionary list")
                .font(.headline)
            TextField("Name", text: $name, prompt: Text("Names, work, products…"))
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(save)
                .accessibilityIdentifier("dictionary.list.name")
            DictionaryValidationMessage(message: validationMessage,
                                        fallback: "All lists are used together when you dictate.")
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(edit.listID == nil ? "Create" : "Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(validationMessage != nil)
                    .accessibilityIdentifier("dictionary.list.save")
            }
        }
        .padding(24)
        .frame(width: 380)
        .onAppear { name = edit.name; focused = true }
    }

    private var candidate: PersonalDictionary {
        var value = configuration.configuration.dictionary
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let listID = edit.listID {
            if let index = value.lists.firstIndex(where: { $0.id == listID }) { value.lists[index].name = trimmed }
        } else {
            value.lists.append(DictionaryList(id: edit.id, name: trimmed, entries: []))
        }
        return value
    }

    private var validationMessage: String? {
        if let listID = edit.listID,
           !configuration.configuration.dictionary.lists.contains(where: { $0.id == listID }) {
            return "This list was removed. Close this window and choose another list."
        }
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Enter a name for this list." }
        return candidate.validationError
    }

    private func save() {
        guard validationMessage == nil else { return }
        let value = candidate
        configuration.update { $0.dictionary = value }
        onSave(edit.listID ?? edit.id)
        dismiss()
    }
}

private struct DictionaryEntrySheet: View {
    let edit: DictionaryEntryEdit
    @ObservedObject var configuration: ConfigurationStore
    @Environment(\.dismiss) private var dismiss
    @State private var term = ""
    @State private var aliases = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(edit.entry == nil ? "Add dictionary term" : "Edit dictionary term")
                .font(.headline)
            VStack(alignment: .leading, spacing: 6) {
                Text("Preferred spelling")
                TextField("Preferred spelling", text: $term, prompt: Text("MiniMax"))
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit(save)
                    .accessibilityIdentifier("dictionary.entry.term")
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Alternate spellings")
                TextField("Alternate spellings", text: $aliases, prompt: Text("Optional, separated by commas"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                    .accessibilityIdentifier("dictionary.entry.aliases")
                Text("Transcribed variations to replace with the preferred spelling.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            DictionaryValidationMessage(message: validationMessage,
                                        fallback: "Alternate spellings can point to only one preferred term.")
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(edit.entry == nil ? "Add" : "Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(validationMessage != nil)
                    .accessibilityIdentifier("dictionary.entry.save")
            }
        }
        .padding(24)
        .frame(width: 420)
        .onAppear {
            term = edit.entry?.term ?? ""
            aliases = edit.entry?.aliases.joined(separator: ", ") ?? ""
            focused = true
        }
    }

    private var candidate: PersonalDictionary {
        var value = configuration.configuration.dictionary
        guard let listIndex = value.lists.firstIndex(where: { $0.id == edit.listID }) else { return value }
        let entry = DictionaryEntry(id: edit.entry?.id ?? edit.id,
                                    term: term.trimmingCharacters(in: .whitespacesAndNewlines),
                                    aliases: aliases.split(separator: ",")
                                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                                        .filter { !$0.isEmpty })
        if let existing = edit.entry {
            if let entryIndex = value.lists[listIndex].entries.firstIndex(where: { $0.id == existing.id }) {
                value.lists[listIndex].entries[entryIndex] = entry
            }
        } else {
            value.lists[listIndex].entries.append(entry)
        }
        return value
    }

    private var validationMessage: String? {
        guard let list = configuration.configuration.dictionary.lists.first(where: { $0.id == edit.listID }) else {
            return "This list was removed. Close this window and choose another list."
        }
        if let entry = edit.entry, !list.entries.contains(where: { $0.id == entry.id }) {
            return "This term was removed. Close this window to add a new term."
        }
        if term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Enter the preferred spelling." }
        return candidate.validationError
    }

    private func save() {
        guard validationMessage == nil else { return }
        let value = candidate
        configuration.update { $0.dictionary = value }
        dismiss()
    }
}

private struct DictionaryValidationMessage: View {
    var message: String?
    var fallback: String

    var body: some View {
        Text(message ?? fallback)
            .font(.caption)
            .foregroundStyle(message == nil ? .secondary : Color.orange)
            .lineLimit(2, reservesSpace: true)
            .frame(maxWidth: .infinity, minHeight: 30, maxHeight: 30, alignment: .topLeading)
            .help(message ?? fallback)
            .accessibilityIdentifier("dictionary.validation")
    }
}
