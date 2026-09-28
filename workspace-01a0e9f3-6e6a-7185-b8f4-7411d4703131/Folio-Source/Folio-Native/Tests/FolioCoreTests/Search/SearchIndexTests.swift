import XCTest
import Foundation
@testable import FolioCore

final class SearchIndexTests: XCTestCase, @unchecked Sendable {
    private func withIndex(_ body: (LocalSearchIndex, URL, URL, UUID) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("folio-search-" + UUID().uuidString)
        let vault = root.appendingPathComponent("vault"), cache = root.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let index = try await LocalSearchIndex.open(cacheDirectory: cache, vaultRoot: vault, projectID: id, rootIdentity: "test-root")
        do { try await body(index, vault, cache, id); await index.close() }
        catch { await index.close(); throw error }
    }
    private func doc(_ title: String, body: String, id: UUID = UUID(), tags: [String] = [], path: String? = nil) -> IndexedNote {
        .init(id: id, path: path ?? "Notes/\(title).md", title: title, tags: tags, body: body,
              revision: ContentDigest.sha256(Data(body.utf8)), modifiedAt: Date(timeIntervalSince1970: 100))
    }
    private func put(_ value: IndexedNote, in index: LocalSearchIndex, rebuild: IndexRebuildTicket? = nil) async throws {
        let ticket = try await index.reserveUpdate(for: value.id)
        let applied = try await index.upsert(value, ticket: ticket, rebuild: rebuild)
        XCTAssertTrue(applied)
    }
    func testTitleAndBodySearchWithExactTitleRanking() async throws {
        try await withIndex { index, _, _, _ in
            let exact = doc("Launch strategy", body: "Short note")
            let body = doc("Other", body: String(repeating: "launch strategy ", count: 25))
            try await put(body, in: index); try await put(exact, in: index)
            let hits = try await index.search("launch strategy")
            XCTAssertEqual(hits.first?.id, exact.id)
            XCTAssertEqual(hits.count, 2)
            try await index.verifyIntegrity()
        }
    }
    func testUpdatesRemoveOldTermsAndDeletesRemoveRows() async throws {
        try await withIndex { index, _, _, _ in
            let a = doc("A", body: "oldterm")
            try await put(a, in: index)
            try await put(doc("Renamed", body: "newterm", id: a.id), in: index)
            let old = try await index.search("oldterm")
            let new = try await index.search("newterm")
            XCTAssertTrue(old.isEmpty); XCTAssertEqual(new.first?.path, "Notes/Renamed.md")
            try await index.remove(a.id)
            let deleted = try await index.search("newterm")
            XCTAssertTrue(deleted.isEmpty)
            try await index.verifyIntegrity()
        }
    }
    func testLiteralPhrasesAndFTSOperatorsCannotEscapeQuery() async throws {
        try await withIndex { index, _, _, _ in
            try await put(doc("Literal OR", body: "red green blue"), in: index)
            try await put(doc("Second", body: "green red"), in: index)
            let phrase = try await index.search("\"red green\"")
            XCTAssertEqual(phrase.count, 1)
            let literal = try await index.search("OR")
            XCTAssertEqual(literal.count, 1)
            _ = try await index.search("\" ; DROP TABLE docs; --")
            let stats = try await index.statistics()
            XCTAssertEqual(stats.documentCount, 2)
        }
    }
    func testScopePrefixAccentAndTags() async throws {
        try await withIndex { index, _, _, _ in
            try await put(doc("Café research", body: "architecture notes", tags: ["Roadmap"]), in: index)
            let folded = try await index.search("cafe res", scope: .titles)
            XCTAssertEqual(folded.count, 1)
            let body = try await index.search("arch", scope: .titles)
            XCTAssertTrue(body.isEmpty)
            let tag = try await index.search("road", scope: .tags)
            XCTAssertEqual(tag.first?.tags, ["Roadmap"])
        }
    }
    func testStaleReservationCannotOverwriteNewerRevision() async throws {
        try await withIndex { index, _, _, _ in
            let id = UUID()
            let old = try await index.reserveUpdate(for: id)
            let current = try await index.reserveUpdate(for: id)
            let applied = try await index.upsert(doc("New", body: "newword", id: id), ticket: current)
            let stale = try await index.upsert(doc("Old", body: "oldword", id: id), ticket: old)
            XCTAssertTrue(applied); XCTAssertFalse(stale)
            let results = try await index.search("newword")
            XCTAssertEqual(results.first?.title, "New")
        }
    }
    func testRebuildPurgesAbsentNotesOnlyWhenFinished() async throws {
        try await withIndex { index, _, _, _ in
            let a = doc("Alpha", body: "alpha"), b = doc("Beta", body: "beta")
            try await put(a, in: index); try await put(b, in: index)
            let rebuild = try await index.beginRebuild()
            try await put(a, in: index, rebuild: rebuild)
            let during = try await index.search("beta")
            XCTAssertEqual(during.count, 1)
            let done = try await index.finishRebuild(rebuild)
            XCTAssertTrue(done)
            let after = try await index.search("beta")
            XCTAssertTrue(after.isEmpty)
            try await index.verifyIntegrity()
        }
    }
    func testCancelledRebuildDoesNotDeleteUnseenRows() async throws {
        try await withIndex { index, _, _, _ in
            try await put(doc("Original", body: "survives"), in: index)
            let token = try await index.beginRebuild()
            await index.cancelRebuild(token)
            let done = try await index.finishRebuild(token)
            XCTAssertFalse(done)
            let rows = try await index.search("survives")
            XCTAssertEqual(rows.count, 1)
        }
    }
    func testLiveUpdateDuringRebuildSurvivesFinalPurge() async throws {
        try await withIndex { index, _, _, _ in
            let token = try await index.beginRebuild()
            let value = doc("Live save", body: "latest")
            try await put(value, in: index)
            _ = try await index.finishRebuild(token)
            let rows = try await index.search("latest")
            XCTAssertEqual(rows.first?.id, value.id)
        }
    }
    func testNewerRebuildInvalidatesEarlierWork() async throws {
        try await withIndex { index, _, _, _ in
            let old = try await index.beginRebuild()
            let current = try await index.beginRebuild()
            let value = doc("Old job", body: "must not appear")
            let update = try await index.reserveUpdate(for: value.id)
            let applied = try await index.upsert(value, ticket: update, rebuild: old)
            XCTAssertFalse(applied)
            let staleFinish = try await index.finishRebuild(old)
            XCTAssertFalse(staleFinish)
            _ = try await index.finishRebuild(current)
            let stats = try await index.statistics()
            XCTAssertEqual(stats.documentCount, 0)
        }
    }
    func testDeletedNoteInvalidatesPendingUpdateTicket() async throws {
        try await withIndex { index, _, _, _ in
            let note = doc("Deleted", body: "invisible")
            let ticket = try await index.reserveUpdate(for: note.id)
            try await index.remove(note.id)
            let applied = try await index.upsert(note, ticket: ticket)
            XCTAssertFalse(applied)
        }
    }
    func testCachePersistsAndCanBeReopened() async throws {
        try await withIndex { index, vault, cache, id in
            let value = doc("Persisted", body: "searchable after reopen")
            try await put(value, in: index)
            await index.close()
            let next = try await LocalSearchIndex.open(cacheDirectory: cache, vaultRoot: vault, projectID: id, rootIdentity: "test-root")
            let rows = try await next.search("reopen")
            XCTAssertEqual(rows.first?.id, value.id)
            try await next.verifyIntegrity(); await next.close()
        }
    }
    func testCacheInsideVaultIsRejected() async throws {
        try await withIndex { _, vault, _, id in
            do {
                _ = try await LocalSearchIndex.open(cacheDirectory: vault.appendingPathComponent("cache"), vaultRoot: vault, projectID: id, rootIdentity: "test")
                XCTFail("Expected cache boundary rejection")
            } catch SearchIndexError.cacheInsideVault { }
        }
    }
    func testCacheSymlinkIntoVaultIsRejected() async throws {
        try await withIndex { _, vault, cache, id in
            let link = cache.deletingLastPathComponent().appendingPathComponent("linked-cache")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: vault)
            do { _ = try await LocalSearchIndex.open(cacheDirectory: link, vaultRoot: vault, projectID: id, rootIdentity: "test"); XCTFail("Expected rejection") }
            catch SearchIndexError.cacheInsideVault { }
        }
    }
    func testUnsafeCachePermissionsAreRejected() async throws {
        try await withIndex { index, vault, cache, id in
            await index.close()
            try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: cache.path)
            do { _ = try await LocalSearchIndex.open(cacheDirectory: cache, vaultRoot: vault, projectID: id, rootIdentity: "test-root"); XCTFail("Expected private-cache requirement") }
            catch SearchIndexError.unsafeCachePath { }
        }
    }
    func testInvalidRevisionAndNULCannotCorruptExistingEntry() async throws {
        try await withIndex { index, _, _, _ in
            let good = doc("Safe", body: "still present")
            try await put(good, in: index)
            let wrong = IndexedNote(id: good.id, path: good.path, title: good.title, body: "wrong", revision: good.revision, modifiedAt: .now)
            let ticket = try await index.reserveUpdate(for: good.id)
            do { _ = try await index.upsert(wrong, ticket: ticket); XCTFail("Expected hash check") }
            catch SearchIndexError.invalidDocument { }
            let nul = doc("Nul", body: "one\0two")
            let n = try await index.reserveUpdate(for: nul.id)
            do { _ = try await index.upsert(nul, ticket: n); XCTFail("Expected NUL rejection") }
            catch SearchIndexError.invalidDocument { }
            let rows = try await index.search("present")
            XCTAssertEqual(rows.first?.id, good.id)
            try await index.verifyIntegrity()
        }
    }
    func testPlainExcerptCannotInjectMarkup() async throws {
        try await withIndex { index, _, _, _ in
            try await put(doc("Unsafe-looking text", body: "payload <script>alert('not executable')</script>"), in: index)
            let result = try await index.search("payload")
            XCTAssertTrue(result.first?.excerpt.contains("<script>") == true)
        }
    }
    func testLimitsAndZeroWorkBudgetFailExplicitly() async throws {
        try await withIndex { index, _, _, _ in
            do { _ = try await index.search(String(repeating: "x", count: 513)); XCTFail("Expected query cap") }
            catch SearchIndexError.queryTooLong { }
            do { _ = try await index.search("x", limit: 1000); XCTFail("Expected limit") }
            catch SearchIndexError.queryTooLong { }
            do { _ = try await index.search("x", budgetMilliseconds: 0); XCTFail("Expected explicit cancellation") }
            catch SearchIndexError.cancelled { }
        }
    }
    func testResourceProfileChangesActualSQLiteBudget() async throws {
        try await withIndex { index, _, _, _ in
            try await index.setProfile(.lowMemory)
            let low = try await index.statistics()
            XCTAssertEqual(low.cacheKiB, 4096)
            try await index.setProfile(.largeVault)
            let high = try await index.statistics()
            XCTAssertEqual(high.cacheKiB, 32768)
        }
    }
    func testPaginationAndClearKeepFTSConsistent() async throws {
        try await withIndex { index, _, _, _ in
            for number in 0..<12 { try await put(doc("Item \(number)", body: "sharedword"), in: index) }
            let first = try await index.search("sharedword", limit: 5)
            let second = try await index.search("sharedword", limit: 5, offset: 5)
            XCTAssertEqual(first.count, 5); XCTAssertEqual(second.count, 5)
            XCTAssertTrue(Set(first.map(\.id)).isDisjoint(with: Set(second.map(\.id))))
            try await index.clear()
            let rows = try await index.search("sharedword")
            XCTAssertTrue(rows.isEmpty)
            try await index.verifyIntegrity()
        }
    }
    func testClosedIndexCannotQuery() async throws {
        try await withIndex { index, _, _, _ in
            await index.close()
            do { _ = try await index.search("x"); XCTFail("Expected closed index") }
            catch SearchIndexError.closed { }
        }
    }

    func testExplicitCacheResetCanRecoverCorruptDerivedFileWithoutTouchingVault() async throws {
        try await withIndex { index, vault, cache, id in
            let original = vault.appendingPathComponent("Original.md")
            try Data("never delete the note".utf8).write(to: original)
            let file = index.fileURL
            await index.close()
            try Data("corrupted derived bytes".utf8).write(to: file)
            try await LocalSearchIndex.discardCacheAfterConfirmation(cacheDirectory: cache, vaultRoot: vault, projectID: id, rootIdentity: "test-root")
            let fresh = try await LocalSearchIndex.open(cacheDirectory: cache, vaultRoot: vault, projectID: id, rootIdentity: "test-root")
            let count = try await fresh.statistics()
            XCTAssertEqual(count.documentCount, 0)
            XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "never delete the note")
            await fresh.close()
        }
    }
    func testCacheResetCannotBeARecursiveDirectoryDelete() async throws {
        try await withIndex { index, vault, cache, id in
            let file = index.fileURL
            await index.close()
            try FileManager.default.removeItem(at: file)
            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
            let sentinel = file.appendingPathComponent("Keep.md")
            try Data("keep".utf8).write(to: sentinel)
            do { try await LocalSearchIndex.discardCacheAfterConfirmation(cacheDirectory: cache, vaultRoot: vault, projectID: id, rootIdentity: "test-root"); XCTFail("Expected directory refusal") }
            catch SearchIndexError.unsafeCachePath { }
            XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "keep")
        }
    }

    func testVMWorkBudgetInterruptsAndConnectionRemainsUsable() async throws {
        try await withIndex { index, _, _, _ in
            for number in 0..<180 { try await put(doc("Budget \(number)", body: "sharedbudget uniquevalue\(number)"), in: index) }
            do { _ = try await index.search("sharedbudget", maximumSteps: 1000); XCTFail("Expected bounded query interruption") }
            catch SearchIndexError.cancelled { }
            let result = try await index.search("\"uniquevalue42\"")
            XCTAssertEqual(result.count, 1)
            try await index.verifyIntegrity()
        }
    }

}
