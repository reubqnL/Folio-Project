import XCTest
import Foundation
@testable import FolioCore

final class SpeechLifecycleTests: XCTestCase {
    private func draft() -> CaptureDraft { CaptureDraft(target: CaptureFixtures.binding()) }
    private func started(locale: String = "en-GB") throws -> (SpeechCaptureMachine, VoiceRun) {
        var machine = SpeechCaptureMachine()
        let run = try machine.begin(binding: .init(draft: draft()), capability: .ready(locale: locale), permission: .granted, profile: .balanced, userPressedRecord: true)
        try machine.microphoneDidStart(runID: run.id)
        return (machine, run)
    }
    private func finish(_ machine: inout SpeechCaptureMachine, _ run: VoiceRun) throws {
        try machine.requestStop(runID: run.id, discard: false)
        try machine.microphoneDidStop(runID: run.id)
        try machine.providerDidClose(runID: run.id)
    }
    func testNoStartWithoutExplicitRecordAction() {
        var machine = SpeechCaptureMachine()
        XCTAssertThrowsError(try machine.begin(binding: .init(draft: draft()), capability: .ready(locale: "en-GB"), permission: .granted, profile: .balanced, userPressedRecord: false))
        XCTAssertFalse(machine.microphoneActive); XCTAssertFalse(machine.resourcesHeld)
    }
    func testMissingAssetsCannotSilentlyStartOrDownload() {
        for capability in [SpeechCapability.needsAssets(locale: "en-GB"), .downloading(locale: "en-GB"), .unavailable("unsupported")] {
            var machine = SpeechCaptureMachine()
            XCTAssertThrowsError(try machine.begin(binding: .init(draft: draft()), capability: capability, permission: .granted, profile: .balanced, userPressedRecord: true))
            XCTAssertFalse(machine.isBusy)
        }
    }
    func testMicrophonePermissionPrecedesPreparation() throws {
        var machine = SpeechCaptureMachine()
        let run = try machine.begin(binding: .init(draft: draft()), capability: .ready(locale: "en-GB"), permission: .notDetermined, profile: .balanced, userPressedRecord: true)
        XCTAssertEqual(machine.phase, .awaitingPermission)
        XCTAssertFalse(machine.mayStartMicrophone(runID: run.id))
        XCTAssertTrue(try machine.permissionResolved(runID: run.id, result: .granted))
        XCTAssertTrue(machine.mayStartMicrophone(runID: run.id))
        XCTAssertFalse(machine.microphoneActive)
    }
    func testDeniedAndRestrictedPermissionsFailClosed() {
        for permission in [MicrophonePermission.denied, .restricted] {
            var machine = SpeechCaptureMachine()
            XCTAssertThrowsError(try machine.begin(binding: .init(draft: draft()), capability: .ready(locale: "en-GB"), permission: permission, profile: .balanced, userPressedRecord: true))
            XCTAssertFalse(machine.microphoneActive)
        }
    }
    func testLatePermissionGrantAfterCancelCannotStartCapture() throws {
        var machine = SpeechCaptureMachine()
        let run = try machine.begin(binding: .init(draft: draft()), capability: .ready(locale: "en-GB"), permission: .notDetermined, profile: .balanced, userPressedRecord: true)
        try machine.requestStop(runID: run.id, discard: true)
        XCTAssertFalse(try machine.permissionResolved(runID: run.id, result: .granted))
        XCTAssertFalse(machine.mayStartMicrophone(runID: run.id))
        XCTAssertTrue(machine.resourcesHeld)
        try machine.microphoneDidStop(runID: run.id); try machine.providerDidClose(runID: run.id)
        XCTAssertEqual(machine.phase, .cancelled)
    }
    func testUnexpectedLateStartRemainsVisibleAndMustBeStopped() throws {
        var machine = SpeechCaptureMachine()
        let run = try machine.begin(binding: .init(draft: draft()), capability: .ready(locale: "en-GB"), permission: .granted, profile: .balanced, userPressedRecord: true)
        try machine.requestStop(runID: run.id, discard: true)
        XCTAssertThrowsError(try machine.microphoneDidStart(runID: run.id))
        XCTAssertTrue(machine.microphoneActive); XCTAssertEqual(machine.phase, .cancelling)
    }
    func testStopClickIsNotAFalseMicrophoneOffAcknowledgement() throws {
        var (machine, run) = try started()
        try machine.requestStop(runID: run.id, discard: false)
        XCTAssertTrue(machine.microphoneActive); XCTAssertTrue(machine.resourcesHeld)
        try machine.microphoneDidStop(runID: run.id)
        XCTAssertFalse(machine.microphoneActive); XCTAssertTrue(machine.resourcesHeld)
        XCTAssertThrowsError(try machine.resetAfterClosed())
    }
    func testProviderCannotCloseBeforeMicrophoneAcknowledgement() throws {
        var (machine, run) = try started()
        XCTAssertThrowsError(try machine.providerDidClose(runID: run.id)) { XCTAssertEqual($0 as? VoiceError, .resourceNotReleased) }
        XCTAssertTrue(machine.microphoneActive)
    }
    func testSecondRecordingIsBlockedWhileFirstStillFinalizes() throws {
        var (machine, run) = try started()
        try machine.requestStop(runID: run.id, discard: false); try machine.microphoneDidStop(runID: run.id)
        XCTAssertThrowsError(try machine.begin(binding: .init(draft: draft()), capability: .ready(locale: "en-GB"), permission: .granted, profile: .balanced, userPressedRecord: true)) {
            XCTAssertEqual($0 as? VoiceError, .busy)
        }
    }
    func testVolatileTextReplacesEarlierHypothesisInsteadOfDuplicating() throws {
        var (machine, run) = try started()
        try machine.accept(.init(startMilliseconds: 0, endMilliseconds: 1000, text: "a wrong", isFinal: false), runID: run.id)
        try machine.accept(.init(startMilliseconds: 0, endMilliseconds: 1500, text: "a corrected phrase", isFinal: true), runID: run.id)
        XCTAssertEqual(machine.transcript, "a corrected phrase"); XCTAssertTrue(machine.volatileText.isEmpty)
    }
    func testFinalTextCannotBeRewrittenByAnotherHypothesis() throws {
        var (machine, run) = try started()
        try machine.accept(.init(startMilliseconds: 0, endMilliseconds: 1000, text: "final", isFinal: true), runID: run.id)
        XCTAssertThrowsError(try machine.accept(.init(startMilliseconds: 0, endMilliseconds: 1000, text: "changed", isFinal: false), runID: run.id))
        XCTAssertEqual(machine.transcript, "final")
    }
    func testDuplicateFinalEventIsIdempotent() throws {
        var (machine, run) = try started()
        let segment = SpeechSegment(startMilliseconds: 0, endMilliseconds: 1000, text: "once", isFinal: true)
        try machine.accept(segment, runID: run.id); try machine.accept(segment, runID: run.id)
        XCTAssertEqual(machine.transcript, "once")
    }
    func testOutOfOrderNonOverlappingResultsAreDisplayedChronologically() throws {
        var (machine, run) = try started()
        try machine.accept(.init(startMilliseconds: 1000, endMilliseconds: 2000, text: "world", isFinal: true), runID: run.id)
        try machine.accept(.init(startMilliseconds: 0, endMilliseconds: 1000, text: "Hello", isFinal: true), runID: run.id)
        XCTAssertEqual(machine.transcript, "Hello world")
    }
    func testCJKSegmentsDoNotInventInterwordSpaces() throws {
        var (machine, run) = try started(locale: "ja-JP")
        try machine.accept(.init(startMilliseconds: 0, endMilliseconds: 1000, text: "日本", isFinal: true), runID: run.id)
        try machine.accept(.init(startMilliseconds: 1000, endMilliseconds: 2000, text: "語", isFinal: true), runID: run.id)
        XCTAssertEqual(machine.transcript, "日本語")
    }
    func testLateResultAfterCancelOrReviewIsIgnoredByState() throws {
        var (machine, run) = try started()
        try machine.accept(.init(startMilliseconds: 0, endMilliseconds: 1000, text: "discard", isFinal: false), runID: run.id)
        try machine.requestStop(runID: run.id, discard: true)
        XCTAssertThrowsError(try machine.accept(.init(startMilliseconds: 0, endMilliseconds: 1000, text: "late", isFinal: true), runID: run.id))
        try machine.microphoneDidStop(runID: run.id); try machine.providerDidClose(runID: run.id)
        XCTAssertTrue(machine.transcript.isEmpty); XCTAssertEqual(machine.phase, .cancelled)
    }
    func testForeignRunCannotMutateCurrentTranscript() throws {
        var (machine, _) = try started()
        XCTAssertThrowsError(try machine.accept(.init(startMilliseconds: 0, endMilliseconds: 100, text: "foreign", isFinal: true), runID: UUID())) { XCTAssertEqual($0 as? VoiceError, .staleRun) }
        XCTAssertTrue(machine.transcript.isEmpty)
    }
    func testReviewAndApprovalRequireResourceClosure() throws {
        var (machine, run) = try started()
        try machine.accept(.init(startMilliseconds: 0, endMilliseconds: 1000, text: "review me", isFinal: true), runID: run.id)
        XCTAssertThrowsError(try machine.approveForUse(expectedRevision: machine.reviewRevision, acknowledgesIncomplete: false))
        try finish(&machine, run)
        let approved = try machine.approveForUse(expectedRevision: machine.reviewRevision, acknowledgesIncomplete: false)
        XCTAssertEqual(approved.text, "review me")
    }
    func testPartialTranscriptNeedsExplicitAcknowledgement() throws {
        var (machine, run) = try started()
        try machine.accept(.init(startMilliseconds: 0, endMilliseconds: 1000, text: "provisional", isFinal: false), runID: run.id)
        try finish(&machine, run)
        XCTAssertThrowsError(try machine.approveForUse(expectedRevision: machine.reviewRevision, acknowledgesIncomplete: false)) { XCTAssertEqual($0 as? VoiceError, .partialAcknowledgementRequired) }
        XCTAssertNoThrow(try machine.approveForUse(expectedRevision: machine.reviewRevision, acknowledgesIncomplete: true))
    }
    func testCorrectionInvalidatesEarlierReviewRevision() throws {
        var (machine, run) = try started()
        try machine.accept(.init(startMilliseconds: 0, endMilliseconds: 1000, text: "wrong", isFinal: true), runID: run.id)
        try finish(&machine, run)
        let old = machine.reviewRevision
        try machine.editTranscript("corrected")
        XCTAssertThrowsError(try machine.approveForUse(expectedRevision: old, acknowledgesIncomplete: true)) { XCTAssertEqual($0 as? VoiceError, .staleReview) }
    }
    func testStopReasonsRemainVisibleInReview() throws {
        var (machine, run) = try started()
        try machine.accept(.init(startMilliseconds: 0, endMilliseconds: 1000, text: "retained", isFinal: true), runID: run.id)
        try machine.requestStop(runID: run.id, discard: false, reason: .audioOverflow)
        try machine.microphoneDidStop(runID: run.id); try machine.providerDidClose(runID: run.id, reason: .audioOverflow)
        XCTAssertEqual(machine.warnings.count, 1); XCTAssertTrue(machine.needsPartialAcknowledgement)
    }
    func testDurationAndResultBoundsAreEnforced() throws {
        var (machine, run) = try started()
        XCTAssertFalse(try machine.updateElapsed(100, runID: run.id))
        XCTAssertTrue(try machine.updateElapsed(run.limits.maximumMilliseconds, runID: run.id))
        XCTAssertThrowsError(try machine.accept(.init(startMilliseconds: -1, endMilliseconds: 1, text: "bad", isFinal: true), runID: run.id))
        XCTAssertThrowsError(try machine.accept(.init(startMilliseconds: 0, endMilliseconds: 100, text: "a\0b", isFinal: true), runID: run.id))
    }
    func testTranscriptCannotBeCorrectedWhileRecording() throws {
        var (machine, _) = try started()
        XCTAssertThrowsError(try machine.editTranscript("manual overwrite"))
    }
    func testReviewedVoiceImportsIntoOnlyTheBoundCaptureRevision() throws {
        var capture = draft(), machine = SpeechCaptureMachine()
        let run = try machine.begin(binding: .init(draft: capture), capability: .ready(locale: "en-GB"), permission: .granted, profile: .balanced, userPressedRecord: true)
        try machine.microphoneDidStart(runID: run.id)
        try machine.accept(.init(startMilliseconds: 0, endMilliseconds: 1000, text: "Approved voice text", isFinal: true), runID: run.id)
        try finish(&machine, run)
        let voice = try machine.approveForUse(expectedRevision: machine.reviewRevision, acknowledgesIncomplete: false)
        var changed = capture; changed.editInput("new typed input", kind: .typed)
        XCTAssertThrowsError(try changed.importReviewedVoice(voice)) { XCTAssertEqual($0 as? VoiceError, .staleReview) }
        try capture.importReviewedVoice(voice)
        XCTAssertEqual(capture.sourceKind, .transcript); XCTAssertTrue(capture.transcriptIsConfirmed)
        XCTAssertEqual(capture.input, "Approved voice text")
    }
    func testAnotherCaptureCannotConsumeTheTranscript() throws {
        let original = draft(); var machine = SpeechCaptureMachine()
        let run = try machine.begin(binding: .init(draft: original), capability: .ready(locale: "en-GB"), permission: .granted, profile: .balanced, userPressedRecord: true)
        try machine.microphoneDidStart(runID: run.id); try machine.accept(.init(startMilliseconds: 0,endMilliseconds: 100,text: "text",isFinal: true),runID:run.id)
        try finish(&machine,run)
        let approved = try machine.approveForUse(expectedRevision: machine.reviewRevision, acknowledgesIncomplete: false)
        var foreign = draft()
        XCTAssertThrowsError(try foreign.importReviewedVoice(approved)) { XCTAssertEqual($0 as? VoiceError, .wrongCapture) }
    }
    func testDownloadConsentIsSeparateAndLocaleBound() throws {
        XCTAssertThrowsError(try SpeechAssetConsent.approve(capability: .needsAssets(locale: "en-GB"), displayedLocale: "en-GB", userConfirmedDownload: false))
        XCTAssertThrowsError(try SpeechAssetConsent.approve(capability: .needsAssets(locale: "en-GB"), displayedLocale: "fr-FR", userConfirmedDownload: true))
        XCTAssertEqual(try SpeechAssetConsent.approve(capability: .needsAssets(locale: "en-GB"), displayedLocale: "en-GB", userConfirmedDownload: true).locale, "en-GB")
    }
    func testReservationLedgerNeverClaimsSomeoneElsesReservation() {
        var ledger = SpeechReservationLedger()
        ledger.didReserve(locale: "en-GB", newlyReserved: false)
        XCTAssertFalse(ledger.mayRelease("en-GB"))
        ledger.didReserve(locale: "fr-FR", newlyReserved: true)
        XCTAssertTrue(ledger.mayRelease("fr-FR"))
        ledger.didRelease("fr-FR", succeeded: false); XCTAssertTrue(ledger.mayRelease("fr-FR"))
        ledger.didRelease("fr-FR", succeeded: true); XCTAssertFalse(ledger.mayRelease("fr-FR"))
    }
    func testFinalResultsMayArriveAfterMicStopsButNotAfterReviewCloses() throws {
        var (machine, run) = try started()
        try machine.requestStop(runID: run.id, discard: false)
        try machine.microphoneDidStop(runID: run.id)
        try machine.accept(.init(startMilliseconds: 0, endMilliseconds: 1000, text: "final tail", isFinal: true), runID: run.id)
        try machine.providerDidClose(runID: run.id)
        XCTAssertEqual(machine.transcript, "final tail")
        XCTAssertThrowsError(try machine.accept(.init(startMilliseconds: 1000, endMilliseconds: 1100, text: "too late", isFinal: true), runID: run.id))
        XCTAssertEqual(machine.transcript, "final tail")
    }
    func testTranscriptBudgetFailureDoesNotReplaceEarlierText() throws {
        var (machine, run) = try started()
        let first = String(repeating: "a", count: 15000)
        try machine.accept(.init(startMilliseconds: 0, endMilliseconds: 1000, text: first, isFinal: true), runID: run.id)
        XCTAssertThrowsError(try machine.accept(.init(startMilliseconds: 1000, endMilliseconds: 2000, text: String(repeating: "b", count: 15000), isFinal: true), runID: run.id)) {
            XCTAssertEqual($0 as? VoiceError, .transcriptTooLarge)
        }
        XCTAssertEqual(machine.transcript, first)
    }
    func testInvalidLocaleCannotBeARecordingCapability() {
        var machine = SpeechCaptureMachine()
        XCTAssertThrowsError(try machine.begin(binding: .init(draft: draft()), capability: .ready(locale: "en-GB\nsecret"), permission: .granted, profile: .balanced, userPressedRecord: true))
        XCTAssertFalse(machine.isBusy)
    }
    func testRestoredReservationLedgerRejectsInvalidIdentifiers() {
        let ledger = SpeechReservationLedger(restoring: ["en-GB", "../other", "bad\nlocale", ""])
        XCTAssertEqual(ledger.ownedLocales, ["en-GB"])
    }

}
