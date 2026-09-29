import XCTest
@testable import FolioCore

final class WorkspaceLayoutPolicyTests: XCTestCase {
    func testSupportedMinimumWindowLeavesEveryPaneAtItsIdealWidth() {
        let layout = WorkspaceLayout.resolve(
            availableWidth: WorkspaceLayoutPolicy.minimumWindowWidth,
            showingExplorer: true,
            showingAssistant: true
        )
        XCTAssertEqual(layout.explorerWidth, WorkspaceLayoutPolicy.explorerIdealWidth)
        XCTAssertEqual(layout.assistantWidth, WorkspaceLayoutPolicy.assistantIdealWidth)
        XCTAssertGreaterThanOrEqual(layout.editorWidth, WorkspaceLayoutPolicy.minimumEditorWidth)
        XCTAssertFalse(layout.isCompact)
    }

    func testTheSmallestWindowIsChosenSoTheEditorRuleCanAlwaysHold() {
        let paneBudget = WorkspaceLayoutPolicy.explorerIdealWidth
            + WorkspaceLayoutPolicy.assistantIdealWidth
            + WorkspaceLayoutPolicy.dividerWidth * 2
        XCTAssertGreaterThanOrEqual(
            WorkspaceLayoutPolicy.minimumWindowWidth - paneBudget,
            WorkspaceLayoutPolicy.minimumEditorWidth
        )
    }

    /// Choosing Split is an explicit request, so at the smallest supported
    /// window the panes narrow slightly rather than Split being refused.
    func testChoosingSplitNarrowsThePanesInsteadOfBeingRefused() {
        let reserved = WorkspaceLayoutPolicy.minimumSplitWidth + WorkspaceLayoutPolicy.paneRoundingSlack
        let layout = WorkspaceLayout.resolve(
            availableWidth: WorkspaceLayoutPolicy.minimumWindowWidth,
            showingExplorer: true,
            showingAssistant: true,
            editorMinimumWidth: reserved
        )
        XCTAssertTrue(layout.allowsSplit)
        XCTAssertEqual(layout.editorWidth, reserved)
        XCTAssertGreaterThanOrEqual(layout.editorWidth, WorkspaceLayoutPolicy.minimumSplitWidth)
        XCTAssertEqual(layout.editorWidth, 605)
        XCTAssertGreaterThanOrEqual(layout.explorerWidth ?? .infinity, WorkspaceLayoutPolicy.explorerMinimumWidth)
        XCTAssertGreaterThanOrEqual(layout.assistantWidth ?? .infinity, WorkspaceLayoutPolicy.assistantMinimumWidth)
        XCTAssertFalse(layout.isCompact)
    }

    func testSplitStillFitsWhenBothPanesAreAtTheirMinimumWidth() {
        let narrowestSplit = WorkspaceLayoutPolicy.explorerMinimumWidth
            + WorkspaceLayoutPolicy.assistantMinimumWidth
            + WorkspaceLayoutPolicy.dividerWidth * 2
            + WorkspaceLayoutPolicy.minimumSplitWidth
            + WorkspaceLayoutPolicy.paneRoundingSlack
        XCTAssertLessThanOrEqual(narrowestSplit, WorkspaceLayoutPolicy.minimumWindowWidth)
    }

    func testWindowBelowTheSupportedMinimumStillNeverHidesAPane() {
        let layout = WorkspaceLayout.resolve(availableWidth: 800, showingExplorer: true, showingAssistant: true)
        XCTAssertEqual(layout.explorerWidth, WorkspaceLayoutPolicy.explorerMinimumWidth)
        XCTAssertEqual(layout.assistantWidth, WorkspaceLayoutPolicy.assistantMinimumWidth)
        XCTAssertEqual(layout.editorWidth, 800 - 200 - 220 - 2)
    }

    func testAssistantYieldsItsWidthBeforeTheExplorerDoes() {
        let layout = WorkspaceLayout.resolve(availableWidth: 880, showingExplorer: true, showingAssistant: true)
        XCTAssertEqual(layout.assistantWidth, WorkspaceLayoutPolicy.assistantMinimumWidth)
        XCTAssertEqual(layout.explorerWidth, WorkspaceLayoutPolicy.explorerIdealWidth - 2)
        XCTAssertEqual(layout.editorWidth, WorkspaceLayoutPolicy.minimumEditorWidth)
    }

    func testPanePreferencesAreHonouredExactly() {
        let none = WorkspaceLayout.resolve(availableWidth: 1040, showingExplorer: false, showingAssistant: false)
        XCTAssertNil(none.explorerWidth)
        XCTAssertNil(none.assistantWidth)
        XCTAssertEqual(none.editorWidth, 1040)

        let explorerOnly = WorkspaceLayout.resolve(availableWidth: 1040, showingExplorer: true, showingAssistant: false)
        XCTAssertEqual(explorerOnly.explorerWidth, WorkspaceLayoutPolicy.explorerIdealWidth)
        XCTAssertNil(explorerOnly.assistantWidth)
        XCTAssertEqual(explorerOnly.editorWidth, 1040 - 241)
    }

    /// The defect this policy replaces: crossing a width threshold used to move
    /// every control on screen. With a fixed pair of pane preferences the
    /// writing surface must only ever gain width.
    func testEditorWidthIsMonotonicWhileTheWindowGrows() {
        var previous = -1.0
        for width in stride(from: 120.0, through: 2600.0, by: 1.0) {
            let layout = WorkspaceLayout.resolve(availableWidth: width, showingExplorer: true, showingAssistant: true)
            XCTAssertGreaterThanOrEqual(layout.editorWidth, previous, "editor lost width at \(width)")
            XCTAssertLessThanOrEqual(layout.editorWidth, width)
            previous = layout.editorWidth
        }
    }

    func testNoPaneIsEverNarrowerThanItsMinimum() {
        for width in stride(from: 0.0, through: 2000.0, by: 5.0) {
            let layout = WorkspaceLayout.resolve(availableWidth: width, showingExplorer: true, showingAssistant: true)
            XCTAssertGreaterThanOrEqual(layout.explorerWidth ?? .infinity, WorkspaceLayoutPolicy.explorerMinimumWidth)
            XCTAssertGreaterThanOrEqual(layout.assistantWidth ?? .infinity, WorkspaceLayoutPolicy.assistantMinimumWidth)
            XCTAssertGreaterThanOrEqual(layout.editorWidth, 0)
        }
    }

    func testZeroWidthIsTotalRatherThanNegative() {
        let layout = WorkspaceLayout.resolve(availableWidth: 0, showingExplorer: true, showingAssistant: true)
        XCTAssertEqual(layout.explorerWidth, WorkspaceLayoutPolicy.explorerMinimumWidth)
        XCTAssertEqual(layout.assistantWidth, WorkspaceLayoutPolicy.assistantMinimumWidth)
        XCTAssertEqual(layout.editorWidth, 0)
        XCTAssertTrue(layout.isCompact)
    }

    func testSplitIsOfferedOnceTwoPanesAreUsable() {
        let justFits = EditorPaneLayout.resolve(
            availableWidth: WorkspaceLayoutPolicy.minimumSplitWidth,
            presentation: .split
        )
        XCTAssertEqual(justFits.arrangement, .split)
        XCTAssertFalse(justFits.splitFellBackToSource)
        XCTAssertGreaterThanOrEqual(justFits.sourceWidth, WorkspaceLayoutPolicy.minimumEditorPaneWidth)
        XCTAssertGreaterThanOrEqual(justFits.previewWidth, WorkspaceLayoutPolicy.minimumEditorPaneWidth)
        XCTAssertEqual(
            justFits.sourceWidth + justFits.previewWidth + WorkspaceLayoutPolicy.dividerWidth,
            WorkspaceLayoutPolicy.minimumSplitWidth
        )
    }

    func testSplitReflowsToSourceInsteadOfCollapsingBothPanes() {
        let narrow = EditorPaneLayout.resolve(
            availableWidth: WorkspaceLayoutPolicy.minimumSplitWidth - 1,
            presentation: .split
        )
        XCTAssertEqual(narrow.arrangement, .source)
        XCTAssertTrue(narrow.splitFellBackToSource)
        XCTAssertEqual(narrow.sourceWidth, WorkspaceLayoutPolicy.minimumSplitWidth - 1)
    }

    func testSplitPanesShareTheAreaEvenlyAtAnyUsableWidth() {
        for width in stride(from: WorkspaceLayoutPolicy.minimumSplitWidth, through: 1600.0, by: 7.0) {
            let layout = EditorPaneLayout.resolve(availableWidth: width, presentation: .split)
            XCTAssertEqual(layout.arrangement, .split)
            XCTAssertEqual(layout.sourceWidth + layout.previewWidth + WorkspaceLayoutPolicy.dividerWidth, width, accuracy: 0.0001)
            XCTAssertLessThanOrEqual(abs(layout.sourceWidth - layout.previewWidth), 0.5)
        }
    }

    func testSourceAndPreviewUseTheWholeArea() {
        for presentation in [EditorPresentation.source, .preview] {
            let layout = EditorPaneLayout.resolve(availableWidth: 730, presentation: presentation)
            XCTAssertEqual(layout.sourceWidth, 730)
            XCTAssertEqual(layout.previewWidth, 730)
            XCTAssertFalse(layout.splitFellBackToSource)
            XCTAssertEqual(layout.arrangement, presentation == .source ? .source : .preview)
        }
    }

    func testZeroWidthSplitAlsoReflowsInsteadOfProducingNegativePanes() {
        let layout = EditorPaneLayout.resolve(availableWidth: 0, presentation: .split)
        XCTAssertEqual(layout.arrangement, .source)
        XCTAssertTrue(layout.splitFellBackToSource)
        XCTAssertEqual(layout.sourceWidth, 0)
        XCTAssertEqual(layout.previewWidth, 0)
    }

    func testWindowSupportCheckMatchesTheEnforcedMinimum() {
        XCTAssertTrue(WorkspaceLayoutPolicy.isSupportedWindow(
            width: WorkspaceLayoutPolicy.minimumWindowWidth,
            height: WorkspaceLayoutPolicy.minimumWindowHeight
        ))
        XCTAssertFalse(WorkspaceLayoutPolicy.isSupportedWindow(
            width: WorkspaceLayoutPolicy.minimumWindowWidth - 1,
            height: WorkspaceLayoutPolicy.minimumWindowHeight
        ))
        XCTAssertFalse(WorkspaceLayoutPolicy.isSupportedWindow(
            width: WorkspaceLayoutPolicy.minimumWindowWidth,
            height: WorkspaceLayoutPolicy.minimumWindowHeight - 1
        ))
    }
}
