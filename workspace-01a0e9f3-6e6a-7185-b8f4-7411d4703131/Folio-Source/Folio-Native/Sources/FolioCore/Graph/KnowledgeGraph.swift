import Foundation

public struct GraphEntityID: RawRepresentable, Hashable, Codable, Sendable, Comparable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static func note(_ id: UUID) -> Self { .init(rawValue: "note:" + id.uuidString) }
    public static func task(_ id: UUID) -> Self { .init(rawValue: "task:" + id.uuidString) }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    public var underlyingUUID: UUID? { rawValue.split(separator: ":", maxSplits: 1).last.flatMap { UUID(uuidString: String($0)) } }
}
public enum GraphNodeKind: String, Codable, Sendable { case note, task, cluster }
public struct GraphNode: Identifiable, Equatable, Sendable {
    public let id: GraphEntityID
    public let title: String
    public let kind: GraphNodeKind
    public let group: String
    public let isMissing: Bool
    public let members: [GraphEntityID]
    public init(id: GraphEntityID, title: String, kind: GraphNodeKind, group: String, isMissing: Bool = false, members: [GraphEntityID] = []) {
        self.id = id; self.title = title; self.kind = kind; self.group = group; self.isMissing = isMissing; self.members = members
    }
}
public enum GraphRelation: String, Codable, Sendable { case noteLink, taskNote, dependency }
public struct GraphEdge: Hashable, Sendable, Identifiable {
    public let from: GraphEntityID
    public let to: GraphEntityID
    public let kind: GraphRelation
    public let count: Int
    public var id: String { from.rawValue + ">" + kind.rawValue + ">" + to.rawValue }
    public init(from: GraphEntityID, to: GraphEntityID, kind: GraphRelation, count: Int = 1) {
        self.from = from; self.to = to; self.kind = kind; self.count = count
    }
}
public struct GraphNoteInput: Sendable {
    public let id: UUID
    public let title: String
    public let path: String
    public let targets: [String]
    public let omittedBody: Bool
    public init(id: UUID, title: String, path: String, targets: [String], omittedBody: Bool = false) {
        self.id = id; self.title = title; self.path = path; self.targets = targets; self.omittedBody = omittedBody
    }
    public init(snapshot: VaultSnapshot) {
        id = snapshot.note.id; title = snapshot.note.title; path = snapshot.note.relativePath
        let extraction = GraphLinkExtractor.targets(in: snapshot.markdown)
        targets = extraction.targets; omittedBody = extraction.omitted
    }
}
public enum GraphLinkExtractor {
    public static func targets(in markdown: String) -> (targets: [String], omitted: Bool) {
        let parsed = MarkdownParser.parse(markdown)
        if parsed.isLimited { return ([], true) }
        var targets = Set<String>()
        func visit(_ nodes: [MarkdownInline]) {
            for node in nodes {
                switch node {
                case .link(_, .note(let target)): targets.insert(target)
                case .strong(let inner), .emphasis(let inner), .strike(let inner): visit(inner)
                default: break
                }
            }
        }
        for block in parsed.blocks {
            switch block.kind {
            case .heading(_, let text), .paragraph(let text), .quote(let text), .listItem(_, _, _, let text): visit(text)
            case .table(let headings, let rows, _): for cell in headings { visit(cell) }; for row in rows { for cell in row { visit(cell) } }
            default: break // code, HTML, metadata and images never create authored links
            }
        }
        return (targets.sorted(), false)
    }
}

public struct KnowledgeGraph: Sendable {
    public let nodes: [GraphEntityID: GraphNode]
    public let edges: [GraphEdge]
    public let unresolvedLinks: Int
    public let omittedNoteBodies: Int
    private let neighbours: [GraphEntityID: Set<GraphEntityID>]

    public init(notes: [GraphNoteInput], roadmap: RoadmapDocument) {
        var nodes: [GraphEntityID: GraphNode] = [:], edges = Set<GraphEdge>()
        var titleMap: [String: [UUID]] = [:], pathMap: [String: [UUID]] = [:]
        func stripped(_ path: String) -> String {
            path.replacingOccurrences(of: #"\.(md|markdown)$"#, with: "", options: [.regularExpression, .caseInsensitive])
        }
        for note in notes {
            let id = GraphEntityID.note(note.id)
            let folder = (note.path as NSString).deletingLastPathComponent
            nodes[id] = .init(id: id, title: note.title, kind: .note, group: folder.isEmpty ? "Notes" : folder)
            titleMap[NoteSearchQuery.fold(note.title), default: []].append(note.id)
            pathMap[NoteSearchQuery.fold(stripped(note.path)), default: []].append(note.id)
        }
        var unresolved = 0
        for note in notes {
            let source = GraphEntityID.note(note.id)
            for raw in note.targets {
                let target = raw.components(separatedBy: "#")[0].trimmingCharacters(in: .whitespacesAndNewlines)
                guard case .note = MarkdownLinkPolicy.classify(target) else { unresolved += 1; continue }
                let name = stripped(target)
                let folder = (note.path as NSString).deletingLastPathComponent
                let explicit = name.contains("/") || name != target
                let matches: Set<UUID>
                if explicit {
                    let local = folder.isEmpty ? name : folder + "/" + name
                    matches = Set((pathMap[NoteSearchQuery.fold(name)] ?? []) + (pathMap[NoteSearchQuery.fold(local)] ?? []))
                } else { matches = Set(titleMap[NoteSearchQuery.fold(name)] ?? []) }
                if matches.count == 1, let id = matches.first {
                    let destination = GraphEntityID.note(id)
                    if source != destination { edges.insert(.init(from: source, to: destination, kind: .noteLink)) }
                } else { unresolved += 1 }
            }
        }
        for item in roadmap.items {
            let id = GraphEntityID.task(item.id)
            nodes[id] = .init(id: id, title: item.title, kind: .task, group: "Roadmap · " + item.status.title)
            for noteID in item.linkedNoteIDs {
                let target = GraphEntityID.note(noteID)
                if nodes[target] == nil { nodes[target] = .init(id: target, title: "Missing linked note", kind: .note, group: "Unresolved links", isMissing: true) }
                edges.insert(.init(from: id, to: target, kind: .taskNote))
            }
        }
        for dependency in roadmap.dependencies {
            let from = GraphEntityID.task(dependency.predecessor), to = GraphEntityID.task(dependency.successor)
            if nodes[from] != nil && nodes[to] != nil { edges.insert(.init(from: from, to: to, kind: .dependency)) }
            else { unresolved += 1 }
        }
        var adjacency: [GraphEntityID: Set<GraphEntityID>] = [:]
        for edge in edges { adjacency[edge.from, default: []].insert(edge.to); adjacency[edge.to, default: []].insert(edge.from) }
        self.nodes = nodes; self.edges = edges.sorted { $0.id < $1.id }; self.neighbours = adjacency
        unresolvedLinks = unresolved; omittedNoteBodies = notes.filter(\.omittedBody).count
    }
    public func neighbourhood(around focus: GraphEntityID, hops: Int = 1) -> GraphNeighbourhood {
        guard nodes[focus] != nil else { return .init(focus: focus, nodes: [], edges: [], distances: [:]) }
        let depth = min(2, max(1, hops))
        var distance: [GraphEntityID: Int] = [focus: 0], frontier = [focus]
        for hop in 1...depth {
            var next: [GraphEntityID] = []
            for id in frontier {
                for neighbour in (neighbours[id] ?? []).sorted() where distance[neighbour] == nil {
                    distance[neighbour] = hop; next.append(neighbour)
                }
            }
            frontier = next
        }
        let included = Set(distance.keys)
        return .init(focus: focus, nodes: included.sorted().compactMap { nodes[$0] },
                     edges: edges.filter { included.contains($0.from) && included.contains($0.to) }, distances: distance)
    }
}

public struct GraphNeighbourhood: Sendable {
    public let focus: GraphEntityID
    public let nodes: [GraphNode]
    public let edges: [GraphEdge]
    public let distances: [GraphEntityID: Int]
}
public struct GraphBudget: Equatable, Sendable {
    public let nodes: Int
    public let edges: Int
    public init(nodes: Int = 200, edges: Int = 800) { self.nodes = min(2000, max(8, nodes)); self.edges = min(8000, max(16, edges)) }
    public static func adaptive(memoryBytes: UInt64, lowPower: Bool, thermalConstrained: Bool) -> Self {
        if lowPower || thermalConstrained { return .init(nodes: 80, edges: 240) }
        return memoryBytes >= 16 * 1024 * 1024 * 1024 ? .init(nodes: 400, edges: 1600) : .init()
    }
}
public struct GraphProjection: Sendable {
    public let focus: GraphEntityID
    public let nodes: [GraphNode]
    public let edges: [GraphEdge]
    public let omittedNodes: Int
    public let omittedEdges: Int
    public static func make(_ input: GraphNeighbourhood, budget: GraphBudget, expanded: Set<GraphEntityID> = []) -> Self {
        var visible: [GraphNode] = [], mapping: [GraphEntityID: GraphEntityID] = [:]
        if input.nodes.count <= budget.nodes {
            visible = input.nodes; for node in visible { mapping[node.id] = node.id }
        } else {
            if let focus = input.nodes.first(where: { $0.id == input.focus }) { visible.append(focus); mapping[focus.id] = focus.id }
            var groups = Dictionary(grouping: input.nodes.filter { $0.id != input.focus }, by: \.group).map { ($0.key, $0.value.sorted { $0.id < $1.id }) }
            groups.sort { $0.1.count == $1.1.count ? $0.0 < $1.0 : $0.1.count > $1.1.count }
            let maximumGroups = min(8, budget.nodes - 1)
            if groups.count > maximumGroups {
                let keep = maximumGroups - 1
                let tail = groups.dropFirst(keep).flatMap(\.1).sorted { $0.id < $1.id }
                groups = Array(groups.prefix(keep)) + [("Other connections", tail)]
            }
            for (index, group) in groups.enumerated() {
                let clusterID = GraphEntityID(rawValue: "cluster:" + String(ContentDigest.sha256(Data((input.focus.rawValue + ":" + group.0).utf8)).prefix(24)))
                let reserved = groups.count - index - 1
                let room = max(0, budget.nodes - visible.count - reserved)
                let show = expanded.contains(clusterID) ? max(0, min(group.1.count, room - (room < group.1.count ? 1 : 0))) : 0
                for node in group.1.prefix(show) { visible.append(node); mapping[node.id] = node.id }
                let rest = Array(group.1.dropFirst(show))
                if !rest.isEmpty {
                    visible.append(.init(id: clusterID, title: group.0 + " · \(rest.count)", kind: .cluster, group: group.0, members: rest.map(\.id)))
                    for node in rest { mapping[node.id] = clusterID }
                }
            }
        }
        var aggregated: [String: GraphEdge] = [:]
        var internalEdges = 0
        for edge in input.edges {
            guard let from = mapping[edge.from], let to = mapping[edge.to] else { continue }
            if from == to { internalEdges += 1; continue }
            let key = from.rawValue + ">" + edge.kind.rawValue + ">" + to.rawValue
            let count = (aggregated[key]?.count ?? 0) + edge.count
            aggregated[key] = .init(from: from, to: to, kind: edge.kind, count: count)
        }
        let allEdges = aggregated.values.sorted { $0.id < $1.id }
        return .init(focus: input.focus, nodes: visible, edges: Array(allEdges.prefix(budget.edges)),
                     omittedNodes: input.nodes.count - visible.filter { $0.kind != .cluster }.count,
                     omittedEdges: internalEdges + max(0, allEdges.count - budget.edges))
    }
}
