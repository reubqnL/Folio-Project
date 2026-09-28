import Foundation

public struct CaptureChange: Identifiable, Equatable, Sendable {
    public let id: String
    public let range: SourceSpan
    public let before: String
    public let after: String
}
public struct CaptureSection: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let text: String
}

public enum CaptureDiff {
    /// Bounded line-level LCS. No unbounded quadratic work on large note bodies.
    public static func changes(before: String, after: String) throws -> [CaptureChange] {
        guard before.utf8.count <= 32 * 1024, after.utf8.count <= 36 * 1024 else { throw CaptureError.reviewTooComplex }
        let a = lines(before), b = lines(after)
        guard a.count <= 400, b.count <= 400 else { throw CaptureError.reviewTooComplex }
        let width = b.count + 1
        var lengths = [UInt16](repeating: 0, count: (a.count + 1) * width)
        if !a.isEmpty && !b.isEmpty {
            for i in stride(from: a.count - 1, through: 0, by: -1) {
                for j in stride(from: b.count - 1, through: 0, by: -1) {
                    lengths[i * width + j] = a[i] == b[j] ? lengths[(i+1) * width + j+1] + 1 : max(lengths[(i+1) * width + j], lengths[i * width + j+1])
                }
            }
        }
        var result: [CaptureChange] = [], i = 0, j = 0, offset = 0
        var start: Int?, removed = "", inserted = ""
        func flush() {
            guard let position = start else { return }
            let identity = "\(position):\(removed.utf16.count):" + removed + "\u{001F}" + inserted
            result.append(.init(id: ContentDigest.sha256(Data(identity.utf8)), range: .init(location: position, length: removed.utf16.count), before: removed, after: inserted))
            start = nil; removed = ""; inserted = ""
        }
        while i < a.count || j < b.count {
            if i < a.count && j < b.count && a[i] == b[j] {
                flush(); offset += a[i].utf16.count; i += 1; j += 1
            } else if j < b.count && (i == a.count || lengths[i * width + j+1] >= lengths[(i+1) * width + j]) {
                if start == nil { start = offset }
                inserted += b[j]; j += 1
            } else {
                if start == nil { start = offset }
                removed += a[i]; offset += a[i].utf16.count; i += 1
            }
        }
        flush(); return result
    }
    public static func apply(_ changes: [CaptureChange], selected: Set<String>, to before: String) throws -> String {
        guard !selected.isEmpty else { throw CaptureError.emptyApproval }
        let known = Set(changes.map(\.id))
        guard selected.isSubset(of: known) else { throw CaptureError.invalidApproval }
        var result = before
        for change in changes.reversed() where selected.contains(change.id) {
            guard try CaptureTextRanges.substring(before, span: change.range) == change.before else { throw CaptureError.invalidApproval }
            result = try CaptureTextRanges.replacing(result, span: change.range, with: change.after)
        }
        return result
    }
    private static func lines(_ text: String) -> [String] {
        var result: [String] = [], line = ""
        for character in text {
            line.append(character)
            if character.isNewline { result.append(line); line = "" }
        }
        if !line.isEmpty { result.append(line) }
        return result
    }
}

public struct CaptureProposal: Sendable {
    public let id: UUID
    public let originalRequestID: UUID
    public let draftID: UUID
    public let draftRevision: UUID
    public let target: CaptureTargetSnapshot
    public let destination: CaptureDestination
    public let range: SourceSpan
    public let rawOutput: String
    public let displayedOutput: String
    public let replacement: String
    public let beforeTarget: String
    public let sections: [CaptureSection]
    public let changes: [CaptureChange]
    public let warnings: [String]
    public let comparesNewerTarget: Bool
    let budget: CaptureBudget

    public static func make(request: PreparedCapture, output: String) throws -> Self {
        try make(originalRequestID: request.id, draftID: request.draftID, draftRevision: request.draftRevision,
                 target: request.target, destination: request.destination, output: output, budget: request.budget, rebased: false)
    }
    private static func make(originalRequestID: UUID, draftID: UUID, draftRevision: UUID,
                             target: CaptureTargetSnapshot, destination: CaptureDestination, output: String,
                             budget: CaptureBudget, rebased: Bool) throws -> Self {
        let warnings = try CaptureOutputValidation.validate(output, budget: budget)
        let range = try CaptureTextRanges.targetRange(destination, in: target.text)
        let before = try CaptureTextRanges.substring(target.text, span: range)
        let ending = CaptureTextRanges.newline(in: target.text)
        let normalized = CaptureTextRanges.normalizeNewlines(output, to: ending)
        let prefix = appendSeparator(destination: destination, text: target.text, ending: ending)
        let replacement = prefix + normalized
        let diff = try CaptureDiff.changes(before: before, after: replacement)
        let sections = try splitSections(normalized)
        return .init(id: UUID(), originalRequestID: originalRequestID, draftID: draftID, draftRevision: draftRevision,
                     target: target, destination: destination, range: range, rawOutput: output, displayedOutput: normalized,
                     replacement: replacement, beforeTarget: before, sections: sections, changes: diff, warnings: warnings,
                     comparesNewerTarget: rebased, budget: budget)
    }
    /// Explicitly creates a new review, never carries approval IDs forward.
    /// Selection replacement requires a NEW user-selected range in the current
    /// text; an old offset is not automatically relocated into newer writing.
    public func comparingCurrent(_ current: CaptureTargetSnapshot, newSelection: SourceSpan? = nil) throws -> Self {
        guard current.binding == target.binding else { throw CaptureError.wrongTarget }
        let destination: CaptureDestination
        switch self.destination {
        case .selection:
            guard let newSelection else { throw CaptureError.invalidSelection }
            destination = .selection(newSelection)
        default: destination = self.destination
        }
        return try Self.make(originalRequestID: originalRequestID, draftID: draftID, draftRevision: draftRevision,
                             target: current, destination: destination, output: rawOutput, budget: budget, rebased: true)
    }
    public func editingOutput(_ output: String) throws -> Self {
        try Self.make(originalRequestID: originalRequestID, draftID: draftID, draftRevision: draftRevision,
                      target: target, destination: destination, output: output, budget: budget, rebased: comparesNewerTarget)
    }
    public func plan(_ approval: CaptureApproval, current: CaptureTargetSnapshot) throws -> CaptureTextEdit {
        guard current.binding == target.binding else { throw CaptureError.wrongTarget }
        guard current.generation == target.generation, current.digest == target.digest else { throw CaptureError.staleTarget }
        guard approval.proposalID == id else { throw CaptureError.invalidApproval }
        guard warnings.isEmpty || approval.acknowledgesWarnings else { throw CaptureError.warningNotAcknowledged }
        let text: String
        switch approval.selection {
        case .wholeDraft: text = replacement
        case .sections(let selected):
            if case .body = destination { throw CaptureError.sectionsCannotReplaceWholeBody }
            guard !selected.isEmpty else { throw CaptureError.emptyApproval }
            guard selected.isSubset(of: Set(sections.map(\.id))) else { throw CaptureError.invalidApproval }
            let ending = CaptureTextRanges.newline(in: target.text)
            let pieces = sections.filter { selected.contains($0.id) }.map { $0.text.trimmingCharacters(in: .newlines) }
            text = Self.appendSeparator(destination: destination, text: target.text, ending: ending) + pieces.joined(separator: ending + ending)
        case .changes(let selected): text = try CaptureDiff.apply(changes, selected: selected, to: beforeTarget)
        }
        let after = try CaptureTextRanges.replacing(current.text, span: range, with: text)
        guard after != current.text else { throw CaptureError.emptyApproval }
        guard after.utf8.count <= 8 * 1024 * 1024 else { throw CaptureError.targetTooLarge }
        return .init(id: UUID(), proposalID: id, binding: target.binding,
                     expectedGeneration: target.generation, expectedDigest: target.digest,
                     range: range, replacement: text, beforeFragment: beforeTarget,
                     afterDigest: ContentDigest.sha256(Data(after.utf8)), resultingText: after)
    }
    private static func appendSeparator(destination: CaptureDestination, text: String, ending: String) -> String {
        guard case .append = destination, !text.isEmpty else { return "" }
        if text.hasSuffix(ending + ending) { return "" }
        return text.hasSuffix(ending) ? ending : ending + ending
    }
    private static func splitSections(_ output: String) throws -> [CaptureSection] {
        let parsed = MarkdownParser.parse(output)
        guard !parsed.isLimited else { throw CaptureError.reviewTooComplex }
        var starts: [(Int, String)] = [(0, "Draft")]
        for block in parsed.blocks {
            guard case .heading(let level, let text) = block.kind, level <= 2 else { continue }
            let title = MarkdownText.plain(text)
            if block.source.location == 0 { starts[0].1 = title }
            else { starts.append((block.source.location, title)) }
        }
        guard starts.count <= 128 else { throw CaptureError.reviewTooComplex }
        let ns = output as NSString
        return starts.indices.map { index in
            let position = starts[index].0, end = index + 1 < starts.count ? starts[index+1].0 : ns.length
            let text = ns.substring(with: NSRange(location: position, length: end - position))
            return .init(id: ContentDigest.sha256(Data(("\(index):" + text).utf8)), title: starts[index].1, text: text)
        }
    }
}

public enum CaptureApprovalSelection: Sendable {
    case wholeDraft
    case sections(Set<String>)
    case changes(Set<String>)
}
public struct CaptureApproval: Sendable {
    public let proposalID: UUID
    public let selection: CaptureApprovalSelection
    public let acknowledgesWarnings: Bool
    public init(proposalID: UUID, selection: CaptureApprovalSelection, acknowledgesWarnings: Bool = false) {
        self.proposalID = proposalID; self.selection = selection; self.acknowledgesWarnings = acknowledgesWarnings
    }
}
public struct CaptureTextEdit: Sendable, Identifiable {
    public let id: UUID
    public let proposalID: UUID
    public let binding: CaptureDocumentBinding
    public let expectedGeneration: Int
    public let expectedDigest: String
    public let range: SourceSpan
    public let replacement: String
    public let beforeFragment: String
    public let afterDigest: String
    public let resultingText: String
    public func validate(current: CaptureTargetSnapshot) throws {
        guard current.binding == binding else { throw CaptureError.wrongTarget }
        guard current.generation == expectedGeneration, current.digest == expectedDigest else { throw CaptureError.staleTarget }
        guard try CaptureTextRanges.substring(current.text, span: range) == beforeFragment else { throw CaptureError.invalidSelection }
        let applied = try CaptureTextRanges.replacing(current.text, span: range, with: replacement)
        guard ContentDigest.sha256(Data(applied.utf8)) == afterDigest else { throw CaptureError.invalidApproval }
    }
}
public struct CaptureUndoReceipt: Sendable {
    public let edit: CaptureTextEdit
    public let observedGeneration: Int
    public init(edit: CaptureTextEdit, applied: CaptureTargetSnapshot) throws {
        guard applied.binding == edit.binding, applied.digest == edit.afterDigest,
              applied.generation > edit.expectedGeneration else { throw CaptureError.staleUndo }
        self.edit = edit; self.observedGeneration = applied.generation
    }
    public func inverse(current: CaptureTargetSnapshot) throws -> CaptureTextEdit {
        guard current.binding == edit.binding, current.digest == edit.afterDigest,
              current.generation == observedGeneration else { throw CaptureError.staleUndo }
        let range = SourceSpan(location: edit.range.location, length: edit.replacement.utf16.count)
        let restored = try CaptureTextRanges.replacing(current.text, span: range, with: edit.beforeFragment)
        guard ContentDigest.sha256(Data(restored.utf8)) == edit.expectedDigest else { throw CaptureError.staleUndo }
        return .init(id: UUID(), proposalID: edit.proposalID, binding: edit.binding,
                     expectedGeneration: current.generation, expectedDigest: current.digest,
                     range: range, replacement: edit.beforeFragment, beforeFragment: edit.replacement,
                     afterDigest: edit.expectedDigest, resultingText: restored)
    }
}
