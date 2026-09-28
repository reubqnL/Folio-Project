import SwiftUI
import FolioCore

/// Source remains mounted in all modes so merely switching presentation does not
/// destroy its NSTextView, selection or undo manager. Native runtime proof is
/// still required; this is deliberately not a second web-based editor.
struct EditorPanes: View {
    @Bindable var session: WorkspaceSession
    @Bindable var document: OpenNoteDocument
    var body: some View {
        GeometryReader { geometry in
            let split = document.editorPresentation == .split
            let sourceVisible = document.editorPresentation != .preview && session.workspaceSection == .notes
            let previewVisible = document.editorPresentation != .source && session.workspaceSection == .notes
            let width = split ? geometry.size.width / 2 : geometry.size.width
            ZStack(alignment: .leading) {
                NativeMarkdownEditor(
                    documentID: document.id,
                    text: session.textBinding(for: document),
                    selection: Binding(get: { document.selectedRange }, set: { document.selectedRange = $0 }),
                    resetUndoToken: document.resetUndoToken,
                    isEditable: !session.isOpening && !document.isResolvingConflict && sourceVisible,
                    isVisible: sourceVisible,
                    findRequest: session.findInNoteRequest,
                    pendingCaptureEdit: document.pendingCaptureEdit,
                    currentCaptureTarget: { try session.captureSnapshot(for: document) },
                    captureMutationFinished: { id, error in session.captureMutationFinished(documentID: document.id, commandID: id, error: error) },
                    onUserEdit: { session.clearPasteNotice() },
                    onConvertedPaste: { message, editor in
                        session.showPasteNotice(message, undo: { [weak editor] in editor?.undoManager?.undo() })
                    }
                )
                .frame(width: width, height: geometry.size.height)
                .opacity(sourceVisible ? 1 : 0).allowsHitTesting(sourceVisible).accessibilityHidden(!sourceVisible)
                MarkdownPreviewView(document: document, session: session, isVisible: previewVisible)
                    .frame(width: width, height: geometry.size.height)
                    .offset(x: split ? width : 0)
                    .opacity(previewVisible ? 1 : 0).allowsHitTesting(previewVisible).accessibilityHidden(!previewVisible)
                if split { Divider().frame(width: 1, height: geometry.size.height).offset(x: width) }
            }.clipped()
        }
    }
}
