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

struct KnownProjectIdentity: Codable {
    let projectID: UUID
    let rootIdentity: String
    let name: String
}
