import Foundation

/// Per-block parse record used by the incremental reparser. Internal: the
/// public surface stays `parse(_:)`/`excerpt(_:)` with identical results.
struct ParsedBlockRecord: Equatable, Sendable {
    var block: MarkdownBlock
    var digest: String
    var firstLine: Int
    var lastLine: Int
    var warnings: [String]
}

/// Detailed parse output shared by the full parser and the incremental
/// session. `lineStarts[i]` is the UTF-16 offset where line `i` begins.
struct ParsedDocumentRecord: Equatable, Sendable {
    var blocks: [ParsedBlockRecord]
    var sourceUTF16Length: Int
    var lineStarts: [Int]
    var lineCount: Int
    var limitation: String?
}

public enum MarkdownParser {
    public static func parse(_ source: String, limits: MarkdownLimits = .init()) -> MarkdownDocument {
        project(parseDetailed(source, limits: limits))
    }

    /// Projects a detailed record onto the public document shape, reproducing
    /// the exact global warning processing (deduplicated, sorted).
    static func project(_ record: ParsedDocumentRecord) -> MarkdownDocument {
        .init(
            blocks: record.blocks.map(\.block),
            sourceUTF16Length: record.sourceUTF16Length,
            warnings: Array(Set(record.blocks.flatMap(\.warnings))).sorted(),
            limitation: record.limitation
        )
    }

    /// Splits source into lines exactly the way the parser scans them.
    static func splitLines(_ source: String) -> (texts: [String], starts: [Int], ends: [Int]) {
        let units = Array(source.utf16)
        var texts: [String] = [], starts: [Int] = [], ends: [Int] = []
        var start = 0, position = 0
        while position < units.count {
            if units[position] == 10 || units[position] == 13 {
                let end = position
                if units[position] == 13 && position + 1 < units.count && units[position+1] == 10 { position += 1 }
                position += 1
                texts.append(String(decoding: units[start..<end], as: UTF16.self))
                starts.append(start); ends.append(position)
                start = position
            } else { position += 1 }
        }
        if start < units.count || texts.isEmpty {
            texts.append(String(decoding: units[start...], as: UTF16.self))
            starts.append(start); ends.append(units.count)
        }
        return (texts, starts, ends)
    }

    /// `frontMatter` is true only for a parse that begins at the document
    /// start; incremental window parses mid-document must not form it.
    static func parseDetailed(_ source: String, limits: MarkdownLimits = .init(), frontMatter: Bool = true) -> ParsedDocumentRecord {
        let total = source.utf16.count
        guard (1...2 * 1024 * 1024).contains(limits.maximumUTF8Bytes),
              (1...128 * 1024).contains(limits.maximumLineUTF16),
              (1...20_000).contains(limits.maximumBlocks), source.utf8.count <= limits.maximumUTF8Bytes else {
            return .init(blocks: [], sourceUTF16Length: total, lineStarts: [], lineCount: 0, limitation: "This note exceeds the current preview budget. Source editing is unchanged. You can explicitly request an excerpt.")
        }
        let split = splitLines(source)
        let texts = split.texts, starts = split.starts, ends = split.ends
        if texts.contains(where: { $0.utf16.count > limits.maximumLineUTF16 }) {
            return .init(blocks: [], sourceUTF16Length: total, lineStarts: starts, lineCount: texts.count, limitation: "An exceptionally long line exceeds the preview budget. Choose an excerpt explicitly; your source stays intact.")
        }
        var records: [ParsedBlockRecord] = [], occurrences: [String: Int] = [:]
        var index = 0
        func add(_ kind: MarkdownBlockKind, from first: Int, through last: Int, warnings: [String] = []) {
            let location = starts[first], length = ends[last] - starts[first]
            let bytes = String(decoding: source.utf16.dropFirst(location).prefix(length), as: UTF16.self)
            // Content+occurrence identity preserves unchanged block views when
            // earlier text moves their source offsets. It isn't a note identity.
            let digest = ContentDigest.sha256(Data(bytes.utf8))
            let occurrence = occurrences[digest, default: 0]; occurrences[digest] = occurrence + 1
            let block = MarkdownBlock(id: String(digest.prefix(24)) + "-\(occurrence)", source: .init(location: location, length: length), kind: kind)
            records.append(.init(block: block, digest: digest, firstLine: first, lastLine: last, warnings: warnings))
        }
        if frontMatter, let first = texts.first,
           first.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}")) == "---",
           let end = (1..<min(texts.count, 129)).first(where: { ["---", "..."].contains(texts[$0].trimmingCharacters(in: .whitespaces)) }) {
            add(.metadata(texts[0...end].joined(separator: "\n")), from: 0, through: end)
            index = end + 1
        }
        while index < texts.count {
            if Task<Never, Never>.isCancelled {
                return .init(blocks: [], sourceUTF16Length: total, lineStarts: starts, lineCount: texts.count, limitation: "Preview generation was cancelled.")
            }
            if records.count >= limits.maximumBlocks {
                return .init(blocks: [], sourceUTF16Length: total, lineStarts: starts, lineCount: texts.count, limitation: "This note has too many preview blocks for the current renderer. Source editing is unchanged.")
            }
            let text = texts[index]
            let trim = text.trimmingCharacters(in: .whitespaces)
            if trim.isEmpty { index += 1; continue }
            if let fence = openingFence(text) {
                let first = index
                index += 1
                var contents: [String] = []
                while index < texts.count && !closesFence(texts[index].trimmingCharacters(in: .whitespaces), marker: fence.marker, count: fence.count) {
                    contents.append(texts[index]); index += 1
                }
                let closed = index < texts.count
                let last = closed ? index : max(first, index - 1)
                add(.code(language: fence.language, text: contents.joined(separator: "\n")), from: first, through: last,
                    warnings: closed ? [] : ["An unclosed code fence is shown as code through the end of the note."])
                if closed { index += 1 }
                continue
            }
            if let heading = heading(trim) {
                add(.heading(level: heading.level, text: MarkdownInlineParser.parse(heading.text)), from: index, through: index)
                index += 1; continue
            }
            if index + 1 < texts.count, let level = setextLevel(texts[index+1].trimmingCharacters(in: .whitespaces)) {
                add(.heading(level: level, text: MarkdownInlineParser.parse(text)), from: index, through: index + 1)
                index += 2; continue
            }
            if isRule(trim) { add(.rule, from: index, through: index); index += 1; continue }
            if index + 1 < texts.count, text.contains("|"), let align = tableAlignment(texts[index+1]) {
                let first = index
                let headers = tableCells(text)
                guard headers.count == align.count, headers.count <= 12 else {
                    add(.paragraph(MarkdownInlineParser.parse(text)), from: index, through: index); index += 1; continue
                }
                index += 2
                var rows: [[[MarkdownInline]]] = []
                while index < texts.count, !texts[index].trimmingCharacters(in: .whitespaces).isEmpty, texts[index].contains("|"), rows.count < 200 {
                    let cells = tableCells(texts[index])
                    var row = Array(cells.prefix(headers.count))
                    while row.count < headers.count { row.append("") }
                    rows.append(row.map(MarkdownInlineParser.parse)); index += 1
                }
                add(.table(headers: headers.map(MarkdownInlineParser.parse), rows: rows, alignment: align), from: first, through: index - 1,
                    warnings: rows.count == 200 ? ["A table exceeded 200 rendered rows; remaining lines are shown as ordinary text."] : [])
                continue
            }
            if trim.hasPrefix(">") {
                let first = index
                var contents: [String] = []
                while index < texts.count, texts[index].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    var value = String(texts[index].trimmingCharacters(in: .whitespaces).dropFirst())
                    if value.hasPrefix(" ") { value.removeFirst() }
                    contents.append(value); index += 1
                }
                add(.quote(MarkdownInlineParser.parse(contents.joined(separator: "\n"))), from: first, through: index - 1); continue
            }
            if let item = listItem(text) {
                add(.listItem(depth: item.depth, number: item.number, checked: item.checked, text: MarkdownInlineParser.parse(item.text)), from: index, through: index)
                index += 1; continue
            }
            if trim.hasPrefix("<"), !trim.hasPrefix("<http") {
                let first = index
                var contents = [text]; index += 1
                while index < texts.count, !texts[index].trimmingCharacters(in: .whitespaces).isEmpty { contents.append(texts[index]); index += 1 }
                add(.literalHTML(contents.joined(separator: "\n")), from: first, through: index - 1,
                    warnings: ["Raw HTML is displayed literally; it cannot execute or load resources."])
                continue
            }
            let first = index
            var paragraph = [text]; index += 1
            while index < texts.count {
                let next = texts[index]
                let nextTrim = next.trimmingCharacters(in: .whitespaces)
                if nextTrim.isEmpty || openingFence(next) != nil || heading(nextTrim) != nil || isRule(nextTrim) || nextTrim.hasPrefix(">") || listItem(next) != nil || nextTrim.hasPrefix("<") { break }
                if index + 1 < texts.count, tableAlignment(texts[index+1]) != nil, next.contains("|") { break }
                if index + 1 < texts.count, setextLevel(texts[index+1].trimmingCharacters(in: .whitespaces)) != nil { break }
                paragraph.append(next); index += 1
            }
            add(.paragraph(MarkdownInlineParser.parse(paragraph.joined(separator: "\n"))), from: first, through: index - 1)
        }
        return .init(blocks: records, sourceUTF16Length: total, lineStarts: starts, lineCount: texts.count, limitation: nil)
    }

    /// Explicitly requested excerpt; never automatically substitutes a truncated
    /// source editor. Character iteration keeps grapheme clusters whole.
    public static func excerpt(_ source: String, maximumUTF8Bytes: Int = 128 * 1024) -> String {
        var bytes = 0, lineUnits = 0, result = ""
        for character in source {
            let value = String(character)
            let size = value.utf8.count
            if bytes + size > maximumUTF8Bytes || lineUnits + value.utf16.count > 8192 { break }
            result.append(character); bytes += size
            if character.isNewline { lineUnits = 0 } else { lineUnits += value.utf16.count }
        }
        return result
    }
    static func openingFence(_ text: String) -> (marker: Character, count: Int, language: String)? {
        let indentation = text.prefix(while: { $0 == " " }).count
        guard indentation <= 3 else { return nil }
        let value = text.dropFirst(indentation)
        guard let first = value.first, first == "`" || first == "~" else { return nil }
        let count = value.prefix(while: { $0 == first }).count
        guard count >= 3 else { return nil }
        let info = value.dropFirst(count).trimmingCharacters(in: .whitespaces)
        if first == "`" && info.contains("`") { return nil }
        return (first, count, String(info.prefix(40)))
    }
    static func closesFence(_ text: String, marker: Character, count: Int) -> Bool {
        let run = text.prefix(while: { $0 == marker }).count
        return run >= count && text.dropFirst(run).trimmingCharacters(in: .whitespaces).isEmpty
    }
    private static func heading(_ text: String) -> (level: Int, text: String)? {
        let count = text.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(count), text.count == count || text.dropFirst(count).first?.isWhitespace == true else { return nil }
        var value = text.dropFirst(count).trimmingCharacters(in: .whitespaces)
        if let range = value.range(of: #"\s+#+\s*$"#, options: .regularExpression) { value.removeSubrange(range) }
        return (count, value)
    }
    private static func setextLevel(_ text: String) -> Int? {
        guard text.count >= 3 else { return nil }
        if text.allSatisfy({ $0 == "=" }) { return 1 }
        if text.allSatisfy({ $0 == "-" }) { return 2 }
        return nil
    }
    private static func isRule(_ text: String) -> Bool {
        let value = text.filter { !$0.isWhitespace }
        guard value.count >= 3, let first = value.first, ["-", "*", "_"].contains(first) else { return false }
        return value.allSatisfy { $0 == first }
    }
    private static func listItem(_ text: String) -> (depth: Int, number: Int?, checked: Bool?, text: String)? {
        let indent = text.prefix(while: { $0 == " " || $0 == "\t" })
        let value = String(text.dropFirst(indent.count))
        let pattern = #"^(?:([-+*])|([0-9]{1,9})[.)])\s+(.*)$"#
        guard let match = value.range(of: pattern, options: .regularExpression) else { return nil }
        let full = String(value[match])
        let prefix = full.prefix(while: { !$0.isWhitespace })
        var body = full.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        let number = Int(prefix.dropLast())
        var checked: Bool?
        if body.hasPrefix("[ ] ") { checked = false; body = String(body.dropFirst(4)) }
        else if body.hasPrefix("[x] ") || body.hasPrefix("[X] ") { checked = true; body = String(body.dropFirst(4)) }
        return (min(8, indent.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) } / 2), number, checked, body)
    }
    private static func tableCells(_ text: String) -> [String] {
        var value = text.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("|") { value.removeFirst() }
        if value.hasSuffix("|") && !value.hasSuffix("\\|") { value.removeLast() }
        var cells: [String] = [], current = "", escaped = false, code = false
        for c in value {
            if escaped { current.append(c); escaped = false; continue }
            if c == "\\" { escaped = true; continue }
            if c == "`" { code.toggle() }
            if c == "|" && !code { cells.append(current.trimmingCharacters(in: .whitespaces)); current = "" }
            else { current.append(c) }
        }
        cells.append(current.trimmingCharacters(in: .whitespaces)); return cells
    }
    private static func tableAlignment(_ text: String) -> [TableAlignment]? {
        let cells = tableCells(text)
        guard !cells.isEmpty, cells.count <= 12 else { return nil }
        var result: [TableAlignment] = []
        for cell in cells {
            let value = cell.trimmingCharacters(in: .whitespaces)
            let dashes = value.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            guard dashes.count >= 3, dashes.allSatisfy({ $0 == "-" }) else { return nil }
            result.append(value.hasSuffix(":") ? (value.hasPrefix(":") ? .centre : .right) : .left)
        }
        return result
    }
}
