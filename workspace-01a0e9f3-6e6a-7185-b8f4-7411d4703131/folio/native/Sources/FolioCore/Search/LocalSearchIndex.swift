import Foundation
import CSQLite
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct SearchIndexStatistics: Sendable {
    public let documentCount: Int
    public let cacheKiB: Int
    public let sqliteVersion: String
    public let fts5: Bool
}

/// A disposable plaintext index for a PLAIN vault. Never use this implementation
/// for encrypted projects. It is not the authority for note contents or saves.
public actor LocalSearchIndex {
    public nonisolated let fileURL: URL
    private let database: SQLiteConnection
    private let indexID = UUID()
    private var currentTickets: [UUID: UUID] = [:]
    private var activeRebuild: IndexRebuildTicket?
    private var profile: SearchProfile
    private let binding: String
    private var closed = false

    public static func open(cacheDirectory: URL, vaultRoot: URL, projectID: UUID, rootIdentity: String,
                            profile: SearchProfile = .balanced) async throws -> LocalSearchIndex {
        try await Task.detached(priority: .utility) {
            try LocalSearchIndex(cacheDirectory: cacheDirectory, vaultRoot: vaultRoot,
                                 projectID: projectID, rootIdentity: rootIdentity, profile: profile)
        }.value
    }

    /// Caller must close its index handle and obtain explicit user approval.
    /// Deletes only three deterministic derived files, never directories or notes.
    public static func discardCacheAfterConfirmation(cacheDirectory: URL, vaultRoot: URL, projectID: UUID, rootIdentity: String) async throws {
        try await Task.detached(priority: .utility) {
            let cache = cacheDirectory.standardizedFileURL.resolvingSymlinksInPath()
            let vault = vaultRoot.standardizedFileURL.resolvingSymlinksInPath()
            guard cacheDirectory.isFileURL, vaultRoot.isFileURL, !cache.pathComponents.starts(with: vault.pathComponents) else { throw SearchIndexError.cacheInsideVault }
            guard FileManager.default.fileExists(atPath: cache.path) else { return }
            let attrs = try FileManager.default.attributesOfItem(atPath: cache.path)
            guard attrs[.type] as? FileAttributeType == .typeDirectory,
                  let permissions = attrs[.posixPermissions] as? NSNumber,
                  permissions.intValue & 0o077 == 0 else { throw SearchIndexError.unsafeCachePath }
            let basename = projectID.uuidString + "-" + ContentDigest.sha256(Data(rootIdentity.utf8)).prefix(24) + "-search-v1.sqlite"
            for suffix in ["", "-wal", "-shm"] {
                let path = cache.appendingPathComponent(basename + suffix).path
                // unlink cannot recursively delete a directory, and does not
                // follow a final symlink into unrelated data.
                let status = path.withCString { unlink($0) }
                if status != 0 && errno != ENOENT { throw SearchIndexError.unsafeCachePath }
            }
        }.value
    }

    private init(cacheDirectory: URL, vaultRoot: URL, projectID: UUID, rootIdentity: String, profile: SearchProfile) throws {
        guard cacheDirectory.isFileURL, vaultRoot.isFileURL else { throw SearchIndexError.unsafeCachePath }
        let cache = cacheDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let vault = vaultRoot.standardizedFileURL.resolvingSymlinksInPath()
        guard !cache.pathComponents.starts(with: vault.pathComponents) else { throw SearchIndexError.cacheInsideVault }
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: cache.path)
        guard directoryAttributes[.type] as? FileAttributeType == .typeDirectory,
              let permissions = directoryAttributes[.posixPermissions] as? NSNumber,
              permissions.intValue & 0o077 == 0 else { throw SearchIndexError.unsafeCachePath }
        let suffix = ContentDigest.sha256(Data(rootIdentity.utf8)).prefix(24)
        let file = cache.appendingPathComponent(projectID.uuidString + "-" + suffix + "-search-v1.sqlite")
        if FileManager.default.fileExists(atPath: file.path) {
            let values = try FileManager.default.attributesOfItem(atPath: file.path)
            guard values[.type] as? FileAttributeType == .typeRegular else { throw SearchIndexError.unsafeCachePath }
        }
        let connection = try SQLiteConnection(file: file)
        let expectedBinding = projectID.uuidString + ":" + rootIdentity
        try connection.execute("PRAGMA trusted_schema=OFF; PRAGMA temp_store=MEMORY; PRAGMA mmap_size=0; PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=ON; PRAGMA max_page_count=262144;")
        try connection.execute("PRAGMA cache_size=-\(profile.pageCacheKiB)")
        let versionStatement = try connection.statement("PRAGMA user_version")
        _ = try versionStatement.step()
        let version = versionStatement.integer(0)
        versionStatement.finish()
        if version == 0 {
            let tables = try connection.statement("SELECT count(*) FROM sqlite_schema WHERE name NOT LIKE 'sqlite_%'")
            _ = try tables.step()
            guard tables.integer(0) == 0 else { throw SearchIndexError.schemaMismatch }
            tables.finish()
            do {
                try connection.transaction {
                    try connection.execute("""
                    CREATE TABLE cache_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
                    CREATE TABLE docs (
                      rowid INTEGER PRIMARY KEY, note_id TEXT NOT NULL UNIQUE,
                      path TEXT NOT NULL, title TEXT NOT NULL, folded_title TEXT NOT NULL,
                      tags TEXT NOT NULL, tags_json TEXT NOT NULL, body TEXT NOT NULL,
                      revision TEXT NOT NULL, modified REAL NOT NULL, seen_generation TEXT NOT NULL
                    );
                    CREATE VIRTUAL TABLE search_fts USING fts5(
                      title, path, tags, body, content='docs', content_rowid='rowid',
                      tokenize='unicode61 remove_diacritics 2', prefix='2 3 4'
                    );
                    PRAGMA application_id=1179601993;
                    PRAGMA user_version=1;
                    """)
                    let meta = try connection.statement("INSERT INTO cache_meta(key,value) VALUES('binding',?)")
                    try meta.bind(expectedBinding, 1); _ = try meta.step()
                }
            } catch { throw SearchIndexError.unavailable }
        } else if version != 1 { throw SearchIndexError.schemaMismatch }
        let owner = try connection.statement("SELECT value FROM cache_meta WHERE key='binding'")
        guard try owner.step(), try owner.text(0) == expectedBinding else { throw SearchIndexError.workspaceMismatch }
        owner.finish()
        let check = try connection.statement("PRAGMA quick_check(1)")
        guard try check.step(), try check.text(0) == "ok" else { throw SearchIndexError.schemaMismatch }
        check.finish()
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        self.fileURL = file; self.database = connection; self.binding = expectedBinding; self.profile = profile
    }

    public func close() { database.close(); closed = true; currentTickets.removeAll(); activeRebuild = nil }
    public func setProfile(_ value: SearchProfile) throws {
        try requireOpen(); try database.execute("PRAGMA cache_size=-\(value.pageCacheKiB)"); profile = value
    }
    public func statistics() throws -> SearchIndexStatistics {
        try requireOpen()
        let count = try database.statement("SELECT count(*) FROM docs"); _ = try count.step()
        let documentCount = count.integer(0); count.finish()
        let pages = try database.statement("PRAGMA cache_size"); _ = try pages.step()
        let cacheKiB = -pages.integer(0)
        return .init(documentCount: documentCount, cacheKiB: cacheKiB,
                     sqliteVersion: String(cString: sqlite3_libversion()), fts5: true)
    }

    /// Reserve BEFORE reading from the store. A later save/rescan reservation
    /// invalidates this lease, so stale background reads cannot overwrite it.
    public func reserveUpdate(for id: UUID) throws -> IndexUpdateTicket {
        try requireOpen()
        let token = UUID(); currentTickets[id] = token
        return .init(indexID: indexID, noteID: id, nonce: token)
    }
    public func beginRebuild() throws -> IndexRebuildTicket {
        try requireOpen(); try Task.checkCancellation()
        let ticket = IndexRebuildTicket(indexID: indexID, nonce: UUID())
        activeRebuild = ticket
        return ticket
    }
    @discardableResult
    public func upsert(_ note: IndexedNote, ticket: IndexUpdateTicket, rebuild: IndexRebuildTicket? = nil) throws -> Bool {
        try requireOpen(); try Task.checkCancellation()
        guard ticket.indexID == indexID, ticket.noteID == note.id, currentTickets[note.id] == ticket.nonce else { return false }
        if let rebuild, rebuild != activeRebuild { return false }
        try validate(note)
        let seen = activeRebuild?.nonce.uuidString ?? ""
        let tagsJSON = String(decoding: try JSONEncoder().encode(note.tags), as: UTF8.self)
        let existing = try database.statement("SELECT revision,path,title,tags_json,modified FROM docs WHERE note_id=?")
        try existing.bind(note.id.uuidString, 1)
        if try existing.step(), try existing.text(0) == note.revision,
           try existing.text(1) == note.path, try existing.text(2) == note.title,
           try existing.text(3) == tagsJSON, existing.double(4) == note.modifiedAt.timeIntervalSince1970 {
            existing.finish()
            let mark = try database.statement("UPDATE docs SET seen_generation=? WHERE note_id=?")
            try mark.bind(seen, 1); try mark.bind(note.id.uuidString, 2); _ = try mark.step()
            return true
        }
        existing.finish()
        try database.transaction {
            try removeFTS(id: note.id)
            let doc = try database.statement("""
                INSERT INTO docs(note_id,path,title,folded_title,tags,tags_json,body,revision,modified,seen_generation)
                VALUES(?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(note_id) DO UPDATE SET path=excluded.path,title=excluded.title,folded_title=excluded.folded_title,
                  tags=excluded.tags,tags_json=excluded.tags_json,body=excluded.body,revision=excluded.revision,
                  modified=excluded.modified,seen_generation=excluded.seen_generation
                """)
            let values = [note.id.uuidString, note.path, note.title, NoteSearchQuery.fold(note.title),
                          note.tags.joined(separator: " "), tagsJSON, note.body, note.revision]
            for (offset, value) in values.enumerated() { try doc.bind(value, Int32(offset + 1)) }
            try doc.bind(note.modifiedAt.timeIntervalSince1970, 9); try doc.bind(seen, 10); _ = try doc.step()
            let fts = try database.statement("INSERT INTO search_fts(rowid,title,path,tags,body) SELECT rowid,title,path,tags,body FROM docs WHERE note_id=?")
            try fts.bind(note.id.uuidString, 1); _ = try fts.step()
        }
        return true
    }

    public func remove(_ id: UUID) throws {
        try requireOpen(); currentTickets[id] = UUID()
        try database.transaction {
            try removeFTS(id: id)
            let deletion = try database.statement("DELETE FROM docs WHERE note_id=?")
            try deletion.bind(id.uuidString, 1); _ = try deletion.step()
        }
    }
    /// Only a completed snapshot purges rows not observed in that generation.
    /// Cancelling a partial rebuild leaves its cache explicitly incomplete.
    @discardableResult
    public func finishRebuild(_ ticket: IndexRebuildTicket) throws -> Bool {
        try requireOpen(); try Task.checkCancellation()
        guard ticket == activeRebuild else { return false }
        try database.transaction {
            let fts = try database.statement("INSERT INTO search_fts(search_fts,rowid,title,path,tags,body) SELECT 'delete',rowid,title,path,tags,body FROM docs WHERE seen_generation != ?")
            try fts.bind(ticket.nonce.uuidString, 1); _ = try fts.step()
            let deletion = try database.statement("DELETE FROM docs WHERE seen_generation != ?")
            try deletion.bind(ticket.nonce.uuidString, 1); _ = try deletion.step()
        }
        activeRebuild = nil
        return true
    }
    public func cancelRebuild(_ ticket: IndexRebuildTicket) {
        if ticket == activeRebuild { activeRebuild = nil }
    }
    public func clear() throws {
        try requireOpen()
        try database.transaction {
            try database.execute("INSERT INTO search_fts(search_fts) VALUES('delete-all'); DELETE FROM docs;")
        }
        activeRebuild = nil; currentTickets.removeAll()
    }

    public func search(_ input: String, scope: NoteSearchScope = .everything, limit: Int = 100,
                       offset: Int = 0, budgetMilliseconds: Int = 500, maximumSteps: Int = 2_000_000) throws -> [NoteSearchHit] {
        try requireOpen(); try Task.checkCancellation()
        guard (1...200).contains(limit), (0...10_000).contains(offset), (0...5000).contains(budgetMilliseconds),
              (0...10_000_000).contains(maximumSteps) else { throw SearchIndexError.queryTooLong }
        let query = try NoteSearchQuery(input, scope: scope)
        if query.isEmpty { return [] }
        guard budgetMilliseconds > 0, maximumSteps > 0 else { throw SearchIndexError.cancelled }
        let budget = SearchWorkBudget(milliseconds: budgetMilliseconds, virtualMachineSteps: maximumSteps)
        let opaque = Unmanaged.passUnretained(budget).toOpaque()
        sqlite3_progress_handler(database.handle, 1000, { value in
            guard let value else { return 1 }
            return Unmanaged<SearchWorkBudget>.fromOpaque(value).takeUnretainedValue().shouldStop() ? 1 : 0
        }, opaque)
        defer { sqlite3_progress_handler(database.handle, 0, nil, nil) }
        let sql = try database.statement("""
            SELECT docs.note_id,docs.path,docs.title,docs.tags_json,
                   snippet(search_fts,3,'','',' … ',24),docs.revision,docs.modified
            FROM search_fts JOIN docs ON docs.rowid=search_fts.rowid
            WHERE search_fts MATCH ?
            ORDER BY CASE WHEN docs.folded_title=? THEN 0
                          WHEN substr(docs.folded_title,1,length(?))=? THEN 1 ELSE 2 END,
                     bm25(search_fts,8.0,2.0,5.0,1.0),docs.modified DESC,docs.path ASC
            LIMIT ? OFFSET ?
            """)
        try sql.bind(query.ftsExpression, 1)
        for position in 2...4 { try sql.bind(query.rankingText, Int32(position)) }
        try sql.bind(limit, 5); try sql.bind(offset, 6)
        var result: [NoteSearchHit] = []
        while try sql.step() {
            try Task.checkCancellation()
            guard let id = UUID(uuidString: try sql.text(0)) else { throw SearchIndexError.schemaMismatch }
            let tags = try JSONDecoder().decode([String].self, from: Data(sql.text(3).utf8))
            result.append(.init(id: id, path: try sql.text(1), title: try sql.text(2), tags: tags,
                                excerpt: try sql.text(4), revision: try sql.text(5), modifiedAt: Date(timeIntervalSince1970: sql.double(6))))
        }
        return result
    }

    public func verifyIntegrity() throws {
        try requireOpen()
        // FTS5 external-content integrity check compares the index to docs.
        try database.execute("INSERT INTO search_fts(search_fts, rank) VALUES('integrity-check', 1)")
    }
    private func removeFTS(id: UUID) throws {
        let statement = try database.statement("INSERT INTO search_fts(search_fts,rowid,title,path,tags,body) SELECT 'delete',rowid,title,path,tags,body FROM docs WHERE note_id=?")
        try statement.bind(id.uuidString, 1); _ = try statement.step()
    }
    private func validate(_ note: IndexedNote) throws {
        try VaultPaths.validateNote(note.path)
        guard !note.title.isEmpty, note.title.utf8.count <= 1024, note.tags.count <= 64,
              note.body.utf8.count <= 8 * 1024 * 1024, !note.body.contains("\0"),
              note.tags.allSatisfy({ $0.utf8.count <= 128 && !$0.contains("\0") }),
              !note.title.contains("\0"), note.modifiedAt.timeIntervalSince1970.isFinite,
              ContentDigest.sha256(Data(note.body.utf8)) == note.revision else { throw SearchIndexError.invalidDocument }
    }
    private func requireOpen() throws { if closed { throw SearchIndexError.closed } }
}
