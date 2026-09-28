import Foundation

public enum VoiceError: Error, LocalizedError, Equatable, Sendable {
    case consentRequired, busy, staleRun, unsupportedLocale, assetsMissing, permissionDenied
    case invalidState, invalidResult, transcriptTooLarge, emptyTranscript, reviewRequired
    case partialAcknowledgementRequired, invalidAudioFormat, audioOverflow, captureFailed
    case resourceNotReleased, wrongCapture, staleReview
    public var errorDescription: String? {
        switch self {
        case .consentRequired: "Microphone use and language-asset downloads require separate explicit actions."
        case .busy: "A speech session is still preparing, recording or stopping. Wait for its resources to close."
        case .staleRun: "This event belongs to an earlier speech session and was ignored."
        case .unsupportedLocale: "On-device speech is unavailable for this language/device. Text input remains available; no cloud fallback is used."
        case .assetsMissing: "Install the explicitly selected Apple language assets before recording."
        case .permissionDenied: "Microphone access was denied or restricted. No recording was started."
        case .invalidState: "That speech action is not available in the current lifecycle state."
        case .invalidResult: "A speech result failed its bounds/order checks. Review retained text; no result was applied automatically."
        case .transcriptTooLarge: "The transcript reached its safety limit. Stop and review; nothing will be silently truncated for AI."
        case .emptyTranscript: "There is no transcript text to approve."
        case .reviewRequired: "Stop recording and review the transcript before using it."
        case .partialAcknowledgementRequired: "This recording may be incomplete. Review and explicitly acknowledge that before using the text."
        case .invalidAudioFormat: "This audio format is unsupported by the bounded local capture pipeline."
        case .audioOverflow: "Audio processing fell behind. Capture stopped rather than silently dropping audio. Review the incomplete transcript."
        case .captureFailed: "Local speech capture failed. No cloud provider was used. Review any retained partial text."
        case .resourceNotReleased: "The microphone/analyzer has not acknowledged closure. A new capture is blocked."
        case .wrongCapture: "This transcript belongs to a different note or capture session."
        case .staleReview: "The transcript or capture changed after review. Approve the current version again."
        }
    }
}
public enum MicrophonePermission: String, Sendable { case notDetermined, granted, denied, restricted }
public enum SpeechCapability: Equatable, Sendable {
    case ready(locale: String)
    case needsAssets(locale: String)
    case downloading(locale: String)
    case unavailable(String)
    public var locale: String? {
        switch self { case .ready(let value), .needsAssets(let value), .downloading(let value): value; case .unavailable: nil }
    }
}
public struct VoiceLimits: Equatable, Sendable {
    public let maximumMilliseconds: Int64
    public let maximumTranscriptBytes: Int
    public let maximumSegments: Int
    public let queueSlots: Int
    public init(profile: SearchProfile) {
        maximumSegments = 512
        switch profile {
        case .lowMemory: maximumMilliseconds = 60_000; maximumTranscriptBytes = 16 * 1024; queueSlots = 4
        case .balanced: maximumMilliseconds = 120_000; maximumTranscriptBytes = 24 * 1024; queueSlots = 8
        case .largeVault: maximumMilliseconds = 180_000; maximumTranscriptBytes = 32 * 1024; queueSlots = 8
        }
    }
}
public struct VoiceCaptureBinding: Equatable, Sendable {
    public let target: CaptureDocumentBinding
    public let draftID: UUID
    public let draftRevision: UUID
    public init(draft: CaptureDraft) { target = draft.target; draftID = draft.id; draftRevision = draft.revision }
}
public struct VoiceRun: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let binding: VoiceCaptureBinding
    public let locale: String
    public let limits: VoiceLimits
}
public struct SpeechSegment: Equatable, Sendable, Identifiable {
    public var id: String { "\(startMilliseconds):\(endMilliseconds)" }
    public let startMilliseconds: Int64
    public let endMilliseconds: Int64
    public let text: String
    public let isFinal: Bool
    public init(startMilliseconds: Int64, endMilliseconds: Int64, text: String, isFinal: Bool) {
        self.startMilliseconds = startMilliseconds; self.endMilliseconds = endMilliseconds; self.text = text; self.isFinal = isFinal
    }
}
public enum VoiceStopReason: String, CaseIterable, Sendable {
    case requested, durationLimit, audioOverflow, deviceChanged, applicationInactive, systemSleep, processingFailure, finalizationTimeout
    public var warning: String? {
        switch self {
        case .requested: nil
        case .durationLimit: "Recording stopped at the selected profile's duration limit."
        case .audioOverflow: "Audio processing could not keep up; some speech may be missing."
        case .deviceChanged: "The input device changed or became unavailable."
        case .applicationInactive: "Folio lost focus, so microphone capture was stopped."
        case .systemSleep: "The Mac was going to sleep, so microphone capture was stopped."
        case .processingFailure: "Speech processing failed before a normal complete finish."
        case .finalizationTimeout: "Final transcription did not finish within the waiting budget."
        }
    }
}
public enum VoicePhase: String, Sendable {
    case idle, awaitingPermission, preparing, recording, stopping, cancelling, review, cancelled, failed
}
public struct ReviewedVoiceTranscript: Sendable {
    public let runID: UUID
    public let binding: VoiceCaptureBinding
    public let locale: String
    public let reviewRevision: UUID
    public let text: String
    public let digest: String
    public let incompleteWarnings: [String]
}

/// An app-owned reservation set. Never releases another subsystem's language
/// reservation just to make room. Apple still controls eventual asset deletion.
public struct SpeechReservationLedger: Sendable {
    private var owned = Set<String>()
    public init() {}
    public init(restoring locales: [String]) {
        owned = Set(locales.prefix(20).filter { value in
            !value.isEmpty && value.utf8.count <= 80 && value.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
            }
        })
    }
    public mutating func didReserve(locale: String, newlyReserved: Bool) { if newlyReserved { owned.insert(locale) } }
    public func mayRelease(_ locale: String) -> Bool { owned.contains(locale) }
    public mutating func didRelease(_ locale: String, succeeded: Bool) { if succeeded { owned.remove(locale) } }
    public var ownedLocales: [String] { owned.sorted() }
}
