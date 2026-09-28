import Foundation

public enum SearchProfile: String, CaseIterable, Codable, Sendable {
    case lowMemory, balanced, largeVault
    public var title: String {
        switch self { case .lowMemory: "Low memory"; case .balanced: "Balanced"; case .largeVault: "Large vault" }
    }
    public var pageCacheKiB: Int {
        switch self { case .lowMemory: 4096; case .balanced: 16384; case .largeVault: 32768 }
    }
    public var indexingBatchSize: Int {
        switch self { case .lowMemory: 4; case .balanced: 16; case .largeVault: 32 }
    }
}

public enum NoteSearchScope: String, CaseIterable, Sendable {
    case everything, titles, tags
    public var title: String { switch self { case .everything: "All text"; case .titles: "Titles & paths"; case .tags: "Tags" } }
}

public enum SearchIndexError: Error, LocalizedError, Sendable {
    case closed, cacheInsideVault, unsafeCachePath, invalidDocument, queryTooLong
    case unavailable, cancelled, schemaMismatch, workspaceMismatch, staleTicket
    case sqlite(Int32)
    public var errorDescription: String? {
        switch self {
        case .closed: "The search cache is closed."
        case .cacheInsideVault: "The derived search cache must live outside the Markdown vault."
        case .unsafeCachePath: "The search-cache location could not be validated."
        case .invalidDocument: "A note exceeded the index limits or contains unsupported text. The original file was not changed."
        case .queryTooLong: "Use a shorter query: at most 512 UTF-8 bytes and 16 terms."
        case .unavailable: "SQLite FTS5 is unavailable in this environment. Notes still work."
        case .cancelled: "Search was cancelled or exceeded its work budget."
        case .schemaMismatch: "This derived index uses an unsupported or damaged schema. Rebuild the cache; do not alter the notes."
        case .workspaceMismatch: "This cache belongs to a different project or root."
        case .staleTicket: "A newer indexing request superseded this update."
        case .sqlite(let code): "The derived search cache could not complete an operation (SQLite \(code)). Notes were not changed."
        }
    }
}

public struct IndexedNote: Equatable, Sendable {
    public let id: UUID
    public let path: String
    public let title: String
    public let tags: [String]
    public let body: String
    public let revision: String
    public let modifiedAt: Date

    public init(id: UUID, path: String, title: String, tags: [String] = [], body: String, revision: String, modifiedAt: Date) {
        self.id = id; self.path = path; self.title = title; self.tags = tags
        self.body = body; self.revision = revision; self.modifiedAt = modifiedAt
    }
    public init(snapshot: VaultSnapshot) {
        self.init(id: snapshot.note.id, path: snapshot.note.relativePath, title: snapshot.note.title,
                  tags: NoteMetadata.tags(in: snapshot.markdown), body: snapshot.markdown,
                  revision: snapshot.revision, modifiedAt: snapshot.note.modifiedAt)
    }
}

public struct NoteSearchHit: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let path: String
    public let title: String
    public let tags: [String]
    public let excerpt: String
    public let revision: String
    public let modifiedAt: Date
}

public struct IndexUpdateTicket: Hashable, Sendable {
    let indexID: UUID
    let noteID: UUID
    let nonce: UUID
}
public struct IndexRebuildTicket: Hashable, Sendable {
    let indexID: UUID
    let nonce: UUID
}

/// Literal terms/quoted phrases, never arbitrary FTS operators or SQL.
public struct NoteSearchQuery: Equatable, Sendable {
    public let ftsExpression: String
    public let rankingText: String
    public let isEmpty: Bool

    public init(_ input: String, scope: NoteSearchScope = .everything) throws {
        guard input.utf8.count <= 512, !input.contains("\0") else { throw SearchIndexError.queryTooLong }
        var terms: [(String, Bool)] = []
        var current = "", quoted = false
        func append(_ phrase: Bool) {
            let value = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) { terms.append((value, phrase)) }
            current = ""
        }
        for character in input {
            if character == "\"" {
                append(quoted); quoted.toggle()
            } else if character.isWhitespace && !quoted { append(false) }
            else { current.append(character) }
        }
        append(quoted)
        guard terms.count <= 16 else { throw SearchIndexError.queryTooLong }
        isEmpty = terms.isEmpty
        rankingText = Self.fold(terms.map(\.0).joined(separator: " "))
        let expression = terms.enumerated().map { index, term in
            let escaped = term.0.replacingOccurrences(of: "\"", with: "\"\"")
            let prefix = index == terms.count - 1 && !term.1 ? "*" : ""
            return "\"" + escaped + "\"" + prefix
        }.joined(separator: " AND ")
        switch scope {
        case .everything: ftsExpression = expression
        case .titles: ftsExpression = "{title path} : (" + expression + ")"
        case .tags: ftsExpression = "tags : (" + expression + ")"
        }
    }
    public static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}

/// A deliberately limited, non-executing front-matter tag reader. It does not
/// rewrite YAML and does not claim full YAML compatibility (anchors/types/etc.).
public enum NoteMetadata {
    public static func tags(in text: String) -> [String] {
        let prefix = String(text.prefix(16_384))
        let lines = prefix.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF} \t")) == "---" else { return [] }
        var found: [String] = [], inList = false
        for line in lines.dropFirst().prefix(128) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" || trimmed == "..." { break }
            if trimmed.hasPrefix("tags:") {
                let value = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                inList = value.isEmpty
                if value.hasPrefix("[") && value.hasSuffix("]") {
                    found += splitTags(String(value.dropFirst().dropLast()))
                } else if !value.isEmpty { found.append(unquote(value)) }
            } else if inList && trimmed.hasPrefix("- ") && line.first?.isWhitespace == true {
                found.append(unquote(String(trimmed.dropFirst(2))))
            } else if !trimmed.isEmpty { inList = false }
        }
        var seen = Set<String>()
        return found.filter {
            !$0.isEmpty && $0.utf8.count <= 128 && $0.rangeOfCharacter(from: .controlCharacters) == nil && seen.insert(NoteSearchQuery.fold($0)).inserted
        }.prefix(64).map { $0 }
    }
    private static func splitTags(_ value: String) -> [String] {
        var result: [String] = [], current = "", quote: Character?
        for c in value {
            if c == "\"" || c == "'" {
                if quote == c { quote = nil } else if quote == nil { quote = c }
                current.append(c)
            } else if c == "," && quote == nil { result.append(unquote(current)); current = "" }
            else { current.append(c) }
        }
        guard quote == nil else { return [] }
        result.append(unquote(current)); return result
    }
    private static func unquote(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespaces)
        if value.count >= 2, let first = value.first, ["\"", "'"].contains(first), value.last == first {
            value = String(value.dropFirst().dropLast())
        }
        return value
    }
}
