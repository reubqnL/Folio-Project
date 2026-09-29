import XCTest
import Foundation
@testable import FolioCore

final class EncryptedWorkingStoreTests: XCTestCase, @unchecked Sendable {
    private func folder() throws -> URL {
        let value = FileManager.default.temporaryDirectory.appendingPathComponent("folio-rdm-working-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true)
        return value
    }

    private func makeStore(_ parent: URL, limits: RDMWorkingLimits = .init()) async throws -> RDMWorkingStore {
        let credentials = try await RDMFixtures.shared.credentials()
        return try RDMWorkingStore(parent: parent, baseName: "project.rdm", keys: credentials.keys, limits: limits)
    }

    private func slot(_ parent: URL, _ slot: Int) -> URL {
        parent.appendingPathComponent(".folio/project.rdm.rdmworking." + String(slot))
    }

    private func draft(_ body: String = "WORKING_DRAFT_CANARY text", id: UUID = UUID(), updatedAt: Int64 = 1_000) -> RDMWorkingDraft {
        .init(id: id, path: "Notes/Draft.md", markdown: body, updatedAt: updatedAt)
    }

    private let head = String(repeating: "ab", count: 32)

    // MARK: - Round trip and chaining

    func testEmptyParentRestoresEmpty() async throws {
        let parent = try folder(); defer { try? FileManager.default.removeItem(at: parent) }
        let store = try await makeStore(parent)
        let restored = try await store.restore()
        XCTAssertEqual(restored, .empty)
    }

    func testSingleDraftRoundTripsAcrossReopen() async throws {
        let parent = try folder(); defer { try? FileManager.default.removeItem(at: parent) }
        do {
            let store = try await makeStore(parent)
            try await store.save(drafts: [draft()], baseSnapshotID: head)
            await store.close()
        }
        let reopened = try await makeStore(parent)
        let restored = try await reopened.restore()
        guard case .current(let state) = restored else { return XCTFail("Expected current state, got \(restored)") }
        XCTAssertEqual(state.projectID, RDMFixtures.projectID)
        XCTAssertEqual(state.baseSnapshotID, head)
        XCTAssertEqual(state.drafts.count, 1)
        XCTAssertEqual(state.drafts[0].markdown, "WORKING_DRAFT_CANARY text")
    }

    func testChainedGenerationsRemainCurrent() async throws {
        let parent = try folder(); defer { try? FileManager.default.removeItem(at: parent) }
        let store = try await makeStore(parent)
        try await store.save(drafts: [draft("first")], baseSnapshotID: head)
        try await store.save(drafts: [draft("second", id: UUID())], baseSnapshotID: head)
        try await store.save(drafts: [draft("third")], baseSnapshotID: head)
        let restored = try await store.restore()
        guard case .current(let state) = restored else { return XCTFail("Expected current state, got \(restored)") }
        XCTAssertEqual(state.drafts.map(\.markdown), ["third"])
    }

    func testClearRemovesLocalDraftCopies() async throws {
        let parent = try folder(); defer { try? FileManager.default.removeItem(at: parent) }
        let store = try await makeStore(parent)
        try await store.save(drafts: [draft()], baseSnapshotID: head)
        try await store.clear()
        let restored = try await store.restore()
        XCTAssertEqual(restored, .empty)
        let slot0Exists = FileManager.default.fileExists(atPath: slot(parent, 0).path)
        let slot1Exists = FileManager.default.fileExists(atPath: slot(parent, 1).path)
        XCTAssertFalse(slot0Exists)
        XCTAssertFalse(slot1Exists)
    }

    // MARK: - Stale detection

    func testTamperedCiphertextSurfacesStaleAndBlocksWrites() async throws {
        let parent = try folder(); defer { try? FileManager.default.removeItem(at: parent) }
        let store = try await makeStore(parent)
        try await store.save(drafts: [draft()], baseSnapshotID: head)
        var bytes = try Data(contentsOf: slot(parent, 0))
        bytes[bytes.count - 1] ^= 0xFF
        try bytes.write(to: slot(parent, 0))
        let restored = try await store.restore()
        guard case .stale = restored else { return XCTFail("Tampered copy must not be trusted, got \(restored)") }
        do {
            try await store.save(drafts: [draft()], baseSnapshotID: head)
            XCTFail("Write over stale state was accepted")
        } catch RDMError.recoveryRequired { }
    }

    func testTamperedHeaderSurfacesStale() async throws {
        let parent = try folder(); defer { try? FileManager.default.removeItem(at: parent) }
        let store = try await makeStore(parent)
        try await store.save(drafts: [draft()], baseSnapshotID: head)
        var bytes = try Data(contentsOf: slot(parent, 0))
        bytes[5] ^= 0x01 // flip the slot claim in the clear header
        try bytes.write(to: slot(parent, 0))
        let restored = try await store.restore()
        guard case .stale = restored else { return XCTFail("Altered header must not be trusted, got \(restored)") }
    }

    func testMissingHistorySlotSurfacesStale() async throws {
        let parent = try folder(); defer { try? FileManager.default.removeItem(at: parent) }
        let store = try await makeStore(parent)
        try await store.save(drafts: [draft()], baseSnapshotID: head)
        try await store.save(drafts: [draft()], baseSnapshotID: head)
        try FileManager.default.removeItem(at: slot(parent, 0))
        let restored = try await store.restore()
        guard case .stale = restored else { return XCTFail("Incomplete history must not be trusted, got \(restored)") }
    }

    func testSingleSlotRollbackThatBreaksTheChainSurfacesStale() async throws {
        let parent = try folder(); defer { try? FileManager.default.removeItem(at: parent) }
        let store = try await makeStore(parent)
        try await store.save(drafts: [draft("generation 1")], baseSnapshotID: head)
        let olderBytes = try Data(contentsOf: slot(parent, 0))
        try await store.save(drafts: [draft("generation 2")], baseSnapshotID: head)
        try await store.save(drafts: [draft("generation 3")], baseSnapshotID: head)
        try await store.save(drafts: [draft("generation 4")], baseSnapshotID: head)
        try olderBytes.write(to: slot(parent, 0))
        let restored = try await store.restore()
        guard case .stale(let state, _) = restored else { return XCTFail("Broken chain must not be trusted, got \(restored)") }
        XCTAssertEqual(state?.drafts.first?.markdown, "generation 4")
    }

    func testMixedEpochCopiesSurfaceStale() async throws {
        let parent = try folder(); defer { try? FileManager.default.removeItem(at: parent) }
        let store = try await makeStore(parent)
        // Epoch A: a chained pair, then a forced stale resolution re-anchors it
        // as epoch B. Mixing one old-epoch record back in must surface stale.
        try await store.save(drafts: [draft("epoch A")], baseSnapshotID: head)
        try await store.save(drafts: [draft("epoch A2")], baseSnapshotID: head)
        let epochARecord = try Data(contentsOf: slot(parent, 0))
        try FileManager.default.removeItem(at: slot(parent, 0))
        let accepted = try await store.resolve()
        XCTAssertEqual(accepted?.drafts.first?.markdown, "epoch A2")
        try await store.save(drafts: [draft("epoch B")], baseSnapshotID: head)
        try epochARecord.write(to: slot(parent, 0))
        let restored = try await store.restore()
        guard case .stale = restored else { return XCTFail("Mixed epochs must not be trusted, got \(restored)") }
    }

    func testForeignProjectWorkingCopyIsNotAccepted() async throws {
        let parent = try folder(); defer { try? FileManager.default.removeItem(at: parent) }
        let store = try await makeStore(parent)
        try await store.save(drafts: [draft()], baseSnapshotID: head)
        let other = RDMProjectKeys(projectID: UUID(), master: try RDMSecret.random(), slots: [])
        defer { other.lock() }
        let foreign = try RDMWorkingStore(parent: parent, baseName: "project.rdm", keys: other)
        let restored = try await foreign.restore()
        guard case .stale = restored else { return XCTFail("Foreign keys must not read another project's working copies, got \(restored)") }
    }

    // MARK: - Reviewed resolution

    func testResolveAcceptsBestStateAndReanchorsTheChain() async throws {
        let parent = try folder(); defer { try? FileManager.default.removeItem(at: parent) }
        let store = try await makeStore(parent)
        try await store.save(drafts: [draft("kept draft")], baseSnapshotID: head)
        try await store.save(drafts: [draft("kept draft")], baseSnapshotID: head)
        try FileManager.default.removeItem(at: slot(parent, 0))
        let before = try await store.restore()
        guard case .stale = before else { return XCTFail("Expected stale before resolution, got \(before)") }
        let accepted = try await store.resolve()
        XCTAssertEqual(accepted?.drafts.first?.markdown, "kept draft")
        let restored = try await store.restore()
        guard case .current(let state) = restored else { return XCTFail("Expected current after resolution, got \(restored)") }
        XCTAssertEqual(state.drafts.first?.markdown, "kept draft")
        // Draft writes work again after the explicit resolution.
        try await store.save(drafts: [draft("after resolution")], baseSnapshotID: head)
        let next = try await store.restore()
        guard case .current(let updated) = next else { return XCTFail("Expected current state, got \(next)") }
        XCTAssertEqual(updated.drafts.first?.markdown, "after resolution")
    }

    func testResolveWithUnreadableCopiesPreservesBytesAndReturnsNoDrafts() async throws {
        let parent = try folder(); defer { try? FileManager.default.removeItem(at: parent) }
        let store = try await makeStore(parent)
        try await store.save(drafts: [draft()], baseSnapshotID: head)
        var bytes = try Data(contentsOf: slot(parent, 0))
        bytes[bytes.count - 1] ^= 0xFF
        try bytes.write(to: slot(parent, 0))
        let accepted = try await store.resolve()
        XCTAssertNil(accepted)
        let restored = try await store.restore()
        XCTAssertEqual(restored, .empty)
        let names = try FileManager.default.contentsOfDirectory(atPath: parent.appendingPathComponent(".folio").path)
        XCTAssertTrue(names.contains { $0.contains("discarded") }, "Set-aside bytes must be preserved privately")
    }

    // MARK: - Validation and bounds

    func testInvalidDraftPathAndDuplicateIDsAreRejected() async throws {
        let parent = try folder(); defer { try? FileManager.default.removeItem(at: parent) }
        let store = try await makeStore(parent)
        let id = UUID()
        do {
            try await store.save(drafts: [.init(id: id, path: "../escape.md", markdown: "x", updatedAt: 1)], baseSnapshotID: head)
            XCTFail("Invalid path was accepted")
        } catch { }
        do {
            try await store.save(drafts: [draft(id: id), draft(id: id)], baseSnapshotID: head)
            XCTFail("Duplicate draft identities were accepted")
        } catch RDMError.duplicateIdentity { }
    }

    func testDraftBoundsAreEnforced() async throws {
        let parent = try folder(); defer { try? FileManager.default.removeItem(at: parent) }
        var limits = RDMWorkingLimits()
        limits.maximumDrafts = 1
        limits.maximumDraftMarkdownBytes = 16
        let store = try await makeStore(parent, limits: limits)
        do {
            try await store.save(drafts: [draft("this draft text is too long")], baseSnapshotID: head)
            XCTFail("Oversized draft was accepted")
        } catch RDMError.invalidContent { }
        do {
            try await store.save(drafts: [draft("ok"), draft("also ok")], baseSnapshotID: head)
            XCTFail("Excess draft count was accepted")
        } catch RDMError.resourceLimit { }
        do {
            try await store.save(drafts: [draft()], baseSnapshotID: "not-hex")
            XCTFail("Malformed base snapshot was accepted")
        } catch RDMError.invalidFormat { }
    }

    // MARK: - No plaintext residue

    func testWorkingFilesContainNoPlaintextDraftOrNoteBytes() async throws {
        let parent = try folder(); defer { try? FileManager.default.removeItem(at: parent) }
        let store = try await makeStore(parent)
        try await store.save(drafts: [draft("WORKING_DRAFT_PRIVATE_CANARY body")], baseSnapshotID: head)
        try await store.writeIndexCache(snapshotID: head, notes: [.init(id: UUID(), path: "Notes/Canary.md", markdown: "INDEX_CACHE_PRIVATE_CANARY body")])
        let needles = ["WORKING_DRAFT_PRIVATE_CANARY", "INDEX_CACHE_PRIVATE_CANARY", "Canary.md", "Draft.md", "Notes/"]
        let root = parent.appendingPathComponent(".folio")
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let item = enumerator?.nextObject() as? URL {
            let bytes = try Data(contentsOf: item)
            for needle in needles {
                XCTAssertNil(bytes.range(of: Data(needle.utf8)), "\(needle) leaked into \(item.lastPathComponent)")
            }
        }
    }

    // MARK: - Encrypted index cache

    func testIndexCacheRoundTripsOnlyForItsSnapshot() async throws {
        let parent = try folder(); defer { try? FileManager.default.removeItem(at: parent) }
        let store = try await makeStore(parent)
        let notes = [RDMNote(id: UUID(), path: "Notes/Alpha.md", markdown: "alpha body"),
                     RDMNote(id: UUID(), path: "Notes/Beta.md", markdown: "beta body")]
        try await store.writeIndexCache(snapshotID: head, notes: notes)
        let loaded = try await store.loadIndexCache(snapshotID: head)
        XCTAssertEqual(loaded, notes)
        let otherSnapshot = await store.loadIndexCache(snapshotID: String(repeating: "cd", count: 32))
        XCTAssertNil(otherSnapshot)
    }

    func testIndexCacheCorruptionFallsBackToNil() async throws {
        let parent = try folder(); defer { try? FileManager.default.removeItem(at: parent) }
        let store = try await makeStore(parent)
        try await store.writeIndexCache(snapshotID: head, notes: [.init(id: UUID(), path: "Notes/A.md", markdown: "a")])
        let cache = parent.appendingPathComponent(".folio/project.rdm.rdmindex")
        var bytes = try Data(contentsOf: cache)
        bytes[bytes.count - 1] ^= 0xFF
        try bytes.write(to: cache)
        let corrupted = await store.loadIndexCache(snapshotID: head)
        XCTAssertNil(corrupted)
        // The cache is derived data; a fresh write replaces it without residue.
        try await store.writeIndexCache(snapshotID: head, notes: [.init(id: UUID(), path: "Notes/B.md", markdown: "b")])
        let replaced = await store.loadIndexCache(snapshotID: head)
        XCTAssertEqual(replaced?.first?.path, "Notes/B.md")
    }

    func testIndexCacheRejectsForeignSnapshotContent() async throws {
        let parent = try folder(); defer { try? FileManager.default.removeItem(at: parent) }
        let store = try await makeStore(parent)
        do {
            try await store.writeIndexCache(snapshotID: "not-hex", notes: [])
            XCTFail("Malformed snapshot identity was accepted")
        } catch RDMError.invalidFormat { }
        do {
            try await store.writeIndexCache(snapshotID: head, notes: [.init(id: UUID(), path: "../escape.md", markdown: "x")])
            XCTFail("Invalid cache note path was accepted")
        } catch { }
    }
}
