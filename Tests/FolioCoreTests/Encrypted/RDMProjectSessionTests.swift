import XCTest
import Foundation
@testable import FolioCore

final class RDMProjectSessionTests: XCTestCase, @unchecked Sendable {
    private func folder() throws -> URL {
        let value = FileManager.default.temporaryDirectory.appendingPathComponent("folio-rdm-session-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true)
        return value
    }

    func testCreateBuildsMemoryOnlyIndexAndReturnsRecoveryCodeSeparately() async throws {
        let parent = try folder(); defer { try? FileManager.default.removeItem(at: parent) }
        let file = parent.appendingPathComponent("project.rdm")
        let created = try await RDMProjectSession.create(at: file, project: RDMFixtures.project(), passphrase: RDMFixtures.passphrase)
        XCTAssertTrue(created.recoveryCode.hasPrefix("FOLIO-R1-"))
        let hits = try await created.session.search("private canary")
        XCTAssertEqual(hits.count, 1)
        let entries = try FileManager.default.contentsOfDirectory(atPath: parent.path)
        XCTAssertTrue(entries.contains("project.rdm"))
        XCTAssertTrue(entries.contains(".folio"))
        XCTAssertFalse(entries.contains { $0.contains("sqlite") || $0.contains("wal") || $0.contains("cache") })
        await created.session.close()
    }

    func testOpenByRecoveryCodeRebuildsTheIndexAfterClose() async throws {
        let parent = try folder(); defer { try? FileManager.default.removeItem(at: parent) }
        let file = parent.appendingPathComponent("project.rdm")
        let created = try await RDMProjectSession.create(at: file, project: RDMFixtures.project(), passphrase: RDMFixtures.passphrase)
        await created.session.close()
        let opened = try await RDMProjectSession.open(at: file, recoveryCode: created.recoveryCode)
        let hits = try await opened.search("private canary")
        let current = try await opened.currentProject()
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(current, RDMFixtures.project())
        await opened.close()
    }

    func testCheckpointReplacesTheIndexOnlyAfterTheArchiveWriteSucceeds() async throws {
        let parent = try folder(); defer { try? FileManager.default.removeItem(at: parent) }
        let file = parent.appendingPathComponent("project.rdm")
        let created = try await RDMProjectSession.create(at: file, project: RDMFixtures.project(), passphrase: RDMFixtures.passphrase)
        let next = RDMFixtures.project("replacement private canary")
        let sealed = try await created.session.checkpoint(next)
        let onDisk = try RDMArchive.inspect(Data(contentsOf: file))
        let current = try await created.session.currentProject()
        let replacementHits = try await created.session.search("replacement private canary")
        XCTAssertEqual(sealed.snapshotID, onDisk.snapshotID)
        XCTAssertEqual(current, next)
        XCTAssertEqual(replacementHits.count, 1)
        await created.session.close()
    }

    func testInvalidCheckpointLeavesTheOldArchiveAndIndexUsable() async throws {
        let parent = try folder(); defer { try? FileManager.default.removeItem(at: parent) }
        let file = parent.appendingPathComponent("project.rdm")
        let created = try await RDMProjectSession.create(at: file, project: RDMFixtures.project(), passphrase: RDMFixtures.passphrase)
        let before = try Data(contentsOf: file)
        let invalid = RDMProjectPayload(id: RDMFixtures.projectID, name: "Invalid", notes: [
            .init(id: UUID(), path: "../escape.md", markdown: "must not replace")
        ])
        do { _ = try await created.session.checkpoint(invalid); XCTFail("Invalid checkpoint was accepted") }
        catch { }
        let hits = try await created.session.search("private canary")
        let current = try await created.session.currentProject()
        XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(current, RDMFixtures.project())
        await created.session.close()
    }

    func testClosingSessionErasesIndexAccessAndReleasesProjectLock() async throws {
        let parent = try folder(); defer { try? FileManager.default.removeItem(at: parent) }
        let file = parent.appendingPathComponent("project.rdm")
        let created = try await RDMProjectSession.create(at: file, project: RDMFixtures.project(), passphrase: RDMFixtures.passphrase)
        await created.session.lock()
        do { _ = try await created.session.search("private"); XCTFail("Locked session returned index data") }
        catch RDMError.locked { }
        let reopened = try await RDMProjectSession.open(at: file, passphrase: RDMFixtures.passphrase)
        let hits = try await reopened.search("private canary")
        XCTAssertEqual(hits.count, 1)
        await reopened.close()
    }

    // MARK: - Persistent encrypted working state

    func testUnsavedDraftsSurviveCloseAndReopen() async throws {
        let parent = try folder(); defer { try? FileManager.default.removeItem(at: parent) }
        let file = parent.appendingPathComponent("project.rdm")
        let created = try await RDMProjectSession.create(at: file, project: RDMFixtures.project(), passphrase: RDMFixtures.passphrase)
        let draft = RDMWorkingDraft(id: UUID(), path: "Notes/WIP.md", markdown: "DRAFT_CANARY unsaved text", updatedAt: 5_000)
        try await created.session.stageDraft(draft)
        await created.session.close()
        let reopened = try await RDMProjectSession.open(at: file, passphrase: RDMFixtures.passphrase)
        let restored = try await reopened.restoreWorkingState()
        guard case .current(let state) = restored else {
            await reopened.close(); return XCTFail("Expected current working state, got \(restored)")
        }
        XCTAssertEqual(state.drafts, [draft])
        await reopened.close()
    }

    func testDiscardingDraftsClearsWorkingCopiesWhenNoneRemain() async throws {
        let parent = try folder(); defer { try? FileManager.default.removeItem(at: parent) }
        let file = parent.appendingPathComponent("project.rdm")
        let created = try await RDMProjectSession.create(at: file, project: RDMFixtures.project(), passphrase: RDMFixtures.passphrase)
        let first = RDMWorkingDraft(id: UUID(), path: "Notes/One.md", markdown: "first draft", updatedAt: 1)
        let second = RDMWorkingDraft(id: UUID(), path: "Notes/Two.md", markdown: "second draft", updatedAt: 2)
        try await created.session.stageDraft(first)
        try await created.session.stageDraft(second)
        try await created.session.discardDraft(id: first.id)
        let remaining = try await created.session.restoreWorkingState()
        guard case .current(let state) = remaining else {
            await created.session.close(); return XCTFail("Expected current working state, got \(remaining)")
        }
        XCTAssertEqual(state.drafts, [second])
        try await created.session.discardDraft(id: second.id)
        let cleared = try await created.session.restoreWorkingState()
        XCTAssertEqual(cleared, .empty)
        await created.session.close()
    }

    func testStaleWorkingStateBlocksStagingUntilExplicitlyResolved() async throws {
        let parent = try folder(); defer { try? FileManager.default.removeItem(at: parent) }
        let file = parent.appendingPathComponent("project.rdm")
        let created = try await RDMProjectSession.create(at: file, project: RDMFixtures.project(), passphrase: RDMFixtures.passphrase)
        let workInProgress = UUID()
        try await created.session.stageDraft(.init(id: workInProgress, path: "Notes/WIP.md", markdown: "recover me", updatedAt: 1))
        try await created.session.stageDraft(.init(id: workInProgress, path: "Notes/WIP.md", markdown: "recover me v2", updatedAt: 2))
        try FileManager.default.removeItem(at: parent.appendingPathComponent(".folio/project.rdm.rdmworking.0"))
        let restored = try await created.session.restoreWorkingState()
        guard case .stale = restored else {
            await created.session.close(); return XCTFail("Incomplete working history must surface stale, got \(restored)")
        }
        do {
            try await created.session.stageDraft(.init(id: UUID(), path: "Notes/Other.md", markdown: "x", updatedAt: 3))
            XCTFail("Staging over stale working state was accepted")
        } catch RDMError.recoveryRequired { }
        let accepted = try await created.session.resolveWorkingState()
        XCTAssertEqual(accepted?.drafts.first?.markdown, "recover me v2")
        try await created.session.stageDraft(.init(id: UUID(), path: "Notes/Other.md", markdown: "after review", updatedAt: 4))
        let after = try await created.session.restoreWorkingState()
        guard case .current(let state) = after else {
            await created.session.close(); return XCTFail("Expected current state after resolution, got \(after)")
        }
        XCTAssertEqual(state.drafts.count, 2)
        await created.session.close()
    }

    func testCheckpointRefreshesTheEncryptedIndexCacheWithoutPlaintextResidue() async throws {
        let parent = try folder(); defer { try? FileManager.default.removeItem(at: parent) }
        let file = parent.appendingPathComponent("project.rdm")
        let created = try await RDMProjectSession.create(at: file, project: RDMFixtures.project(), passphrase: RDMFixtures.passphrase)
        let cache = parent.appendingPathComponent(".folio/project.rdm.rdmindex")
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.path))
        let next = RDMFixtures.project("replacement private canary")
        _ = try await created.session.checkpoint(next)
        await created.session.close()
        let bytes = try Data(contentsOf: cache)
        for needle in ["PRIVATE_NOTE_CANARY", "replacement private canary", "Secret title.md", "PRIVATE_PROJECT_CANARY"] {
            XCTAssertNil(bytes.range(of: Data(needle.utf8)), "\(needle) leaked into the index cache")
        }
        let reopened = try await RDMProjectSession.open(at: file, passphrase: RDMFixtures.passphrase)
        let hits = try await reopened.search("replacement private canary")
        XCTAssertEqual(hits.count, 1)
        await reopened.close()
    }

    func testCorruptedIndexCacheFallsBackToAnInMemoryRebuild() async throws {
        let parent = try folder(); defer { try? FileManager.default.removeItem(at: parent) }
        let file = parent.appendingPathComponent("project.rdm")
        let created = try await RDMProjectSession.create(at: file, project: RDMFixtures.project(), passphrase: RDMFixtures.passphrase)
        await created.session.close()
        let cache = parent.appendingPathComponent(".folio/project.rdm.rdmindex")
        var bytes = try Data(contentsOf: cache)
        bytes[bytes.count - 1] ^= 0xFF
        try bytes.write(to: cache)
        let reopened = try await RDMProjectSession.open(at: file, passphrase: RDMFixtures.passphrase)
        let hits = try await reopened.search("private canary")
        XCTAssertEqual(hits.count, 1)
        await reopened.close()
    }
}
