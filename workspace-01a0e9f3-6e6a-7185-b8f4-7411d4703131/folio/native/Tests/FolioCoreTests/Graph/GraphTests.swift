import XCTest
import Foundation
@testable import FolioCore

final class GraphTests: XCTestCase {
    private func note(_ title: String, targets: [String] = [], folder: String = "Notes") -> GraphNoteInput {
        .init(id: UUID(), title: title, path: folder + "/" + title + ".md", targets: targets)
    }
    func testDefaultNeighbourhoodIsExactlyOneHop() {
        let a = note("A", targets: ["B"]), b = note("B", targets: ["C"]), c = note("C")
        let graph = KnowledgeGraph(notes: [a,b,c], roadmap: .empty)
        let one = graph.neighbourhood(around: .note(a.id))
        XCTAssertEqual(Set(one.nodes.map(\.id)), [.note(a.id), .note(b.id)])
        XCTAssertEqual(graph.neighbourhood(around: .note(a.id), hops: 2).nodes.count, 3)
    }
    func testTaskLinksAndDependenciesShareCanonicalIdentities() {
        let n = note("Design")
        let a = RoadmapItem(title: "Build", linkedNoteIDs: [n.id]), b = RoadmapItem(title: "Ship")
        let roadmap = RoadmapDocument(items: [a,b], dependencies: [.init(predecessor: a.id, successor: b.id)])
        let graph = KnowledgeGraph(notes: [n], roadmap: roadmap)
        let view = graph.neighbourhood(around: .task(a.id))
        XCTAssertEqual(Set(view.nodes.map(\.id)), [.task(a.id), .task(b.id), .note(n.id)])
        XCTAssertEqual(Set(view.edges.map(\.kind)), [.taskNote, .dependency])
    }
    func testAmbiguousTitlesDoNotCreateGuessedEdges() {
        let a = note("A", targets: ["Duplicate"]), b = note("Duplicate", folder: "One"), c = note("Duplicate", folder: "Two")
        let graph = KnowledgeGraph(notes: [a,b,c], roadmap: .empty)
        XCTAssertTrue(graph.edges.isEmpty); XCTAssertEqual(graph.unresolvedLinks, 1)
    }
    func testExplicitRelativePathResolvesWithinProjectOnly() {
        let a = note("A", targets: ["B.md", "../outside.md"]), b = note("B")
        let graph = KnowledgeGraph(notes: [a,b], roadmap: .empty)
        XCTAssertEqual(graph.edges.count, 1); XCTAssertEqual(graph.unresolvedLinks, 1)
    }
    func testDeletedLinkedNoteIsVisibleAsMissingNotOpened() {
        let absent = UUID(), task = RoadmapItem(title: "Task", linkedNoteIDs: [])
        var linked = task; linked.linkedNoteIDs = [absent]
        let graph = KnowledgeGraph(notes: [], roadmap: .init(items: [linked]))
        XCTAssertEqual(graph.nodes[.note(absent)]?.isMissing, true)
        XCTAssertEqual(graph.neighbourhood(around: .task(task.id)).nodes.count, 2)
    }
    func testCodeHTMLAndImagesDoNotInventNoteRelations() {
        let source = "[[Real]]\n\n```md\n[[Code]]\n```\n\n<div>[[HTML]]</div>\n\n![Image](Hidden.md)\n"
        let result = GraphLinkExtractor.targets(in: source)
        XCTAssertEqual(result.targets, ["Real"]); XCTAssertFalse(result.omitted)
    }
    func testOversizedBodiesHaveExplicitOmission() {
        let result = GraphLinkExtractor.targets(in: String(repeating: "x", count: 600_000))
        XCTAssertTrue(result.omitted); XCTAssertTrue(result.targets.isEmpty)
    }
    func testClustersRespectBudgetAndRepresentEveryNeighbour() {
        let neighbours = (0..<150).map { note("N\($0)", folder: "Folder\($0 % 20)") }
        let centre = note("Hub", targets: neighbours.map { $0.path })
        let graph = KnowledgeGraph(notes: [centre] + neighbours, roadmap: .empty)
        let neighbourhood = graph.neighbourhood(around: .note(centre.id))
        let projected = GraphProjection.make(neighbourhood, budget: .init(nodes: 8, edges: 16))
        XCTAssertLessThanOrEqual(projected.nodes.count, 8)
        XCTAssertLessThanOrEqual(projected.edges.count, 16)
        let represented = Set(projected.nodes.flatMap { $0.kind == .cluster ? $0.members : [$0.id] })
        XCTAssertEqual(represented, Set(neighbourhood.nodes.map(\.id)))
        XCTAssertEqual(projected.omittedNodes, 150)
    }
    func testClusterExpansionNeverDeletesLogicalData() {
        let linked = (0..<50).map { note("N\($0)") }
        let hub = note("Hub", targets: linked.map(\.title))
        let graph = KnowledgeGraph(notes: [hub]+linked, roadmap: .empty)
        let logical = graph.neighbourhood(around: .note(hub.id))
        let collapsed = GraphProjection.make(logical, budget: .init(nodes: 20, edges: 100))
        let cluster = collapsed.nodes.first { $0.kind == .cluster }!
        let expanded = GraphProjection.make(logical, budget: .init(nodes: 20, edges: 100), expanded: [cluster.id])
        XCTAssertGreaterThan(expanded.nodes.filter { $0.kind != .cluster }.count, 1)
        XCTAssertLessThanOrEqual(expanded.nodes.count, 20)
        XCTAssertEqual(logical.nodes.count, 51)
    }
    func testDeterministicLayoutAndCameraNeverRequireIdleSimulation() {
        let a = note("A", targets: ["B"]), b = note("B")
        let graph = KnowledgeGraph(notes: [a,b], roadmap: .empty)
        let projection = GraphProjection.make(graph.neighbourhood(around: .note(a.id)), budget: .init())
        XCTAssertEqual(GraphLayout.positions(for: projection), GraphLayout.positions(for: projection))
        var camera = GraphCamera(); XCTAssertFalse(camera.threeDimensional)
        let flat = camera.project(.init(x: 0.5, y: 0, z: 0.5), width: 800, height: 600)
        camera.threeDimensional = true; camera.yaw = 0.8
        XCTAssertNotEqual(flat, camera.project(.init(x: 0.5, y: 0, z: 0.5), width: 800, height: 600))
    }
    func testCameraSanitisesInvalidValuesAndSupportsPicking() {
        var camera = GraphCamera(); camera.zoom = .nan; camera.panX = .infinity; camera.pitch = -.infinity; camera.sanitise()
        XCTAssertEqual(camera.zoom, 1); XCTAssertEqual(camera.panX, 0); XCTAssertEqual(camera.pitch, 0)
        let id = GraphEntityID.note(UUID())
        XCTAssertEqual(camera.hitTest(x: 400, y: 300, positions: [id: .init(x: 0, y: 0)], width: 800, height: 600), id)
        XCTAssertNil(camera.hitTest(x: .nan, y: 300, positions: [id: .init(x: 0,y: 0)], width: 800, height: 600))
    }
    func testPowerAndThermalBudgetsReduceRenderedWork() {
        let full = GraphBudget.adaptive(memoryBytes: 32 * 1024 * 1024 * 1024, lowPower: false, thermalConstrained: false)
        let low = GraphBudget.adaptive(memoryBytes: 32 * 1024 * 1024 * 1024, lowPower: true, thermalConstrained: false)
        XCTAssertLessThan(low.nodes, full.nodes); XCTAssertLessThan(low.edges, full.edges)
    }
}
