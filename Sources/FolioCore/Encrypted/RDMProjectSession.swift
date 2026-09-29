import Foundation

public struct RDMCreatedProjectSession: Sendable {
    public let session: RDMProjectSession
    /// Display exactly once through a reviewed recovery flow. This value is not
    /// retained by the session or written to the encrypted archive.
    public let recoveryCode: String
}

/// The encrypted-project boundary used by a future native workspace UI.
///
/// The session owns the checkpoint actor, a memory-only derived index and the
/// persistent encrypted working store (unsaved drafts plus the derived index
/// cache). It deliberately does not expose plaintext files, a SQLite path, a
/// WAL, or a long-lived recovery-code property. Index replacement is prepared
/// before a checkpoint and committed only after the authenticated archive is
/// installed.
public actor RDMProjectSession {
    public nonisolated let fileURL: URL
    private let store: RDMFileStore
    private var index: EncryptedWorkingIndex
    private let working: RDMWorkingStore
    private var closed = false

    private init(store: RDMFileStore, index: EncryptedWorkingIndex, working: RDMWorkingStore) {
        self.fileURL = store.fileURL
        self.store = store
        self.index = index
        self.working = working
    }

    public static func create(at fileURL: URL, project: RDMProjectPayload,
                              passphrase: String) async throws -> RDMCreatedProjectSession {
        let created = try await RDMFileStore.create(at: fileURL, project: project, passphrase: passphrase)
        do {
            let working = try await created.store.makeWorkingStore()
            do {
                let index = try await makeIndex(store: created.store, project: project)
                let snapshotID = try await created.store.currentSnapshotID()
                // Derived cache; its failure is never project-data loss. The
                // next open falls back to the in-memory rebuild.
                try? await working.writeIndexCache(snapshotID: snapshotID, notes: project.notes)
                return .init(session: .init(store: created.store, index: index, working: working),
                             recoveryCode: created.recoveryCode)
            } catch {
                await working.close()
                throw error
            }
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
            let working = try await store.makeWorkingStore()
            do {
                let snapshotID = try await store.currentSnapshotID()
                let index = try await openIndex(store: store, working: working, project: project, snapshotID: snapshotID)
                return .init(store: store, index: index, working: working)
            } catch {
                await working.close()
                throw error
            }
        } catch {
            await store.close()
            throw error
        }
    }

    /// Opens the derived index from its encrypted cache when the cache matches
    /// the current archive head; every cache problem falls back to the full
    /// in-memory rebuild from the authenticated project.
    private static func openIndex(store: RDMFileStore, working: RDMWorkingStore,
                                  project: RDMProjectPayload, snapshotID: String) async throws -> EncryptedWorkingIndex {
        let index = try await store.makeWorkingIndex()
        if let notes = await working.loadIndexCache(snapshotID: snapshotID) {
            do {
                try await index.rebuild(notes: notes)
                return index
            } catch {
                // Derived cache; fall back to the full rebuild below.
            }
        }
        do {
            try await index.rebuild(project)
            return index
        } catch {
            await index.close()
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
            // The derived cache is refreshed after the durable checkpoint. Its
            // failure is never project-data loss; the next open rebuilds instead.
            try? await working.writeIndexCache(snapshotID: sealed.snapshotID, notes: next.notes)
            return sealed
        } catch {
            await replacement.close()
            throw error
        }
    }

    // MARK: - Local working state (unsaved drafts)

    /// Restores local unsaved drafts. `.stale` results need explicit review
    /// through `resolveWorkingState()` before further draft writes.
    public func restoreWorkingState() async throws -> RDMWorkingRestore {
        try requireOpen()
        return try await working.restore()
    }

    /// Persists one unsaved draft (upsert by note id) in the encrypted working
    /// store. This is local durability only; it is not a checkpoint.
    public func stageDraft(_ draft: RDMWorkingDraft) async throws {
        try requireOpen()
        var drafts = try await currentDrafts()
        if let existing = drafts.firstIndex(where: { $0.id == draft.id }) {
            drafts[existing] = draft
        } else {
            drafts.append(draft)
        }
        let head = try await store.currentSnapshotID()
        try await working.save(drafts: drafts, baseSnapshotID: head)
    }

    /// Removes one staged draft. When none remain, the local draft copies are
    /// removed entirely.
    public func discardDraft(id: UUID) async throws {
        try requireOpen()
        let remaining = try await currentDrafts().filter { $0.id != id }
        if remaining.isEmpty {
            try await working.clear()
        } else {
            let head = try await store.currentSnapshotID()
            try await working.save(drafts: remaining, baseSnapshotID: head)
        }
    }

    /// Explicit reviewed resolution of inconsistent local working copies.
    /// Returns the accepted state; nil when no drafts remain.
    @discardableResult
    public func resolveWorkingState() async throws -> RDMWorkingState? {
        try requireOpen()
        return try await working.resolve()
    }

    private func currentDrafts() async throws -> [RDMWorkingDraft] {
        switch try await working.restore() {
        case .empty:
            return []
        case .current(let state):
            return state.drafts
        case .stale:
            throw RDMError.recoveryRequired
        }
    }

    public func lock() async {
        guard !closed else { return }
        await index.close()
        await working.close()
        await store.lock()
        closed = true
    }

    public func close() async {
        guard !closed else { return }
        await index.close()
        await working.close()
        await store.close()
        closed = true
    }

    private func requireOpen() throws {
        guard !closed else { throw RDMError.locked }
    }
}
