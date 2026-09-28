import XCTest
import Foundation
@testable import FolioCore

final class RoadmapStorageTests: XCTestCase, @unchecked Sendable {
    enum Stop: Error { case injected }
    private func withProject(_ action: (PlainVaultStore, URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("folio-roadmap-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await PlainVaultStore.open(at: root, createIfMissing: true)
        do { try await action(store, root); await store.close() }
        catch { await store.close(); throw error }
    }
    private func written(_ outcome: RoadmapSaveResult) throws -> RoadmapSnapshot {
        guard case .written(let value) = outcome else { XCTFail("Unexpected planning conflict"); throw Stop.injected }
        return value
    }
    func testOpeningEmptyPlanDoesNotCreateAFile() async throws {
        try await withProject { store, root in
            let plan = try await store.loadRoadmap()
            XCTAssertTrue(plan.document.items.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".folio/roadmap.json").path))
        }
    }
    func testCreateMoveAndReloadAreRealPersistentChanges() async throws {
        try await withProject { store, root in
            let base = try await store.loadRoadmap()
            let task = RoadmapItem(title: "Build", start: try .init("2026-10-01"), due: try .init("2026-10-03"))
            let candidate = try RoadmapEngine.propose(.create(task), on: base.document)
            let created = try written(try await store.saveRoadmap(base, document: candidate.document))
            let moved = try RoadmapEngine.propose(.move(ids: [task.id], status: .inProgress, before: nil), on: created.document)
            _ = try written(try await store.saveRoadmap(created, document: moved.document))
            await store.close()
            let reopened = try await PlainVaultStore.open(at: root)
            _ = try await reopened.recover()
            let persisted = try await reopened.loadRoadmap()
            XCTAssertEqual(persisted.document.items.first?.status, .inProgress)
            XCTAssertEqual(persisted.document.items.first?.id, task.id)
            await reopened.close()
        }
    }
    func testInvalidCandidateNeverCreatesDestination() async throws {
        try await withProject { store, root in
            let base = try await store.loadRoadmap()
            let bad = RoadmapDocument(items: [.init(title: "", start: try .init("2026-10-10"), due: try .init("2026-10-01"))])
            do { _ = try await store.saveRoadmap(base, document: bad); XCTFail("Invalid dates/title must not be saved") }
            catch PlanningError.invalidChange { }
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".folio/roadmap.json").path))
        }
    }
    func testStaleBasePreservesExternalRoadmap() async throws {
        try await withProject { store, root in
            let empty = try await store.loadRoadmap()
            let initial = RoadmapDocument(items: [.init(title: "First")])
            let saved = try written(try await store.saveRoadmap(empty, document: initial))
            let external = RoadmapDocument(items: [.init(title: "External")])
            let target = root.appendingPathComponent(".folio/roadmap.json")
            let bytes = try RoadmapCodec.encode(external); try bytes.write(to: target)
            let proposed = RoadmapDocument(items: [.init(title: "Local")])
            guard case .conflict(let current, _) = try await store.saveRoadmap(saved, document: proposed) else { return XCTFail() }
            XCTAssertEqual(current.document, external)
            XCTAssertEqual(try Data(contentsOf: target), bytes)
            let report = try await store.recover()
            XCTAssertTrue(report.review.contains { $0.relativePath == ".folio/roadmap.json" })
            XCTAssertEqual(try Data(contentsOf: target), bytes)
        }
    }
    func testRaceAtInstallKeepsTheDisplacedVersion() async throws {
        try await withProject { store, root in
            let empty = try await store.loadRoadmap()
            let saved = try written(try await store.saveRoadmap(empty, document: .init(items: [.init(title: "Base")])) )
            let target = root.appendingPathComponent(".folio/roadmap.json")
            let external = RoadmapDocument(items: [.init(title: "Racing writer")])
            let bytes = try RoadmapCodec.encode(external)
            let result = try await store.saveRoadmap(saved, document: .init(items: [.init(title: "Local")]), hooks: .init {
                if $0 == .beforeInstall { try bytes.write(to: target) }
            })
            guard case .conflict(_, let id) = result else { return XCTFail() }
            let displaced = root.appendingPathComponent(".folio/roadmap-journal/\(id.uuidString)/install.json")
            XCTAssertEqual(try Data(contentsOf: displaced), bytes)
        }
    }
    func testEveryInterruptedBoundaryRecoversIdempotently() async throws {
        for stage in VaultWriteStage.allCases {
            try await withProject { store, root in
                let base = try await store.loadRoadmap()
                let proposal = RoadmapDocument(items: [.init(title: "Recover \(stage.rawValue)")])
                do {
                    _ = try await store.saveRoadmap(base, document: proposal, hooks: .init { if $0 == stage { throw Stop.injected } })
                    XCTFail("Fault not reached")
                } catch Stop.injected { }
                await store.close()
                let next = try await PlainVaultStore.open(at: root)
                _ = try await next.recover()
                let restored = try await next.loadRoadmap()
                XCTAssertEqual(restored.document, proposal)
                let repeated = try await next.recover()
                XCTAssertTrue(repeated.replayed.isEmpty)
                await next.close()
            }
        }
    }
    func testCommittedRecordNeverRollsBackNewerExternalPlan() async throws {
        try await withProject { store, root in
            let base = try await store.loadRoadmap()
            _ = try await store.saveRoadmap(base, document: .init(items: [.init(title: "Saved")]))
            let later = RoadmapDocument(items: [.init(title: "New external work")])
            let bytes = try RoadmapCodec.encode(later)
            try bytes.write(to: root.appendingPathComponent(".folio/roadmap.json"))
            _ = try await store.recover()
            let result = try await store.loadRoadmap()
            XCTAssertEqual(result.document, later)
        }
    }
    func testForkChangesScopeWithoutChangingTaskIDs() async throws {
        try await withProject { store, _ in
            let base = try await store.loadRoadmap()
            let saved = try written(try await store.saveRoadmap(base, document: .init(items: [.init(title: "Task")])) )
            _ = try await store.forkIdentity()
            let fork = try await store.loadRoadmap()
            XCTAssertNotEqual(fork.projectID, saved.projectID)
            XCTAssertEqual(fork.document.items.map(\.id), saved.document.items.map(\.id))
            do { _ = try await store.saveRoadmap(saved, document: .init(items: [])); XCTFail("Old workspace snapshot must be rejected") }
            catch PlanningError.wrongWorkspace { }
        }
    }
    func testUnknownFieldsAreNotSilentlyRewritten() async throws {
        try await withProject { store, root in
            let base = try await store.loadRoadmap()
            _ = try await store.saveRoadmap(base, document: .init(items: [.init(title: "Known")]))
            let path = root.appendingPathComponent(".folio/roadmap.json")
            var object = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as! [String: Any]
            object["future-field"] = true
            let bytes = try JSONSerialization.data(withJSONObject: object); try bytes.write(to: path)
            do { _ = try await store.loadRoadmap(); XCTFail() } catch PlanningError.invalidDocument { }
            XCTAssertEqual(try Data(contentsOf: path), bytes)
        }
    }
    func testRoadmapMetadataDoesNotAppearAsANote() async throws {
        try await withProject { store, _ in
            let base = try await store.loadRoadmap()
            _ = try await store.saveRoadmap(base, document: .init(items: [.init(title: "Task")]))
            let notes = try await store.scan()
            XCTAssertTrue(notes.isEmpty)
        }
    }
    func testPendingRoadmapTransactionBlocksNewWritesUntilRecovery() async throws {
        try await withProject { store, root in
            let base = try await store.loadRoadmap()
            do {
                _ = try await store.saveRoadmap(base, document: .init(items: [.init(title: "Pending")]), hooks: .init { if $0 == .journalSealed { throw Stop.injected } })
                XCTFail("Expected interruption")
            } catch Stop.injected { }
            await store.close()
            let next = try await PlainVaultStore.open(at: root)
            do { _ = try await next.createNote(title: "Must wait", folder: "Notes"); XCTFail("Recovery must run first") }
            catch VaultError.recoveryRequired { }
            _ = try await next.recover()
            let recovered = try await next.loadRoadmap()
            XCTAssertEqual(recovered.document.items.first?.title, "Pending")
            await next.close()
        }
    }

}
