import SwiftUI
import Observation
import FolioCore

@MainActor
@Observable
final class ShortcutPreferences {
    var bindings = ShortcutPolicy.defaults
    var failure: String?
    init() {
        if let data = UserDefaults.standard.data(forKey: "folioCommandShortcuts") {
            do { bindings = try ShortcutPolicy.validated(JSONDecoder().decode([FolioCommandID: CommandShortcut].self, from: data)) }
            catch { failure = "Invalid saved shortcuts were ignored; native-safe defaults are active." }
        }
    }
    func assign(_ shortcut: CommandShortcut, to command: FolioCommandID) {
        do {
            try ShortcutPolicy.validate(shortcut, for: command, in: bindings)
            bindings[command] = shortcut; failure = nil
            UserDefaults.standard.set(try JSONEncoder().encode(bindings), forKey: "folioCommandShortcuts")
        } catch { failure = error.localizedDescription }
    }
    func reset() { bindings = ShortcutPolicy.defaults; failure = nil; UserDefaults.standard.removeObject(forKey: "folioCommandShortcuts") }
    func shortcut(for command: FolioCommandID) -> CommandShortcut { bindings[command] ?? command.defaultShortcut }
}

extension CommandShortcut {
    var nativeKey: KeyEquivalent { KeyEquivalent(key.first ?? "?") }
    var nativeModifiers: EventModifiers {
        var value: EventModifiers = []
        if modifiers.contains(.command) { value.insert(.command) }
        if modifiers.contains(.shift) { value.insert(.shift) }
        if modifiers.contains(.option) { value.insert(.option) }
        if modifiers.contains(.control) { value.insert(.control) }
        return value
    }
}

struct MappedCommandButton: View {
    @Bindable var session: WorkspaceSession
    let command: FolioCommandID
    var body: some View {
        let key = session.shortcuts.shortcut(for: command)
        Button(command.title) { session.runCommand(command) }
            .keyboardShortcut(key.nativeKey, modifiers: key.nativeModifiers)
            .disabled(session.commandContext.disabledReason(for: command) != nil)
            .help(session.commandContext.disabledReason(for: command) ?? command.title)
    }
}
