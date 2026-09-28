import Foundation

public enum RoadmapEngine {
    public static func validateStructure(_ document: RoadmapDocument) throws {
        guard document.version == 1 else { throw PlanningError.unsupportedVersion }
        guard document.items.count <= 10_000, document.dependencies.count <= 50_000 else { throw PlanningError.tooLarge }
        guard Set(document.items.map(\.id)).count == document.items.count,
              Set(document.dependencies.map(\.id)).count == document.dependencies.count else { throw PlanningError.duplicateIdentity }
        for item in document.items {
            guard item.title.utf8.count <= 512, item.detail.utf8.count <= 64 * 1024,
                  item.title.rangeOfCharacter(from: .controlCharacters) == nil,
                  item.linkedNoteIDs.count <= 512,
                  Set(item.linkedNoteIDs).count == item.linkedNoteIDs.count else { throw PlanningError.invalidDocument }
        }
    }
    public static func issues(in document: RoadmapDocument) -> [PlanningIssue] {
        var result: [PlanningIssue] = []
        let items = Dictionary(document.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for item in document.items {
            if item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result.append(.title(item.id)) }
            if let start = item.start, let due = item.due, start > due { result.append(.reversedDates(item.id)) }
            if item.kind == .milestone, let start = item.start, let due = item.due, start != due { result.append(.invalidMilestone(item.id)) }
        }
        var pairs = Set<String>()
        var adjacency: [UUID: [UUID]] = [:]
        for edge in document.dependencies {
            guard let predecessor = items[edge.predecessor], let successor = items[edge.successor] else {
                result.append(.missingEndpoint(edge.id)); continue
            }
            if edge.predecessor == edge.successor { result.append(.selfDependency(edge.id)); continue }
            let pair = edge.predecessor.uuidString + "/" + edge.successor.uuidString
            if !pairs.insert(pair).inserted { result.append(.duplicateDependency(edge.id)); continue }
            adjacency[edge.predecessor, default: []].append(edge.successor)
            if let finish = predecessor.due, let start = successor.start, start < finish {
                result.append(.dateConflict(edge: edge.id, predecessor: predecessor.id, successor: successor.id, minimumStart: finish))
            }
        }
        if let path = cycle(in: adjacency, order: document.items.map(\.id)) { result.append(.cycle(path)) }
        return result
    }
    public static func propose(_ edit: RoadmapEdit, on original: RoadmapDocument) throws -> RoadmapProposal {
        try validateStructure(original)
        var candidate = original
        try apply(edit, to: &candidate, depth: 0)
        candidate.revision = UUID()
        try validateStructure(candidate)
        return .init(expectedRevision: original.revision, document: candidate, issues: issues(in: candidate))
    }
    public static func repaired(_ proposal: RoadmapProposal, with repair: RoadmapRepair) throws -> RoadmapProposal {
        var candidate = proposal.document
        switch repair {
        case .removeDependency(let id):
            candidate.dependencies.removeAll { $0.id == id }
        case .startNoEarlier(let id, let day):
            guard let index = candidate.items.firstIndex(where: { $0.id == id }) else { throw PlanningError.missingItem }
            let item = candidate.items[index]
            if let start = item.start {
                let delta = max(0, start.distance(to: day))
                candidate.items[index].start = try start.adding(days: delta)
                if let due = item.due { candidate.items[index].due = try due.adding(days: delta) }
            } else { candidate.items[index].start = day }
        case .swapDates(let id):
            guard let index = candidate.items.firstIndex(where: { $0.id == id }) else { throw PlanningError.missingItem }
            let start = candidate.items[index].start
            candidate.items[index].start = candidate.items[index].due; candidate.items[index].due = start
        case .collapseMilestone(let id):
            guard let index = candidate.items.firstIndex(where: { $0.id == id }) else { throw PlanningError.missingItem }
            let day = candidate.items[index].due ?? candidate.items[index].start
            candidate.items[index].start = day; candidate.items[index].due = day
        }
        candidate.revision = UUID(); try validateStructure(candidate)
        return .init(expectedRevision: proposal.expectedRevision, document: candidate, issues: issues(in: candidate))
    }
    public static func repairs(for issue: PlanningIssue, in proposal: RoadmapProposal) -> [RoadmapRepair] {
        switch issue {
        case .dateConflict(_, _, let successor, let day): return [.startNoEarlier(item: successor, day: day)]
        case .reversedDates(let id): return [.swapDates(id)]
        case .invalidMilestone(let id): return [.collapseMilestone(id)]
        case .missingEndpoint(let id), .selfDependency(let id), .duplicateDependency(let id): return [.removeDependency(id)]
        case .cycle(let ids):
            let set = Set(ids)
            return proposal.document.dependencies.filter { set.contains($0.predecessor) && set.contains($0.successor) }.map { .removeDependency($0.id) }
        case .title: return []
        }
    }
    private static func apply(_ edit: RoadmapEdit, to document: inout RoadmapDocument, depth: Int) throws {
        guard depth <= 8 else { throw PlanningError.invalidSelection }
        switch edit {
        case .create(let item):
            guard !document.items.contains(where: { $0.id == item.id }) else { throw PlanningError.duplicateIdentity }
            document.items.append(item)
        case .update(let item):
            guard let index = document.items.firstIndex(where: { $0.id == item.id }) else { throw PlanningError.missingItem }
            document.items[index] = item
        case .delete(let ids):
            let selected = try selection(ids, in: document)
            document.items.removeAll { selected.contains($0.id) }
            document.dependencies.removeAll { selected.contains($0.predecessor) || selected.contains($0.successor) }
        case .move(let ids, let status, let before):
            let selected = try selection(ids, in: document)
            if let before {
                guard !selected.contains(before), document.items.contains(where: { $0.id == before && $0.status == status }) else { throw PlanningError.invalidSelection }
            }
            var moved = document.items.filter { selected.contains($0.id) }
            for index in moved.indices { moved[index].status = status }
            document.items.removeAll { selected.contains($0.id) }
            if let before, let position = document.items.firstIndex(where: { $0.id == before }) {
                document.items.insert(contentsOf: moved, at: position)
            } else { document.items.append(contentsOf: moved) }
        case .shiftDates(let ids, let days):
            let selected = try selection(ids, in: document)
            guard (-36_500...36_500).contains(days) else { throw PlanningError.invalidDate }
            for index in document.items.indices where selected.contains(document.items[index].id) {
                if let start = document.items[index].start { document.items[index].start = try start.adding(days: days) }
                if let due = document.items[index].due { document.items[index].due = try due.adding(days: days) }
            }
        case .addDependency(let edge):
            guard !document.dependencies.contains(where: { $0.id == edge.id }) else { throw PlanningError.duplicateIdentity }
            document.dependencies.append(edge)
        case .removeDependency(let id):
            guard document.dependencies.contains(where: { $0.id == id }) else { throw PlanningError.missingItem }
            document.dependencies.removeAll { $0.id == id }
        case .batch(let edits):
            guard edits.count <= 1000 else { throw PlanningError.tooLarge }
            for child in edits { try apply(child, to: &document, depth: depth + 1) }
        }
    }
    private static func selection(_ ids: [UUID], in document: RoadmapDocument) throws -> Set<UUID> {
        let selected = Set(ids)
        guard !selected.isEmpty, selected.count == ids.count,
              selected.isSubset(of: Set(document.items.map(\.id))) else { throw PlanningError.invalidSelection }
        return selected
    }
    /// Iterative DFS: a long dependency chain cannot overflow the call stack.
    private static func cycle(in adjacency: [UUID: [UUID]], order: [UUID]) -> [UUID]? {
        var colour: [UUID: Int] = [:]
        for start in order where colour[start] == nil {
            var stack: [(UUID, Int)] = [(start, 0)], active: [UUID: Int] = [start: 0]
            colour[start] = 1
            while let (node, next) = stack.last {
                let neighbours = adjacency[node] ?? []
                if next == neighbours.count {
                    colour[node] = 2; active.removeValue(forKey: node); stack.removeLast(); continue
                }
                stack[stack.count - 1].1 += 1
                let target = neighbours[next]
                if colour[target] == 1, let index = active[target] { return stack[index...].map(\.0) }
                if colour[target] == nil {
                    colour[target] = 1; active[target] = stack.count; stack.append((target, 0))
                }
            }
        }
        return nil
    }
}

/// Session undo/redo; new revisions prevent a content undo from reusing an old
/// write token. External reloads must reset history, never overwrite newer work.
public struct RoadmapHistory: Sendable {
    private struct Entry: Sendable { let document: RoadmapDocument; let bytes: Int }
    private var undoStack: [Entry] = [], redoStack: [Entry] = []
    private var head: UUID?
    private var headDigest: String?
    public init() {}
    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public mutating func record(before: RoadmapDocument, after: RoadmapDocument) throws {
        let encodedBefore = try RoadmapCodec.encode(before)
        let digestBefore = ContentDigest.sha256(encodedBefore)
        if let head, head != before.revision || headDigest != digestBefore { throw PlanningError.staleRevision }
        undoStack.append(.init(document: before, bytes: encodedBefore.count))
        while undoStack.count > 32 || undoStack.reduce(0, { $0 + $1.bytes }) > 16 * 1024 * 1024 { undoStack.removeFirst() }
        redoStack = []; head = after.revision; headDigest = ContentDigest.sha256(try RoadmapCodec.encode(after))
    }
    public mutating func undo(current: RoadmapDocument) throws -> RoadmapDocument {
        guard current.revision == head, headDigest == ContentDigest.sha256(try RoadmapCodec.encode(current)) else { throw PlanningError.staleRevision }
        guard let previous = undoStack.popLast() else { throw PlanningError.historyEmpty }
        redoStack.append(.init(document: current, bytes: try RoadmapCodec.encode(current).count))
        var restored = previous.document; restored.revision = UUID(); head = restored.revision; headDigest = ContentDigest.sha256(try RoadmapCodec.encode(restored))
        return restored
    }
    public mutating func redo(current: RoadmapDocument) throws -> RoadmapDocument {
        guard current.revision == head, headDigest == ContentDigest.sha256(try RoadmapCodec.encode(current)) else { throw PlanningError.staleRevision }
        guard let next = redoStack.popLast() else { throw PlanningError.historyEmpty }
        undoStack.append(.init(document: current, bytes: try RoadmapCodec.encode(current).count))
        var restored = next.document; restored.revision = UUID(); head = restored.revision; headDigest = ContentDigest.sha256(try RoadmapCodec.encode(restored))
        return restored
    }
}
