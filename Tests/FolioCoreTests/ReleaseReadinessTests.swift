import XCTest
@testable import FolioCore

final class ReleaseReadinessTests: XCTestCase {
    private var passingEvidence: [ReleaseGate: EvidenceStatus] {
        Dictionary(uniqueKeysWithValues: ReleaseGate.allCases.map { ($0, .passed) })
    }

    func testNoEvidenceBlocksEveryGate() {
        let result = ReleaseReadiness(evidence: [:])
        XCTAssertFalse(result.mayRelease)
        XCTAssertFalse(result.mayBeginWindowsEvaluation)
        XCTAssertEqual(result.blockers, ReleaseGate.allCases)
    }

    func testEachFailedGateIndividuallyBlocksRelease() {
        for gate in ReleaseGate.allCases {
            var evidence = passingEvidence
            evidence[gate] = .failed
            let result = ReleaseReadiness(evidence: evidence)
            XCTAssertFalse(result.mayRelease, gate.rawValue)
            XCTAssertEqual(result.blockers, [gate])
        }
    }

    func testUnrunChecksCannotBeCountedAsPassing() {
        var evidence = passingEvidence
        evidence[.independentSecurityReview] = .notRun
        XCTAssertFalse(ReleaseReadiness(evidence: evidence).mayRelease)
    }

    func testMissingCheckRemainsBlocking() {
        var evidence = passingEvidence
        evidence.removeValue(forKey: .durabilityAndCrashRecovery)
        XCTAssertFalse(ReleaseReadiness(evidence: evidence).mayRelease)
    }

    func testCompletePassingEvidenceAllowsReleaseDecision() {
        let result = ReleaseReadiness(evidence: passingEvidence)
        XCTAssertTrue(result.mayRelease)
        XCTAssertFalse(result.mayBeginWindowsEvaluation)
    }

    func testWindowsEvaluationAlsoRequiresNativePhaseTwoCompletion() {
        let result = ReleaseReadiness(evidence: passingEvidence, nativePhaseTwoComplete: true)
        XCTAssertTrue(result.mayBeginWindowsEvaluation)
        var incomplete = passingEvidence
        incomplete[.independentSecurityReview] = .notRun
        XCTAssertFalse(ReleaseReadiness(evidence: incomplete, nativePhaseTwoComplete: true).mayBeginWindowsEvaluation)
    }

    func testPassingOnlySigningDoesNotMeanMacIsSecured() {
        let result = ReleaseReadiness(evidence: [
            .distributionSigning: .passed,
            .notarizationAndStapling: .passed
        ])
        XCTAssertFalse(result.mayRelease)
        XCTAssertFalse(result.mayBeginWindowsEvaluation)
    }
}
