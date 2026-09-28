import XCTest
import Foundation
@testable import FolioCore

final class EncryptedWorkingIndexTests: XCTestCase, @unchecked Sendable {
    private func project() -> RDMProjectPayload {
        RDMProjectPayload(id: UUID(), name: "Encrypted fixture", notes: [
            .init(id: UUID(), path: "Notes/Alpha.md", markdown: "alpha private phrase"),
            .init(id: UUID(), path: "Notes/Beta.md", markdown: "beta private phrase")
        ])
    }
    func testRebuildSearchesOnlyMemoryAndReturnsCurrentObjects() async throws {
        let value = project(), index = try EncryptedWorkingIndex(projectID: value.id)
        try await index.rebuild(value)
        let hits = try await index.search("alpha private phrase")
        XCTAssertEqual(hits.count, 1); XCTAssertEqual(hits[0].path, "Notes/Alpha.md")
        let stats = try await index.statistics(); XCTAssertEqual(stats.records, 2); XCTAssertGreaterThan(stats.bytes, 0)
        await index.close()
    }
    func testNoPersistentCachePathIsCreatedByTheWorkingIndex() async throws {
        let value = project(), index = try EncryptedWorkingIndex(projectID: value.id)
        try await index.rebuild(value)
        let files = try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)
        XCTAssertFalse(files.contains { $0.contains("Encrypted fixture") || $0.contains("rdm") })
        await index.close()
    }
    func testForeignProjectRebuildIsRejected() async throws {
        let index = try EncryptedWorkingIndex(projectID: UUID())
        do { try await index.rebuild(project()); XCTFail("Expected workspace rejection") }
        catch EncryptedIndexError.wrongProject { }
    }
    func testUpdatesDoNotLeaveTheOldBodyIndexed() async throws {
        let value = project(), index = try EncryptedWorkingIndex(projectID: value.id)
        try await index.rebuild(value)
        let note = value.notes[0]
        try await index.add(.init(id: note.id, path: note.path, markdown: "replacement only"))
        let privateHits = try await index.search("alpha private phrase")
        let replacementHit = try await index.search("replacement").first?.id
        XCTAssertTrue(privateHits.isEmpty)
        XCTAssertEqual(replacementHit, note.id)
    }
    func testDeleteAndCloseEraseDerivedSearchAvailability() async throws {
        let value = project(), index = try EncryptedWorkingIndex(projectID: value.id)
        try await index.rebuild(value)
        let id = value.notes[0].id; try await index.remove(id)
        let removedHits = try await index.search("alpha private phrase")
        XCTAssertTrue(removedHits.isEmpty)
        await index.close()
        do { _ = try await index.search("beta"); XCTFail("Closed index returned data") }
        catch EncryptedIndexError.closed { }
    }
    func testBoundsRejectOversizedRecordsAndQueries() async throws {
        let value = project(), index = try EncryptedWorkingIndex(projectID: value.id, maximumRecords: 1, maximumBytes: 100)
        do { try await index.rebuild(value); XCTFail("Expected record bound") }
        catch EncryptedIndexError.tooLarge { }
        let other = try EncryptedWorkingIndex(projectID: value.id)
        do { _ = try await other.search(String(repeating: "x", count: 513)); XCTFail() }
        catch EncryptedIndexError.queryTooLong { }
    }
    func testClearDoesNotMakeTheIndexAppearPersisted() async throws {
        let value = project(), index = try EncryptedWorkingIndex(projectID: value.id)
        try await index.rebuild(value); try await index.clear()
        let stats = try await index.statistics()
        let hits = try await index.search("alpha private phrase")
        XCTAssertEqual(stats.records, 0)
        XCTAssertTrue(hits.isEmpty)
    }
    func testFailedRebuildPreservesTheLastUsableIndex() async throws {
        let value = project(), index = try EncryptedWorkingIndex(projectID: value.id)
        try await index.rebuild(value)
        let invalid = RDMProjectPayload(id: value.id, name: value.name, notes: [
            value.notes[0], .init(id: UUID(), path: "../escape.md", markdown: "must reject")
        ])
        do { try await index.rebuild(invalid); XCTFail("Invalid rebuild was accepted") }
        catch { }
        let hits = try await index.search("beta private phrase")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].id, value.notes[1].id)
        await index.close()
    }
}
