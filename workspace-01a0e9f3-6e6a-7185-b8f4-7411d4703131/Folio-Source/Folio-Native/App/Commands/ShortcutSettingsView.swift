import SwiftUI
import FolioCore

struct ShortcutSettingsView: View {
    @Bindable var preferences: ShortcutPreferences
    @State private var command: FolioCommandID = .searchNotes
    @State private var key = "f"
    @State private var modifiers: CommandModifiers = [.command, .shift]

    var body: some View {
        Form {
            Section("Remap a Folio command") {
                Picker("Command", selection: $command) {
                    ForEach(FolioCommandID.allCases) { Text($0.title).tag($0) }
                }
                HStack {
                    TextField("Key", text: $key).frame(width: 70)
                    Text("⌘").font(.headline)
                    Toggle("⇧", isOn: modifier(.shift))
                    Toggle("⌥", isOn: modifier(.option))
                    Toggle("⌃", isOn: modifier(.control))
                }
                Text("Command is required. Native editing, system navigation and VoiceOver shortcuts are protected.")
                    .font(.caption).foregroundStyle(.secondary)
                if let error = preferences.failure { Text(error).font(.caption).foregroundStyle(.orange) }
                HStack {
                    Button("Assign") { preferences.assign(.init(key: key, modifiers: modifiers.union(.command)), to: command) }
                    Button("Restore Defaults") { preferences.reset(); load() }
                }
            }
            Section("Current commands") {
                ForEach(FolioCommandID.allCases) { command in
                    HStack { Text(command.title); Spacer(); Text(preferences.shortcut(for: command).label).monospaced() }
                }
            }
        }.formStyle(.grouped)
        .onAppear { load() }
        .onChange(of: command) { _, _ in preferences.failure = nil; load() }
    }
    private func modifier(_ value: CommandModifiers) -> Binding<Bool> {
        Binding(get: { modifiers.contains(value) }, set: { selected in
            if selected { modifiers.insert(value) } else { modifiers.remove(value) }
        })
    }
    private func load() { let shortcut = preferences.shortcut(for: command); key = shortcut.key; modifiers = shortcut.modifiers }
}
