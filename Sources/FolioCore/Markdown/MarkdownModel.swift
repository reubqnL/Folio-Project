import Foundation

public enum EditorPresentation: String, CaseIterable, Codable, Sendable {
    case source, preview, split
    public var title: String { rawValue.capitalized }
}
public struct SourceSpan: Equatable, Sendable {
    public let location: Int
    public let length: Int
    public var end: Int { location + length }
    public init(location: Int, length: Int) { self.location = location; self.length = length }
}
public enum MarkdownLink: Equatable, Sendable {
    case note(String)
    case external(String)
    case anchor(String)
    case blocked(String)
}
public indirect enum MarkdownInline: Equatable, Sendable {
    case text(String), code(String)
    case strong([MarkdownInline]), emphasis([MarkdownInline]), strike([MarkdownInline])
    case link(label: [MarkdownInline], destination: MarkdownLink)
    case image(alt: String, destination: String)
}
public enum TableAlignment: String, Equatable, Sendable { case left, centre, right }
public enum MarkdownBlockKind: Equatable, Sendable {
    case heading(level: Int, text: [MarkdownInline])
    case paragraph([MarkdownInline])
    case code(language: String, text: String)
    case quote([MarkdownInline])
    case listItem(depth: Int, number: Int?, checked: Bool?, text: [MarkdownInline])
    case table(headers: [[MarkdownInline]], rows: [[[MarkdownInline]]], alignment: [TableAlignment])
    case metadata(String)
    case literalHTML(String)
    case rule
}
public struct MarkdownBlock: Identifiable, Equatable, Sendable {
    public let id: String
    public let source: SourceSpan
    public let kind: MarkdownBlockKind
}
public struct MarkdownDocument: Equatable, Sendable {
    public let blocks: [MarkdownBlock]
    public let sourceUTF16Length: Int
    public let warnings: [String]
    public let limitation: String?
    public var isLimited: Bool { limitation != nil }

    /// Cursor movement itself never scrolls preview. The UI calls this only for
    /// an explicit Follow cursor action. Whitespace resolves to the prior block.
    public func block(atUTF16Offset offset: Int) -> MarkdownBlock? {
        guard !blocks.isEmpty else { return nil }
        let position = min(max(0, offset), sourceUTF16Length)
        var low = 0, high = blocks.count
        while low < high {
            let middle = (low + high) / 2
            if blocks[middle].source.location <= position { low = middle + 1 } else { high = middle }
        }
        return blocks[max(0, low - 1)]
    }
}
public struct MarkdownLimits: Sendable {
    public var maximumUTF8Bytes = 512 * 1024
    public var maximumLineUTF16 = 32 * 1024
    public var maximumBlocks = 10_000
    public init() {}
}

public enum MarkdownLinkPolicy {
    public static func classify(_ input: String) -> MarkdownLink {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 2048, !value.contains("\\"),
              value.rangeOfCharacter(from: .controlCharacters) == nil,
              let decoded = value.removingPercentEncoding,
              decoded.rangeOfCharacter(from: .controlCharacters) == nil else { return .blocked(input) }
        if value.hasPrefix("#") { return .anchor(String(value.dropFirst())) }
        if let url = URL(string: value), let scheme = url.scheme?.lowercased() {
            guard ["http", "https", "mailto"].contains(scheme), url.user == nil, url.password == nil else { return .blocked(input) }
            if scheme != "mailto", url.host?.isEmpty != false { return .blocked(input) }
            return .external(url.absoluteString)
        }
        // A note target is resolved only against the current project's known IDs,
        // never converted into an arbitrary filesystem URL.
        guard !value.hasPrefix("/"), !value.hasPrefix("~"),
              !value.split(separator: "/").contains("..") else { return .blocked(input) }
        return .note(value)
    }
}
