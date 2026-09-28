import Foundation
import FolioCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Developer-only integration/crash probe. The scenario uses generated temporary
/// projects. External crash runners must also supply fresh disposable folders.
@main
struct PlanningProbe {
    static func main() async {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            if args.first == "scenario" { try await scenario(report: args.count > 1 ? args[1] : nil); return }
            guard args.count >= 2 else { throw Failure.failed("Use scenario [report] or init/write/recover/read <disposable-folder>") }
            let command = args[0], root = URL(fileURLWithPath: args[1], isDirectory: true)
            let store = try await PlainVaultStore.open(at: root, createIfMissing: command == "init")
            let recovery = try await store.recover()
            if command == "recover" { try emit(["replayed": recovery.replayed, "review": recovery.review.map(\.explanation)]) }
            else if command == "init" { try emit(["status": "initialised"]) }
            else if command == "read" {
                let value = try await store.loadRoadmap()
                try emit(["revision": value.document.revision.uuidString, "titles": value.document.items.map(\.title)])
            } else if command == "write" {
                let base = try await store.loadRoadmap()
                let title = args.count > 2 ? args[2] : "Task"
                var document = base.document
                if document.items.isEmpty { document.items = [.init(title: title)] }
                else { document.items[0].title = title }
                document.revision = UUID()
                let boundary = args.first(where: { $0.hasPrefix("--pause-at=") })?.components(separatedBy: "=").last
                let result = try await store.saveRoadmap(base, document: document, hooks: .init { stage in
                    if stage.rawValue == boundary {
                        FileHandle.standardOutput.write(Data(("PAUSED " + stage.rawValue + "\n").utf8))
                        fflush(nil); while true { _ = pause() }
                    }
                })
                switch result {
                case .written(let snapshot): try emit(["status": "written", "revision": snapshot.document.revision.uuidString])
                case .conflict(_, let id): try emit(["status": "conflict", "recovery": id.uuidString])
                }
            } else { throw Failure.failed("Unknown command") }
            await store.close()
        } catch { FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1) }
    }

    static func scenario(report: String?) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("folio-planning-scenario-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await PlainVaultStore.open(at: root, createIfMissing: true)
        var checks: [String] = []
        let first = try snapshot(try await store.createNote(title: "Launch strategy", folder: "Notes", markdown: "# Launch strategy\n\n[[Security review]]"))
        let second = try snapshot(try await store.createNote(title: "Security review", folder: "Notes", markdown: "# Security review\n"))
        checks.append("Real Markdown notes created with stable identities")
        let foundation = RoadmapItem(title: "Native foundation", status: .inProgress, start: try .init("2026-10-01"), due: try .init("2026-10-10"), linkedNoteIDs: [first.note.id])
        let release = RoadmapItem(title: "Release gate", status: .ready, kind: .milestone, due: try .init("2026-10-20"), linkedNoteIDs: [second.note.id])
        let undated = RoadmapItem(title: "Research next idea")
        let base = try await store.loadRoadmap()
        let proposal = try RoadmapEngine.propose(.batch([
            .create(foundation), .create(release), .create(undated),
            .addDependency(.init(predecessor: foundation.id, successor: release.id))
        ]), on: base.document)
        try require(proposal.mayApply, "Initial proposal")
        let saved = try roadmap(try await store.saveRoadmap(base, document: proposal.document))
        checks.append("Tasks, milestone, note links and dependency committed as one roadmap snapshot")
        let timeline = try TimelineProjection(document: saved.document, start: .init("2026-10-01"), days: 31)
        try require(timeline.rows.count == 2 && timeline.unscheduledIDs == [undated.id], "Timeline and unscheduled projection")
        checks.append("Timeline and Unscheduled tray use the same canonical entities without inventing dates")
        let move = try RoadmapEngine.propose(.move(ids: [foundation.id], status: .done, before: nil), on: saved.document)
        let moved = try roadmap(try await store.saveRoadmap(saved, document: move.document))
        try require(moved.document.items(in: .done).first?.id == foundation.id, "Kanban move")
        checks.append("Kanban status move persists and preserves task identity")
        var history = RoadmapHistory(); try history.record(before: saved.document, after: moved.document)
        let undo = try history.undo(current: moved.document)
        let undone = try roadmap(try await store.saveRoadmap(moved, document: undo))
        try require(undone.document.items.first(where: { $0.id == foundation.id })?.status == .inProgress, "Undo")
        checks.append("Undo is a new persisted revision, not reuse of an old write token")
        let attemptedEdge = RoadmapDependency(predecessor: release.id, successor: foundation.id)
        let bad = try RoadmapEngine.propose(.addDependency(attemptedEdge), on: undone.document)
        try require(!bad.mayApply, "Cycle blocked")
        let cycle = bad.issues.first { if case .cycle = $0 { return true }; return false }!
        let repair = RoadmapEngine.repairs(for: cycle, in: bad).first { option in
            if case .removeDependency(let id) = option { return id == attemptedEdge.id }; return false
        }!
        let fixed = try RoadmapEngine.repaired(bad, with: repair)
        try require(fixed.mayApply, "Guided repair candidate")
        checks.append("Dependency cycle is held as an unapplied proposal with explicit repair choices")
        let originalBytes = try Data(contentsOf: root.appendingPathComponent(first.note.relativePath))
        let graph = KnowledgeGraph(notes: [GraphNoteInput(snapshot: first), GraphNoteInput(snapshot: second)], roadmap: undone.document)
        let neighbour = graph.neighbourhood(around: .task(foundation.id))
        try require(neighbour.nodes.contains(where: { $0.id == .note(first.note.id) }) && neighbour.nodes.contains(where: { $0.id == .task(release.id) }), "Shared graph identities")
        checks.append("Graph unifies task-note links, Markdown relations and planning dependencies")
        let all = graph.neighbourhood(around: .note(first.note.id), hops: 2)
        let projection = GraphProjection.make(all, budget: .init(nodes: 8, edges: 16))
        let positions = GraphLayout.positions(for: projection)
        var camera = GraphCamera()
        let point = positions[projection.focus]!
        let flat = camera.project(point, width: 1000, height: 700)
        try require(camera.hitTest(x: flat.x, y: flat.y, positions: positions, width: 1000, height: 700) == projection.focus, "Graph picking")
        camera.threeDimensional = true; camera.yaw = 0.5
        try require(camera.project(point, width: 1000, height: 700).x.isFinite, "3D camera math")
        checks.append("Deterministic CPU layout, picking and optional 3D projection execute on the same graph")
        try require(try Data(contentsOf: root.appendingPathComponent(first.note.relativePath)) == originalBytes, "No note rewrite")
        checks.append("Roadmap and graph operations do not rewrite the linked Markdown")
        await store.close()
        let reopened = try await PlainVaultStore.open(at: root)
        _ = try await reopened.recover()
        let restored = try await reopened.loadRoadmap()
        try require(restored.document == undone.document, "Reopen roadmap")
        await reopened.close()
        checks.append("Roadmap reopens with its exact task IDs, links, order and revision")
        let object: [String: Any] = [
            "status": "PASS", "platform": ProcessInfo.processInfo.operatingSystemVersionString,
            "check_count": checks.count, "checks": checks,
            "scope": "Generated temporary vault; actual persistent roadmap, projections and graph core",
            "not_proven": ["Mac SwiftUI/AppKit runtime", "Metal shader/pipeline/device execution", "APFS/power-loss durability", "native accessibility/performance", "release security"]
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        if let report { try data.write(to: URL(fileURLWithPath: report)) }
        print(String(decoding: data, as: UTF8.self))
    }
    enum Failure: Error, LocalizedError {
        case failed(String)
        var errorDescription: String? { if case .failed(let message) = self { return message }; return nil }
    }
    static func require(_ condition: Bool, _ message: String) throws { if !condition { throw Failure.failed(message) } }
    static func snapshot(_ result: VaultSaveResult) throws -> VaultSnapshot { if case .written(let value) = result { return value }; throw Failure.failed("Unexpected note conflict") }
    static func roadmap(_ result: RoadmapSaveResult) throws -> RoadmapSnapshot { if case .written(let value) = result { return value }; throw Failure.failed("Unexpected roadmap conflict") }
    static func emit(_ value: [String: Any]) throws { print(String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)) }
}
