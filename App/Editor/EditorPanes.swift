import SwiftUI
import FolioCore

/// Source remains mounted in all modes so merely switching presentation does not
/// destroy its NSTextView, selection or undo manager. Native runtime proof is
/// still required; this is deliberately not a second web-based editor.
///
/// Pane widths come from `EditorPaneLayout`. Split is offered only while two
/// panes would each stay usable; below that the area reflows to a single Source
/// pane and says why, instead of squeezing both panes until neither can be read
/// or clicked. The Source editor stays mounted in every mode, so the fallback
/// does not discard the text view.
struct EditorPanes: View {
    @Bindable var session: WorkspaceSession
    @Bindable var document: OpenNoteDocument

    /// The fallback banner is deliberately a fixed height so the pane height can
    /// be computed exactly from the measured area rather than guessed.
    private let fallbackNoticeHeight: CGFloat = 34

    var body: some View {
        GeometryReader { geometry in
            let layout = EditorPaneLayout.resolve(
                availableWidth: geometry.size.width,
                presentation: document.editorPresentation
            )
            let inNotes = session.workspaceSection == .notes
            let sourceVisible = layout.arrangement != .preview && inNotes
            let previewVisible = layout.arrangement != .source && inNotes
            let paneHeight = max(0, geometry.size.height - (layout.splitFellBackToSource ? fallbackNoticeHeight : 0))

            VStack(spacing: 0) {
                if layout.splitFellBackToSource { fallbackNotice }
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
                    .frame(width: layout.sourceWidth, height: paneHeight)
                    .clipped()
                    .opacity(sourceVisible ? 1 : 0)
                    .allowsHitTesting(sourceVisible)
                    .accessibilityHidden(!sourceVisible)

                    MarkdownPreviewView(document: document, session: session, isVisible: previewVisible)
                        .frame(width: layout.previewWidth, height: paneHeight)
                        .clipped()
                        .offset(x: layout.arrangement == .split ? layout.sourceWidth + WorkspaceLayoutPolicy.dividerWidth : 0)
                        .opacity(previewVisible ? 1 : 0)
                        .allowsHitTesting(previewVisible)
                        .accessibilityHidden(!previewVisible)

                    if layout.arrangement == .split {
                        Divider()
                            .frame(width: WorkspaceLayoutPolicy.dividerWidth, height: paneHeight)
                            .offset(x: layout.sourceWidth)
                            .allowsHitTesting(false)
                    }
                }
                .frame(width: geometry.size.width, height: paneHeight, alignment: .leading)
                .clipped()
                Spacer(minLength: 0)
            }
        }
    }

    private var fallbackNotice: some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.split.2x1")
            Text("Split needs a wider window — showing Source.")
                .lineLimit(1)
                .layoutPriority(-1)
            Spacer(minLength: 8)
            Button("Preview") { document.editorPresentation = .preview }
                .controlSize(.small)
                .fixedSize()
            Button("Hide Panels") {
                session.showsExplorer = false
                session.showsAssistant = false
            }
            .controlSize(.small)
            .fixedSize()
            .disabled(!session.showsExplorer && !session.showsAssistant)
        }
        .font(.caption)
        .padding(.horizontal, 14)
        .frame(height: fallbackNoticeHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FolioStyle.gold.opacity(0.1))
        .help("Two editor panes each need at least \(Int(WorkspaceLayoutPolicy.minimumEditorPaneWidth)) points. Widen the window, hide the project sidebar or capture panel from the Workspace menu or the toolbar's More menu, or keep writing in Source.")
    }
}
