import XCTest
import Foundation
@testable import FolioCore

final class RDMFileStoreTests: XCTestCase, @unchecked Sendable {
    private func folder() throws -> URL {
        let value = FileManager.default.temporaryDirectory.appendingPathComponent("folio-rdm-file-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true)
        return value
    }
    func testCreateWritesOnlyEncryptedRDMAndLockSidecar() async throws {
        let parent = try folder(); defer { try? FileManager.default.removeItem(at: parent) }
        let file = parent.appendingPathComponent("project.rdm")
        let created = try await RDMFileStore.create(at: file, project: RDMFixtures.project(), passphrase: RDMFixtures.passphrase)
        let bytes = try Data(contentsOf: file)
        XCTAssertGreaterThan(bytes.count, 100)
        XCTAssertFalse(bytes.range(of: Data("PRIVATE_NOTE_CANARY".utf8)) != nil)
        XCTAssertTrue(FileManager.default.fileExists(atPath: parent.appendingPathComponent(".folio/session.lock").path))
        await created.store.close()
    }
    func testCreateRefusesToReplaceAnExistingDestination() async throws {
        let parent = try folder(); defer { try? FileManager.default.removeItem(at: parent) }
        let file = parent.appendingPathComponent("project.rdm")
        let sentinel = Data("do not replace".utf8)
        try sentinel.write(to: file)
        do {
            _ = try await RDMFileStore.create(at: file, project: RDMFixtures.project(), passphrase: RDMFixtures.passphrase)
            XCTFail("Existing destination was replaced")
        } catch RDMError.destinationExists { }
        XCTAssertEqual(try Data(contentsOf: file), sentinel)
    }

    func testOpenByPassphraseAndRecoveryCodeRoundTripsCheckpoint() async throws {
        let parent = try folder(); defer { try? FileManager.default.removeItem(at: parent) }
        let file = parent.appendingPathComponent("project.rdm")
        let created = try await RDMFileStore.create(at: file, project: RDMFixtures.project(), passphrase: RDMFixtures.passphrase)
        let next = RDMFixtures.project("changed body")
        let checkpoint = try await created.store.checkpoint(next)
        XCTAssertEqual(checkpoint.projectID, next.id)
        await created.store.close()
        let opened = try await RDMFileStore.open(at: file, passphrase: RDMFixtures.passphrase)
        let current = try await opened.currentProject()
        XCTAssertEqual(current, next)
        await opened.close()
        let recovery = try await RDMFileStore.open(at: file, recoveryCode: created.recoveryCode)
        let recoveredSnapshot = try await recovery.currentSnapshotID()
        XCTAssertEqual(recoveredSnapshot, checkpoint.snapshotID)
        await recovery.close()
    }
    func testSecondRDMWriterIsRejectedByProjectLock() async throws {
        let parent = try folder(); defer { try? FileManager.default.removeItem(at: parent) }
        let file = parent.appendingPathComponent("project.rdm")
        let created = try await RDMFileStore.create(at: file, project: RDMFixtures.project(), passphrase: RDMFixtures.passphrase)
        do { _ = try await RDMFileStore.open(at: file, passphrase: RDMFixtures.passphrase); XCTFail("Expected lock") }
        catch VaultError.busy { }
        await created.store.close()
    }
    func testStaleExternalCheckpointIsNotOverwritten() async throws {
        let parent = try folder(); defer { try? FileManager.default.removeItem(at: parent) }
        let file = parent.appendingPathComponent("project.rdm")
        let created = try await RDMFileStore.create(at: file, project: RDMFixtures.project(), passphrase: RDMFixtures.passphrase)
        let original = try Data(contentsOf: file)
        let externalParent = try folder(); defer { try? FileManager.default.removeItem(at: externalParent) }
        let externalFile = externalParent.appendingPathComponent("external.rdm")
        let external = try await RDMFileStore.create(at: externalFile, project: RDMFixtures.project("external"), passphrase: RDMFixtures.passphrase)
        let externalBytes = try Data(contentsOf: externalFile)
        await external.store.close()
        try externalBytes.write(to: file)
        do { _ = try await created.store.checkpoint(RDMFixtures.project("local")); XCTFail("Expected stale checkpoint") }
        catch RDMError.staleCheckpoint { }
        XCTAssertEqual(try Data(contentsOf: file), externalBytes)
        XCTAssertNotEqual(try Data(contentsOf: file), original)
        await created.store.close()
    }
    func testCheckpointFailureDoesNotCreatePlaintextStagingMember() async throws {
        let parent = try folder(); defer { try? FileManager.default.removeItem(at: parent) }
        let file = parent.appendingPathComponent("project.rdm")
        let created = try await RDMFileStore.create(at: file, project: RDMFixtures.project(), passphrase: RDMFixtures.passphrase)
        let before = try Set(FileManager.default.contentsOfDirectory(atPath: parent.path))
        await created.store.lock()
        let after = try Set(FileManager.default.contentsOfDirectory(atPath: parent.path))
        XCTAssertEqual(before, after)
        XCTAssertFalse(after.contains { $0.contains("rdm-write") })
    }
    func testMalformedExtensionAndMissingFileAreRejected() async throws {
        let parent = try folder(); defer { try? FileManager.default.removeItem(at: parent) }
        do { _ = try await RDMFileStore.open(at: parent.appendingPathComponent("not-a-project.zip"), passphrase: RDMFixtures.passphrase); XCTFail() }
        catch RDMError.invalidFormat { }
        do { _ = try await RDMFileStore.open(at: parent.appendingPathComponent("missing.rdm"), passphrase: RDMFixtures.passphrase); XCTFail() }
        catch RDMError.invalidFormat { }
}

    func testClosingStoreLocksKeyBeforeASecondOpen() async throws {
        let parent = try folder(); defer { try? FileManager.default.removeItem(at: parent) }
        let file = parent.appendingPathComponent("project.rdm")
        let created = try await RDMFileStore.create(at: file, project: RDMFixtures.project(), passphrase: RDMFixtures.passphrase)
        await created.store.lock()
        let reopened = try await RDMFileStore.open(at: file, passphrase: RDMFixtures.passphrase)
        let project = try await reopened.currentProject()
        XCTAssertEqual(project, RDMFixtures.project())
        await reopened.lock()
    }

    func testUnreadableEncryptedFileIsRejectedWithoutFallback() async throws {
        let parent = try folder(); defer { try? FileManager.default.removeItem(at: parent) }
        let file = parent.appendingPathComponent("project.rdm")
        let created = try await RDMFileStore.create(at: file, project: RDMFixtures.project(), passphrase: RDMFixtures.passphrase)
        await created.store.close()
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let original = attributes[.posixPermissions] as? NSNumber
        defer {
            if let original { try? FileManager.default.setAttributes([.posixPermissions: original], ofItemAtPath: file.path) }
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        do { _ = try await RDMFileStore.open(at: file, passphrase: RDMFixtures.passphrase); XCTFail("Unreadable archive was opened") }
        catch { }
    }

    func testDirectoryAtRDMPathIsRejectedAsAProjectFile() async throws {
        let parent = try folder(); defer { try? FileManager.default.removeItem(at: parent) }
        let file = parent.appendingPathComponent("project.rdm")
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        do { _ = try await RDMFileStore.open(at: file, passphrase: RDMFixtures.passphrase); XCTFail("Directory was opened as an archive") }
        catch { }
    }

    func testSparseOversizedRDMFileIsRejectedBeforeReadingItsBytes() async throws {
        let parent = try folder(); defer { try? FileManager.default.removeItem(at: parent) }
        let file = parent.appendingPathComponent("project.rdm")
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: nil))
        let handle = try FileHandle(forWritingTo: file)
        try handle.seek(toOffset: UInt64(RDMArchive.maximumArchiveBytes + 1))
        try handle.write(contentsOf: Data([0]))
        try handle.close()
        do { _ = try await RDMFileStore.open(at: file, passphrase: RDMFixtures.passphrase); XCTFail("Oversized archive was read") }
        catch VaultError.tooLarge { }
    }

}
