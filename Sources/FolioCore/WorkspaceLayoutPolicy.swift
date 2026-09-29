import Foundation

/// Native window and pane geometry, kept out of the SwiftUI views so the
/// shrink and fallback rules can be exercised without a window server.
///
/// These numbers are engineering minimums, not additional choices attributed
/// to the user. They exist for one reason: no control may be silently clipped
/// or pushed out of the window, and no pane may collapse to a width at which
/// its buttons stop being reachable.
///
/// `PaneVisibility.writingFirst(availableWidth:)` remains the earlier
/// width-threshold policy and is deliberately left unchanged for callers that
/// already depend on it. The workspace no longer uses it: hiding a pane because
/// a window crossed a threshold moved every control on screen, which is the
/// defect this policy replaces.
public struct WorkspaceLayoutPolicy {
    /// Smallest size the window may be resized to. The window scene is
    /// configured with `.contentMinSize`, so AppKit refuses the resize instead
    /// of clipping the content view and leaving controls unreachable.
    ///
    /// The width is what the reported defects needed: at 1040 the toolbar, both
    /// panes and two 300-point editor panes still fit, so nothing has to be
    /// hidden or squeezed. The height is the value that already worked before
    /// this policy, and it fits the smallest laptop displays Folio targets.
    public static let minimumWindowWidth: Double = 1040
    public static let minimumWindowHeight: Double = 640
    public static let defaultWindowWidth: Double = 1320
    public static let defaultWindowHeight: Double = 820

    /// A vertical `Divider` in an `HStack` occupies one point.
    public static let dividerWidth: Double = 1

    public static let explorerMinimumWidth: Double = 200
    public static let explorerIdealWidth: Double = 240
    public static let assistantMinimumWidth: Double = 220
    public static let assistantIdealWidth: Double = 250

    /// The writing surface never drops below this while panes are shown.
    public static let minimumEditorWidth: Double = 420
    /// A single editor pane narrower than this is not worth showing, so Split
    /// reports that it cannot fit instead of collapsing two panes to slivers.
    public static let minimumEditorPaneWidth: Double = 300
    public static let minimumSplitWidth: Double = minimumEditorPaneWidth * 2 + dividerWidth
    /// Extra width the workspace reserves when the user has chosen Split. The
    /// columns are laid out independently from the decision, so without this a
    /// sub-point rounding difference could make the workspace plan for two
    /// panes and the pane view then reflow to one.
    public static let paneRoundingSlack: Double = 4

    /// True for the smallest supported window, so the UI can promise that this
    /// size is usable rather than merely permitted.
    public static func isSupportedWindow(width: Double, height: Double) -> Bool {
        width >= minimumWindowWidth && height >= minimumWindowHeight
    }
}

/// The resolved widths of the workspace columns.
///
/// Invariant: for a fixed pair of pane preferences, `editorWidth` never
/// decreases when `availableWidth` grows, and no pane is ever narrower than its
/// minimum or collapsed by width. Panes only ever narrow toward their minimums,
/// so growing or shrinking the window cannot make a control jump across the
/// screen.
public struct WorkspaceLayout: Equatable, Sendable {
    public let availableWidth: Double
    /// `nil` only when the user asked for the pane to be hidden.
    public let explorerWidth: Double?
    /// `nil` only when the user asked for the pane to be hidden.
    public let assistantWidth: Double?
    public let editorWidth: Double

    /// Even the pane minimums could not leave the writing surface its minimum.
    /// `.contentMinSize` should make this unreachable; the flag keeps the UI
    /// honest if Folio is ever embedded somewhere narrower.
    public var isCompact: Bool { editorWidth < WorkspaceLayoutPolicy.minimumEditorWidth }
    /// The writing surface is wide enough for two usable editor panes.
    public var allowsSplit: Bool { editorWidth >= WorkspaceLayoutPolicy.minimumSplitWidth }
    public var showsExplorer: Bool { explorerWidth != nil }
    public var showsAssistant: Bool { assistantWidth != nil }

    /// - Parameter editorMinimumWidth: what the writing surface has to keep.
    ///   Pass `WorkspaceLayoutPolicy.minimumSplitWidth` while the user has chosen
    ///   Split, so an explicit request narrows the panes a little instead of
    ///   being refused. At the smallest supported window both panes together
    ///   still fit next to two usable editor panes.
    public static func resolve(
        availableWidth: Double,
        showingExplorer: Bool,
        showingAssistant: Bool,
        editorMinimumWidth: Double = WorkspaceLayoutPolicy.minimumEditorWidth
    ) -> WorkspaceLayout {
        let available = max(0, availableWidth)
        var explorer: Double? = showingExplorer ? WorkspaceLayoutPolicy.explorerIdealWidth : nil
        var assistant: Double? = showingAssistant ? WorkspaceLayoutPolicy.assistantIdealWidth : nil

        func used() -> Double {
            var total = 0.0
            if explorer != nil { total += WorkspaceLayoutPolicy.dividerWidth }
            if assistant != nil { total += WorkspaceLayoutPolicy.dividerWidth }
            total += explorer ?? 0
            total += assistant ?? 0
            return total
        }
        func editorWidth() -> Double { max(0, available - used()) }

        // Give back the shortfall from the assistant first, then the explorer:
        // the capture panel is the more peripheral of the two, and the writing
        // surface keeps its minimum before any pane drops below its own.
        var shortfall = editorMinimumWidth - editorWidth()
        if shortfall > 0, let width = assistant, width > WorkspaceLayoutPolicy.assistantMinimumWidth {
            let reduced = max(WorkspaceLayoutPolicy.assistantMinimumWidth, width - shortfall)
            shortfall -= width - reduced
            assistant = reduced
        }
        if shortfall > 0, let width = explorer, width > WorkspaceLayoutPolicy.explorerMinimumWidth {
            let reduced = max(WorkspaceLayoutPolicy.explorerMinimumWidth, width - shortfall)
            explorer = reduced
        }
        return WorkspaceLayout(
            availableWidth: available,
            explorerWidth: explorer,
            assistantWidth: assistant,
            editorWidth: editorWidth()
        )
    }
}

/// How the editor area itself is divided.
///
/// Split is only offered when two panes would each stay usable. Below that the
/// area reflows to a single pane and says so, instead of squeezing two panes
/// until neither can be read or clicked.
public struct EditorPaneLayout: Equatable, Sendable {
    public enum Arrangement: Equatable, Sendable { case source, preview, split }

    public let arrangement: Arrangement
    public let sourceWidth: Double
    public let previewWidth: Double
    /// The user asked for Split, the window is too narrow for two usable panes,
    /// and Source is being shown instead. The view must state this explicitly.
    public let splitFellBackToSource: Bool

    public static func resolve(
        availableWidth: Double,
        presentation: EditorPresentation
    ) -> EditorPaneLayout {
        let available = max(0, availableWidth)
        switch presentation {
        case .source:
            return EditorPaneLayout(arrangement: .source, sourceWidth: available,
                                    previewWidth: available, splitFellBackToSource: false)
        case .preview:
            return EditorPaneLayout(arrangement: .preview, sourceWidth: available,
                                    previewWidth: available, splitFellBackToSource: false)
        case .split:
            guard available >= WorkspaceLayoutPolicy.minimumSplitWidth else {
                return EditorPaneLayout(arrangement: .source, sourceWidth: available,
                                        previewWidth: available, splitFellBackToSource: true)
            }
            let source = (available - WorkspaceLayoutPolicy.dividerWidth) / 2
            let preview = available - WorkspaceLayoutPolicy.dividerWidth - source
            return EditorPaneLayout(arrangement: .split, sourceWidth: source,
                                    previewWidth: preview, splitFellBackToSource: false)
        }
    }
}
