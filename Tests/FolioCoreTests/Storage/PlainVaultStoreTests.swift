import XCTest
import Foundation
@testable import FolioCore

// Stateless XCTest container; each test owns a distinct temporary directory.
// Async discovery in Swift 6/Linux passes the instance across executors.
final class PlainVaultStoreTests: XCTestCase, @unchecked Sendable {
    enum Injected: Error { case crash }

    private func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("folio-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func withVault(limits: VaultLimits = .init(), _ body: (PlainVaultStore, URL) async throws -> Void) async throws {
        let root = try temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await PlainVaultStore.open(at: root, createIfMissing: true, limits: limits)
        do { try await body(store, root); await store.close() }
        catch { await store.close(); throw error }
    }
    private func written(_ result: VaultSaveResult, file: StaticString = #filePath, line: UInt = #line) throws -> VaultSnapshot {
        guard case .written(let value) = result else { XCTFail("Expected committed write", file: file, line: line); throw Injected.crash }
        return value
    }
    private func create(_ store: PlainVaultStore, text: String = "base") async throws -> VaultSnapshot {
        try written(try await store.createNote(title: "First note", folder: "Notes", markdown: text))
    }

    func testOpeningUninitialisedFolderDoesNotCreateMetadata() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        do { _ = try await PlainVaultStore.open(at: root); XCTFail("Expected consent requirement") }
        catch VaultError.needsInitialization { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".folio").path))
    }
    func testProjectAndNoteIDsSurviveReopening() async throws {
        try await withVault { store, root in
            let project = try await store.project()
            let first = try await create(store)
            await store.close()
            let next = try await PlainVaultStore.open(at: root)
            _ = try await next.recover()
            let nextProject = try await next.project()
            let rows = try await next.scan()
            XCTAssertEqual(nextProject.id, project.id)
            XCTAssertEqual(rows.first?.id, first.note.id)
            let opened = try await next.readNote(id: first.note.id)
            XCTAssertEqual(opened.markdown, "base")
            await next.close()
        }
    }
    func testExistingUTF8FrontMatterBOMAndLineEndingsAreNotRewritten() async throws {
        try await withVault { store, root in
            let original = Data("\u{FEFF}---\r\ntitle: café\r\ncustom: keep me\r\n---\r\nمرحبا 👩🏽‍💻\r\n".utf8)
            let path = root.appendingPathComponent("Existing.md")
            try original.write(to: path)
            let rows = try await store.scan()
            let opened = try await store.readNote(id: rows[0].id)
            XCTAssertEqual(opened.bytes, original)
            XCTAssertEqual(Data(opened.markdown.utf8), original)
            _ = try await store.save(opened, markdown: opened.markdown)
            XCTAssertEqual(try Data(contentsOf: path), original)
        }
    }
    func testCreateWritesARealMarkdownFile() async throws {
        try await withVault { store, root in
            let result = try written(try await store.createNote(title: "Plan", folder: "Projects/Folio"))
            XCTAssertEqual(result.note.relativePath, "Projects/Folio/Plan.md")
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(result.note.relativePath), encoding: .utf8), "# Plan\n\n")
        }
    }
    func testCollisionCannotClobberAnExistingFile() async throws {
        try await withVault { store, root in
            let first = try await create(store)
            do { _ = try await create(store, text: "must not overwrite"); XCTFail("Expected collision") }
            catch { }
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(first.note.relativePath)), first.bytes)
        }
    }
    func testSecondFolioWriterIsRejectedUntilClose() async throws {
        try await withVault { store, root in
            do { _ = try await PlainVaultStore.open(at: root); XCTFail("Expected lock rejection") }
            catch VaultError.busy { }
            await store.close()
            let next = try await PlainVaultStore.open(at: root)
            await next.close()
        }
    }
    func testTraversalAndReservedPathsAreRejected() async throws {
        try await withVault { store, _ in
            for folder in ["../outside", "/tmp", "Notes/../../outside", ".folio", "Notes//Sub", "Notes\\Sub", "Notes/\u{0000}"] {
                do { _ = try await store.createNote(title: "bad", folder: folder); XCTFail(folder) }
                catch { }
            }
        }
    }
    func testSymlinkedFolderCannotEscapeSelectedRoot() async throws {
        let outside = try temporary(); defer { try? FileManager.default.removeItem(at: outside) }
        try await withVault { store, root in
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Escape"), withDestinationURL: outside)
            do { _ = try await store.createNote(title: "no", folder: "Escape"); XCTFail("Expected symlink rejection") }
            catch { }
            XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("no.md").path))
        }
    }
    func testSymlinkReplacingAnOpenNoteIsNeverFollowed() async throws {
        let outside = try temporary(); defer { try? FileManager.default.removeItem(at: outside) }
        let secret = outside.appendingPathComponent("Secret.md")
        try Data("outside".utf8).write(to: secret)
        try await withVault { store, root in
            let initial = try await create(store)
            let note = root.appendingPathComponent(initial.note.relativePath)
            try FileManager.default.removeItem(at: note)
            try FileManager.default.createSymbolicLink(at: note, withDestinationURL: secret)
            do { _ = try await store.save(initial, markdown: "do not send outside"); XCTFail("Expected safe failure") }
            catch { }
            XCTAssertEqual(try String(contentsOf: secret, encoding: .utf8), "outside")
        }
    }
    func testSymlinkedMetadataDirectoryIsRejected() async throws {
        let root = try temporary(), outside = try temporary()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(".folio"), withDestinationURL: outside)
        do { _ = try await PlainVaultStore.open(at: root, createIfMissing: true); XCTFail("Expected rejection") }
        catch { }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }
    func testExternalEditCreatesRecoveryCopyWithoutReplacingDisk() async throws {
        try await withVault { store, root in
            let initial = try await create(store)
            let path = root.appendingPathComponent(initial.note.relativePath)
            try Data("external".utf8).write(to: path)
            let result = try await store.save(initial, markdown: "local")
            guard case .conflict(let c) = result else { return XCTFail("Expected conflict") }
            XCTAssertEqual(c.localMarkdown, "local")
            XCTAssertEqual(c.disk?.markdown, "external")
            XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), "external")
            let recovery = try await store.recover()
            XCTAssertTrue(recovery.review.contains { $0.proposedMarkdown == "local" })
            XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), "external")
        }
    }
    func testExternalWriteRacingExchangeIsPreserved() async throws {
        try await withVault { store, root in
            let initial = try await create(store)
            let path = root.appendingPathComponent(initial.note.relativePath)
            let result = try await store.save(initial, markdown: "local", hooks: .init { stage in
                if stage == .beforeInstall { try Data("racing external text".utf8).write(to: path) }
            })
            guard case .conflict(let c) = result else { return XCTFail("Expected race conflict") }
            XCTAssertEqual(c.displacedMarkdown, "racing external text")
            let preserved = root.appendingPathComponent(".folio/journal/\(c.id.uuidString)/install.md")
            XCTAssertEqual(try String(contentsOf: preserved, encoding: .utf8), "racing external text")
            // Atomic exchange may leave the proposed head installed, but no
            // successful save acknowledgement is emitted for this conflict.
            XCTAssertEqual(c.localMarkdown, "local")
        }
    }
    func testDeletedExternalFileIsNotSilentlyResurrected() async throws {
        try await withVault { store, root in
            let initial = try await create(store)
            let url = root.appendingPathComponent(initial.note.relativePath)
            try FileManager.default.removeItem(at: url)
            guard case .conflict = try await store.save(initial, markdown: "local") else { return XCTFail("Expected conflict") }
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
    }
    func testReadOnlyNoteIsNotReplaced() async throws {
        try await withVault { store, root in
            let initial = try await create(store)
            let path = root.appendingPathComponent(initial.note.relativePath)
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: path.path)
            do { _ = try await store.save(initial, markdown: "not allowed"); XCTFail("Expected read-only error") }
            catch VaultError.readOnly { }
            XCTAssertEqual(try Data(contentsOf: path), initial.bytes)
        }
    }
    func testPermissionsArePreservedAcrossReplacement() async throws {
        try await withVault { store, root in
            var initial = try await create(store)
            let path = root.appendingPathComponent(initial.note.relativePath)
            try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: path.path)
            initial = try await store.readNote(id: initial.note.id)
            let after = try written(try await store.save(initial, markdown: "after"))
            XCTAssertEqual(after.permissions, 0o640)
        }
    }
    func testUnambiguousExternalRenameKeepsNoteIdentity() async throws {
        try await withVault { store, root in
            let initial = try await create(store)
            let renamed = root.appendingPathComponent("Renamed.md")
            try FileManager.default.moveItem(at: root.appendingPathComponent(initial.note.relativePath), to: renamed)
            let rows = try await store.scan()
            XCTAssertEqual(rows.first?.id, initial.note.id)
            XCTAssertEqual(rows.first?.relativePath, "Renamed.md")
            _ = try written(try await store.save(initial, markdown: "after rename"))
            XCTAssertEqual(try String(contentsOf: renamed, encoding: .utf8), "after rename")
        }
    }
    func testCopiedFileGetsDistinctIdentity() async throws {
        try await withVault { store, root in
            let initial = try await create(store)
            try FileManager.default.copyItem(at: root.appendingPathComponent(initial.note.relativePath), to: root.appendingPathComponent("Copy.md"))
            let rows = try await store.scan()
            XCTAssertEqual(Set(rows.map(\.id)).count, 2)
        }
    }
    func testInvalidUTF8IsNotLossilyLoaded() async throws {
        try await withVault { store, root in
            let path = root.appendingPathComponent("Invalid.md")
            let bytes = Data([0xFF, 0xFE, 0xFA])
            try bytes.write(to: path)
            let rows = try await store.scan()
            do { _ = try await store.readNote(id: rows[0].id); XCTFail("Expected UTF-8 rejection") }
            catch VaultError.invalidUTF8 { }
            XCTAssertEqual(try Data(contentsOf: path), bytes)
        }
    }
    func testNoteSizeLimitDoesNotCreateDestination() async throws {
        var limits = VaultLimits(); limits.maximumNoteBytes = 10
        try await withVault(limits: limits) { store, root in
            do { _ = try await create(store, text: String(repeating: "x", count: 11)); XCTFail("Expected size limit") }
            catch VaultError.tooLarge { }
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Notes/First note.md").path))
        }
    }
    func testJournalBudgetStopsWritesRatherThanDroppingRecovery() async throws {
        var limits = VaultLimits(); limits.maximumJournalBytes = 100
        try await withVault(limits: limits) { store, root in
            do { _ = try await create(store); XCTFail("Expected quota error") }
            catch VaultError.journalFull { }
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Notes/First note.md").path))
        }
    }
    func testCommittedHistoryIsBounded() async throws {
        var limits = VaultLimits(); limits.retainedCommittedTransactions = 2
        try await withVault(limits: limits) { store, root in
            var value = try await create(store)
            for i in 0..<10 { value = try written(try await store.save(value, markdown: "revision \(i)")) }
            let records = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(".folio/journal").path)
            XCTAssertLessThanOrEqual(records.count, 3)
            XCTAssertEqual(value.markdown, "revision 9")
        }
    }
    func testCommittedJournalNeverRollsBackLaterExternalWork() async throws {
        try await withVault { store, root in
            let first = try await create(store)
            _ = try written(try await store.save(first, markdown: "committed"))
            let path = root.appendingPathComponent(first.note.relativePath)
            try Data("later external work".utf8).write(to: path)
            let report = try await store.recover()
            XCTAssertTrue(report.replayed.isEmpty)
            XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), "later external work")
        }
    }
    func testExplicitForkChangesProjectNotMarkdown() async throws {
        try await withVault { store, root in
            let first = try await create(store)
            let old = try await store.project()
            let fork = try await store.forkIdentity(name: "Independent")
            XCTAssertNotEqual(old.id, fork.id)
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(first.note.relativePath)), first.bytes)
            do { _ = try await store.save(first, markdown: "old workspace request"); XCTFail("Expected stale workspace rejection") }
            catch VaultError.wrongWorkspace { }
        }
    }
    func testConcurrentSavesOfTheSameBaseProduceOneConflict() async throws {
        try await withVault { store, root in
            let initial = try await create(store)
            async let a = store.save(initial, markdown: "writer A")
            async let b = store.save(initial, markdown: "writer B")
            let outcomes = try await [a, b]
            let commits = outcomes.compactMap { outcome -> VaultSnapshot? in
                if case .written(let snapshot) = outcome { return snapshot }; return nil
            }
            let conflicts = outcomes.compactMap { outcome -> VaultConflict? in
                if case .conflict(let conflict) = outcome { return conflict }; return nil
            }
            XCTAssertEqual(commits.count, 1); XCTAssertEqual(conflicts.count, 1)
            XCTAssertNotEqual(commits.first?.markdown, conflicts.first?.localMarkdown)
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(initial.note.relativePath), encoding: .utf8), commits.first?.markdown)
        }
    }
    func testManualRecoveryCopyNeverInstallsEvenWhenBaseMatches() async throws {
        try await withVault { store, root in
            let initial = try await create(store)
            let item = try await store.preserveDraft(initial, markdown: "newer local typing", reason: "Explicit review only")
            let report = try await store.recover()
            XCTAssertTrue(report.replayed.isEmpty)
            XCTAssertTrue(report.review.contains { $0.id == item.id && $0.proposedMarkdown == "newer local typing" })
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(initial.note.relativePath), encoding: .utf8), "base")
        }
    }
    func testSnapshotFromCopiedRootCannotWriteAnotherRoot() async throws {
        try await withVault { store, root in
            let initial = try await create(store)
            let copy = root.deletingLastPathComponent().appendingPathComponent("folio-copy-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: copy) }
            try FileManager.default.copyItem(at: root, to: copy)
            let copied = try await PlainVaultStore.open(at: copy)
            _ = try await copied.recover()
            do { _ = try await copied.save(initial, markdown: "wrong root"); XCTFail("Expected root-identity rejection") }
            catch VaultError.wrongWorkspace { }
            await copied.close()
        }
    }
    func testLargeUnicodeTextRoundTripsThroughRealFiles() async throws {
        try await withVault { store, root in
            let original = String(repeating: "café 👩🏽‍💻 مرحبا 日本語\n", count: 30_000)
            let initial = try await create(store, text: original)
            let changed = original + "tail"
            let result = try written(try await store.save(initial, markdown: changed))
            XCTAssertEqual(result.markdown, changed)
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(result.note.relativePath)), Data(changed.utf8))
        }
    }
    func testReplacingNoteDoesNotModifyUnselectedHardLinkedFile() async throws {
        try await withVault { store, root in
            let initial = try await create(store)
            let other = root.deletingLastPathComponent().appendingPathComponent("folio-hardlink-" + UUID().uuidString + ".md")
            defer { try? FileManager.default.removeItem(at: other) }
            try FileManager.default.linkItem(at: root.appendingPathComponent(initial.note.relativePath), to: other)
            _ = try written(try await store.save(initial, markdown: "only the selected note"))
            XCTAssertEqual(try String(contentsOf: other, encoding: .utf8), "base")
        }
    }

    func testClosedStoreCannotWrite() async throws {
        try await withVault { store, _ in
            await store.close()
            do { _ = try await create(store); XCTFail("Expected closed store") }
            catch VaultError.closed { }
        }
    }
    func testUnknownMetadataVersionIsPreservedAndRejected() async throws {
        try await withVault { store, root in
            await store.close()
            let url = root.appendingPathComponent(".folio/project.json")
            var object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
            object["version"] = 999
            let future = try JSONSerialization.data(withJSONObject: object)
            try future.write(to: url)
            do { _ = try await PlainVaultStore.open(at: root); XCTFail("Expected version error") }
            catch VaultError.unsupportedFormat { }
            XCTAssertEqual(try Data(contentsOf: url), future)
        }
    }
    func testUnknownOwnedMetadataFieldsAreNotSilentlyDropped() async throws {
        try await withVault { store, root in
            await store.close()
            let url = root.appendingPathComponent(".folio/project.json")
            var object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
            object["futureFeature"] = ["keep": true]
            let future = try JSONSerialization.data(withJSONObject: object)
            try future.write(to: url)
            do { _ = try await PlainVaultStore.open(at: root); XCTFail("Expected metadata error") }
            catch VaultError.malformedMetadata { }
            XCTAssertEqual(try Data(contentsOf: url), future)
        }
    }
    func testRecreatingADeletedPathInvalidatesTheOldIdentity() async throws {
        try await withVault { store, root in
            let original = try await create(store)
            try FileManager.default.removeItem(at: root.appendingPathComponent(original.note.relativePath))
            let replacement = try await create(store, text: "new identity")
            XCTAssertNotEqual(original.note.id, replacement.note.id)
            do { _ = try await store.readNote(id: original.note.id); XCTFail("Old ID must not alias a newly created note") }
            catch VaultError.missingNote { }
            let current = try await store.readNote(id: replacement.note.id)
            XCTAssertEqual(current.markdown, "new identity")
        }
    }

}
