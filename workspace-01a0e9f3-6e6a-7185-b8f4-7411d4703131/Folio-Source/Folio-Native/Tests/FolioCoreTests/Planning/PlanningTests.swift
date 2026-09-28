import XCTest
import Foundation
@testable import FolioCore

final class PlanningTests: XCTestCase {
    private func day(_ value: String) throws -> CivilDay { try .init(value) }
    func testLeapDaysAndInvalidDates() throws {
        XCTAssertEqual(try day("2024-02-29").adding(days: 1).description, "2024-03-01")
        XCTAssertThrowsError(try day("2023-02-29"))
        XCTAssertThrowsError(try day("2100-02-29"))
        XCTAssertNoThrow(try day("2000-02-29"))
        XCTAssertThrowsError(try day("2026-2-01"))
        XCTAssertThrowsError(try day("2026-13-01"))
    }
    func testDayArithmeticIsIndependentOfDSTAndTimeZone() throws {
        let start = try day("2026-03-28")
        XCTAssertEqual(try start.adding(days: 2).description, "2026-03-30")
        XCTAssertEqual(try day("2026-12-31").adding(days: 1).description, "2027-01-01")
        XCTAssertEqual(try day("2026-01-01").adding(days: -1).description, "2025-12-31")
        XCTAssertEqual(start.distance(to: try day("2026-03-30")), 2)
    }
    func testDatesEncodeAsCalendarStringsNotTimestamps() throws {
        let value = try day("2026-09-28")
        let data = try JSONEncoder().encode(value)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "\"2026-09-28\"")
        XCTAssertEqual(try JSONDecoder().decode(CivilDay.self, from: data), value)
    }
    func testEmptyRoadmapDoesNotInventDates() throws {
        let item = RoadmapItem(title: "Unscheduled")
        let doc = RoadmapDocument(items: [item])
        let projection = try TimelineProjection(document: doc, start: day("2026-09-01"), days: 30)
        XCTAssertTrue(projection.rows.isEmpty)
        XCTAssertEqual(projection.unscheduledIDs, [item.id])
    }
    func testDateOnlyMarkersStayDistinctFromDuration() throws {
        let a = RoadmapItem(title: "Due", due: try day("2026-09-15"))
        let b = RoadmapItem(title: "Start", start: try day("2026-09-16"))
        let c = RoadmapItem(title: "Milestone", kind: .milestone, due: try day("2026-09-20"))
        let p = try TimelineProjection(document: .init(items: [a, b, c]), start: day("2026-09-01"), days: 30)
        XCTAssertEqual(p.rows.map(\.mark), [.dueOnly, .startOnly, .milestone])
        XCTAssertEqual(p.rows.map(\.lengthDays), [1, 1, 1])
    }
    func testTimelineClipsWithoutChangingAuthoredDates() throws {
        let item = RoadmapItem(title: "Long", start: try day("2026-08-20"), due: try day("2026-10-20"))
        let p = try TimelineProjection(document: .init(items: [item]), start: day("2026-09-01"), days: 30)
        XCTAssertEqual(p.rows.first?.lengthDays, 30)
        XCTAssertEqual(p.rows.first?.clippedStart, true); XCTAssertEqual(p.rows.first?.clippedEnd, true)
        XCTAssertEqual(item.start?.description, "2026-08-20")
    }
    func testStatusMoveAndReorderShareCanonicalArray() throws {
        let a = RoadmapItem(title: "A"), b = RoadmapItem(title: "B"), c = RoadmapItem(title: "C", status: .done)
        let doc = RoadmapDocument(items: [a,b,c])
        let proposal = try RoadmapEngine.propose(.move(ids: [b.id, a.id], status: .done, before: c.id), on: doc)
        XCTAssertTrue(proposal.mayApply)
        XCTAssertEqual(proposal.document.items(in: .done).map(\.id), [a.id,b.id,c.id])
        XCTAssertEqual(doc.items(in: .backlog).count, 2)
    }
    func testInvalidMoveDoesNotPartiallyMutateOriginal() throws {
        let a = RoadmapItem(title: "A")
        let doc = RoadmapDocument(items: [a])
        XCTAssertThrowsError(try RoadmapEngine.propose(.move(ids: [a.id], status: .done, before: a.id), on: doc))
        XCTAssertEqual(doc.items[0].status, .backlog)
    }
    func testDeleteRemovesEdgesButNotUnrelatedItems() throws {
        let a = RoadmapItem(title: "A"), b = RoadmapItem(title: "B"), c = RoadmapItem(title: "C")
        let doc = RoadmapDocument(items: [a,b,c], dependencies: [.init(predecessor: a.id, successor: b.id)])
        let proposal = try RoadmapEngine.propose(.delete([a.id]), on: doc)
        XCTAssertEqual(proposal.document.items.map(\.id), [b.id,c.id]); XCTAssertTrue(proposal.document.dependencies.isEmpty)
    }
    func testCycleIsReportedAndRepairRequiresExplicitApplication() throws {
        let a = RoadmapItem(title: "A"), b = RoadmapItem(title: "B"), c = RoadmapItem(title: "C")
        let doc = RoadmapDocument(items: [a,b,c], dependencies: [.init(predecessor: a.id, successor: b.id), .init(predecessor: b.id, successor: c.id)])
        let edge = RoadmapDependency(predecessor: c.id, successor: a.id)
        let candidate = try RoadmapEngine.propose(.addDependency(edge), on: doc)
        XCTAssertFalse(candidate.mayApply)
        XCTAssertTrue(candidate.issues.contains { if case .cycle = $0 { return true }; return false })
        XCTAssertEqual(doc.dependencies.count, 2)
        let repaired = try RoadmapEngine.repaired(candidate, with: .removeDependency(edge.id))
        XCTAssertTrue(repaired.mayApply); XCTAssertEqual(repaired.expectedRevision, doc.revision)
    }
    func testDateConflictRepairPreservesSuccessorDuration() throws {
        let a = RoadmapItem(title: "Prerequisite", due: try day("2026-10-10"))
        let b = RoadmapItem(title: "Successor", start: try day("2026-10-05"), due: try day("2026-10-08"))
        let doc = RoadmapDocument(items: [a,b])
        let proposed = try RoadmapEngine.propose(.addDependency(.init(predecessor: a.id, successor: b.id)), on: doc)
        XCTAssertFalse(proposed.mayApply)
        let fixed = try RoadmapEngine.repaired(proposed, with: .startNoEarlier(item: b.id, day: day("2026-10-10")))
        XCTAssertTrue(fixed.mayApply)
        XCTAssertEqual(fixed.document.items[1].start?.description, "2026-10-10")
        XCTAssertEqual(fixed.document.items[1].due?.description, "2026-10-13")
    }
    func testSameDayHandoffIsAllowedAtDateOnlyPrecision() throws {
        let a = RoadmapItem(title: "A", due: try day("2026-10-10"))
        let b = RoadmapItem(title: "B", start: try day("2026-10-10"))
        let p = try RoadmapEngine.propose(.addDependency(.init(predecessor: a.id, successor: b.id)), on: .init(items: [a,b]))
        XCTAssertTrue(p.mayApply)
    }
    func testShiftKeepsUnscheduledItemsUndated() throws {
        let a = RoadmapItem(title: "A"), b = RoadmapItem(title: "B", due: try day("2026-09-30"))
        let p = try RoadmapEngine.propose(.shiftDates(ids: [a.id,b.id], days: 2), on: .init(items: [a,b]))
        XCTAssertNil(p.document.items[0].start); XCTAssertNil(p.document.items[0].due)
        XCTAssertEqual(p.document.items[1].due?.description, "2026-10-02")
    }
    func testMilestoneDurationAndReversedDatesRequireRepair() throws {
        let item = RoadmapItem(title: "M", kind: .milestone, start: try day("2026-10-10"), due: try day("2026-10-05"))
        let proposed = try RoadmapEngine.propose(.create(item), on: .empty)
        XCTAssertFalse(proposed.mayApply)
        let repaired = try RoadmapEngine.repaired(proposed, with: .collapseMilestone(item.id))
        XCTAssertTrue(repaired.mayApply)
    }
    func testCodecRoundTripKeepsLinkedNoteIDsAndOrder() throws {
        let ids = [UUID(), UUID()]
        let document = RoadmapDocument(items: [.init(title: "Linked", linkedNoteIDs: ids)])
        XCTAssertEqual(try RoadmapCodec.decode(RoadmapCodec.encode(document)), document)
    }
    func testUnknownSchemaAndFieldsAreRejectedWithoutGuessing() throws {
        var raw = try JSONSerialization.jsonObject(with: RoadmapCodec.encode(.empty)) as! [String:Any]
        raw["future"] = true
        XCTAssertThrowsError(try RoadmapCodec.decode(JSONSerialization.data(withJSONObject: raw)))
        raw.removeValue(forKey: "future"); raw["version"] = 99
        XCTAssertThrowsError(try RoadmapCodec.decode(JSONSerialization.data(withJSONObject: raw)))
    }
    func testDuplicateIDsAreRejected() {
        let item = RoadmapItem(title: "same")
        XCTAssertThrowsError(try RoadmapEngine.validateStructure(.init(items: [item,item])))
    }
    func testUndoRedoUseFreshRevisionsAndRejectExternalHead() throws {
        let base = RoadmapDocument.empty
        let next = try RoadmapEngine.propose(.create(.init(title: "A")), on: base).document
        var history = RoadmapHistory(); try history.record(before: base, after: next)
        let undone = try history.undo(current: next)
        XCTAssertTrue(undone.items.isEmpty); XCTAssertNotEqual(undone.revision, base.revision)
        let redone = try history.redo(current: undone)
        XCTAssertEqual(redone.items.count, 1); XCTAssertNotEqual(redone.revision, next.revision)
        XCTAssertThrowsError(try history.undo(current: RoadmapDocument(items: redone.items)))
    }
    func testLongDependencyChainDoesNotUseRecursiveDFS() throws {
        let items = (0..<3000).map { RoadmapItem(title: "Item \($0)") }
        var edges = (1..<items.count).map { RoadmapDependency(predecessor: items[$0-1].id, successor: items[$0].id) }
        XCTAssertTrue(RoadmapEngine.issues(in: .init(items: items, dependencies: edges)).isEmpty)
        edges.append(.init(predecessor: items.last!.id, successor: items.first!.id))
        XCTAssertTrue(RoadmapEngine.issues(in: .init(items: items, dependencies: edges)).contains { if case .cycle = $0 { return true }; return false })
    }
    func testHistoryRejectsExternalContentChangeEvenIfRevisionWasReused() throws {
        let initial = RoadmapDocument.empty
        let after = try RoadmapEngine.propose(.create(.init(title: "Original")), on: initial).document
        var history = RoadmapHistory(); try history.record(before: initial, after: after)
        var external = after; external.items[0].title = "Changed without a new revision"
        XCTAssertThrowsError(try history.undo(current: external))
    }

}
