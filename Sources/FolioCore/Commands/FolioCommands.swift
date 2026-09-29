import Foundation

public enum FolioCommandID: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case openProject, newNote, save, searchNotes, commandPalette, capture
    case showSource, showPreview, showSplit, followCursor
    case refresh, recovery, showLauncher, rebuildSearch, repairLinks
    case showRoadmap, showConnections, newRoadmapItem, undoRoadmap, redoRoadmap
    public var id: Self { self }
    public var title: String {
        switch self {
        case .openProject: "Open Project Folder…"
        case .newNote: "New Note…"
        case .save: "Save Note"
        case .searchNotes: "Search Notes…"
        case .commandPalette: "Command Palette…"
        case .capture: "Open Capture Composer…"
        case .showSource: "Editor: Source"
        case .showPreview: "Editor: Preview"
        case .showSplit: "Editor: Split"
        case .followCursor: "Preview: Follow Cursor"
        case .refresh: "Refresh Project"
        case .recovery: "Review Recovery Copies…"
        case .showLauncher: "Show Launcher"
        case .rebuildSearch: "Rebuild Search Cache"
        case .repairLinks: "Repair Note Links…"
        case .showRoadmap: "Open Roadmap"
        case .showConnections: "Open Connections Graph"
        case .newRoadmapItem: "New Roadmap Item…"
        case .undoRoadmap: "Undo Roadmap Change"
        case .redoRoadmap: "Redo Roadmap Change"
        }
    }
    public var keywords: String {
        switch self {
        case .openProject: "vault folder workspace"
        case .newNote: "create markdown title location"
        case .save: "write flush local"
        case .searchNotes: "find full text title tags"
        case .commandPalette: "actions commands"
        case .capture: "local AI text transcript context review"
        case .showSource: "markdown raw edit"
        case .showPreview: "reading render markdown"
        case .showSplit: "side by side reading writing"
        case .followCursor: "jump selection paragraph preview"
        case .refresh: "rescan external changes"
        case .recovery: "conflict preserved journal"
        case .showLauncher: "home modules"
        case .rebuildSearch: "index reset derived cache"
        case .repairLinks: "link broken missing ambiguous fix repair wikilink"
        case .showRoadmap: "planning timeline kanban"
        case .showConnections: "graph links neighbourhood 2d 3d"
        case .newRoadmapItem: "create task milestone dates"
        case .undoRoadmap: "planning undo"
        case .redoRoadmap: "planning redo"
        }
    }
    public var defaultShortcut: CommandShortcut {
        switch self {
        case .openProject: .init(key: "o", modifiers: [.command])
        case .newNote: .init(key: "n", modifiers: [.command])
        case .save: .init(key: "s", modifiers: [.command])
        case .searchNotes: .init(key: "f", modifiers: [.command, .shift])
        case .commandPalette: .init(key: "p", modifiers: [.command, .shift])
        case .capture: .init(key: "k", modifiers: [.command, .option, .shift])
        case .showSource: .init(key: "1", modifiers: [.command, .option])
        case .showPreview: .init(key: "2", modifiers: [.command, .option])
        case .showSplit: .init(key: "3", modifiers: [.command, .option])
        case .followCursor: .init(key: "l", modifiers: [.command, .option])
        case .refresh: .init(key: "r", modifiers: [.command, .shift])
        case .recovery: .init(key: "u", modifiers: [.command, .shift])
        case .showLauncher: .init(key: "l", modifiers: [.command, .shift])
        case .rebuildSearch: .init(key: "f", modifiers: [.command, .option, .shift])
        case .repairLinks: .init(key: "e", modifiers: [.command, .shift])
        case .showRoadmap: .init(key: "r", modifiers: [.command, .option])
        case .showConnections: .init(key: "g", modifiers: [.command, .option])
        case .newRoadmapItem: .init(key: "n", modifiers: [.command, .option, .shift])
        case .undoRoadmap: .init(key: "u", modifiers: [.command, .option])
        case .redoRoadmap: .init(key: "u", modifiers: [.command, .option, .shift])
        }
    }
}

public struct CommandContext: Sendable {
    public var hasProject: Bool
    public var hasNote: Bool
    public var busy: Bool
    public var editorMode: EditorPresentation
    public var canUndoRoadmap: Bool
    public var canRedoRoadmap: Bool
    public init(hasProject: Bool, hasNote: Bool, busy: Bool, editorMode: EditorPresentation = .source, canUndoRoadmap: Bool = false, canRedoRoadmap: Bool = false) {
        self.hasProject = hasProject; self.hasNote = hasNote; self.busy = busy; self.editorMode = editorMode
        self.canUndoRoadmap = canUndoRoadmap; self.canRedoRoadmap = canRedoRoadmap
    }
    public func disabledReason(for command: FolioCommandID) -> String? {
        if busy && command != .showLauncher && command != .commandPalette { return "Finish the current project operation first." }
        switch command {
        case .openProject, .showLauncher, .commandPalette: return nil
        case .newNote, .searchNotes, .refresh, .recovery, .rebuildSearch, .showRoadmap, .showConnections, .newRoadmapItem: return hasProject ? nil : "Open a project first."
        case .save, .showSource, .showPreview, .showSplit, .capture, .repairLinks: return hasNote ? nil : "Open a note first."
        case .undoRoadmap: return canUndoRoadmap ? nil : "There is no available roadmap undo."
        case .redoRoadmap: return canRedoRoadmap ? nil : "There is no available roadmap redo."
        case .followCursor:
            if !hasNote { return "Open a note first." }
            return editorMode == .source ? "Open Preview or Split first." : nil
        }
    }
}
public enum CommandCatalog {
    public static func matches(_ query: String) -> [FolioCommandID] {
        let q = NoteSearchQuery.fold(String(query.prefix(256))).trimmingCharacters(in: .whitespacesAndNewlines)
        let terms = q.split(whereSeparator: \.isWhitespace).map(String.init)
        return FolioCommandID.allCases.filter { command in
            let haystack = NoteSearchQuery.fold(command.title + " " + command.keywords)
            return terms.allSatisfy { haystack.contains($0) }
        }.sorted {
            let a = NoteSearchQuery.fold($0.title), b = NoteSearchQuery.fold($1.title)
            if a.hasPrefix(q) != b.hasPrefix(q) { return a.hasPrefix(q) }
            return $0.title < $1.title
        }
    }
}

public struct CommandModifiers: OptionSet, Hashable, Codable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let command = Self(rawValue: 1)
    public static let shift = Self(rawValue: 2)
    public static let option = Self(rawValue: 4)
    public static let control = Self(rawValue: 8)
}
public struct CommandShortcut: Hashable, Codable, Sendable {
    public var key: String
    public var modifiers: CommandModifiers
    public init(key: String, modifiers: CommandModifiers) { self.key = key.lowercased(); self.modifiers = modifiers }
    public var label: String {
        (modifiers.contains(.control) ? "⌃" : "") + (modifiers.contains(.option) ? "⌥" : "") +
        (modifiers.contains(.shift) ? "⇧" : "") + (modifiers.contains(.command) ? "⌘" : "") + key.uppercased()
    }
}
public enum ShortcutError: Error, LocalizedError, Equatable {
    case invalidKey, reserved, duplicate(String)
    public var errorDescription: String? {
        switch self {
        case .invalidKey: "Choose one ASCII letter/digit and include Command."
        case .reserved: "That shortcut belongs to native editing, accessibility or system navigation."
        case .duplicate(let title): "That shortcut is already assigned to \(title)."
        }
    }
}
public enum ShortcutPolicy {
    public static var defaults: [FolioCommandID: CommandShortcut] {
        Dictionary(uniqueKeysWithValues: FolioCommandID.allCases.map { ($0, $0.defaultShortcut) })
    }
    public static func validate(_ shortcut: CommandShortcut, for command: FolioCommandID,
                                in bindings: [FolioCommandID: CommandShortcut]) throws {
        guard shortcut.key.utf8.count == 1, let c = shortcut.key.unicodeScalars.first,
              CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789").contains(c),
              shortcut.modifiers.contains(.command), shortcut.modifiers.rawValue & ~15 == 0 else { throw ShortcutError.invalidKey }
        // Preserve cut/copy/paste/select-all/undo variants, native in-note Find,
        // app/window navigation and VoiceOver's Control-Option chord.
        if ["c", "v", "x", "a", "z", "q", "w", "h", "m"].contains(shortcut.key) { throw ShortcutError.reserved }
        if shortcut.key == "f" && shortcut.modifiers == [.command] { throw ShortcutError.reserved }
        if shortcut.modifiers.contains([.control, .option]) { throw ShortcutError.reserved }
        for (other, assigned) in bindings where other != command && assigned == shortcut { throw ShortcutError.duplicate(other.title) }
    }
    public static func validated(_ candidate: [FolioCommandID: CommandShortcut]) throws -> [FolioCommandID: CommandShortcut] {
        var complete = defaults
        for (command, shortcut) in candidate { complete[command] = shortcut }
        for (command, shortcut) in complete { try validate(shortcut, for: command, in: complete) }
        return complete
    }
}
