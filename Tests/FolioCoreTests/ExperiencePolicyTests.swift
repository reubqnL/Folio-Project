import XCTest
@testable import FolioCore

final class ExperiencePolicyTests: XCTestCase {
    func testConfirmedChoicesAreExplicit() {
        let policy = ExperiencePolicy()
        XCTAssertTrue(policy.alwaysShowLauncher)
        XCTAssertTrue(policy.editorHasLayoutPriority)
        XCTAssertTrue(policy.requireTitleAndLocation)
        XCTAssertTrue(policy.showNonblockingPasteNotice)
    }
    func testWideLayoutShowsAllPanes() {
        let layout = PaneVisibility.writingFirst(availableWidth: 1440)
        XCTAssertTrue(layout.explorer)
        XCTAssertTrue(layout.assistant)
    }
    func testAssistantCollapsesFirst() {
        let layout = PaneVisibility.writingFirst(availableWidth: 1180)
        XCTAssertTrue(layout.explorer)
        XCTAssertFalse(layout.assistant)
    }
    func testCompactLayoutPrioritizesWriting() {
        let layout = PaneVisibility.writingFirst(availableWidth: 960)
        XCTAssertFalse(layout.explorer)
        XCTAssertFalse(layout.assistant)
    }
    func testThresholdBoundaries() {
        XCTAssertFalse(PaneVisibility.writingFirst(availableWidth: 1279).assistant)
        XCTAssertTrue(PaneVisibility.writingFirst(availableWidth: 1280).assistant)
        XCTAssertFalse(PaneVisibility.writingFirst(availableWidth: 1039).explorer)
        XCTAssertTrue(PaneVisibility.writingFirst(availableWidth: 1040).explorer)
    }
    func testExplicitTitleAndFolderCreateOnlyADraft() throws {
        let draft = try DraftNote(title: "  First thought  ", relativeFolder: "Projects/Folio")
        XCTAssertEqual(draft.title, "First thought")
        XCTAssertEqual(draft.relativeFolder, "Projects/Folio")
        XCTAssertEqual(draft.markdown, "# First thought\n\n")
    }
    func testMissingOrUnsafeTitleIsRejected() {
        for title in ["", "  ", ".", "..", "one/two", "one\\two", "one\u{0000}two"] {
            XCTAssertThrowsError(try DraftNote(title: title, relativeFolder: "Notes"))
        }
    }
    func testAbsoluteTraversalAndEmptyFolderSegmentsAreRejected() {
        for folder in ["", "/tmp", "../Notes", "Notes/../Secrets", "Notes//Work", "Notes/", "C:\\Notes"] {
            XCTAssertThrowsError(try DraftNote(title: "Thought", relativeFolder: folder))
        }
    }
}
