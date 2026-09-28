import SwiftUI
import AppKit
import FolioCore

struct RoadmapView: View {
    @Bindable var session: WorkspaceSession
    @Bindable var planning: RoadmapController
    @State private var prerequisite: UUID?
    @State private var filter = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Text("Roadmap").font(.title2.weight(.semibold))
                Picker("Roadmap view", selection: $planning.presentation) {
                    Text("Timeline").tag(RoadmapPresentation.timeline)
                    Text("Kanban").tag(RoadmapPresentation.kanban)
                }.pickerStyle(.segmented).frame(width: 200)
                Spacer()
                Button { Task { await planning.undo() } } label: { Image(systemName: "arrow.uturn.backward") }.help("Undo roadmap change")
                    .disabled(!planning.history.canUndo || planning.hasUnwrittenChanges)
                Button { Task { await planning.redo() } } label: { Image(systemName: "arrow.uturn.forward") }.help("Redo roadmap change")
                    .disabled(!planning.history.canRedo || planning.hasUnwrittenChanges)
                Button("New Item…") { planning.beginNew() }.buttonStyle(.borderedProminent).disabled(planning.snapshot == nil || planning.isSaving)
            }.padding(18)
            Divider()
            if let failure = planning.failure {
                HStack { Label(failure, systemImage: "exclamationmark.triangle").font(.caption); Spacer(); Button("Reload") { Task { await planning.reload() } } }
                    .padding(10).background(Color.orange.opacity(0.08))
            }
            if let proposal = planning.pendingProposal { repairPanel(proposal) }
            if !planning.selectedIDs.isEmpty {
                HStack {
                    Text("\(planning.selectedIDs.count) selected").font(.caption)
                    Menu("Move…") { ForEach(RoadmapStatus.allCases, id: \.self) { status in Button(status.title) { Task { await planning.moveSelection(to: status) } } } }
                    Button("−1 day") { shift(-1) }; Button("+1 day") { shift(1) }
                    Button("Delete…") { confirmDelete() }
                    Spacer()
                    Button("Clear Selection") { planning.selectedIDs = [] }
                }.controlSize(.small).padding(.horizontal, 16).padding(.vertical, 8)
                    .disabled(planning.isSaving)
                Divider()
            }
            if planning.snapshot == nil {
                ContentUnavailableView("Roadmap unavailable", systemImage: "calendar", description: Text("Open a project or resolve its metadata error. No empty replacement file is created automatically."))
            } else {
                HStack(spacing: 0) {
                    Group { if planning.presentation == .timeline { timeline } else { board } }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if let selected = planning.selectedItem {
                        Divider(); inspector(selected).frame(width: 270)
                    }
                }
            }
            Divider()
            HStack {
                if planning.isSaving { ProgressView().controlSize(.small) }
                Text(planning.status).font(.caption)
                Spacer()
                Text("\(planning.document.items.count) items · \(planning.document.dependencies.count) dependencies").font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, 16).padding(.vertical, 8)
        }
        .sheet(item: $planning.editRequest) { request in TaskEditorView(session: session, planning: planning, request: request) }
        .onChange(of: planning.selectedIDs) { _, _ in prerequisite = nil }
    }

    private var timeline: some View {
        VStack(spacing: 0) {
            HStack {
                Button { planning.shiftWindow(-14) } label: { Image(systemName: "chevron.left") }
                Text(planning.windowStart.description).font(.callout.monospacedDigit())
                Button { planning.shiftWindow(14) } label: { Image(systemName: "chevron.right") }
                Button("Today") { planning.windowStart = .today() }
                Spacer()
                Picker("Window", selection: $planning.windowDays) { Text("6 weeks").tag(42); Text("12 weeks").tag(84); Text("Year").tag(365) }
                    .frame(width: 115)
            }.controlSize(.small).padding(12)
            HStack(alignment: .top, spacing: 0) {
                if let projection = try? TimelineProjection(document: planning.document, start: planning.windowStart, days: planning.windowDays) {
                    ScrollView([.horizontal, .vertical]) {
                        LazyVStack(spacing: 0) {
                            HStack(spacing: 0) {
                                Text("SCHEDULED").font(.caption2.weight(.semibold)).foregroundStyle(.secondary).frame(width: 210, alignment: .leading)
                                HStack(spacing: 0) {
                                    ForEach(0..<planning.windowDays, id: \.self) { offset in
                                        Text(offset % 7 == 0 ? String((try? planning.windowStart.adding(days: offset).description.suffix(5)) ?? "") : "")
                                            .font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 24, alignment: .leading)
                                    }
                                }
                            }.frame(height: 30)
                            ForEach(projection.rows) { row in
                                if let item = planning.document.items.first(where: { $0.id == row.id }) {
                                    HStack(spacing: 0) {
                                        Button { planning.select(item.id) } label: {
                                            HStack { Image(systemName: planning.selectedIDs.contains(item.id) ? "checkmark.circle.fill" : "circle"); Text(item.title).lineLimit(1); Spacer() }
                                        }.buttonStyle(.plain).frame(width: 210, alignment: .leading)
                                        ZStack(alignment: .leading) {
                                            HStack(spacing: 0) { ForEach(0..<planning.windowDays, id: \.self) { _ in Rectangle().fill(Color.white.opacity(0.04)).frame(width: 1); Color.clear.frame(width: 23) } }
                                            Button { planning.select(item.id) } label: {
                                                if row.mark == .span {
                                                    RoundedRectangle(cornerRadius: 4).fill(statusColor(item.status).opacity(0.75))
                                                        .overlay(Text(item.title).font(.caption2).foregroundStyle(Color.black).lineLimit(1).padding(.horizontal, 5))
                                                        .frame(width: max(12, CGFloat(row.lengthDays * 24 - 4)), height: 24)
                                                } else {
                                                    Image(systemName: row.mark == .milestone ? "diamond.fill" : "circle.dotted")
                                                        .foregroundStyle(statusColor(item.status)).frame(width: 24, height: 24)
                                                }
                                            }.buttonStyle(.plain).offset(x: CGFloat(row.offsetDays * 24))
                                                .help(scheduleLabel(item))
                                        }.frame(width: CGFloat(planning.windowDays * 24), height: 43)
                                    }
                                    .background(planning.selectedIDs.contains(item.id) ? Color.white.opacity(0.04) : .clear)
                                    Divider()
                                }
                            }
                            if !projection.outsideWindowIDs.isEmpty {
                                Text("\(projection.outsideWindowIDs.count) scheduled items are outside this visible date window.")
                                    .font(.caption).foregroundStyle(.secondary).padding(12)
                            }
                        }.padding(12)
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    HStack { Text("UNSCHEDULED").font(.caption.weight(.semibold)); Spacer(); Text("\(planning.document.unscheduled.count)").foregroundStyle(.secondary) }
                    Text("No dates invented. Select an item to schedule it.").font(.caption).foregroundStyle(.secondary)
                    ScrollView { LazyVStack(spacing: 9) { ForEach(planning.document.unscheduled) { item in card(item) } } }
                }.padding(12).frame(width: 235)
            }
        }
    }

    private var board: some View {
        VStack(spacing: 10) {
            TextField("Filter roadmap items", text: $filter).textFieldStyle(.roundedBorder).padding(.horizontal, 14).padding(.top, 12)
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(RoadmapStatus.allCases, id: \.self) { status in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack { Circle().fill(statusColor(status)).frame(width: 7,height: 7); Text(status.title).font(.headline); Spacer(); Text("\(planning.document.items(in: status).count)").foregroundStyle(.secondary) }
                            ScrollView {
                                LazyVStack(spacing: 9) {
                                    ForEach(planning.document.items(in: status).filter { filter.isEmpty || ($0.title + " " + $0.detail).localizedStandardContains(filter) }) { item in card(item) }
                                }
                            }
                        }.padding(12).frame(width: 245).frame(maxHeight: .infinity)
                            .background(Color.white.opacity(0.025)).clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }.padding(14)
            }
        }
    }
    private func card(_ item: RoadmapItem) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top) {
                Button { planning.select(item.id, extending: true) } label: { Image(systemName: planning.selectedIDs.contains(item.id) ? "checkmark.square.fill" : "square") }
                    .buttonStyle(.plain).accessibilityLabel("Select \(item.title) for bulk actions")
                Button { planning.select(item.id) } label: { Text(item.title).font(.callout.weight(.semibold)).frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.plain)
                if item.kind == .milestone { Image(systemName: "diamond").font(.caption) }
            }
            Text(scheduleLabel(item)).font(.caption2).foregroundStyle(.secondary)
            HStack {
                if !item.linkedNoteIDs.isEmpty { Label("\(item.linkedNoteIDs.count)", systemImage: "link").font(.caption2).foregroundStyle(.secondary) }
                Spacer()
                Menu("Move") {
                    ForEach(RoadmapStatus.allCases, id: \.self) { status in Button(status.title) { Task { _ = await planning.submit(.move(ids: [item.id], status: status, before: nil)) } } }
                    Divider()
                    Button("Move Up") { Task { await planning.moveItem(item.id, direction: -1) } }
                    Button("Move Down") { Task { await planning.moveItem(item.id, direction: 1) } }
                }.controlSize(.mini)
                Button { planning.beginEdit(item.id) } label: { Image(systemName: "pencil") }.buttonStyle(.plain).help("Edit item")
            }
        }.padding(11).background(planning.selectedIDs.contains(item.id) ? FolioStyle.gold.opacity(0.12) : FolioStyle.editor)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.08)))
    }
    private func inspector(_ item: RoadmapItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 17) {
                Text("SELECTED ITEM").font(.caption2.weight(.semibold)).tracking(1.4).foregroundStyle(.secondary)
                Text(item.title).font(.title3.weight(.semibold))
                Text(item.status.title).foregroundStyle(statusColor(item.status))
                Text(scheduleLabel(item)).font(.caption).foregroundStyle(.secondary)
                if !item.detail.isEmpty { Text(item.detail).font(.callout).textSelection(.enabled) }
                Button("Edit Item…") { planning.beginEdit(item.id) }
                Button("Inspect Connections") { session.focusGraph(.task(item.id)) }
                Divider()
                Text("LINKED NOTES").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(item.linkedNoteIDs, id: \.self) { id in
                    let note = session.notes.first { $0.id == id }
                    Button(note?.title ?? "Missing linked note") { Task { await session.openNoteFromPlanning(id) } }
                        .disabled(note == nil)
                }
                Divider()
                Text("PREREQUISITES").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(planning.document.dependencies.filter { $0.successor == item.id }) { dependency in
                    HStack {
                        Text(planning.document.items.first { $0.id == dependency.predecessor }?.title ?? "Missing item").font(.callout)
                        Spacer()
                        Button { Task { _ = await planning.submit(.removeDependency(dependency.id)) } } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain).help("Remove prerequisite")
                    }
                }
                Picker("Add prerequisite", selection: $prerequisite) {
                    Text("Choose item…").tag(UUID?.none)
                    ForEach(planning.document.items.filter { $0.id != item.id }) { candidate in Text(candidate.title).tag(Optional(candidate.id)) }
                }.labelsHidden()
                Button("Add Dependency") {
                    if let prerequisite { Task { _ = await planning.submit(.addDependency(.init(predecessor: prerequisite, successor: item.id))) } }
                }.disabled(prerequisite == nil)
                Text("Day-level finish-to-start: same-day handoff is allowed. Changes are never automatically cascaded through the project.")
                    .font(.caption2).foregroundStyle(.secondary)
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }.background(FolioStyle.sidebar)
    }
    private func repairPanel(_ proposal: RoadmapProposal) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Review the proposed roadmap change").font(.headline)
            let changed = proposal.document.items.filter { item in planning.document.items.first { $0.id == item.id } != item }
            Text("\(changed.count) item(s) change; proposed dependencies: \(proposal.document.dependencies.count). Nothing is applied by a repair button alone.")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(proposal.issues.enumerated()), id: \.offset) { _, issue in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(issue.message).font(.caption).foregroundStyle(.orange)
                            ForEach(Array(RoadmapEngine.repairs(for: issue, in: proposal).enumerated()), id: \.offset) { _, repair in
                                Button(repairLabel(repair, document: proposal.document)) { planning.repair(repair) }.controlSize(.small)
                            }
                        }
                    }
                    ForEach(changed.prefix(20)) { item in Text(item.title + " · " + scheduleLabel(item) + " · " + item.status.title).font(.caption) }
                    if changed.count > 20 { Text("Additional changed items are retained in the proposal.").font(.caption2) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 150)
            HStack {
                Button("Apply Reviewed Change") { Task { _ = await planning.applyPending() } }.disabled(!proposal.mayApply || planning.isSaving)
                Button("Rebase on Current File") { Task { await planning.rebasePending() } }.disabled(planning.isSaving)
                Button("Cancel Change") { planning.cancelProposal() }.disabled(planning.isSaving)
            }.controlSize(.small)
        }.padding(14).background(FolioStyle.gold.opacity(0.08))
    }
    private func repairLabel(_ repair: RoadmapRepair, document: RoadmapDocument) -> String {
        func title(_ id: UUID) -> String { document.items.first { $0.id == id }?.title ?? "Missing item" }
        switch repair {
        case .removeDependency(let id):
            if let edge = document.dependencies.first(where: { $0.id == id }) { return "Preview removal: \(title(edge.predecessor)) → \(title(edge.successor))" }
            return "Preview removing invalid dependency"
        case .startNoEarlier(let id, let day): return "Preview moving \(title(id)) to \(day) or later"
        case .swapDates(let id): return "Preview swapping dates for \(title(id))"
        case .collapseMilestone(let id): return "Preview making \(title(id)) a single-day milestone"
        }
    }
    private func scheduleLabel(_ item: RoadmapItem) -> String {
        if let start = item.start, let due = item.due { return start == due ? start.description : start.description + " → " + due.description }
        if let start = item.start { return "Start " + start.description + " · no due date" }
        if let due = item.due { return "Due " + due.description + " · no start date" }
        return "Unscheduled"
    }
    private func statusColor(_ status: RoadmapStatus) -> Color {
        switch status { case .backlog: .gray; case .ready: .blue; case .inProgress: FolioStyle.gold; case .blocked: .orange; case .done: .green }
    }
    private func shift(_ days: Int) { let ids = Array(planning.selectedIDs); Task { _ = await planning.submit(.shiftDates(ids: ids, days: days)) } }
    private func confirmDelete() {
        let alert = NSAlert(); alert.messageText = "Delete \(planning.selectedIDs.count) roadmap item(s)?"
        alert.informativeText = "Associated dependency edges are removed. Linked Markdown notes are not deleted. The roadmap change can be undone in this session."
        alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Delete Items")
        if alert.runModal() == .alertSecondButtonReturn { let ids = Array(planning.selectedIDs); Task { _ = await planning.submit(.delete(ids)) } }
    }
}
