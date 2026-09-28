import Foundation
import Observation
import FolioCore

@MainActor
@Observable
final class GraphController {
    var catalogue: KnowledgeGraph?
    var logical: GraphNeighbourhood?
    var projection: GraphProjection?
    var positions: [GraphEntityID: GraphPoint3] = [:]
    var focus: GraphEntityID?
    var selected: GraphEntityID?
    var expanded = Set<GraphEntityID>()
    var camera = GraphCamera()
    var hops = 1
    var showList = false
    var listFilter = ""
    var isBuilding = false
    var processed = 0
    var total = 0
    var failure: String?
    var notice: String?
    var budget = GraphBudget()
    @ObservationIgnored private var store: PlainVaultStore?
    @ObservationIgnored private var notes: [VaultNote] = []
    @ObservationIgnored private var input: [UUID: GraphNoteInput] = [:]
    @ObservationIgnored private var roadmap = RoadmapDocument.empty
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var buildGeneration = UUID()
    @ObservationIgnored private var projectionGeneration = UUID()
    @ObservationIgnored private var buildTask: Task<Void, Never>?
    @ObservationIgnored private var projectionTask: Task<Void, Never>?
    @ObservationIgnored private var hasScanned = false
    @ObservationIgnored private var noteVersions: [UUID: UUID] = [:]

    var selectedNode: GraphNode? {
        guard let selected else { return nil }
        return projection?.nodes.first { $0.id == selected } ?? catalogue?.nodes[selected]
    }
    var listNodes: [GraphNode] {
        let values = logical?.nodes ?? []
        return listFilter.isEmpty ? values : values.filter { ($0.title + " " + $0.group).localizedStandardContains(listFilter) }
    }
    var selectedConnections: [GraphEdge] {
        guard let selected else { return [] }
        return (logical?.edges ?? []).filter { $0.from == selected || $0.to == selected }
    }
    func configure(store: PlainVaultStore, notes: [VaultNote], roadmap: RoadmapDocument) {
        buildTask?.cancel(); projectionTask?.cancel()
        generation = UUID(); buildGeneration = UUID(); projectionGeneration = UUID()
        self.store = store; self.notes = notes; self.roadmap = roadmap
        input = [:]; noteVersions = [:]; catalogue = nil; logical = nil; projection = nil; positions = [:]
        hasScanned = false; isBuilding = false; failure = nil; notice = nil
        focus = notes.first.map { .note($0.id) } ?? roadmap.items.first.map { .task($0.id) }
        selected = focus; camera = .init(); hops = 1; showList = false; expanded = []
        adaptBudget()
    }
    func setRoadmap(_ value: RoadmapDocument) {
        guard value != roadmap else { return }
        roadmap = value
        if focus == nil { focus = value.items.first.map { .task($0.id) } }
        if hasScanned { buildCatalogue() }
    }
    func reconcileNotes(_ latest: [VaultNote]) {
        let old = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, $0) })
        notes = latest
        let ids = Set(latest.map(\.id))
        input = input.filter { ids.contains($0.key) }
        guard hasScanned || isBuilding else { return }
        for note in latest where old[note.id] != note { refreshNote(note.id) }
        buildCatalogue()
    }
    func refreshNote(_ id: UUID) {
        guard hasScanned || isBuilding, let store else { return }
        let token = generation, lease = UUID()
        noteVersions[id] = lease
        Task { @MainActor [weak self] in
            do {
                let snapshot = try await store.readNote(id: id)
                let parsed = await Task.detached(priority: .utility) { GraphNoteInput(snapshot: snapshot) }.value
                guard let self, token == self.generation, self.noteVersions[id] == lease else { return }
                self.input[id] = parsed; self.buildCatalogue()
            } catch {
                guard let self, token == self.generation else { return }
                self.notice = "Some note links need a graph rebuild."
            }
        }
    }
    func buildIfNeeded() { if !hasScanned && !isBuilding { rebuild() } else { adaptBudget() } }
    func rebuild() {
        guard let store else { return }
        buildTask?.cancel()
        let token = generation, job = UUID(); buildGeneration = job
        let source = notes
        isBuilding = true; processed = 0; total = source.count; failure = nil
        buildTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var parsed: [UUID: GraphNoteInput] = [:], scannedBytes: UInt64 = 0
            var leases: [UUID: UUID] = [:]
            do {
                for note in source {
                    try Task.checkCancellation()
                    guard token == self.generation, job == self.buildGeneration else { return }
                    let lease = UUID(); self.noteVersions[note.id] = lease; leases[note.id] = lease
                    if note.byteCount > 512 * 1024 || scannedBytes + note.byteCount > 64 * 1024 * 1024 {
                        parsed[note.id] = .init(id: note.id, title: note.title, path: note.relativePath, targets: [], omittedBody: true)
                    } else {
                        do {
                            let snapshot = try await store.readNote(id: note.id)
                            scannedBytes += UInt64(snapshot.bytes.count)
                            parsed[note.id] = await Task.detached(priority: .utility) { GraphNoteInput(snapshot: snapshot) }.value
                        } catch {
                            parsed[note.id] = .init(id: note.id, title: note.title, path: note.relativePath, targets: [], omittedBody: true)
                        }
                    }
                    self.processed += 1
                    if self.processed % 16 == 0 { await Task.yield() }
                }
                guard token == self.generation, job == self.buildGeneration else { return }
                for (id, current) in self.input where self.noteVersions[id] != leases[id] { parsed[id] = current }
                self.input = parsed; self.hasScanned = true; self.isBuilding = false
                self.buildCatalogue()
            } catch {
                guard token == self.generation, job == self.buildGeneration else { return }
                self.isBuilding = false
                if !(error is CancellationError) { self.failure = error.localizedDescription }
            }
        }
    }
    private func buildCatalogue() {
        let token = generation, job = UUID(); projectionGeneration = job
        let records = notes.map { note in
            input[note.id] ?? GraphNoteInput(id: note.id, title: note.title, path: note.relativePath, targets: [], omittedBody: true)
        }
        let plan = roadmap
        projectionTask?.cancel()
        projectionTask = Task { @MainActor [weak self] in
            let graph = await Task.detached(priority: .utility) { KnowledgeGraph(notes: records, roadmap: plan) }.value
            guard let self, token == self.generation, job == self.projectionGeneration, !Task.isCancelled else { return }
            self.catalogue = graph
            if self.focus == nil || graph.nodes[self.focus!] == nil {
                self.focus = graph.nodes.keys.sorted().first; self.selected = self.focus
            }
            self.project()
        }
    }
    func project() {
        guard let catalogue, let focus else { projection = nil; logical = nil; positions = [:]; return }
        let depth = hops, budget = budget, expanded = expanded
        let token = generation, job = UUID(); projectionGeneration = job
        projectionTask?.cancel()
        projectionTask = Task { @MainActor [weak self] in
            let output = await Task.detached(priority: .utility) {
                let neighbourhood = catalogue.neighbourhood(around: focus, hops: depth)
                let projected = GraphProjection.make(neighbourhood, budget: budget, expanded: expanded)
                return (neighbourhood, projected, GraphLayout.positions(for: projected))
            }.value
            guard let self, token == self.generation, job == self.projectionGeneration, !Task.isCancelled else { return }
            self.logical = output.0; self.projection = output.1; self.positions = output.2
        }
    }
    func inspect(_ id: GraphEntityID) { selected = id }
    func focusHere(_ id: GraphEntityID) {
        guard catalogue?.nodes[id] != nil else { return }
        focus = id; selected = id; camera = .init(); expanded = []; project()
    }
    func expandSelectedCluster() {
        guard let node = selectedNode, node.kind == .cluster else { return }
        expanded.insert(node.id); project()
    }
    func resetClusters() { expanded = []; project() }
    func setHops(_ value: Int) { hops = min(2, max(1, value)); expanded = []; project() }
    func adaptBudget() {
        let info = ProcessInfo.processInfo
        let next = GraphBudget.adaptive(memoryBytes: info.physicalMemory,
            lowPower: info.isLowPowerModeEnabled, thermalConstrained: info.thermalState == .serious || info.thermalState == .critical)
        if budget != next { budget = next; project() }
    }
    func resetCamera() { let mode = camera.threeDimensional; camera = .init(); camera.threeDimensional = mode }
}
