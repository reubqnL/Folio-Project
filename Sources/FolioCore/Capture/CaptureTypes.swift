import Foundation

public enum CaptureError: Error, LocalizedError, Equatable, Sendable {
    case emptyInput, oversizedInput, oversizedContext, duplicateContext, foreignWorkspace
    case transcriptNotConfirmed, invalidSelection, protectedMetadata, targetTooLarge
    case busy, unavailable(String), cancelled, timedOut, providerFailed
    case invalidOutput, outputTooLarge, reviewTooComplex, emptyApproval, invalidApproval
    case staleTarget, wrongTarget, warningNotAcknowledged, sectionsCannotReplaceWholeBody
    case staleUndo, staleJob
    public var errorDescription: String? {
        switch self {
        case .emptyInput: "Add some text before requesting a structured draft."
        case .oversizedInput: "The capture input is too large for the chosen resource profile. Select a smaller passage; nothing was truncated or sent."
        case .oversizedContext: "The selected context exceeds the request budget. Remove or narrow an explicit selection; Folio will not silently drop context."
        case .duplicateContext: "That note is already included. Remove it explicitly before adding a different excerpt."
        case .foreignWorkspace: "Capture context belongs to a different project session."
        case .transcriptNotConfirmed: "Review and confirm the exact transcript before AI restructures it. Editing it invalidates its previous confirmation."
        case .invalidSelection: "The selected range is invalid or splits a Unicode character. Select the passage again."
        case .protectedMetadata: "AI changes cannot replace the note's front matter. Choose its body, a body selection or append."
        case .targetTooLarge: "The proposed replacement is too large for bounded review. Choose a smaller selection or append instead."
        case .busy: "A local generation is still running or cancelling. It must finish before another request starts."
        case .unavailable(let reason): "Local generation is unavailable: " + reason
        case .cancelled: "Generation was cancelled. No generated text was applied."
        case .timedOut: "The local model exceeded the waiting budget. Cancellation was requested; late output will be discarded."
        case .providerFailed: "The local model could not complete this request. Input was retained. Narrow the context or try again; there is no cloud fallback."
        case .invalidOutput: "The generated draft failed validation. No note was changed."
        case .outputTooLarge: "The generated draft exceeded the review budget. No note was changed."
        case .reviewTooComplex: "The draft exceeds the bounded section/diff review limits. Request a smaller draft."
        case .emptyApproval: "Choose at least one section or change to apply."
        case .invalidApproval: "This approval does not belong to the current draft. Review it again."
        case .staleTarget: "The note changed after this review began. Compare against its current version and approve again."
        case .wrongTarget: "This proposal belongs to another note or editor session."
        case .warningNotAcknowledged: "Review the draft warnings before applying it."
        case .sectionsCannotReplaceWholeBody: "Section selection is for appending or replacing an explicit selection. Use detailed comparison to selectively revise a whole note body."
        case .staleUndo: "Newer edits exist. Use native Undo or review the changes; Folio will not overwrite them with a stale undo."
        case .staleJob: "This generation no longer belongs to the current capture."
        }
    }
}

public struct CaptureWorkspace: Hashable, Sendable {
    public let projectID: UUID
    public let rootIdentity: String
    public let sessionID: UUID
    public init(projectID: UUID, rootIdentity: String, sessionID: UUID) {
        self.projectID = projectID; self.rootIdentity = rootIdentity; self.sessionID = sessionID
    }
}
public struct CaptureDocumentBinding: Hashable, Sendable {
    public let workspace: CaptureWorkspace
    public let noteID: UUID
    public let editorID: UUID
    public init(workspace: CaptureWorkspace, noteID: UUID, editorID: UUID) {
        self.workspace = workspace; self.noteID = noteID; self.editorID = editorID
    }
}
public struct CaptureTargetSnapshot: Equatable, Sendable {
    public let binding: CaptureDocumentBinding
    public let generation: Int
    public let text: String
    public let digest: String
    public init(binding: CaptureDocumentBinding, generation: Int, text: String) throws {
        guard generation >= 0, text.utf8.count <= 8 * 1024 * 1024, !text.contains("\0") else { throw CaptureError.targetTooLarge }
        self.binding = binding; self.generation = generation; self.text = text
        digest = ContentDigest.sha256(Data(text.utf8))
    }
}
public enum CaptureSourceKind: String, CaseIterable, Sendable { case typed, transcript }
public enum CaptureDestination: Equatable, Sendable {
    case append
    case selection(SourceSpan)
    case body
}
public struct CaptureContextFragment: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let workspace: CaptureWorkspace
    public let noteID: UUID
    public let title: String
    public let text: String
    public let sourceDigest: String
    public let range: SourceSpan?
    public init(workspace: CaptureWorkspace, noteID: UUID, title: String, source: String, range: SourceSpan? = nil) throws {
        guard !title.isEmpty, title.utf8.count <= 512, title.rangeOfCharacter(from: .controlCharacters) == nil else { throw CaptureError.oversizedContext }
        guard source.utf8.count <= 8 * 1024 * 1024 else { throw CaptureError.oversizedContext }
        let text = try range.map { try CaptureTextRanges.substring(source, span: $0) } ?? source
        guard !text.contains("\0") else { throw CaptureError.oversizedContext }
        id = UUID(); self.workspace = workspace; self.noteID = noteID; self.title = title
        self.text = text; self.range = range; sourceDigest = ContentDigest.sha256(Data(source.utf8))
    }
}

public struct CaptureBudget: Equatable, Sendable {
    public let maximumInputBytes: Int
    public let maximumContextBytes: Int
    public let maximumPromptBytes: Int
    public let maximumOutputBytes: Int
    public let maximumOutputTokens: Int
    public let timeoutMilliseconds: Int
    public init(profile: SearchProfile) {
        switch profile {
        case .lowMemory:
            maximumInputBytes = 2048; maximumContextBytes = 3072; maximumPromptBytes = 7168
            maximumOutputBytes = 12 * 1024; maximumOutputTokens = 512; timeoutMilliseconds = 30_000
        case .balanced:
            maximumInputBytes = 4096; maximumContextBytes = 4096; maximumPromptBytes = 10_240
            maximumOutputBytes = 24 * 1024; maximumOutputTokens = 768; timeoutMilliseconds = 45_000
        case .largeVault:
            maximumInputBytes = 5120; maximumContextBytes = 5120; maximumPromptBytes = 12_288
            maximumOutputBytes = 32 * 1024; maximumOutputTokens = 1024; timeoutMilliseconds = 60_000
        }
    }
}

public struct CaptureDraft: Sendable {
    public let id: UUID
    public let target: CaptureDocumentBinding
    public private(set) var revision: UUID
    public private(set) var input = ""
    public private(set) var sourceKind: CaptureSourceKind = .typed
    public private(set) var destination: CaptureDestination = .append
    public private(set) var contexts: [CaptureContextFragment] = []
    private var selectionDigest: String?
    private var selectionGeneration: Int?
    private var confirmedTranscriptDigest: String?
    private var confirmedTranscriptRevision: UUID?

    public init(target: CaptureDocumentBinding) { id = UUID(); self.target = target; revision = UUID() }
    public mutating func editInput(_ value: String, kind: CaptureSourceKind) {
        if input != value || sourceKind != kind {
            input = value; sourceKind = kind; revision = UUID()
            confirmedTranscriptDigest = nil; confirmedTranscriptRevision = nil
        }
    }
    public mutating func setDestination(_ value: CaptureDestination, target snapshot: CaptureTargetSnapshot? = nil) {
        let digest: String?, generation: Int?
        if case .selection = value, snapshot?.binding == target { digest = snapshot?.digest; generation = snapshot?.generation }
        else { digest = nil; generation = nil }
        if destination != value || selectionDigest != digest || selectionGeneration != generation {
            destination = value; selectionDigest = digest; selectionGeneration = generation; revision = UUID()
        }
    }
    public func destinationMatches(_ snapshot: CaptureTargetSnapshot) -> Bool {
        guard case .selection = destination else { return true }
        return snapshot.binding == target && snapshot.digest == selectionDigest && snapshot.generation == selectionGeneration
    }
    public mutating func addContext(_ fragment: CaptureContextFragment) throws {
        guard fragment.workspace == target.workspace else { throw CaptureError.foreignWorkspace }
        guard contexts.count < 8 else { throw CaptureError.oversizedContext }
        guard !contexts.contains(where: { $0.noteID == fragment.noteID }) else { throw CaptureError.duplicateContext }
        contexts.append(fragment); revision = UUID()
    }
    public mutating func removeContext(_ id: UUID) { contexts.removeAll { $0.id == id }; revision = UUID() }
    public mutating func confirmTranscript() throws {
        guard sourceKind == .transcript, !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CaptureError.emptyInput }
        confirmedTranscriptDigest = ContentDigest.sha256(Data(input.utf8))
        confirmedTranscriptRevision = revision
    }
    /// Only a closed, explicitly reviewed speech result can enter capture. It
    /// is bound to this exact draft revision; no prior proposal is auto-applied.
    public mutating func importReviewedVoice(_ voice: ReviewedVoiceTranscript) throws {
        guard voice.binding.target == target, voice.binding.draftID == id else { throw VoiceError.wrongCapture }
        guard voice.binding.draftRevision == revision,
              voice.digest == ContentDigest.sha256(Data(voice.text.utf8)) else { throw VoiceError.staleReview }
        editInput(voice.text, kind: .transcript)
        try confirmTranscript()
    }
    public var transcriptIsConfirmed: Bool {
        sourceKind != .transcript || (confirmedTranscriptRevision == revision && confirmedTranscriptDigest == ContentDigest.sha256(Data(input.utf8)))
    }
}

public enum CaptureTextRanges {
    public static func validate(_ span: SourceSpan, in text: String) throws {
        let total = text.utf16.count
        guard span.location >= 0, span.length >= 0, span.location <= total, span.length <= total - span.location else { throw CaptureError.invalidSelection }
        let end = span.location + span.length
        if (span.location == 0 || span.location == total) && (end == 0 || end == total) { return }
        var offset = 0, foundStart = span.location == 0, foundEnd = end == 0
        for character in text {
            offset += String(character).utf16.count
            if offset == span.location { foundStart = true }
            if offset == end { foundEnd = true }
            if offset >= end { break }
        }
        guard foundStart && foundEnd else { throw CaptureError.invalidSelection }
    }
    public static func substring(_ text: String, span: SourceSpan) throws -> String {
        try validate(span, in: text)
        return (text as NSString).substring(with: NSRange(location: span.location, length: span.length))
    }
    public static func replacing(_ text: String, span: SourceSpan, with replacement: String) throws -> String {
        try validate(span, in: text)
        let source = text as NSString
        return source.replacingCharacters(in: NSRange(location: span.location, length: span.length), with: replacement)
    }
    /// Protect a leading YAML-style front-matter block, including BOM/newlines.
    /// An ambiguous/unclosed leading marker is not guessed safe for replacement.
    public static func bodyRange(in text: String) throws -> SourceSpan {
        let full = text as NSString
        let probe = String(text.prefix(16_384))
        let ns = probe as NSString
        var offset = 0
        let first = ns.lineRange(for: NSRange(location: 0, length: 0))
        if ns.length == 0 { return .init(location: 0, length: 0) }
        let firstText = ns.substring(with: first).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.init(charactersIn: "\u{FEFF}")))
        guard firstText == "---" else { return .init(location: 0, length: full.length) }
        offset = NSMaxRange(first)
        while offset < ns.length {
            let line = ns.lineRange(for: NSRange(location: offset, length: 0))
            let value = ns.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines)
            if value == "---" || value == "..." { let end = NSMaxRange(line); return .init(location: end, length: full.length - end) }
            offset = NSMaxRange(line)
        }
        throw CaptureError.protectedMetadata
    }
    public static func targetRange(_ destination: CaptureDestination, in text: String) throws -> SourceSpan {
        switch destination {
        case .append: return .init(location: text.utf16.count, length: 0)
        case .body:
            let range = try bodyRange(in: text)
            guard try substring(text, span: range).utf8.count <= 24 * 1024 else { throw CaptureError.targetTooLarge }
            return range
        case .selection(let range):
            try validate(range, in: text)
            guard range.length > 0 else { throw CaptureError.invalidSelection }
            let body = try bodyRange(in: text)
            guard range.location >= body.location else { throw CaptureError.protectedMetadata }
            guard try substring(text, span: range).utf8.count <= 24 * 1024 else { throw CaptureError.targetTooLarge }
            return range
        }
    }
    public static func newline(in text: String) -> String { text.contains("\r\n") ? "\r\n" : "\n" }
    public static func normalizeNewlines(_ text: String, to ending: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").replacingOccurrences(of: "\n", with: ending)
    }
}
