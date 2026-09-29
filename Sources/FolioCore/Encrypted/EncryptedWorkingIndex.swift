import Foundation

public struct EncryptedIndexHit: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let path: String
    public let title: String
    public let excerpt: String
}
public enum EncryptedIndexError: Error, LocalizedError, Equatable, Sendable {
    case closed, wrongProject, tooLarge, invalidInput, queryTooLong
    public var errorDescription: String? {
        switch self {
        case .closed: "The encrypted working index is closed."
        case .wrongProject: "This object belongs to another encrypted project."
        case .tooLarge: "The encrypted project's in-memory derived index exceeded its bounded profile."
        case .invalidInput: "The derived index input is invalid. Authored content was not changed."
        case .queryTooLong: "Use a shorter search query."
        }
    }
}

/// Encrypted-project v1 derived index: memory-only by design. It contains no
/// SQLite file, WAL, temp file, thumbnail or persistent plaintext cache. The
/// actor's stored Data is erased on close where possible; this is not OS-level
/// memory secrecy. A reviewed encrypted persistent index can replace this later.
public actor EncryptedWorkingIndex {
    public nonisolated let projectID: UUID
    public nonisolated let persistentPlaintextStorage = false
    private struct Record: Sendable {
        let id: UUID
        let path: String
        let title: String
        var body: String
        let digest: String
    }
    private var records: [UUID: Record] = [:]
    private var totalBytes = 0
    private let maximumRecords: Int
    private let maximumBytes: Int
    private let maximumNoteBytes: Int
    private var closed = false

    public init(projectID: UUID, maximumRecords: Int = 100_000, maximumBytes: Int = 64 * 1024 * 1024,
                maximumNoteBytes: Int = 8 * 1024 * 1024) throws {
        guard (1...100_000).contains(maximumRecords), (1...512 * 1024 * 1024).contains(maximumBytes),
              (1...64 * 1024 * 1024).contains(maximumNoteBytes) else { throw EncryptedIndexError.tooLarge }
        self.projectID = projectID; self.maximumRecords = maximumRecords
        self.maximumBytes = maximumBytes; self.maximumNoteBytes = maximumNoteBytes
    }
    public func rebuild(_ project: RDMProjectPayload) throws {
        try requireOpen(); guard project.id == projectID else { throw EncryptedIndexError.wrongProject }
        try rebuild(notes: project.notes)
    }

    /// Rebuilds from an authenticated note set (checkpoint payload or a
    /// validated encrypted index cache). The caller binds the note set to the
    /// project identity; this method preserves the same validation and bounds
    /// as a full project rebuild.
    public func rebuild(notes: [RDMNote]) throws {
        try requireOpen()
        guard notes.count <= maximumRecords else { throw EncryptedIndexError.tooLarge }
        var next: [UUID: Record] = [:]
        next.reserveCapacity(notes.count)
        var nextBytes = 0
        for note in notes {
            guard next[note.id] == nil else { throw EncryptedIndexError.invalidInput }
            let record = try makeRecord(note)
            let bodyBytes = record.body.utf8.count
            guard bodyBytes <= maximumBytes, nextBytes <= maximumBytes - bodyBytes else { throw EncryptedIndexError.tooLarge }
            next[note.id] = record
            nextBytes += bodyBytes
        }
        // Commit only after every note has passed validation and bounds checks.
        // A failed rebuild therefore cannot erase the last usable index.
        records = next
        totalBytes = nextBytes
    }
    public func add(_ note: RDMNote) throws {
        try requireOpen()
        let record = try makeRecord(note)
        let bodyBytes = record.body.utf8.count
        let prior = records[note.id]?.body.utf8.count ?? 0
        guard records[note.id] != nil || records.count < maximumRecords else { throw EncryptedIndexError.tooLarge }
        guard bodyBytes <= maximumBytes,
              totalBytes - prior <= maximumBytes - bodyBytes else { throw EncryptedIndexError.tooLarge }
        records[note.id] = record
        totalBytes = totalBytes - prior + bodyBytes
    }
    private func makeRecord(_ note: RDMNote) throws -> Record {
        try VaultPaths.validateNote(note.path)
        guard !note.path.contains("\0"), note.titleSafe.utf8.count <= 1024,
              note.markdown.utf8.count <= maximumNoteBytes else { throw EncryptedIndexError.invalidInput }
        let body = note.markdown
        return .init(id: note.id, path: note.path, title: note.titleSafe, body: body,
                     digest: ContentDigest.sha256(Data(body.utf8)))
    }
    public func remove(_ id: UUID) throws {
        try requireOpen()
        guard records[id] != nil else { return }
        records[id] = nil
        totalBytes = records.values.reduce(0) { $0 + $1.body.utf8.count }
    }

    public func search(_ query: String, limit: Int = 100) throws -> [EncryptedIndexHit] {
        try requireOpen(); guard query.utf8.count <= 512, (1...200).contains(limit) else { throw EncryptedIndexError.queryTooLong }
        let terms = query.split(whereSeparator: \.isWhitespace).map { NoteSearchQuery.fold(String($0)) }.filter { !$0.isEmpty }
        guard !terms.isEmpty else { return [] }
        return records.values.compactMap { record in
            let title = NoteSearchQuery.fold(record.title), path = NoteSearchQuery.fold(record.path)
            let body = NoteSearchQuery.fold(record.body)
            guard terms.allSatisfy({ title.contains($0) || path.contains($0) || body.contains($0) }) else { return nil }
            let source = record.body
            return .init(id: record.id, path: record.path, title: record.title, excerpt: String(source.prefix(240)))
        }.sorted { $0.path < $1.path }.prefix(limit).map { $0 }
    }
    public func statistics() throws -> (records: Int, bytes: Int) { try requireOpen(); return (records.count, totalBytes) }
    public func clear() throws {
        try requireOpen()
        records.removeAll(keepingCapacity: false); totalBytes = 0
    }
    public func close() {
        guard !closed else { return }
        records.removeAll(keepingCapacity: false); totalBytes = 0; closed = true
    }
    private func requireOpen() throws { if closed { throw EncryptedIndexError.closed } }
}

private extension RDMNote {
    var titleSafe: String { (path as NSString).lastPathComponent.replacingOccurrences(of: #"\.(md|markdown)$"#, with: "", options: [.regularExpression, .caseInsensitive]) }
}
