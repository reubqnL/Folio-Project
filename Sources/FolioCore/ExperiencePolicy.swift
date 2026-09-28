import Foundation

/// Confirmed personal choices 01–04. Unanswered choices are deliberately absent.
public struct ExperiencePolicy: Equatable, Sendable {
    public let alwaysShowLauncher = true
    public let editorHasLayoutPriority = true
    public let requireTitleAndLocation = true
    public let showNonblockingPasteNotice = true
    public init() {}
}

public struct PaneVisibility: Equatable, Sendable {
    public let explorer: Bool
    public let assistant: Bool

    /// Provisional engineering thresholds: assistant collapses before explorer.
    /// They are not additional choices attributed to the user.
    public static func writingFirst(availableWidth: Double) -> PaneVisibility {
        if availableWidth >= 1280 { return .init(explorer: true, assistant: true) }
        if availableWidth >= 1040 { return .init(explorer: true, assistant: false) }
        return .init(explorer: false, assistant: false)
    }
}

public enum NoteCreationError: Error, LocalizedError, Equatable, Sendable {
    case emptyTitle, invalidTitle, invalidFolder
    public var errorDescription: String? {
        switch self {
        case .emptyTitle: "Give the note a title before creating it."
        case .invalidTitle: "Use a title without path separators or control characters."
        case .invalidFolder: "Choose a relative folder, such as Notes or Projects/Folio; do not use dot segments."
        }
    }
}

/// A draft is not a filesystem save. Disk-backed document identity comes later.
public struct DraftNote: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let title: String
    public let relativeFolder: String
    public var markdown: String

    public init(title: String, relativeFolder: String) throws {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = relativeFolder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { throw NoteCreationError.emptyTitle }
        let separators = CharacterSet(charactersIn: "/\\:")
        guard cleanTitle != ".", cleanTitle != "..",
              cleanTitle.rangeOfCharacter(from: separators.union(.controlCharacters)) == nil
        else { throw NoteCreationError.invalidTitle }
        let components = folder.split(separator: "/", omittingEmptySubsequences: false)
        guard !folder.isEmpty, !folder.hasPrefix("/"), !folder.hasSuffix("/"),
              folder.rangeOfCharacter(from: CharacterSet(charactersIn: "\\:").union(.controlCharacters)) == nil,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else { throw NoteCreationError.invalidFolder }
        self.id = UUID()
        self.title = cleanTitle
        self.relativeFolder = folder
        self.markdown = "# \(cleanTitle)\n\n"
    }
}
