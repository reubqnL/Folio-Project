import Foundation

// Increment 11 — compact link repair (N02; baseline §4.2 "broken links remain
// visible and repairable"; decision 12 "keep the original link until its
// replacement is confirmed").
//
// The scanner recognises authored note links with exactly the semantics of
// `MarkdownInlineParser` (whose inline nodes carry no source offsets): the same
// escape, code-span, wikilink, image, label and emphasis rules, the same size
// and depth bounds, and the same `MarkdownLinkPolicy` classification. Only the
// block kinds the knowledge graph treats as edge carriers are scanned — code,
// literal HTML, metadata and rules never create authored links. Occurrences
// whose authored target does not appear verbatim in the source (table-cell
// escape rewriting) are not offered for repair: a repair must rewrite exactly
// what the author wrote.

public enum NoteLinkForm: String, Equatable, Sendable {
    case wikilink
    case markdown
}

/// One authored note link at an exact source location. The target text is the
/// authored form (`Page`, `Folder/Page.md`, `Page#section`), as the resolver
/// and the knowledge graph see it.
public struct NoteLinkOccurrence: Identifiable, Equatable, Sendable {
    public let id: Int
    public let target: String
    public let targetSpan: SourceSpan
    public let form: NoteLinkForm
    public init(id: Int, target: String, targetSpan: SourceSpan, form: NoteLinkForm) {
        self.id = id; self.target = target; self.targetSpan = targetSpan; self.form = form
    }
}

public struct NoteLinkInspection: Equatable, Sendable, Identifiable {
    public let occurrence: NoteLinkOccurrence
    public let resolution: NoteLinkResolution
    public var id: Int { occurrence.id }
    public init(occurrence: NoteLinkOccurrence, resolution: NoteLinkResolution) {
        self.occurrence = occurrence; self.resolution = resolution
    }
}

/// A confirmed single-link rewrite, bound to the exact source it was computed
/// against. Applying it to any other source refuses rather than mis-editing.
public struct NoteLinkRepairEdit: Equatable, Sendable {
    public let occurrenceID: Int
    public let beforeTarget: String
    public let afterTarget: String
    public let targetSpan: SourceSpan
    public let expectedSourceDigest: String
    public let resultingSourceDigest: String
    public init(occurrenceID: Int, beforeTarget: String, afterTarget: String, targetSpan: SourceSpan,
                expectedSourceDigest: String, resultingSourceDigest: String) {
        self.occurrenceID = occurrenceID
        self.beforeTarget = beforeTarget; self.afterTarget = afterTarget
        self.targetSpan = targetSpan
        self.expectedSourceDigest = expectedSourceDigest; self.resultingSourceDigest = resultingSourceDigest
    }
}

public enum NoteLinkRepairError: Error, Equatable, Sendable {
    case staleSource
    case spanMismatch
    case blockedReplacement
}

// MARK: - Scanner

/// Span-preserving link extraction. Faithful to `MarkdownInlineParser.parse`;
/// tests pin the two together over an adversarial corpus.
enum NoteLinkScanner {
    struct Raw {
        var target: String
        var span: SourceSpan
        var form: NoteLinkForm
    }

    static func scan(source: String) -> [Raw] {
        let record = MarkdownParser.parseDetailed(source)
        guard record.limitation == nil else { return [] }
        let split = MarkdownParser.splitLines(source)
        let texts = split.texts, starts = split.starts
        let sourceUnits = [UInt16](source.utf16)
        var found: [Raw] = []
        for block in record.blocks {
            switch block.block.kind {
            case .paragraph:
                var chars: [UInt16] = [], map: [Int] = []
                for line in block.firstLine...block.lastLine {
                    if line > block.firstLine { chars.append(10); map.append(starts[line] - 1) }
                    append(texts[line], at: starts[line], to: &chars, to: &map)
                }
                run(chars: chars, map: map, source: sourceUnits, depth: 0, record: true, into: &found)
            case .heading:
                if block.lastLine == block.firstLine {
                    guard let content = atxContent(texts[block.firstLine]) else { continue }
                    run(content.text, at: starts[block.firstLine] + content.offset,
                        source: sourceUnits, depth: 0, record: true, into: &found)
                } else {
                    // Setext heading text is the raw first line.
                    run(texts[block.firstLine], at: starts[block.firstLine],
                        source: sourceUnits, depth: 0, record: true, into: &found)
                }
            case .quote:
                var chars: [UInt16] = [], map: [Int] = []
                for line in block.firstLine...block.lastLine {
                    if line > block.firstLine { chars.append(10); map.append(starts[line] - 1) }
                    guard let content = quoteContent(texts[line]) else { continue }
                    append(content.text, at: starts[line] + content.offset, to: &chars, to: &map)
                }
                run(chars: chars, map: map, source: sourceUnits, depth: 0, record: true, into: &found)
            case .listItem:
                guard let content = listContent(texts[block.firstLine]) else { continue }
                run(content.text, at: starts[block.firstLine] + content.offset,
                    source: sourceUnits, depth: 0, record: true, into: &found)
            case .table:
                // Headers and data rows only; the alignment row never carries links.
                var lines = [block.firstLine]
                if block.lastLine >= block.firstLine + 2 { lines.append(contentsOf: (block.firstLine + 2)...block.lastLine) }
                for line in lines {
                    for segment in tableSegments(texts[line]) {
                        run(chars: Array(segment.text.utf16),
                            map: segment.map.map { $0 + starts[line] },
                            source: sourceUnits, depth: 0, record: true, into: &found)
                    }
                }
            case .code, .literalHTML, .metadata, .rule:
                continue
            }
        }
        found.sort { $0.span.location < $1.span.location }
        return found
    }

    // MARK: Block text extraction (mirrors MarkdownParser's strips, with offsets)

    private static func append(_ text: String, at offset: Int, to chars: inout [UInt16], to map: inout [Int]) {
        for (index, unit) in text.utf16.enumerated() {
            chars.append(unit); map.append(offset + index)
        }
    }

    /// Runs the inline scan over `text` whose units map to source offsets
    /// `offset + unit index`.
    private static func run(_ text: String, at offset: Int, source: [UInt16], depth: Int, record: Bool, into found: inout [Raw]) {
        var chars: [UInt16] = [], map: [Int] = []
        append(text, at: offset, to: &chars, to: &map)
        run(chars: chars, map: map, source: source, depth: depth, record: record, into: &found)
    }

    private static func atxContent(_ raw: String) -> (text: String, offset: Int)? {
        let leading = leadingWhitespace(raw)
        let trim = raw.trimmingCharacters(in: .whitespaces)
        let count = trim.prefix(while: { $0 == "#" }).count
        guard count > 0 else { return nil }
        let afterHashes = trim.dropFirst(count)
        let gap = String(afterHashes).unicodeScalars.prefix(while: { CharacterSet.whitespaces.contains($0) }).count
        var value = String(afterHashes).trimmingCharacters(in: .whitespaces)
        if let range = value.range(of: #"\s+#+\s*$"#, options: .regularExpression) { value.removeSubrange(range) }
        return (value, leading + count + gap)
    }

    private static func quoteContent(_ raw: String) -> (text: String, offset: Int)? {
        let leading = leadingWhitespace(raw)
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix(">") else { return nil }
        var value = String(trimmed.dropFirst())
        var offset = leading + 1
        if value.hasPrefix(" ") { value.removeFirst(); offset += 1 }
        return (value, offset)
    }

    private static func listContent(_ raw: String) -> (text: String, offset: Int)? {
        let indent = raw.prefix(while: { $0 == " " || $0 == "\t" })
        let value = String(raw.dropFirst(indent.count))
        let pattern = #"^(?:([-+*])|([0-9]{1,9})[.)])\s+(.*)$"#
        guard let match = value.range(of: pattern, options: .regularExpression) else { return nil }
        let full = String(value[match])
        let marker = full.prefix(while: { !$0.isWhitespace })
        let afterMarker = full.dropFirst(marker.count)
        let gap = String(afterMarker).unicodeScalars.prefix(while: { CharacterSet.whitespaces.contains($0) }).count
        var body = String(afterMarker).trimmingCharacters(in: .whitespaces)
        var offset = indent.count + marker.count + gap
        if body.hasPrefix("[ ] ") { body = String(body.dropFirst(4)); offset += 4 }
        else if body.hasPrefix("[x] ") || body.hasPrefix("[X] ") { body = String(body.dropFirst(4)); offset += 4 }
        return (body, offset)
    }

    struct CellSegment {
        var text: String
        var map: [Int] // raw line-relative offsets, one per unit of `text`
    }

    /// Mirrors `MarkdownParser.tableCells`, tracking each cell character's raw
    /// offset so escape-rewritten cells can be detected and excluded.
    private static func tableSegments(_ raw: String) -> [CellSegment] {
        let units = [UInt16](raw.utf16)
        let leading = leadingWhitespace(raw)
        let trailing = units.dropFirst(leading).reversed().prefix(while: { unit -> Bool in
            guard let scalar = UnicodeScalar(unit) else { return false }
            return CharacterSet.whitespaces.contains(scalar)
        }).count
        var start = leading
        var end = max(start, units.count - trailing)
        if start < end, units[start] == 124 { start += 1 } // leading |
        if end > start, units[end - 1] == 124 {
            let escaped = end - start >= 2 && units[end - 2] == 92
            if !escaped { end -= 1 } // trailing | (not \|)
        }
        var cells: [[(UInt16, Int)]] = []
        var current: [(UInt16, Int)] = []
        var escaped = false, code = false
        var index = start
        while index < end {
            let unit = units[index]
            if escaped { current.append((unit, index)); escaped = false; index += 1; continue }
            if unit == 92 { escaped = true; index += 1; continue }
            if unit == 96 { code.toggle() }
            if unit == 124 && !code {
                cells.append(current); current = []
            } else {
                current.append((unit, index))
            }
            index += 1
        }
        cells.append(current)
        return cells.compactMap { cell in
            var pairs = cell
            while let first = pairs.first, let scalar = UnicodeScalar(first.0), CharacterSet.whitespaces.contains(scalar) { pairs.removeFirst() }
            while let last = pairs.last, let scalar = UnicodeScalar(last.0), CharacterSet.whitespaces.contains(scalar) { pairs.removeLast() }
            guard !pairs.isEmpty else { return nil }
            return CellSegment(text: String(decoding: pairs.map(\.0), as: UTF16.self), map: pairs.map(\.1))
        }
    }

    private static func leadingWhitespace(_ raw: String) -> Int {
        raw.unicodeScalars.prefix(while: { CharacterSet.whitespaces.contains($0) }).count
    }

    // MARK: Inline scan (mirrors MarkdownInlineParser.parse)

    private struct Scan {
        let chars: [UInt16]
        let map: [Int]
        var delimiterPositions: [UInt16: [Int]] = [:]

        init(chars: [UInt16], map: [Int]) {
            self.chars = chars; self.map = map
            for (offset, value) in chars.enumerated() where [96, 93, 41, 42, 95, 126].contains(value) {
                delimiterPositions[value, default: []].append(offset)
            }
        }

        func sub(_ range: Range<Int>) -> Scan {
            Scan(chars: Array(chars[range]), map: Array(map[range]))
        }

        func string(_ range: Range<Int>) -> String {
            String(decoding: chars[range], as: UTF16.self)
        }

        func closes(_ marker: [UInt16], from start: Int) -> Int? {
            guard start < chars.count else { return nil }
            let end = min(chars.count - marker.count, start + 4096)
            guard start <= end else { return nil }
            guard let candidates = delimiterPositions[marker[0]] else { return nil }
            var low = 0, high = candidates.count
            while low < high {
                let middle = (low + high) / 2
                if candidates[middle] < start { low = middle + 1 } else { high = middle }
            }
            while low < candidates.count {
                let n = candidates[low]; low += 1
                if n > end { break }
                if n > 0 && chars[n - 1] == 92 { continue }
                if Array(chars[n..<(n + marker.count)]) == marker { return n }
            }
            return nil
        }

        /// Trims `set` characters from both ends of a unit range, mirroring
        /// `String.trimmingCharacters` on the same units.
        func trimmed(_ range: Range<Int>, set: CharacterSet) -> Range<Int> {
            var start = range.lowerBound, end = range.upperBound
            while start < end, let scalar = UnicodeScalar(chars[start]), set.contains(scalar) { start += 1 }
            while end > start, let scalar = UnicodeScalar(chars[end - 1]), set.contains(scalar) { end -= 1 }
            return start..<end
        }
    }

    private static func run(chars: [UInt16], map: [Int], source: [UInt16], depth: Int, record: Bool, into found: inout [Raw]) {
        run(Scan(chars: chars, map: map), source: source, depth: depth, record: record, into: &found)
    }

    /// Returns the node count the inline parser would produce for this text
    /// (used to mirror its 4096-node bound); records note-link occurrences
    /// when `record` is true.
    @discardableResult
    private static func run(_ scan: Scan, source: [UInt16], depth: Int, record: Bool, into found: inout [Raw]) -> Int {
        guard depth < 8, scan.chars.count <= 64 * 1024 else { return 1 }
        var nodeCount = 0
        var plain = 0
        var position = 0
        func flush() { if plain > 0 { nodeCount += 1; plain = 0 } }
        func emit(_ target: String, _ range: Range<Int>, _ form: NoteLinkForm) {
            guard record, !range.isEmpty else { return }
            let location = scan.map[range.lowerBound]
            let length = scan.map[range.upperBound - 1] + 1 - location
            guard length == target.utf16.count else { return }
            let slice = String(decoding: source.dropFirst(location).prefix(length), as: UTF16.self)
            guard slice == target else { return }
            found.append(.init(target: target, span: .init(location: location, length: length), form: form))
        }
        while position < scan.chars.count {
            if nodeCount >= 4096 { flush(); nodeCount += 1; break }
            let c = scan.chars[position]
            if c == 92, position + 1 < scan.chars.count,
               [92, 42, 95, 96, 91, 93, 40, 41, 33, 126, 124].contains(scan.chars[position + 1]) {
                plain += 1; position += 2; continue
            }
            if c == 96 {
                var count = 1
                while position + count < scan.chars.count && scan.chars[position + count] == 96 && count < 16 { count += 1 }
                let marker = [UInt16](repeating: 96, count: count)
                if let end = scan.closes(marker, from: position + count), end > position + count {
                    flush(); nodeCount += 1; position = end + count; continue
                }
            }
            if c == 91, position + 1 < scan.chars.count, scan.chars[position + 1] == 91,
               let end = scan.closes([93, 93], from: position + 2) {
                let insideStart = position + 2
                var pipe = end
                var index = insideStart
                while index < end {
                    if scan.chars[index] == 124 { pipe = index; break }
                    index += 1
                }
                let targetRange = scan.trimmed(scan.trimmed(insideStart..<pipe, set: .whitespaces), set: .whitespacesAndNewlines)
                let target = scan.string(targetRange)
                if record, case .note(let value) = MarkdownLinkPolicy.classify(target), value == target {
                    emit(target, targetRange, .wikilink)
                }
                flush(); nodeCount += 1; position = end + 2; continue
            }
            let image = c == 33 && position + 1 < scan.chars.count && scan.chars[position + 1] == 91
            if c == 91 || image {
                let start = position + (image ? 2 : 1)
                if let labelEnd = scan.closes([93], from: start), labelEnd + 1 < scan.chars.count,
                   scan.chars[labelEnd + 1] == 40, let targetEnd = scan.closes([41], from: labelEnd + 2) {
                    let targetRange = scan.trimmed((labelEnd + 2)..<targetEnd, set: .whitespacesAndNewlines)
                    let target = scan.string(targetRange)
                    if !image {
                        // Links inside a link's label are parsed but never
                        // become graph edges (GraphLinkExtractor does not
                        // descend into labels), so they are not repair sites.
                        _ = run(scan.sub(start..<labelEnd), source: source, depth: depth + 1, record: false, into: &found)
                        if record, case .note(let value) = MarkdownLinkPolicy.classify(target), value == target {
                            emit(target, targetRange, .markdown)
                        }
                    }
                    flush(); nodeCount += 1; position = targetEnd + 1; continue
                }
            }
            if [42, 95, 126].contains(c) {
                let doubled = position + 1 < scan.chars.count && scan.chars[position + 1] == c
                let length = doubled ? 2 : 1
                if c != 126 || doubled,
                   let end = scan.closes([UInt16](repeating: c, count: length), from: position + length), end > position + length {
                    let wordInternal = c == 95 && position > 0 && scan.chars[position - 1] < 128
                        && CharacterSet.alphanumerics.contains(UnicodeScalar(scan.chars[position - 1])!)
                    if !wordInternal {
                        flush()
                        _ = run(scan.sub((position + length)..<end), source: source, depth: depth + 1, record: record, into: &found)
                        nodeCount += 1
                        position = end + length; continue
                    }
                }
            }
            plain += 1; position += 1
        }
        flush()
        return nodeCount
    }
}

// MARK: - Repair API

public enum NoteLinkRepair {
    /// All rewritable authored note links in the source, in document order.
    /// Code, literal HTML, metadata and rules never contribute; blocked,
    /// external and pure-anchor targets are not note links; occurrences whose
    /// target does not appear verbatim in the source are not rewritable and
    /// are omitted.
    public static func occurrences(in source: String) -> [NoteLinkOccurrence] {
        NoteLinkScanner.scan(source: source).enumerated().map { index, raw in
            NoteLinkOccurrence(id: index, target: raw.target, targetSpan: raw.span, form: raw.form)
        }
    }

    /// Every occurrence paired with its resolution, using the same resolver the
    /// preview link click uses. Broken and ambiguous links stay listed here —
    /// visible and repairable, never silently rewritten.
    public static func inspect(source: String, sourcePath: String, candidates: [NoteLinkCandidate]) -> [NoteLinkInspection] {
        occurrences(in: source).map {
            .init(occurrence: $0, resolution: NoteLinkResolver.resolve($0.target, from: sourcePath, candidates: candidates))
        }
    }

    /// The replacement keeps the author's form: links written as paths keep a
    /// path shape, links written as titles keep a title, and `#section`
    /// anchors are preserved. This chooses the text only; nothing is written
    /// until the edit is applied explicitly.
    public static func replacementTarget(_ candidate: NoteLinkCandidate, for occurrence: NoteLinkOccurrence) -> String {
        let authored = occurrence.target
        let anchorStart = authored.firstIndex(of: "#")
        let name = anchorStart.map { String(authored[..<$0]) } ?? authored
        let anchor = anchorStart.map { String(authored[$0...]) } ?? ""
        let explicit = name.contains("/")
            || name.lowercased().hasSuffix(".md") || name.lowercased().hasSuffix(".markdown")
        var base = explicit ? candidate.path : candidate.title
        if explicit, !(name.lowercased().hasSuffix(".md") || name.lowercased().hasSuffix(".markdown")) {
            base = base.replacingOccurrences(of: #"\.(md|markdown)$"#, with: "", options: [.regularExpression, .caseInsensitive])
        }
        return base + anchor
    }

    /// Builds a single-confirmed-link rewrite. The edit is bound to the source
    /// digest it was computed against and is refused if the replacement would
    /// not re-parse as a note link at the same site (embedded `]]`, `|`, `)`
    /// and similar never corrupt the note).
    public static func edit(replacing occurrence: NoteLinkOccurrence, with newTarget: String, in source: String) throws -> NoteLinkRepairEdit {
        let units = [UInt16](source.utf16)
        let span = occurrence.targetSpan
        guard span.location >= 0, span.end <= units.count else { throw NoteLinkRepairError.spanMismatch }
        let slice = String(decoding: units.dropFirst(span.location).prefix(span.length), as: UTF16.self)
        guard slice == occurrence.target else { throw NoteLinkRepairError.spanMismatch }
        guard case .note(let value) = MarkdownLinkPolicy.classify(newTarget), value == newTarget else {
            throw NoteLinkRepairError.blockedReplacement
        }
        let resulting = splice(source, span: span, replacement: newTarget)
        let rewritable = occurrences(in: resulting).contains {
            $0.targetSpan.location == span.location && $0.target == newTarget && $0.form == occurrence.form
        }
        guard rewritable else { throw NoteLinkRepairError.blockedReplacement }
        return .init(
            occurrenceID: occurrence.id,
            beforeTarget: occurrence.target,
            afterTarget: newTarget,
            targetSpan: span,
            expectedSourceDigest: ContentDigest.sha256(Data(source.utf8)),
            resultingSourceDigest: ContentDigest.sha256(Data(resulting.utf8))
        )
    }

    /// Applies a confirmed edit. The source must still be the one the edit was
    /// computed against — otherwise this refuses instead of overwriting.
    public static func apply(_ edit: NoteLinkRepairEdit, to source: String) throws -> String {
        guard ContentDigest.sha256(Data(source.utf8)) == edit.expectedSourceDigest else {
            throw NoteLinkRepairError.staleSource
        }
        let units = [UInt16](source.utf16)
        let span = edit.targetSpan
        guard span.location >= 0, span.end <= units.count else { throw NoteLinkRepairError.spanMismatch }
        let slice = String(decoding: units.dropFirst(span.location).prefix(span.length), as: UTF16.self)
        guard slice == edit.beforeTarget else { throw NoteLinkRepairError.spanMismatch }
        let resulting = splice(source, span: span, replacement: edit.afterTarget)
        guard ContentDigest.sha256(Data(resulting.utf8)) == edit.resultingSourceDigest else {
            throw NoteLinkRepairError.spanMismatch
        }
        return resulting
    }

    private static func splice(_ source: String, span: SourceSpan, replacement: String) -> String {
        var units = [UInt16](source.utf16)
        units.replaceSubrange(span.location..<span.end, with: replacement.utf16)
        return String(decoding: units, as: UTF16.self)
    }
}
