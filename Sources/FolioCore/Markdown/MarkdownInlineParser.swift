import Foundation

public enum MarkdownInlineParser {
    /// Bounded subset: emphasis/strong/strike, code, links, images and wikilinks.
    /// Literal HTML is text, never handed to an HTML importer or web view.
    public static func parse(_ text: String) -> [MarkdownInline] {
        parse(Array(text.utf16), depth: 0)
    }
    private static func parse(_ chars: [UInt16], depth: Int) -> [MarkdownInline] {
        guard depth < 8, chars.count <= 64 * 1024 else { return [.text(String(decoding: chars, as: UTF16.self))] }
        var result: [MarkdownInline] = [], plain: [UInt16] = [], position = 0
        var delimiterPositions: [UInt16: [Int]] = [:]
        for (offset, value) in chars.enumerated() where [96, 93, 41, 42, 95, 126].contains(value) {
            delimiterPositions[value, default: []].append(offset)
        }
        func string(_ range: Range<Int>) -> String { String(decoding: chars[range], as: UTF16.self) }
        func flush() { if !plain.isEmpty { result.append(.text(String(decoding: plain, as: UTF16.self))); plain.removeAll(keepingCapacity: true) } }
        func closes(_ marker: [UInt16], from start: Int) -> Int? {
            guard start < chars.count else { return nil }
            // Bound failed delimiter searches to avoid quadratic adversarial input.
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
                if n > 0 && chars[n-1] == 92 { continue }
                if Array(chars[n..<(n + marker.count)]) == marker { return n }
            }
            return nil
        }
        while position < chars.count {
            if result.count >= 4096 { flush(); result.append(.text(string(position..<chars.count))); break }
            let c = chars[position]
            if c == 92, position + 1 < chars.count, [92, 42, 95, 96, 91, 93, 40, 41, 33, 126, 124].contains(chars[position+1]) {
                plain.append(chars[position+1]); position += 2; continue
            }
            if c == 96 {
                var count = 1
                while position + count < chars.count && chars[position+count] == 96 && count < 16 { count += 1 }
                let marker = [UInt16](repeating: 96, count: count)
                if let end = closes(marker, from: position + count), end > position + count {
                    flush(); result.append(.code(string((position+count)..<end))); position = end + count; continue
                }
            }
            if c == 91, position + 1 < chars.count, chars[position+1] == 91,
               let end = closes([93, 93], from: position + 2) {
                let inside = string((position+2)..<end)
                let pieces = inside.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
                let target = String(pieces[0]).trimmingCharacters(in: .whitespaces)
                let label = pieces.count == 2 ? String(pieces[1]) : target
                let classification = MarkdownLinkPolicy.classify(target)
                let destination: MarkdownLink
                if case .note = classification { destination = classification }
                else if case .anchor = classification { destination = classification }
                else { destination = .blocked(target) }
                flush(); result.append(.link(label: [.text(label)], destination: destination)); position = end + 2; continue
            }
            let image = c == 33 && position + 1 < chars.count && chars[position+1] == 91
            if c == 91 || image {
                let start = position + (image ? 2 : 1)
                if let labelEnd = closes([93], from: start), labelEnd + 1 < chars.count, chars[labelEnd+1] == 40,
                   let targetEnd = closes([41], from: labelEnd + 2) {
                    let label = string(start..<labelEnd)
                    let target = string((labelEnd+2)..<targetEnd)
                    flush()
                    if image { result.append(.image(alt: label, destination: target)) }
                    else { result.append(.link(label: parse(Array(label.utf16), depth: depth + 1), destination: MarkdownLinkPolicy.classify(target))) }
                    position = targetEnd + 1; continue
                }
            }
            if [42, 95, 126].contains(c) {
                let doubled = position + 1 < chars.count && chars[position+1] == c
                let length = doubled ? 2 : 1
                if c != 126 || doubled,
                   let end = closes([UInt16](repeating: c, count: length), from: position + length), end > position + length {
                    let inside = Array(chars[(position+length)..<end])
                    // Avoid turning ordinary snake_case identifiers into emphasis.
                    let wordInternal = c == 95 && position > 0 && chars[position-1] < 128 && CharacterSet.alphanumerics.contains(UnicodeScalar(chars[position-1])!)
                    if !wordInternal {
                        flush()
                        let content = parse(inside, depth: depth + 1)
                        if c == 126 { result.append(.strike(content)) }
                        else if doubled { result.append(.strong(content)) }
                        else { result.append(.emphasis(content)) }
                        position = end + length; continue
                    }
                }
            }
            plain.append(c); position += 1
        }
        flush(); return result
    }
}
