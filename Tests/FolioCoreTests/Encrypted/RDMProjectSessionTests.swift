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
}
