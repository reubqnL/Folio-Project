import Foundation

/// Measured outcome of one incremental reparse. Block counts are the honest
/// benchmark: expensive per-block work (inline parse, digests) must stay
/// proportional to the edited window, not the document.
public struct MarkdownReparseMetrics: Equatable, Sendable {
    public var blocksReparsed: Int
    public var blocksReused: Int
    public var usedFullParse: Bool
    public init(blocksReparsed: Int, blocksReused: Int, usedFullParse: Bool) {
        self.blocksReparsed = blocksReparsed
        self.blocksReused = blocksReused
        self.usedFullParse = usedFullParse
    }
}

/// Result of one reparse step: the current document plus what the step cost.
public struct MarkdownReparseResult: Sendable {
    public let document: MarkdownDocument
    public let metrics: MarkdownReparseMetrics
}

/// Incremental Markdown reparse session (N02: no whole-document parsing work
/// per keystroke).
///
/// The session keeps the last detailed parse and splices it on edit:
/// 1. The changed lines are localised by a common line prefix/suffix scan
///    (cheap line equality; no per-block parsing).
/// 2. Only the affected block window is reparsed. The window is grown until
///    its parse provably ends between blocks (atomic/completed block, trailing
///    blank lines, a closed fence, the front-matter closer, or end of source),
///    so the unchanged suffix parses identically in context and standalone.
/// 3. Unchanged blocks before and after the window are reused with shifted
///    spans; block identities are renumbered with the parser's exact
///    content+occurrence rule.
/// Any doubt — a limited or cancelled parse, a changed block budget, a
/// catastrophic edit — falls back to a full parse. `reparse` is therefore
/// always equal to `MarkdownParser.parse` on the same source, and tests
/// assert that equivalence directly.
public struct MarkdownReparseSession: Sendable {
    public let limits: MarkdownLimits
    public private(set) var source: String
    public private(set) var document: MarkdownDocument

    private var records: [ParsedBlockRecord]
    private var lineTexts: [String]
    private var lineStarts: [Int]
    private var lineEnds: [Int]

    public init(source: String, limits: MarkdownLimits = .init()) {
        self.limits = limits
        let record = MarkdownParser.parseDetailed(source, limits: limits)
        let split = MarkdownParser.splitLines(source)
        self.source = source
        self.document = MarkdownParser.project(record)
        self.records = record.blocks
        self.lineTexts = split.texts
        self.lineStarts = split.starts
        self.lineEnds = split.ends
    }

    private static let unclosedFenceWarning = "An unclosed code fence is shown as code through the end of the note."
    private static let tableCapWarning = "A table exceeded 200 rendered rows; remaining lines are shown as ordinary text."
    private static let frontMatterClosers = ["---", "..."]

    public mutating func reparse(_ newSource: String) -> MarkdownReparseResult {
        let metrics = performReparse(newSource)
        return .init(document: document, metrics: metrics)
    }

    private mutating func performReparse(_ newSource: String) -> MarkdownReparseMetrics {
        if newSource == source {
            return .init(blocksReparsed: 0, blocksReused: records.count, usedFullParse: false)
        }

        func commitFull() -> MarkdownReparseMetrics {
            let record = MarkdownParser.parseDetailed(newSource, limits: limits)
            let split = MarkdownParser.splitLines(newSource)
            source = newSource
            document = MarkdownParser.project(record)
            records = record.blocks
            lineTexts = split.texts
            lineStarts = split.starts
            lineEnds = split.ends
            return .init(blocksReparsed: record.blocks.count, blocksReused: 0, usedFullParse: true)
        }

        // Only a complete, unlimited previous parse can be spliced.
        guard document.limitation == nil, newSource.utf8.count <= limits.maximumUTF8Bytes else {
            return commitFull()
        }

        let oldTexts = lineTexts, oldRecords = records, oldSource = source
        let oldUTF16Count = oldSource.utf16.count
        let split = MarkdownParser.splitLines(newSource)
        let newTexts = split.texts, newStarts = split.starts

        // Localise the edit to a common line prefix and suffix.
        var prefix = 0
        while prefix < oldTexts.count, prefix < newTexts.count, oldTexts[prefix] == newTexts[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < oldTexts.count - prefix, suffix < newTexts.count - prefix,
              oldTexts[oldTexts.count - 1 - suffix] == newTexts[newTexts.count - 1 - suffix] { suffix += 1 }
        let oldCut = oldTexts.count - suffix
        // A full-document change has nothing reusable to splice.
        guard !(prefix == 0 && suffix == 0) else { return commitFull() }

        // The window starts at the first old block whose end could be moved by
        // the edit. Block-boundary decisions at a line examine that line and
        // the one after it (setext underlines, table alignment rows), so a
        // block ending at prefix-2 is still unstable; blocks ending earlier
        // are decided entirely by unchanged lines and are safe to keep.
        var windowStart = min(prefix, oldRecords.first(where: { $0.lastLine >= prefix - 2 })?.firstLine ?? prefix)
        // The front-matter scan decides from the first ~129 lines of the whole
        // document; an edit anywhere in that range can change it, so those
        // edits reparse from line 0.
        if prefix < 129 { windowStart = 0 }
        let deltaLines = newTexts.count - oldTexts.count
        var windowEnd: Int
        if let boundary = oldRecords.first(where: { $0.firstLine >= oldCut }) {
            windowEnd = boundary.firstLine + deltaLines
        } else {
            windowEnd = newTexts.count
        }
        if windowEnd < windowStart { return commitFull() }

        // Grow the window until its parse provably ends between blocks.
        while true {
            let windowRecord: ParsedDocumentRecord
            if windowEnd == windowStart {
                windowRecord = .init(blocks: [], sourceUTF16Length: 0, lineStarts: [], lineCount: 0, limitation: nil)
            } else {
                let startOffset = newStarts[windowStart]
                let endOffset = windowEnd < newTexts.count ? newStarts[windowEnd] : newSource.utf16.count
                let windowText = String(decoding: newSource.utf16.dropFirst(startOffset).prefix(endOffset - startOffset), as: UTF16.self)
                let parsed = MarkdownParser.parseDetailed(windowText, limits: limits, frontMatter: windowStart == 0)
                guard parsed.limitation == nil, parsed.lineCount == windowEnd - windowStart else {
                    return commitFull()
                }
                windowRecord = parsed
            }

            // Front matter is document-start context: the window must see the
            // same first closer a full parse would.
            if windowStart == 0,
               let closer = (1..<min(newTexts.count, 129)).first(where: {
                   Self.frontMatterClosers.contains(newTexts[$0].trimmingCharacters(in: .whitespaces))
               }),
               closer + 1 > windowEnd {
                windowEnd = closer + 1
                continue
            }

            // No old block may straddle the window end: its mapped tail would
            // be dropped by the splice. Grow past any straddling block.
            // Front-matter blocks are document-start context and are never
            // reused on the suffix side, so they must always be covered.
            var required = windowEnd
            for record in oldRecords {
                if record.lastLine < windowStart || record.lastLine < oldCut { continue }
                let isMetadata: Bool = if case .metadata = record.block.kind { true } else { false }
                if record.firstLine >= oldCut && record.firstLine + deltaLines >= windowEnd && !isMetadata { continue }
                let mappedTail = record.lastLine + deltaLines
                if mappedTail >= windowEnd { required = max(required, mappedTail + 1) }
            }
            if required > windowEnd {
                windowEnd = required
                continue
            }

            if windowEnd >= newTexts.count || provenBoundary(windowRecord, windowLineCount: windowEnd - windowStart) {
                return splice(
                    windowRecord: windowRecord,
                    oldRecords: oldRecords, oldUTF16Count: oldUTF16Count,
                    prefix: prefix, windowStart: windowStart, windowEnd: windowEnd,
                    deltaLines: deltaLines, newSource: newSource, newTexts: newTexts,
                    newStarts: newStarts, newEnds: split.ends
                )
            }

            // Not proven: grow the window and parse again.
            if let last = windowRecord.blocks.last, last.lastLine == windowEnd - windowStart - 1,
               case .code = last.block.kind, last.warnings.contains(Self.unclosedFenceWarning) {
                // An unclosed fence may close later in the suffix. Close it
                // inside the window, or swallow the tail when it never closes
                // (the full parse would treat it as code to the end too).
                let opening = newTexts[windowStart + last.firstLine]
                if let fence = MarkdownParser.openingFence(opening) {
                    if let closerIndex = (windowEnd..<newTexts.count).first(where: {
                        MarkdownParser.closesFence(newTexts[$0].trimmingCharacters(in: .whitespaces), marker: fence.marker, count: fence.count)
                    }) {
                        windowEnd = closerIndex + 1
                    } else {
                        windowEnd = newTexts.count
                    }
                    continue
                }
                return commitFull()
            }
            // Any other reaching-EOF block (paragraph, table, quote, literal
            // HTML) may continue across the boundary; extend to the next blank
            // line — none of those constructs can span one.
            var probe = windowEnd
            while probe < newTexts.count, !newTexts[probe].trimmingCharacters(in: .whitespaces).isEmpty { probe += 1 }
            if probe < newTexts.count { probe += 1 }
            if probe <= windowEnd { return commitFull() }
            windowEnd = probe
        }
    }

    /// A window parse that ends at end-of-source is trivially aligned; at any
    /// earlier boundary it must end on a block that cannot swallow the next
    /// line and whose own formation did not look past the window (setext and
    /// table pairing examine one line ahead).
    private func provenBoundary(_ record: ParsedDocumentRecord, windowLineCount: Int) -> Bool {
        guard let last = record.blocks.last else { return true }
        if last.lastLine < windowLineCount - 1 { return true }
        switch last.block.kind {
        case .code:
            return !last.warnings.contains(Self.unclosedFenceWarning)
        case .table:
            return last.warnings.contains(Self.tableCapWarning)
        case .paragraph, .quote, .literalHTML, .listItem, .rule:
            return false
        default:
            return true
        }
    }

    /// Joins kept prefix blocks, the reparsed window and kept suffix blocks,
    /// then renumbers identities with the parser's content+occurrence rule.
    private mutating func splice(
        windowRecord: ParsedDocumentRecord,
        oldRecords: [ParsedBlockRecord], oldUTF16Count: Int,
        prefix: Int, windowStart: Int, windowEnd: Int,
        deltaLines: Int, newSource: String, newTexts: [String],
        newStarts: [Int], newEnds: [Int]
    ) -> MarkdownReparseMetrics {
        let startOffset = newStarts[windowStart]
        let utf16Delta = newSource.utf16.count - oldUTF16Count
        var merged: [ParsedBlockRecord] = []
        merged.reserveCapacity(oldRecords.count + windowRecord.blocks.count)

        // Kept blocks end before the window starts; blocks reaching the edit
        // boundary line join the window and are reparsed there.
        for record in oldRecords where record.lastLine < windowStart {
            merged.append(record)
        }
        for record in windowRecord.blocks {
            var moved = record
            moved.firstLine = record.firstLine + windowStart
            moved.lastLine = record.lastLine + windowStart
            moved.block = MarkdownBlock(
                id: record.block.id,
                source: .init(location: record.block.source.location + startOffset, length: record.block.source.length),
                kind: record.block.kind
            )
            merged.append(moved)
        }
        for record in oldRecords where record.firstLine + deltaLines >= windowEnd {
            // Front-matter blocks are document-start context: mid-document
            // they parse as ordinary blocks, so they are never suffix-reused.
            if case .metadata = record.block.kind { continue }
            var moved = record
            moved.firstLine = record.firstLine + deltaLines
            moved.lastLine = record.lastLine + deltaLines
            moved.block = MarkdownBlock(
                id: record.block.id,
                source: .init(location: record.block.source.location + utf16Delta, length: record.block.source.length),
                kind: record.block.kind
            )
            merged.append(moved)
        }

        // Match the parser's exact block-budget semantics via fallback.
        if merged.count >= limits.maximumBlocks {
            let record = MarkdownParser.parseDetailed(newSource, limits: limits)
            let split = MarkdownParser.splitLines(newSource)
            source = newSource
            document = MarkdownParser.project(record)
            records = record.blocks
            lineTexts = split.texts
            lineStarts = split.starts
            lineEnds = split.ends
            return .init(blocksReparsed: record.blocks.count, blocksReused: 0, usedFullParse: true)
        }

        var counts: [String: Int] = [:]
        var finalRecords: [ParsedBlockRecord] = []
        finalRecords.reserveCapacity(merged.count)
        for record in merged {
            let occurrence = counts[record.digest, default: 0]
            counts[record.digest] = occurrence + 1
            var renamed = record
            renamed.block = MarkdownBlock(
                id: String(record.digest.prefix(24)) + "-\(occurrence)",
                source: record.block.source,
                kind: record.block.kind
            )
            finalRecords.append(renamed)
        }

        source = newSource
        records = finalRecords
        document = MarkdownDocument(
            blocks: finalRecords.map(\.block),
            sourceUTF16Length: newSource.utf16.count,
            warnings: Array(Set(finalRecords.flatMap(\.warnings))).sorted(),
            limitation: nil
        )
        lineTexts = newTexts
        lineStarts = newStarts
        lineEnds = newEnds
        return .init(
            blocksReparsed: windowRecord.blocks.count,
            blocksReused: finalRecords.count - windowRecord.blocks.count,
            usedFullParse: false
        )
    }
}
