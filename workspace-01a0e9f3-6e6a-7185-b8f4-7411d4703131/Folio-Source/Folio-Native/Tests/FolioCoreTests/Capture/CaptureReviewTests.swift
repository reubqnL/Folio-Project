import XCTest
import Foundation
@testable import FolioCore

final class CaptureReviewTests: XCTestCase {
    private func whole(_ proposal: CaptureProposal, warnings: Bool = false) -> CaptureApproval {
        .init(proposalID: proposal.id, selection: .wholeDraft, acknowledgesWarnings: warnings)
    }
    func testAppendPreservesExistingTextExactlyAndRequiresApproval() throws {
        let target = try CaptureFixtures.target("Existing text\n")
        let proposal = try CaptureProposal.make(request: CaptureFixtures.request(target), output: "# Captured\nNew thought")
        let plan = try proposal.plan(whole(proposal), current: target)
        XCTAssertEqual(plan.resultingText, "Existing text\n\n# Captured\nNew thought")
        XCTAssertEqual(target.text, "Existing text\n")
        try plan.validate(current: target)
    }
    func testBodyReplacementKeepsFrontMatterAndCRLF() throws {
        let target = try CaptureFixtures.target("\u{FEFF}---\r\nid: never-change\r\ncustom: value\r\n---\r\nOld body\r\n")
        let proposal = try CaptureProposal.make(request: CaptureFixtures.request(target, destination: .body), output: "# New\nBody\n")
        let plan = try proposal.plan(whole(proposal), current: target)
        XCTAssertEqual(plan.resultingText, "\u{FEFF}---\r\nid: never-change\r\ncustom: value\r\n---\r\n# New\r\nBody\r\n")
    }
    func testSelectionReplacementDoesNotTouchSurroundingWriting() throws {
        let target = try CaptureFixtures.target("Before 👩🏽‍💻\nReplace me\nAfter\n")
        let raw = (target.text as NSString).range(of: "Replace me")
        let destination = CaptureDestination.selection(.init(location: raw.location, length: raw.length))
        let proposal = try CaptureProposal.make(request: CaptureFixtures.request(target, destination: destination), output: "Changed")
        let plan = try proposal.plan(whole(proposal), current: target)
        XCTAssertEqual(plan.resultingText, "Before 👩🏽‍💻\nChanged\nAfter\n")
    }
    func testSectionApprovalAppendsOnlyChosenSections() throws {
        let target = try CaptureFixtures.target("Base")
        let proposal = try CaptureProposal.make(request: CaptureFixtures.request(target), output: "# One\nFirst\n\n## Two\nSecond\n\n## Three\nThird")
        XCTAssertEqual(proposal.sections.count, 3)
        let approval = CaptureApproval(proposalID: proposal.id, selection: .sections([proposal.sections[1].id]))
        let plan = try proposal.plan(approval, current: target)
        XCTAssertTrue(plan.resultingText.contains("Second"))
        XCTAssertFalse(plan.resultingText.contains("First")); XCTAssertFalse(plan.resultingText.contains("Third"))
    }
    func testSectionModeCannotSilentlyReplaceEntireExistingBody() throws {
        let target = try CaptureFixtures.target("Keep the rest\n")
        let proposal = try CaptureProposal.make(request: CaptureFixtures.request(target, destination: .body), output: "# One\nNew")
        XCTAssertThrowsError(try proposal.plan(.init(proposalID: proposal.id, selection: .sections([proposal.sections[0].id])), current: target)) {
            XCTAssertEqual($0 as? CaptureError, .sectionsCannotReplaceWholeBody)
        }
    }
    func testDetailedComparisonKeepsUnapprovedOldContent() throws {
        let target = try CaptureFixtures.target("Title\nold one\nkeep this\nold two\n")
        let proposal = try CaptureProposal.make(request: CaptureFixtures.request(target, destination: .body), output: "Title\nnew one\nkeep this\nnew two\n")
        XCTAssertEqual(proposal.changes.count, 2)
        let plan = try proposal.plan(.init(proposalID: proposal.id, selection: .changes([proposal.changes[0].id])), current: target)
        XCTAssertEqual(plan.resultingText, "Title\nnew one\nkeep this\nold two\n")
    }
    func testEmptyOrForeignApprovalIsRejected() throws {
        let target = try CaptureFixtures.target()
        let proposal = try CaptureProposal.make(request: CaptureFixtures.request(target), output: "Draft")
        XCTAssertThrowsError(try proposal.plan(.init(proposalID: proposal.id, selection: .sections([])), current: target))
        XCTAssertThrowsError(try proposal.plan(.init(proposalID: UUID(), selection: .wholeDraft), current: target))
        XCTAssertThrowsError(try proposal.plan(.init(proposalID: proposal.id, selection: .changes(["invented"])), current: target))
    }
    func testStaleWritingCannotBeOverwrittenByAnOldReview() throws {
        let target = try CaptureFixtures.target("Original\n")
        let proposal = try CaptureProposal.make(request: CaptureFixtures.request(target, destination: .body), output: "Generated\n")
        let newer = try CaptureFixtures.target("New writing\n", binding: target.binding, generation: 2)
        XCTAssertThrowsError(try proposal.plan(whole(proposal), current: newer)) { XCTAssertEqual($0 as? CaptureError, .staleTarget) }
    }
    func testSameTextAfterInterveningEditStillRequiresNewReview() throws {
        let target = try CaptureFixtures.target()
        let proposal = try CaptureProposal.make(request: CaptureFixtures.request(target), output: "Draft")
        let changedBack = try CaptureFixtures.target(target.text, binding: target.binding, generation: 3)
        XCTAssertThrowsError(try proposal.plan(whole(proposal), current: changedBack)) { XCTAssertEqual($0 as? CaptureError, .staleTarget) }
    }
    func testExplicitComparisonCreatesNewApprovalIdentity() throws {
        let target = try CaptureFixtures.target("Original\n")
        let initial = try CaptureProposal.make(request: CaptureFixtures.request(target, destination: .body), output: "Proposed\n")
        let newer = try CaptureFixtures.target("Newer writing\n", binding: target.binding, generation: 2)
        let compared = try initial.comparingCurrent(newer)
        XCTAssertTrue(compared.comparesNewerTarget); XCTAssertNotEqual(initial.id, compared.id)
        XCTAssertEqual(compared.beforeTarget, newer.text)
        XCTAssertThrowsError(try compared.plan(whole(initial), current: newer))
        XCTAssertNoThrow(try compared.plan(whole(compared), current: newer))
    }
    func testRebasingSelectionNeedsAnExplicitCurrentRange() throws {
        let target = try CaptureFixtures.target("one two three")
        let initial = try CaptureProposal.make(request: CaptureFixtures.request(target, destination: .selection(.init(location: 4, length: 3))), output: "changed")
        let newer = try CaptureFixtures.target("prefix one two three", binding: target.binding, generation: 2)
        XCTAssertThrowsError(try initial.comparingCurrent(newer)) { XCTAssertEqual($0 as? CaptureError, .invalidSelection) }
        let range = (newer.text as NSString).range(of: "two")
        let compared = try initial.comparingCurrent(newer, newSelection: .init(location: range.location, length: range.length))
        let plan = try compared.plan(whole(compared), current: newer)
        XCTAssertEqual(plan.resultingText, "prefix one changed three")
    }
    func testCrossNoteAndEditorSessionApplicationsAreRejected() throws {
        let target = try CaptureFixtures.target()
        let proposal = try CaptureProposal.make(request: CaptureFixtures.request(target), output: "Draft")
        let binding = CaptureDocumentBinding(workspace: target.binding.workspace, noteID: target.binding.noteID, editorID: UUID())
        let other = try CaptureFixtures.target(target.text, binding: binding)
        XCTAssertThrowsError(try proposal.plan(whole(proposal), current: other)) { XCTAssertEqual($0 as? CaptureError, .wrongTarget) }
    }
    func testEditedOutputInvalidatesEarlierSelection() throws {
        let target = try CaptureFixtures.target()
        let proposal = try CaptureProposal.make(request: CaptureFixtures.request(target), output: "First output")
        let edited = try proposal.editingOutput("User corrected output")
        XCTAssertNotEqual(proposal.id, edited.id)
        XCTAssertThrowsError(try edited.plan(whole(proposal), current: target))
    }
    func testUndoRestoresExactOriginalBytesIncludingUnicode() throws {
        let target = try CaptureFixtures.target("# café\r\n👩🏽‍💻\r\n")
        let proposal = try CaptureProposal.make(request: CaptureFixtures.request(target), output: "New information")
        let edit = try proposal.plan(whole(proposal), current: target)
        let after = try CaptureFixtures.target(edit.resultingText, binding: target.binding, generation: 2)
        let receipt = try CaptureUndoReceipt(edit: edit, applied: after)
        let inverse = try receipt.inverse(current: after)
        XCTAssertEqual(Data(inverse.resultingText.utf8), Data(target.text.utf8))
    }
    func testStaleUndoCannotDeleteLaterWriting() throws {
        let target = try CaptureFixtures.target()
        let proposal = try CaptureProposal.make(request: CaptureFixtures.request(target), output: "New")
        let edit = try proposal.plan(whole(proposal), current: target)
        let after = try CaptureFixtures.target(edit.resultingText, binding: target.binding, generation: 2)
        let receipt = try CaptureUndoReceipt(edit: edit, applied: after)
        let later = try CaptureFixtures.target(after.text + "extra", binding: target.binding, generation: 3)
        XCTAssertThrowsError(try receipt.inverse(current: later)) { XCTAssertEqual($0 as? CaptureError, .staleUndo) }
    }
    func testOutputWarningsRequireExplicitAcknowledgement() throws {
        let target = try CaptureFixtures.target()
        let proposal = try CaptureProposal.make(request: CaptureFixtures.request(target), output: "Review https://example.invalid before sharing.")
        XCTAssertFalse(proposal.warnings.isEmpty)
        XCTAssertThrowsError(try proposal.plan(whole(proposal), current: target)) { XCTAssertEqual($0 as? CaptureError, .warningNotAcknowledged) }
        XCTAssertNoThrow(try proposal.plan(whole(proposal, warnings: true), current: target))
    }
    func testBidiFormattingIsVisibleInReviewAndNeedsAcknowledgement() throws {
        let budget = CaptureBudget(profile: .balanced)
        let text = "normal \u{202E}hidden direction\u{202C}"
        let warnings = try CaptureOutputValidation.validate(text, budget: budget)
        XCTAssertFalse(warnings.isEmpty)
        XCTAssertTrue(CaptureOutputValidation.visibleText(text).contains("U+202E"))
    }
    func testGeneratedMetadataAndMalformedOutputAreRejected() throws {
        let budget = CaptureBudget(profile: .balanced)
        for text in ["", " \n ", "bad\0text", "---\nid: generated\n---\nbody", "---\r\nid: unclosed", "```swift\nunclosed"] {
            XCTAssertThrowsError(try CaptureOutputValidation.validate(text, budget: budget), text)
        }
    }
    func testLegitimateUnicodeOutputIsRetained() throws {
        XCTAssertNoThrow(try CaptureOutputValidation.validate("# مرحبا\n👩🏽‍💻 café 日本語", budget: .init(profile: .balanced)))
    }
    func testDiffBudgetRejectsHugeLineMatrices() {
        XCTAssertThrowsError(try CaptureDiff.changes(before: String(repeating: "a\n", count: 401), after: "b\n")) { XCTAssertEqual($0 as? CaptureError, .reviewTooComplex) }
    }
    func testFullHunkApplicationReconstructsProposedText() throws {
        let pairs = [("", "first\n"), ("a\nb\n", "a\nc\n"), ("remove\n", ""), ("α\r\nβ\r\n", "α\r\nγ\r\n")]
        for (before, after) in pairs {
            let changes = try CaptureDiff.changes(before: before, after: after)
            XCTAssertEqual(try CaptureDiff.apply(changes, selected: Set(changes.map(\.id)), to: before), after)
        }
    }
    func testNativeMutationMustValidateTheActualCurrentBuffer() throws {
        let target = try CaptureFixtures.target()
        let proposal = try CaptureProposal.make(request: CaptureFixtures.request(target), output: "Draft")
        let edit = try proposal.plan(whole(proposal), current: target)
        let raced = try CaptureFixtures.target("newer before dispatch", binding: target.binding, generation: 2)
        XCTAssertThrowsError(try edit.validate(current: raced)) { XCTAssertEqual($0 as? CaptureError, .staleTarget) }
    }
    func testDeterministicDiffCorpusReconstructsEveryProposedVersion() throws {
        var seed: UInt64 = 0xF0110
        func next(_ bound: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 32) % UInt64(bound))
        }
        let tokens = ["alpha", "café", "👩🏽‍💻", "مرحبا", "e\u{301}", "日本語", "keep"]
        for _ in 0..<250 {
            let ending = next(2) == 0 ? "\n" : "\r\n"
            let count = next(18)
            let beforeLines = (0..<count).map { _ in tokens[next(tokens.count)] + ending }
            var afterLines = beforeLines
            for _ in 0..<(next(6) + 1) {
                if next(2) == 0 || afterLines.isEmpty { afterLines.insert(tokens[next(tokens.count)] + ending, at: next(afterLines.count + 1)) }
                else { afterLines.remove(at: next(afterLines.count)) }
            }
            let before = beforeLines.joined(), after = afterLines.joined()
            let changes = try CaptureDiff.changes(before: before, after: after)
            if changes.isEmpty { XCTAssertEqual(before, after) }
            else { XCTAssertEqual(try CaptureDiff.apply(changes, selected: Set(changes.map(\.id)), to: before), after) }
        }
    }
    func testExternalLinkWarningsAreCaseInsensitive() throws {
        let warnings = try CaptureOutputValidation.validate("[Example](HTTPS://example.invalid)", budget: .init(profile: .balanced))
        XCTAssertTrue(warnings.contains { $0.contains("external links") })
    }

}
