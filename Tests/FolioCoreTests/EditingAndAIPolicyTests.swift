import XCTest
@testable import FolioCore

final class EditingAndAIPolicyTests: XCTestCase {
    func testSourceCursorIsTheAnchor() {
        let policy = EditorNavigationPolicy()
        XCTAssertTrue(policy.preserveSourceCursor)
        XCTAssertTrue(policy.previewFollowsOnlyOnExplicitAction)
        XCTAssertFalse(policy.automaticallySynchroniseScroll)
    }

    func testTranscriptMustBeReviewedBeforeRestructuring() {
        let policy = AIInteractionPolicy()
        XCTAssertFalse(policy.mayRestructureTranscript(userConfirmedTranscript: false))
        XCTAssertTrue(policy.mayRestructureTranscript(userConfirmedTranscript: true))
    }

    func testUserChoosesFromAllThreeReviewModes() {
        let policy = AIInteractionPolicy()
        XCTAssertNil(policy.initialReviewMode)
        XCTAssertEqual(policy.availableReviewModes, [.wholeDraft, .sections, .detailedComparison])
    }

    func testContextRemainsVisibleAndDoesNotExpandSilently() {
        let policy = AIInteractionPolicy()
        XCTAssertTrue(policy.contextListAlwaysVisible)
        XCTAssertTrue(policy.contextCanBeExplicitlyAddedOrRemoved)
        XCTAssertFalse(policy.silentlyExpandContext)
    }
}
