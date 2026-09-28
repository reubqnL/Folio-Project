import Foundation

public struct RDMCreatedProjectSession: Sendable {
    public let session: RDMProjectSession
    /// Display exactly once through a reviewed recovery flow. This value is not
    /// retained by the session or written to the encrypted archive.
    public let recoveryCode: String
}

/// The encrypted-project boundary used by a future native workspace UI.
///
/// The session owns the checkpoint actor and a memory-only derived index. It
/// deliberately does not expose plaintext files, a SQLite path, a WAL, or a
/// long-lived recovery-code property. Index replacement is prepared before a
/// checkpoint and committed only after the authenticated archive is installed.
public actor RDMProjectSession {
    public nonisolated let fileURL: URL
    private let store: RDMFileStore
    private var index: EncryptedWorkingIndex
    private var closed = false

    private init(store: RDMFileStore, index: EncryptedWorkingIndex) {
        self.fileURL = store.fileURL
        self.store = store
        self.index = index
    }

    public static func create(at fileURL: URL, project: RDMProjectPayload,
                              passphrase: String) async throws -> RDMCreatedProjectSession {
        let created = try await RDMFileStore.create(at: fileURL, project: project, passphrase: passphrase)
        do {
            let index = try await makeIndex(store: created.store, project: project)
            return .init(session: .init(store: created.store, index: index), recoveryCode: created.recoveryCode)
        } catch {
            await created.store.close()
            throw error
        }
    }

    public static func open(at fileURL: URL, passphrase: String) async throws -> RDMProjectSession {
        let store = try await RDMFileStore.open(at: fileURL, passphrase: passphrase)
        return try await open(store: store)
    }

    public static func open(at fileURL: URL, recoveryCode: String) async throws -> RDMProjectSession {
        let store = try await RDMFileStore.open(at: fileURL, recoveryCode: recoveryCode)
        return try await open(store: store)
    }

    private static func open(store: RDMFileStore) async throws -> RDMProjectSession {
        do {
            let project = try await store.currentProject()
            let index = try await makeIndex(store: store, project: project)
            return .init(store: store, index: index)
        } catch {
            await store.close()
            throw error
        }
    }

    private static func makeIndex(store: RDMFileStore, project: RDMProjectPayload) async throws -> EncryptedWorkingIndex {
        let index = try await store.makeWorkingIndex()
        do {
            try await index.rebuild(project)
            return index
        } catch {
            await index.close()
            throw error
        }
    }

    public func currentProject() async throws -> RDMProjectPayload {
        try requireOpen()
        return try await store.currentProject()
    }

    public func currentSnapshotID() async throws -> String {
        try requireOpen()
        return try await store.currentSnapshotID()
    }

    public func search(_ query: String, limit: Int = 100) async throws -> [EncryptedIndexHit] {
        try requireOpen()
        return try await index.search(query, limit: limit)
    }

    public func checkpoint(_ next: RDMProjectPayload) async throws -> RDMSealedArchive {
        try requireOpen()
        // Build and validate the replacement index before touching the current
        // archive. If preparation fails, both the file and current index remain.
        let replacement = try await Self.makeIndex(store: store, project: next)
        do {
            let sealed = try await store.checkpoint(next)
            await index.close()
            index = replacement
            return sealed
        } catch {
            await replacement.close()
            throw error
        }
    }

    public func lock() async {
        guard !closed else { return }
        await index.close()
        await store.lock()
        closed = true
    }

    public func close() async {
        guard !closed else { return }
        await index.close()
        await store.close()
        closed = true
    }

    private func requireOpen() throws {
        guard !closed else { throw RDMError.locked }
    }
}
