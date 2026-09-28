import XCTest
import Foundation
@testable import FolioCore

// Stateless XCTest container; each test owns a distinct temporary directory.
// Async discovery in Swift 6/Linux passes the instance across executors.
final class VaultRecoveryTests: XCTestCase, @unchecked Sendable {
    enum Stop: Error { case injected }
    private func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("folio-recovery-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func written(_ result: VaultSaveResult) throws -> VaultSnapshot {
        guard case .written(let value) = result else { XCTFail("Unexpected conflict"); throw Stop.injected }
        return value
    }
    private func interrupted(at stage: VaultWriteStage, _ action: (URL, UUID) async throws -> Void) async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try await PlainVaultStore.open(at: root, createIfMissing: true)
        let initial = try written(try await store.createNote(title: "Recover", folder: "Notes", markdown: "before"))
        do {
            _ = try await store.save(initial, markdown: "after", hooks: .init { point in
                if point == stage { throw Stop.injected }
            })
            XCTFail("Fault hook did not run")
        } catch Stop.injected { }
        await store.close()
        try await action(root, initial.note.id)
    }
    private func assertRecovered(_ stage: VaultWriteStage) async throws {
        try await interrupted(at: stage) { root, id in
            let store = try await PlainVaultStore.open(at: root)
            _ = try await store.recover()
            let value = try await store.readNote(id: id)
            XCTAssertEqual(value.markdown, "after")
            let repeated = try await store.recover()
            XCTAssertTrue(repeated.replayed.isEmpty)
            await store.close()
        }
    }
    func testRecoveryAfterJournalSeal() async throws { try await assertRecovered(.journalSealed) }
    func testRecoveryBeforeAtomicInstall() async throws { try await assertRecovered(.beforeInstall) }
    func testRecoveryAfterAtomicInstall() async throws { try await assertRecovered(.installed) }
    func testRecoveryAfterMetadataUpdate() async throws { try await assertRecovered(.metadataUpdated) }
    func testRecoveryAfterCommitReceipt() async throws { try await assertRecovered(.committed) }

    func testRecoveryDoesNotReplaceChangedExternalHead() async throws {
        try await interrupted(at: .journalSealed) { root, _ in
            let target = root.appendingPathComponent("Notes/Recover.md")
            try Data("new external head".utf8).write(to: target)
            let store = try await PlainVaultStore.open(at: root)
            let report = try await store.recover()
            XCTAssertFalse(report.review.isEmpty)
            XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "new external head")
            XCTAssertTrue(report.review.contains { $0.proposedMarkdown == "after" })
            await store.close()
        }
    }
    func testRecoveryDoesNotOverrideReadOnlyChange() async throws {
        try await interrupted(at: .journalSealed) { root, _ in
            let target = root.appendingPathComponent("Notes/Recover.md")
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: target.path)
            let store = try await PlainVaultStore.open(at: root)
            let report = try await store.recover()
            XCTAssertFalse(report.review.isEmpty)
            XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "before")
            await store.close()
        }
    }
    func testCorruptedProposalIsQuarantined() async throws {
        try await interrupted(at: .journalSealed) { root, _ in
            let journal = root.appendingPathComponent(".folio/journal")
            for folder in try FileManager.default.contentsOfDirectory(at: journal, includingPropertiesForKeys: nil) {
                if !FileManager.default.fileExists(atPath: folder.appendingPathComponent("committed.json").path) {
                    try Data("corrupted content".utf8).write(to: folder.appendingPathComponent("proposal.md"))
                }
            }
            let store = try await PlainVaultStore.open(at: root)
            let report = try await store.recover()
            XCTAssertFalse(report.review.isEmpty)
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("Notes/Recover.md"), encoding: .utf8), "before")
            await store.close()
        }
    }
    func testUnsealedOrphanIsNotApplied() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try await PlainVaultStore.open(at: root, createIfMissing: true)
        let orphan = root.appendingPathComponent(".folio/journal/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        try Data("do not invent destination".utf8).write(to: orphan.appendingPathComponent("proposal.md"))
        let report = try await store.recover()
        XCTAssertEqual(report.review.count, 1)
        XCTAssertTrue(report.replayed.isEmpty)
        let notes = try await store.scan()
        XCTAssertTrue(notes.isEmpty)
        await store.close()
    }
    func testRecoveryIntentCannotTraverseOutsideVault() async throws {
        try await interrupted(at: .journalSealed) { root, _ in
            let outside = root.deletingLastPathComponent().appendingPathComponent("folio-untouched-" + UUID().uuidString + ".md")
            try Data("untouched".utf8).write(to: outside)
            defer { try? FileManager.default.removeItem(at: outside) }
            let journal = root.appendingPathComponent(".folio/journal")
            for folder in try FileManager.default.contentsOfDirectory(at: journal, includingPropertiesForKeys: nil) {
                if !FileManager.default.fileExists(atPath: folder.appendingPathComponent("committed.json").path) {
                    let path = folder.appendingPathComponent("intent.json")
                    var intent = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as! [String: Any]
                    intent["relativePath"] = "../" + outside.lastPathComponent
                    try JSONSerialization.data(withJSONObject: intent).write(to: path)
                }
            }
            let store = try await PlainVaultStore.open(at: root)
            let report = try await store.recover()
            XCTAssertFalse(report.review.isEmpty)
            XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "untouched")
            await store.close()
        }
    }
    func testInterruptedCreationRecoversItsIntendedIdentity() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try await PlainVaultStore.open(at: root, createIfMissing: true)
        do {
            _ = try await store.createNote(title: "New", folder: "Notes", markdown: "created", hooks: .init { if $0 == .installed { throw Stop.injected } })
            XCTFail("Expected stop")
        } catch Stop.injected { }
        await store.close()
        let journal = root.appendingPathComponent(".folio/journal")
        let tx = try FileManager.default.contentsOfDirectory(at: journal, includingPropertiesForKeys: nil)[0]
        let intent = try JSONSerialization.jsonObject(with: Data(contentsOf: tx.appendingPathComponent("intent.json"))) as! [String: Any]
        let expectedID = UUID(uuidString: intent["noteID"] as! String)
        let next = try await PlainVaultStore.open(at: root)
        _ = try await next.recover()
        let rows = try await next.scan()
        XCTAssertEqual(rows.first?.id, expectedID)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("Notes/New.md"), encoding: .utf8), "created")
        await next.close()
    }
    func testSaveErrorRequiresRecoveryBeforeMoreWrites() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try await PlainVaultStore.open(at: root, createIfMissing: true)
        let first = try written(try await store.createNote(title: "N", folder: "Notes", markdown: "base"))
        do { _ = try await store.save(first, markdown: "next", hooks: .init { if $0 == .journalSealed { throw Stop.injected } }) }
        catch Stop.injected { }
        do { _ = try await store.createNote(title: "Blocked", folder: "Notes"); XCTFail("Expected recovery block") }
        catch VaultError.recoveryRequired { }
        _ = try await store.recover()
        let recovered = try await store.readNote(id: first.note.id)
        XCTAssertEqual(recovered.markdown, "next")
        await store.close()
    }
    func testIndependentCopyDoesNotReplayOldPendingProposal() async throws {
        try await interrupted(at: .journalSealed) { root, _ in
            let store = try await PlainVaultStore.open(at: root)
            let report = try await store.recover(replay: false)
            XCTAssertTrue(report.replayed.isEmpty)
            XCTAssertTrue(report.review.contains { $0.proposedMarkdown == "after" })
            _ = try await store.forkIdentity()
            let again = try await store.recover()
            XCTAssertTrue(again.replayed.isEmpty)
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("Notes/Recover.md"), encoding: .utf8), "before")
            await store.close()
        }
    }

    func testSHA256KnownVectors() {
        XCTAssertEqual(ContentDigest.sha256(Data()), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(ContentDigest.sha256(Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
    func testCoalescingNeverPostponesContinuousTypingIndefinitely() {
        XCTAssertEqual(SaveCoalescing.deadline(firstDirty: 10, latestEdit: 10.01), 10.26, accuracy: 0.00001)
        XCTAssertEqual(SaveCoalescing.deadline(firstDirty: 10, latestEdit: 10.4), 10.5)
        XCTAssertEqual(SaveCoalescing.deadline(firstDirty: 10, latestEdit: 11), 10.5)
    }
}
