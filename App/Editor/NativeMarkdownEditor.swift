import SwiftUI
import AppKit
import FolioCore

/// Native text-input spike, not a completed Markdown editor.
/// Do not access `layoutManager`: that can opt a text view into legacy TextKit.
@MainActor
struct NativeMarkdownEditor: NSViewRepresentable {
    let documentID: UUID
    @Binding var text: String
    @Binding var selection: NSRange
    let resetUndoToken: UUID
    let isEditable: Bool
    let isVisible: Bool
    let findRequest: UUID?
    let pendingCaptureEdit: CaptureTextEdit?
    var currentCaptureTarget: () throws -> CaptureTargetSnapshot
    var captureMutationFinished: (UUID, String?) -> Void
    var onUserEdit: () -> Void
    var onConvertedPaste: (String, NSTextView) -> Void
    @AppStorage("editorPointSize") private var editorPointSize = EditorPreferences.defaultPointSize
    @Environment(\.colorSchemeContrast) private var contrast

    private var pointSize: CGFloat { CGFloat(EditorPreferences.clampedPointSize(editorPointSize)) }
    private var foregroundColor: NSColor {
        contrast == .increased ? .white : NSColor(calibratedWhite: 0.88, alpha: 1)
    }

    init(
        documentID: UUID,
        text: Binding<String>,
        selection: Binding<NSRange>,
        resetUndoToken: UUID,
        isEditable: Bool,
        isVisible: Bool,
        findRequest: UUID?,
        pendingCaptureEdit: CaptureTextEdit?,
        currentCaptureTarget: @escaping () throws -> CaptureTargetSnapshot,
        captureMutationFinished: @escaping (UUID, String?) -> Void,
        onUserEdit: @escaping () -> Void,
        onConvertedPaste: @escaping (String, NSTextView) -> Void
    ) {
        self.documentID = documentID
        self._text = text
        self._selection = selection
        self.resetUndoToken = resetUndoToken
        self.isEditable = isEditable
        self.isVisible = isVisible
        self.findRequest = findRequest
        self.pendingCaptureEdit = pendingCaptureEdit
        self.currentCaptureTarget = currentCaptureTarget
        self.captureMutationFinished = captureMutationFinished
        self.onUserEdit = onUserEdit
        self.onConvertedPaste = onConvertedPaste
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false

        let editor = PasteAwareTextView(usingTextLayoutManager: true)
        editor.isRichText = false
        editor.allowsUndo = true
        editor.usesFindBar = true
        editor.isIncrementalSearchingEnabled = true
        editor.isEditable = isEditable
        editor.isSelectable = true
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.minSize = NSSize(width: 0, height: 0)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainerInset = NSSize(width: 28, height: 24)
        editor.font = .monospacedSystemFont(ofSize: pointSize, weight: .regular)
        editor.textColor = foregroundColor
        editor.backgroundColor = NSColor(calibratedRed: 0.11, green: 0.118, blue: 0.141, alpha: 1)
        editor.insertionPointColor = .white
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticLinkDetectionEnabled = false
        editor.string = text
        editor.setSelectedRange(clamped(selection, length: (text as NSString).length))
        editor.delegate = context.coordinator
        editor.setAccessibilityLabel("Markdown source editor")
        editor.convertedPaste = { [weak coordinator = context.coordinator] message, view in
            coordinator?.parent.onConvertedPaste(message, view)
        }
        scroll.documentView = editor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? PasteAwareTextView else { return }
        context.coordinator.applyingModel = true
        defer { context.coordinator.applyingModel = false }
        if editor.font?.pointSize != pointSize {
            editor.font = .monospacedSystemFont(ofSize: pointSize, weight: .regular)
        }
        if editor.textColor != foregroundColor { editor.textColor = foregroundColor }
        editor.isEditable = isEditable
        if let edit = pendingCaptureEdit, edit.id != context.coordinator.lastScheduledCapture {
            context.coordinator.lastScheduledCapture = edit.id
            let coordinator = context.coordinator
            Task { @MainActor [weak coordinator, weak editor] in
                guard let coordinator, let editor else { return }
                coordinator.applyCapture(edit, to: editor)
            }
        }
        if !isVisible, editor.window?.firstResponder === editor { editor.window?.makeFirstResponder(nil) }
        if let findRequest, findRequest != context.coordinator.lastFindRequest, isVisible {
            context.coordinator.lastFindRequest = findRequest
            editor.window?.makeFirstResponder(editor)
            let item = NSMenuItem(title: "Find", action: nil, keyEquivalent: "")
            item.tag = Int(NSTextFinder.Action.showFindInterface.rawValue)
            editor.performFindPanelAction(item)
        }
        // Do not replace a native IME's provisional composition with the last
        // committed binding value during an unrelated SwiftUI update.
        if editor.hasMarkedText() { return }
        let changedDocument = context.coordinator.documentID != documentID
        let resetHistory = context.coordinator.resetUndoToken != resetUndoToken
        guard changedDocument || resetHistory || editor.string != text else { return }
        let oldSelection = changedDocument ? selection : editor.selectedRange()
        editor.string = text
        if changedDocument || resetHistory {
            editor.undoManager?.removeAllActions()
            let range = clamped(oldSelection, length: (text as NSString).length)
            editor.setSelectedRange(range)
            editor.scrollRangeToVisible(range)
            context.coordinator.documentID = documentID
            context.coordinator.resetUndoToken = resetUndoToken
        } else {
            let count = (text as NSString).length
            let location = min(oldSelection.location, count)
            editor.setSelectedRange(NSRange(location: location, length: min(oldSelection.length, count - location)))
        }
    }

    private func clamped(_ range: NSRange, length: Int) -> NSRange {
        let location = min(range.location, length)
        return NSRange(location: location, length: min(range.length, length - location))
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NativeMarkdownEditor
        var documentID: UUID
        var resetUndoToken: UUID
        var applyingModel = false
        var applyingCapture = false
        var lastFindRequest: UUID?
        var lastScheduledCapture: UUID?
        init(_ parent: NativeMarkdownEditor) {
            self.parent = parent
            self.documentID = parent.documentID
            self.resetUndoToken = parent.resetUndoToken
        }
        func applyCapture(_ edit: CaptureTextEdit, to editor: NSTextView) {
            guard parent.pendingCaptureEdit?.id == edit.id else { return }
            do {
                guard parent.isVisible, editor.isEditable, editor.window != nil, !editor.hasMarkedText() else { throw CaptureError.wrongTarget }
                let current = try parent.currentCaptureTarget()
                guard current.text == editor.string else { throw CaptureError.staleTarget }
                try edit.validate(current: current)
                let range = NSRange(location: edit.range.location, length: edit.range.length)
                let oldSelection = editor.selectedRange()
                applyingCapture = true
                defer { applyingCapture = false }
                editor.breakUndoCoalescing()
                let undo = editor.undoManager
                undo?.beginUndoGrouping()
                editor.insertText(edit.replacement, replacementRange: range)
                undo?.endUndoGrouping()
                undo?.setActionName("Capture Review Change")
                editor.breakUndoCoalescing()
                guard ContentDigest.sha256(Data(editor.string.utf8)) == edit.afterDigest else {
                    // Do not let an unexpected native transformation reach the
                    // autosave binding. Roll back while delegate forwarding is
                    // suppressed; Mac runtime tests must exercise this path.
                    if undo?.canUndo == true { undo?.undo() }
                    if editor.string != current.text { editor.string = current.text; undo?.removeAllActions() }
                    editor.setSelectedRange(oldSelection)
                    throw CaptureError.invalidApproval
                }
                // TextKit normally posts its change notification synchronously.
                // Keep the bound model synchronized exactly once if it did not.
                if parent.text != editor.string { parent.onUserEdit(); parent.text = editor.string }
                parent.selection = editor.selectedRange()
                parent.captureMutationFinished(edit.id, nil)
            } catch { parent.captureMutationFinished(edit.id, error.localizedDescription) }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !applyingModel, !applyingCapture, let view = notification.object as? NSTextView else { return }
            parent.selection = view.selectedRange()
        }
        func textDidChange(_ notification: Notification) {
            guard !applyingModel, !applyingCapture, let view = notification.object as? NSTextView, !view.hasMarkedText() else { return }
            // An intervening edit invalidates the one-click paste-undo notice.
            // Native Command-Z remains available through NSTextView's undo stack.
            parent.onUserEdit()
            parent.text = view.string
        }
    }
}

@MainActor
final class PasteAwareTextView: NSTextView {
    var convertedPaste: ((String, NSTextView) -> Void)?

    override func paste(_ sender: Any?) {
        let clipboard = NSPasteboard.general
        let hasRTF = clipboard.availableType(from: [.rtf]) != nil
        let hasHTML = clipboard.availableType(from: [.html]) != nil
        guard hasRTF || hasHTML else { super.paste(sender); return }

        let output: PasteConversion
        if let data = clipboard.data(forType: .rtf), data.count <= 1_048_576,
           let attributed = try? NSAttributedString(
               data: data,
               options: [.documentType: NSAttributedString.DocumentType.rtf],
               documentAttributes: nil
           ) {
            output = MarkdownPasteConverter.convert(attributed)
        } else if let plain = clipboard.string(forType: .string) {
            // Deliberately do not invoke an HTML/WebKit importer on untrusted
            // clipboard content: it can introduce resource-loading behaviour.
            output = PasteConversion(
                markdown: plain,
                notice: "Pasted as plain Markdown. HTML or oversized rich-text formatting is not supported yet."
            )
        } else {
            NSSound.beep()
            return
        }
        guard !output.markdown.isEmpty else { NSSound.beep(); return }
        breakUndoCoalescing()
        undoManager?.beginUndoGrouping()
        insertText(output.markdown, replacementRange: selectedRange())
        undoManager?.endUndoGrouping()
        undoManager?.setActionName("Paste as Markdown")
        breakUndoCoalescing()
        convertedPaste?(output.notice, self)
    }
}

struct PasteConversion {
    let markdown: String
    let notice: String
}

/// Intentionally small supported subset for the first editor spike:
/// bold, italic, links and line breaks. Lists/tables/headings need fixtures
/// and a fuller converter before this can be labelled production-ready.
@MainActor
enum MarkdownPasteConverter {
    static func convert(_ input: NSAttributedString) -> PasteConversion {
        let source = input.string as NSString
        var result = ""
        var omittedAttachment = false
        input.enumerateAttributes(in: NSRange(location: 0, length: input.length), options: []) { attributes, range, _ in
            if attributes[.attachment] != nil {
                omittedAttachment = true
                return
            }
            let original = source.substring(with: range)
            var fragment = escapeInline(original)
            if let font = attributes[.font] as? NSFont {
                let traits = font.fontDescriptor.symbolicTraits
                let marker = (traits.contains(.bold) ? "**" : "") + (traits.contains(.italic) ? "*" : "")
                if !marker.isEmpty {
                    fragment = fragment.components(separatedBy: "\n").map { line in
                        line.trimmingCharacters(in: .whitespaces).isEmpty ? line : marker + line + marker
                    }.joined(separator: "\n")
                }
            }
            let url: URL?
            if let value = attributes[.link] as? URL { url = value }
            else if let value = attributes[.link] as? String { url = URL(string: value) }
            else { url = nil }
            if let url, ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                let destination = url.absoluteString
                    .replacingOccurrences(of: "(", with: "%28")
                    .replacingOccurrences(of: ")", with: "%29")
                    .replacingOccurrences(of: " ", with: "%20")
                fragment = "[\(fragment)](\(destination))"
            }
            result += fragment
        }
        let extra = omittedAttachment ? " Attachments were omitted; keep the original source." : ""
        return PasteConversion(
            markdown: result,
            notice: "Converted supported rich text to Markdown. Complex layout is not preserved yet." + extra
        )
    }

    private static func escapeInline(_ text: String) -> String {
        var result = text.replacingOccurrences(of: "\\", with: "\\\\")
        for character in ["*", "_", "`", "[", "]"] {
            result = result.replacingOccurrences(of: character, with: "\\" + character)
        }
        return result
    }
}
