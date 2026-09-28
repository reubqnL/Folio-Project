import Foundation

public enum MarkdownText {
    public static func plain(_ tokens: [MarkdownInline]) -> String {
        tokens.map { token in
            switch token {
            case .text(let value), .code(let value): value
            case .strong(let inner), .emphasis(let inner), .strike(let inner): plain(inner)
            case .link(let label, _): plain(label)
            case .image(let alt, _): alt
            }
        }.joined()
    }
    public static func slug(_ text: String) -> String {
        let folded = NoteSearchQuery.fold(text)
        return folded.unicodeScalars.map { scalar -> String in
            if CharacterSet.alphanumerics.contains(scalar) { return String(scalar) }
            if CharacterSet.whitespacesAndNewlines.contains(scalar) || scalar == "-" { return "-" }
            return ""
        }.joined().split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
    }
}
