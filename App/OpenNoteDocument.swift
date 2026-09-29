import Foundation
import Observation
import FolioCore

@MainActor
@Observable
final class OpenNoteDocument: Identifiable {
    let id: UUID
    let editorInstanceID = UUID()
    var pendingCaptureEdit: CaptureTextEdit?
    var baseline: VaultSnapshot
    var text: String
    var editGeneration = 0
    var committedGeneration = 0
    var firstDirtyTime: Double?
    var lastWriteConfirmed = false
    var isSaving = false
    var isResolvingConflict = false
    var conflict: VaultConflict?
    var failure: String?
    var resetUndoToken = UUID()
    var selectedRange = NSRange(location: 0, length: 0)
    var editorPresentation: EditorPresentation = .source
    var previewRequest: PreviewFollowRequest?
    var consumedPreviewRequest: UUID?

    init(_ snapshot: VaultSnapshot, justWritten: Bool = false) {
        id = snapshot.note.id; baseline = snapshot; text = snapshot.markdown; lastWriteConfirmed = justWritten
    }
    var isDirty: Bool { editGeneration != committedGeneration }
    /// N01 durability state derived from the document flags. The status line
    /// shows only this model's labels so queued or timed work can never be
    /// displayed as saved.
    var durability: VaultDurability {
        VaultDurability.resolve(
            conflict: conflict != nil,
            failure: failure,
            isSaving: isSaving,
            isDirty: isDirty,
            lastWriteConfirmed: lastWriteConfirmed
        )
    }
    var status: String { durability.label }
    var statusExplanation: String { durability.explanation }
    func reload(_ snapshot: VaultSnapshot) {
        baseline = snapshot; text = snapshot.markdown
        editGeneration += 1; committedGeneration = editGeneration
        firstDirtyTime = nil; conflict = nil; failure = nil; lastWriteConfirmed = false
        resetUndoToken = UUID()
    }
}

struct NoteCreationSeed {
    let title: String
    let folder: String
    let markdown: String
}

/// A project Folio has opened before, so it can be offered in Open Recent.
///
/// The folder is remembered as a security-scoped bookmark rather than a path:
/// this build is sandboxed, so only a user-selected URL — or a bookmark derived
/// from one — carries permission to read the folder again. `folderPath` is kept
/// separately and is used only for display.
struct KnownProjectIdentity: Codable, Identifiable {
    let projectID: UUID
    let rootIdentity: String
    let name: String
    /// `var` with no default: entries written before Open Recent existed decode
    /// with this key absent, which `Codable` maps to `nil` rather than failing.
    var bookmark: Data?
    var folderPath: String?

    var id: UUID { projectID }

    /// Turns the stored bookmark back into a folder URL.
    ///
    /// Returns `nil` when the project was recorded by a build that did not save
    /// a bookmark, when the folder has been moved or deleted, or when the
    /// bookmark can no longer be resolved.
    func resolveFolderURL() -> URL? {
        guard let bookmark else { return nil }
        var stale = false
        let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        return url
    }
}

