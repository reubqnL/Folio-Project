import Foundation

public enum TimelineMark: String, Sendable { case span, milestone, startOnly, dueOnly }
public struct TimelineRow: Sendable, Identifiable {
    public let id: UUID
    public let offsetDays: Int
    public let lengthDays: Int
    public let mark: TimelineMark
    public let clippedStart: Bool
    public let clippedEnd: Bool
}
public struct TimelineProjection: Sendable {
    public let start: CivilDay
    public let days: Int
    public let rows: [TimelineRow]
    public let unscheduledIDs: [UUID]
    public let outsideWindowIDs: [UUID]
    public init(document: RoadmapDocument, start: CivilDay, days: Int) throws {
        guard (1...366).contains(days) else { throw PlanningError.invalidDate }
        let end = try start.adding(days: days - 1)
        var rows: [TimelineRow] = [], outside: [UUID] = []
        for item in document.scheduled {
            guard let first = item.firstDate, let last = item.lastDate else { continue }
            if last < start || first > end { outside.append(item.id); continue }
            let clippedFirst = max(start, first), clippedLast = min(end, last)
            let mark: TimelineMark = item.kind == .milestone ? .milestone : item.start == nil ? .dueOnly : item.due == nil ? .startOnly : .span
            rows.append(.init(id: item.id, offsetDays: start.distance(to: clippedFirst),
                              lengthDays: max(1, clippedFirst.distance(to: clippedLast) + 1), mark: mark,
                              clippedStart: first < start, clippedEnd: last > end))
        }
        self.start = start; self.days = days; self.rows = rows
        unscheduledIDs = document.unscheduled.map(\.id); outsideWindowIDs = outside
    }
}
