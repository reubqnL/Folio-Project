import SwiftUI
import FolioCore

struct TaskEditorView: View {
    @Bindable var session: WorkspaceSession
    @Bindable var planning: RoadmapController
    let request: TaskEditRequest
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var detail = ""
    @State private var status: RoadmapStatus = .backlog
    @State private var kind: RoadmapItemKind = .task
    @State private var start = ""
    @State private var due = ""
    @State private var links = Set<UUID>()
    @State private var message: String?
    @State private var creating = false
    @State private var newID = UUID()
    @FocusState private var titleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(request.item == nil ? "New roadmap item" : "Edit roadmap item").font(.title2.weight(.semibold))
            ScrollView {
                Form {
                    TextField("Title", text: $title).focused($titleFocused)
                    Picker("Type", selection: $kind) { Text("Task").tag(RoadmapItemKind.task); Text("Milestone").tag(RoadmapItemKind.milestone) }
                    Picker("Status", selection: $status) { ForEach(RoadmapStatus.allCases, id: \.self) { Text($0.title).tag($0) } }
                    TextField("Start · YYYY-MM-DD", text: $start)
                    TextField("Due · YYYY-MM-DD", text: $due)
                    Text("Dates are calendar days. Leave both blank for the Unscheduled tray. Folio never invents dates.")
                        .font(.caption).foregroundStyle(.secondary)
                    VStack(alignment: .leading) {
                        Text("Details").font(.caption)
                        TextEditor(text: $detail).font(.body).frame(height: 110)
                    }
                    Section("Linked notes") {
                        if session.notes.isEmpty { Text("Create a Markdown note first to link it.").foregroundStyle(.secondary) }
                        ForEach(session.notes) { note in
                            Toggle(isOn: Binding(get: { links.contains(note.id) }, set: { selected in
                                if selected { links.insert(note.id) } else { links.remove(note.id) }
                            })) {
                                VStack(alignment: .leading) { Text(note.title); Text(note.relativePath).font(.caption2).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }.formStyle(.grouped)
            }
            if let message { Text(message).font(.caption).foregroundStyle(.orange) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(creating)
                Button(request.item == nil ? "Create Item" : "Review & Save") { save() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(creating || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24).frame(width: 610, height: 660)
        .interactiveDismissDisabled(creating)
        .onAppear {
            if let item = request.item {
                title = item.title; detail = item.detail; status = item.status; kind = item.kind
                start = item.start?.description ?? ""; due = item.due?.description ?? ""; links = Set(item.linkedNoteIDs)
            }
            titleFocused = true
        }
    }
    private func save() {
        do {
            let startDay = start.trimmingCharacters(in: .whitespacesAndNewlines)
            let dueDay = due.trimmingCharacters(in: .whitespacesAndNewlines)
            let item = RoadmapItem(id: request.item?.id ?? newID, title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                detail: detail, status: status, kind: kind,
                start: startDay.isEmpty ? nil : try CivilDay(startDay), due: dueDay.isEmpty ? nil : try CivilDay(dueDay),
                linkedNoteIDs: links.sorted { $0.uuidString < $1.uuidString })
            let edit: RoadmapEdit = request.item == nil ? .create(item) : .update(item)
            creating = true
            Task { @MainActor in
                defer { creating = false }
                if await planning.submit(edit, base: request.base) { planning.selectedIDs = [item.id]; dismiss() }
                else { message = planning.failure }
            }
        } catch { message = error.localizedDescription }
    }
}
