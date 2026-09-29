import SwiftUI
import FolioCore

struct CommandPaletteView: View {
    @Bindable var session: WorkspaceSession
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selected: FolioCommandID?
    @FocusState private var focused: Bool
    private var matches: [FolioCommandID] { CommandCatalog.matches(query) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Image(systemName: "command"); Text("Command palette").font(.headline); Spacer(); Text("Commands, not note content").font(.caption).foregroundStyle(.secondary) }
            TextField("Find a Folio command…", text: $query)
                .textFieldStyle(.roundedBorder).focused($focused)
                .onSubmit { execute(selected ?? matches.first) }
            if matches.isEmpty {
                ContentUnavailableView {
                    Label("No command matches", systemImage: "command")
                } description: {
                    Text("Nothing matches \u{201C}\(query)\u{201D}. The palette searches command names and their keywords, not note content — use Search Notes for that.")
                }
            } else {
                List(selection: $selected) {
                    ForEach(matches) { command in
                        let disabled = session.commandContext.disabledReason(for: command)
                        Button { execute(command) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(command.title)
                                    if let disabled { Text(disabled).font(.caption).foregroundStyle(.secondary) }
                                }
                                Spacer()
                                Text(session.shortcuts.shortcut(for: command).label).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }.padding(.vertical, 4)
                        }
                        .buttonStyle(.plain).disabled(disabled != nil).tag(command)
                    }
                }
            }
            HStack { Text("Shortcuts can be changed in Folio Settings.").font(.caption).foregroundStyle(.secondary); Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.cancelAction) }
        }
        .padding(22).frame(width: 610, height: 500)
        .onAppear { focused = true; selected = matches.first }
        .onChange(of: query) { _, _ in selected = matches.first }
    }
    private func execute(_ command: FolioCommandID?) {
        guard let command, session.commandContext.disabledReason(for: command) == nil else { return }
        dismiss()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            session.runCommand(command)
        }
    }
}
