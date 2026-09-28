import Foundation
import Observation
import FolioCore

struct TaskEditRequest: Identifiable {
    let id = UUID()
    let item: RoadmapItem?
    let base: RoadmapDocument
}
enum RoadmapPresentation: String, CaseIterable { case timeline, kanban }

@MainActor
@Observable
final class RoadmapController {
    var snapshot: RoadmapSnapshot?
    var presentation: RoadmapPresentation = .timeline
    var selectedIDs = Set<UUID>()
    var editRequest: TaskEditRequest?
    var pendingProposal: RoadmapProposal?
    var failure: String?
    var notice: String?
    var isSaving = false
    var windowStart = CivilDay.today()
    var windowDays = 42
    var history = RoadmapHistory()
    @ObservationIgnored private var store: PlainVaultStore?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var pendingEdit: RoadmapEdit?
    @ObservationIgnored private var pendingBase: RoadmapDocument?
    @ObservationIgnored var onChange: ((RoadmapDocument) -> Void)?

    var document: RoadmapDocument { snapshot?.document ?? .empty }
    var selectedItem: RoadmapItem? { selectedIDs.count == 1 ? document.items.first { selectedIDs.contains($0.id) } : nil }
    var hasUnwrittenChanges: Bool { isSaving || pendingProposal != nil }
    var status: String { isSaving ? "Writing roadmap…" : failure != nil ? "Roadmap needs attention" : pendingProposal != nil ? "Roadmap change awaiting review" : "Local roadmap" }

    func connect(_ store: PlainVaultStore) async {
        self.store = store; generation = UUID(); snapshot = nil
        selectedIDs = []; pendingProposal = nil; pendingEdit = nil; pendingBase = nil; editRequest = nil; failure = nil; notice = nil
        history = .init(); presentation = .timeline
        await reload(clearHistory: true)
    }
    func reload(clearHistory: Bool = false) async {
        guard let store, !isSaving else { return }
        let token = generation
        do {
            let loaded = try await store.loadRoadmap()
            guard token == generation else { return }
            let changed = clearHistory || loaded.document != snapshot?.document
            if changed { history = .init() }
            snapshot = loaded
            selectedIDs.formIntersection(Set(loaded.document.items.map(\.id)))
            if let first = loaded.document.scheduled.first?.firstDate, clearHistory { windowStart = (try? first.adding(days: -3)) ?? first }
            if changed { onChange?(loaded.document) }
        } catch { failure = error.localizedDescription }
    }
    func beginNew() { editRequest = .init(item: nil, base: document) }
    func beginEdit(_ id: UUID) {
        guard let item = document.items.first(where: { $0.id == id }) else { return }
        editRequest = .init(item: item, base: document)
    }
    @discardableResult
    func submit(_ edit: RoadmapEdit, base: RoadmapDocument? = nil) async -> Bool {
        guard !isSaving, snapshot != nil else { return false }
        do {
            let original = base ?? document
            let proposed = try RoadmapEngine.propose(edit, on: original)
            pendingEdit = edit; pendingBase = original; pendingProposal = proposed; failure = nil
            if !proposed.mayApply {
                notice = "Your attempted change is preserved below. Choose a repair, review its impact, then apply explicitly."
                return true
            }
            return await applyPending()
        } catch { failure = error.localizedDescription; return false }
    }
    func repair(_ repair: RoadmapRepair) {
        guard let pendingProposal else { return }
        do {
            self.pendingProposal = try RoadmapEngine.repaired(pendingProposal, with: repair)
            notice = "Repair preview updated. Nothing is saved until you choose Apply Reviewed Change."
        } catch { failure = error.localizedDescription }
    }
    @discardableResult
    func applyPending() async -> Bool {
        guard let store, let base = snapshot, let proposed = pendingProposal, !isSaving else { return false }
        guard proposed.mayApply else { return false }
        guard proposed.expectedRevision == base.document.revision, pendingBase == base.document else {
            failure = "This proposal is based on an older roadmap. Rebase it, inspect the changes and approve again."
            return false
        }
        isSaving = true; defer { isSaving = false }
        let token = generation
        do {
            switch try await store.saveRoadmap(base, document: proposed.document) {
            case .written(let saved):
                guard token == generation else { return false }
                do { try history.record(before: base.document, after: saved.document) }
                catch { history = .init() }
                snapshot = saved; pendingProposal = nil; pendingEdit = nil; pendingBase = nil; failure = nil
                notice = "Roadmap written locally."
                selectedIDs.formIntersection(Set(saved.document.items.map(\.id)))
                onChange?(saved.document); return true
            case .conflict(let current, let preserved):
                guard token == generation else { return false }
                snapshot = current; history = .init()
                failure = "The roadmap changed externally. Your proposal is preserved in recovery (\(preserved.uuidString.prefix(8))). Rebase and review; it was not silently accepted."
                onChange?(current.document); return false
            }
        } catch { failure = error.localizedDescription; return false }
    }
    func rebasePending() async {
        guard let store, let edit = pendingEdit, !isSaving else { return }
        do {
            let current = try await store.loadRoadmap()
            snapshot = current; history = .init()
            pendingBase = current.document
            pendingProposal = try RoadmapEngine.propose(edit, on: current.document)
            notice = "Rebased against the current file. Review the full proposal before applying."
            failure = nil; onChange?(current.document)
        } catch { failure = error.localizedDescription }
    }
    func cancelProposal() { pendingProposal = nil; pendingEdit = nil; pendingBase = nil; notice = nil; failure = nil }
    func undo() async { await traverseHistory(redo: false) }
    func redo() async { await traverseHistory(redo: true) }
    private func traverseHistory(redo: Bool) async {
        guard let store, let base = snapshot, !hasUnwrittenChanges else { return }
        do {
            var candidateHistory = history
            let candidate: RoadmapDocument
            if redo { candidate = try candidateHistory.redo(current: base.document) }
            else { candidate = try candidateHistory.undo(current: base.document) }
            isSaving = true; defer { isSaving = false }
            switch try await store.saveRoadmap(base, document: candidate) {
            case .written(let saved):
                history = candidateHistory; snapshot = saved; failure = nil
                selectedIDs.formIntersection(Set(saved.document.items.map(\.id))); onChange?(saved.document)
            case .conflict(let current, _):
                snapshot = current; history = .init(); onChange?(current.document)
                failure = "Undo/redo stopped because another writer changed the roadmap."
            }
        } catch { failure = error.localizedDescription }
    }
    func moveSelection(to status: RoadmapStatus) async {
        let ids = document.items.filter { selectedIDs.contains($0.id) }.map(\.id)
        guard !ids.isEmpty else { return }
        _ = await submit(.move(ids: ids, status: status, before: nil))
    }
    func moveItem(_ id: UUID, direction: Int) async {
        guard let item = document.items.first(where: { $0.id == id }) else { return }
        let column = document.items(in: item.status)
        guard let position = column.firstIndex(where: { $0.id == id }) else { return }
        let before: UUID?
        if direction < 0 {
            guard position > 0 else { return }; before = column[position - 1].id
        } else {
            guard position + 1 < column.count else { return }
            before = position + 2 < column.count ? column[position + 2].id : nil
        }
        _ = await submit(.move(ids: [id], status: item.status, before: before))
    }
    func shiftWindow(_ days: Int) { if let next = try? windowStart.adding(days: days) { windowStart = next } }
    func select(_ id: UUID, extending: Bool = false) {
        if extending {
            if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) }
        } else { selectedIDs = [id] }
    }
}
