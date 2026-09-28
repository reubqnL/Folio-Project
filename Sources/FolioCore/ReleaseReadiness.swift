/// User decision 50: required release gates have no waiver path.
/// This evaluates supplied evidence states. It does not itself compile code,
/// verify signatures, notarize artifacts or perform a security audit.
public enum ReleaseGate: String, CaseIterable, Hashable, Sendable {
    case nativeCompilation
    case inputAndLargeDocumentCorrectness
    case accessibility
    case durabilityAndCrashRecovery
    case externalEditReconciliation
    case keyRecoveryAndEncryptedResidue
    case migrationSafety
    case dependencyReview
    case independentSecurityReview
    case distributionSigning
    case notarizationAndStapling
    case updaterRollbackSafety
}

public enum EvidenceStatus: String, Equatable, Sendable {
    case notRun
    case failed
    case passed
}

public struct ReleaseReadiness: Equatable, Sendable {
    public let blockers: [ReleaseGate]
    public let nativePhaseTwoComplete: Bool
    public var mayRelease: Bool { blockers.isEmpty }

    public init(evidence: [ReleaseGate: EvidenceStatus], nativePhaseTwoComplete: Bool = false) {
        self.nativePhaseTwoComplete = nativePhaseTwoComplete
        blockers = ReleaseGate.allCases.filter { evidence[$0] != .passed }
    }

    /// Decisions 27 + 48: not even toolkit evaluation starts on calendar alone.
    /// Product security readiness must be assessed through verified evidence.
    public var mayBeginWindowsEvaluation: Bool { mayRelease && nativePhaseTwoComplete }
}
