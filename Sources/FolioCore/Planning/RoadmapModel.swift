import Foundation

public enum PlanningError: Error, LocalizedError, Sendable {
    case invalidDate, invalidDocument, unsupportedVersion, missingItem, duplicateIdentity, invalidSelection
    case staleRevision, wrongWorkspace, recoveryRequired, tooLarge, historyEmpty
    case invalidChange([PlanningIssue])
    public var errorDescription: String? {
        switch self {
        case .invalidDate: "Use a real Gregorian date in YYYY-MM-DD form."
        case .invalidDocument: "The roadmap data could not be validated. It has not been replaced."
        case .unsupportedVersion: "This roadmap schema is not supported; no automatic migration was attempted."
        case .missingItem: "That roadmap item no longer exists."
        case .duplicateIdentity: "The roadmap contains duplicate identities or relationships."
        case .invalidSelection: "The move/selection is invalid. No items were changed."
        case .staleRevision: "The roadmap changed since this edit began. Reload and review instead of overwriting it."
        case .wrongWorkspace: "This roadmap snapshot belongs to another project session."
        case .recoveryRequired: "The roadmap needs recovery review before another write."
        case .tooLarge: "This roadmap exceeds the current bounded document limits."
        case .historyEmpty: "There is no session change to undo or redo."
        case .invalidChange(let issues): issues.map(\.message).joined(separator: "\n")
        }
    }
}

public enum RoadmapStatus: String, Codable, CaseIterable, Sendable {
    case backlog, ready, inProgress, blocked, done
    public var title: String {
        switch self { case .backlog: "Backlog"; case .ready: "Ready"; case .inProgress: "In progress"; case .blocked: "Blocked"; case .done: "Done" }
    }
}
public enum RoadmapItemKind: String, Codable, CaseIterable, Sendable { case task, milestone }

public struct RoadmapItem: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var title: String
    public var detail: String
    public var status: RoadmapStatus
    public var kind: RoadmapItemKind
    public var start: CivilDay?
    public var due: CivilDay?
    public var linkedNoteIDs: [UUID]
    public init(id: UUID = UUID(), title: String, detail: String = "", status: RoadmapStatus = .backlog,
                kind: RoadmapItemKind = .task, start: CivilDay? = nil, due: CivilDay? = nil, linkedNoteIDs: [UUID] = []) {
        self.id = id; self.title = title; self.detail = detail; self.status = status; self.kind = kind
        self.start = start; self.due = due; self.linkedNoteIDs = linkedNoteIDs
    }
    public var isUnscheduled: Bool { start == nil && due == nil }
    public var firstDate: CivilDay? { start ?? due }
    public var lastDate: CivilDay? { due ?? start }
}

/// Finish-to-start at calendar-day precision. Same-day handoff is allowed; the
/// model does not invent times of day or resource/capacity scheduling.
public struct RoadmapDependency: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let predecessor: UUID
    public let successor: UUID
    public init(id: UUID = UUID(), predecessor: UUID, successor: UUID) {
        self.id = id; self.predecessor = predecessor; self.successor = successor
    }
}

public struct RoadmapDocument: Codable, Equatable, Sendable {
    public let version: Int
    public var revision: UUID
    public var items: [RoadmapItem]
    public var dependencies: [RoadmapDependency]
    public init(revision: UUID = UUID(), items: [RoadmapItem] = [], dependencies: [RoadmapDependency] = []) {
        version = 1; self.revision = revision; self.items = items; self.dependencies = dependencies
    }
    public static var empty: Self { .init(revision: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!) }
    public func items(in status: RoadmapStatus) -> [RoadmapItem] { items.filter { $0.status == status } }
    public var unscheduled: [RoadmapItem] { items.filter(\.isUnscheduled) }
    public var scheduled: [RoadmapItem] {
        items.filter { !$0.isUnscheduled }.sorted {
            if $0.firstDate == $1.firstDate { return $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            return $0.firstDate! < $1.firstDate!
        }
    }
}

public enum PlanningIssue: Equatable, Sendable {
    case title(UUID), reversedDates(UUID), invalidMilestone(UUID), missingEndpoint(UUID)
    case selfDependency(UUID), duplicateDependency(UUID), cycle([UUID])
    case dateConflict(edge: UUID, predecessor: UUID, successor: UUID, minimumStart: CivilDay)
    public var message: String {
        switch self {
        case .title: "Give every item a non-empty title within the size limit."
        case .reversedDates: "An item's start date is later than its due date."
        case .invalidMilestone: "A milestone must be a single day, not a duration."
        case .missingEndpoint: "A dependency refers to an item that is missing."
        case .selfDependency: "An item cannot depend on itself."
        case .duplicateDependency: "That prerequisite relationship already exists."
        case .cycle(let ids): "A dependency loop connects \(ids.count) items. Remove a relationship to break it."
        case .dateConflict(_, _, _, let date): "A successor starts before its prerequisite finishes. Earliest calendar-day start: \(date)."
        }
    }
}

public indirect enum RoadmapEdit: Sendable {
    case create(RoadmapItem)
    case update(RoadmapItem)
    case delete([UUID])
    case move(ids: [UUID], status: RoadmapStatus, before: UUID?)
    case shiftDates(ids: [UUID], days: Int)
    case addDependency(RoadmapDependency)
    case removeDependency(UUID)
    case batch([RoadmapEdit])
}

public struct RoadmapProposal: Sendable {
    public let expectedRevision: UUID
    public let document: RoadmapDocument
    public let issues: [PlanningIssue]
    public var mayApply: Bool { issues.isEmpty }
}
public enum RoadmapRepair: Sendable {
    case removeDependency(UUID)
    case startNoEarlier(item: UUID, day: CivilDay)
    case swapDates(UUID)
    case collapseMilestone(UUID)
}

public enum RoadmapCodec {
    public static let byteLimit = 8 * 1024 * 1024
    public static func encode(_ document: RoadmapDocument) throws -> Data {
        try RoadmapEngine.validateStructure(document)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(document)
        guard data.count <= byteLimit else { throw PlanningError.tooLarge }
        return data
    }
    public static func decode(_ data: Data) throws -> RoadmapDocument {
        guard data.count <= byteLimit else { throw PlanningError.tooLarge }
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw PlanningError.invalidDocument }
            guard (object["version"] as? Int) == 1 else { throw PlanningError.unsupportedVersion }
            guard Set(object.keys) == Set(["version", "revision", "items", "dependencies"]) else { throw PlanningError.invalidDocument }
            let itemKeys: Set<String> = ["id", "title", "detail", "status", "kind", "start", "due", "linkedNoteIDs"]
            guard let rows = object["items"] as? [[String: Any]], rows.allSatisfy({ Set($0.keys).isSubset(of: itemKeys) }),
                  let edges = object["dependencies"] as? [[String: Any]], edges.allSatisfy({ Set($0.keys) == Set(["id", "predecessor", "successor"]) }) else { throw PlanningError.invalidDocument }
            let document = try JSONDecoder().decode(RoadmapDocument.self, from: data)
            try RoadmapEngine.validateStructure(document)
            return document
        } catch let error as PlanningError { throw error }
        catch { throw PlanningError.invalidDocument }
    }
}
