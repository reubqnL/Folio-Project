import Foundation

/// Pure lifecycle/review policy. Native driver acknowledgements, not a UI click,
/// decide when microphone use and analyzer resources have actually ended.
public struct SpeechCaptureMachine: Sendable {
    public private(set) var phase: VoicePhase = .idle
    public private(set) var run: VoiceRun?
    public private(set) var microphoneActive = false
    public private(set) var resourcesHeld = false
    public private(set) var elapsedMilliseconds: Int64 = 0
    public private(set) var transcript = ""
    public private(set) var finalizedText = ""
    public private(set) var volatileText = ""
    public private(set) var warnings: [String] = []
    public private(set) var reviewRevision = UUID()
    private var finalized: [SpeechSegment] = []
    private var volatile: [SpeechSegment] = []
    private var discarding = false
    private var approvedRevision: UUID?

    public init() {}
    public var isBusy: Bool { resourcesHeld || microphoneActive }
    public var hasUnreviewedText: Bool { !transcript.isEmpty && approvedRevision != reviewRevision }
    public var needsPartialAcknowledgement: Bool { !warnings.isEmpty }

    @discardableResult
    public mutating func begin(binding: VoiceCaptureBinding, capability: SpeechCapability,
                               permission: MicrophonePermission, profile: SearchProfile,
                               userPressedRecord: Bool) throws -> VoiceRun {
        guard userPressedRecord else { throw VoiceError.consentRequired }
        guard !isBusy else { throw VoiceError.busy }
        guard transcript.isEmpty else { throw VoiceError.reviewRequired }
        guard case .ready(let locale) = capability else {
            if case .needsAssets = capability { throw VoiceError.assetsMissing }
            if case .downloading = capability { throw VoiceError.assetsMissing }
            throw VoiceError.unsupportedLocale
        }
        guard validLocale(locale) else { throw VoiceError.unsupportedLocale }
        guard permission != .denied && permission != .restricted else { throw VoiceError.permissionDenied }
        let value = VoiceRun(id: UUID(), binding: binding, locale: locale, limits: .init(profile: profile))
        run = value; phase = permission == .granted ? .preparing : .awaitingPermission
        resourcesHeld = true; microphoneActive = false; discarding = false
        transcript = ""; finalizedText = ""; volatileText = ""; finalized = []; volatile = []; warnings = []
        elapsedMilliseconds = 0; reviewRevision = UUID(); approvedRevision = nil
        return value
    }
    /// Returns false for a late permission response after Stop/Discard.
    public mutating func permissionResolved(runID: UUID, result: MicrophonePermission) throws -> Bool {
        guard run?.id == runID else { throw VoiceError.staleRun }
        guard phase == .awaitingPermission else { return false }
        if result == .granted { phase = .preparing; return true }
        phase = .failed; resourcesHeld = false; microphoneActive = false
        throw VoiceError.permissionDenied
    }
    public func mayStartMicrophone(runID: UUID) -> Bool {
        run?.id == runID && phase == .preparing && resourcesHeld && !discarding
    }
    public mutating func microphoneDidStart(runID: UUID) throws {
        guard run?.id == runID else { throw VoiceError.staleRun }
        microphoneActive = true; resourcesHeld = true
        guard phase == .preparing && !discarding else {
            phase = .cancelling; discarding = true
            throw VoiceError.invalidState
        }
        phase = .recording
    }
    public mutating func requestStop(runID: UUID, discard: Bool, reason: VoiceStopReason = .requested) throws {
        guard run?.id == runID else { throw VoiceError.staleRun }
        guard isBusy else { return }
        if let warning = reason.warning, !warnings.contains(warning) { warnings.append(warning) }
        if discard {
            discarding = true; phase = .cancelling
            transcript = ""; finalizedText = ""; volatileText = ""; finalized = []; volatile = []
            reviewRevision = UUID(); approvedRevision = nil
        } else if !discarding { phase = .stopping }
    }
    public mutating func microphoneDidStop(runID: UUID) throws {
        guard run?.id == runID else { throw VoiceError.staleRun }
        microphoneActive = false
        // The analyzer may still own queued audio/results; keep its slot busy.
        if resourcesHeld && !discarding { phase = .stopping }
    }
    public mutating func accept(_ segment: SpeechSegment, runID: UUID) throws {
        guard let run, run.id == runID else { throw VoiceError.staleRun }
        guard !discarding, phase == .recording || phase == .stopping else { throw VoiceError.invalidState }
        guard segment.startMilliseconds >= 0, segment.endMilliseconds > segment.startMilliseconds,
              segment.endMilliseconds <= run.limits.maximumMilliseconds + 10_000,
              segment.text.utf8.count <= 16 * 1024, !segment.text.contains("\0") else { throw VoiceError.invalidResult }
        if segment.text.isEmpty { return }
        let overlapsFinal = finalized.filter { overlaps($0, segment) }
        if !overlapsFinal.isEmpty {
            if overlapsFinal.count == 1, overlapsFinal[0] == segment { return }
            throw VoiceError.invalidResult
        }
        var nextFinal = finalized, nextVolatile = volatile.filter { !overlaps($0, segment) }
        if segment.isFinal { nextFinal.append(segment) } else { nextVolatile.append(segment) }
        guard nextFinal.count + nextVolatile.count <= run.limits.maximumSegments else { throw VoiceError.transcriptTooLarge }
        nextFinal.sort { $0.startMilliseconds < $1.startMilliseconds }
        nextVolatile.sort { $0.startMilliseconds < $1.startMilliseconds }
        let combined = join(nextFinal + nextVolatile, locale: run.locale)
        guard combined.utf8.count <= run.limits.maximumTranscriptBytes else { throw VoiceError.transcriptTooLarge }
        finalized = nextFinal; volatile = nextVolatile
        finalizedText = join(finalized, locale: run.locale); volatileText = join(volatile, locale: run.locale)
        transcript = combined; reviewRevision = UUID(); approvedRevision = nil
    }
    public mutating func updateElapsed(_ milliseconds: Int64, runID: UUID) throws -> Bool {
        guard let run, run.id == runID else { throw VoiceError.staleRun }
        guard milliseconds >= 0 else { throw VoiceError.invalidResult }
        elapsedMilliseconds = max(elapsedMilliseconds, min(milliseconds, run.limits.maximumMilliseconds))
        return phase == .recording && milliseconds >= run.limits.maximumMilliseconds
    }
    /// The driver must emit this only AFTER microphone shutdown and analyzer
    /// teardown, not merely when cancellation was requested.
    public mutating func providerDidClose(runID: UUID, reason: VoiceStopReason = .requested) throws {
        guard let run, run.id == runID else { throw VoiceError.staleRun }
        guard !microphoneActive else { throw VoiceError.resourceNotReleased }
        guard resourcesHeld else { return }
        resourcesHeld = false
        if discarding {
            phase = .cancelled; transcript = ""; finalizedText = ""; volatileText = ""; finalized = []; volatile = []
            approvedRevision = nil; reviewRevision = UUID(); return
        }
        if let warning = reason.warning, !warnings.contains(warning) { warnings.append(warning) }
        if !volatile.isEmpty {
            warnings.append("Some displayed words were still provisional when analysis ended.")
        }
        transcript = join(finalized + volatile, locale: run.locale)
        phase = transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .failed : .review
        reviewRevision = UUID(); approvedRevision = nil
    }
    public mutating func editTranscript(_ text: String) throws {
        guard phase == .review, !isBusy, let run else { throw VoiceError.reviewRequired }
        guard text.utf8.count <= run.limits.maximumTranscriptBytes, !text.contains("\0") else { throw VoiceError.transcriptTooLarge }
        if text != transcript { transcript = text; reviewRevision = UUID(); approvedRevision = nil }
    }
    public mutating func approveForUse(expectedRevision: UUID, acknowledgesIncomplete: Bool) throws -> ReviewedVoiceTranscript {
        guard phase == .review, !isBusy, let run else { throw VoiceError.reviewRequired }
        guard expectedRevision == reviewRevision else { throw VoiceError.staleReview }
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw VoiceError.emptyTranscript }
        guard warnings.isEmpty || acknowledgesIncomplete else { throw VoiceError.partialAcknowledgementRequired }
        approvedRevision = reviewRevision
        return .init(runID: run.id, binding: run.binding, locale: run.locale, reviewRevision: reviewRevision,
                     text: transcript, digest: ContentDigest.sha256(Data(transcript.utf8)), incompleteWarnings: warnings)
    }
    public mutating func resetAfterClosed() throws {
        guard !isBusy else { throw VoiceError.resourceNotReleased }
        self = .init()
    }
    private func validLocale(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 80 && value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
        }
    }
    private func overlaps(_ a: SpeechSegment, _ b: SpeechSegment) -> Bool {
        a.startMilliseconds < b.endMilliseconds && b.startMilliseconds < a.endMilliseconds
    }
    private func join(_ segments: [SpeechSegment], locale: String) -> String {
        let key = locale.lowercased()
        let compact = key.hasPrefix("zh") || key.hasPrefix("ja") || key.hasPrefix("ko")
        var result = ""
        for segment in segments.sorted(by: { $0.startMilliseconds < $1.startMilliseconds }) {
            let value = segment.text
            if !result.isEmpty, !value.isEmpty, !compact,
               result.last?.isWhitespace == false, value.first?.isWhitespace == false,
               !".,!?;:)]}，。！？、".contains(value.first!) { result += " " }
            result += value
        }
        return result
    }
}
