import SwiftUI
import FolioCore

struct NoteSearchView: View {
    @Bindable var session: WorkspaceSession
    @Bindable var search: NoteSearchController
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool
    @State private var selected: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Label("Search notes", systemImage: "magnifyingglass").font(.headline); Spacer(); Text(session.project?.name ?? "").foregroundStyle(.secondary) }
            TextField("Titles, paths, tags and note contents…", text: $search.query)
                .textFieldStyle(.roundedBorder).focused($focused)
                .onSubmit { if !search.isSearching, let id = selected ?? search.results.first?.id { open(id) } }
            Picker("Search scope", selection: $search.scope) {
                ForEach(NoteSearchScope.allCases, id: \.self) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented)
            HStack {
                if search.isSearching || search.isIndexing { ProgressView().controlSize(.small) }
                Text(search.message).font(.caption).foregroundStyle(.secondary)
                if search.isIndexing { Text("\(search.completed)/\(search.total)").font(.caption.monospacedDigit()) }
                Spacer()
                if search.isIndexing { Button("Pause") { search.cancelIndexing() }.controlSize(.small) }
            }
            if let error = search.failure { Text(error).font(.caption).foregroundStyle(.orange) }
            List(selection: $selected) {
                ForEach(search.results) { hit in
                    Button { open(hit.id) } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack { Text(hit.title).font(.headline); Spacer(); Text(hit.modifiedAt, style: .date).font(.caption).foregroundStyle(.secondary) }
                            Text(hit.path).font(.caption).foregroundStyle(FolioStyle.gold)
                            if !hit.tags.isEmpty { Text(hit.tags.map { "#" + $0 }.joined(separator: "  ")).font(.caption).foregroundStyle(.secondary) }
                            Text(hit.excerpt).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                        }.padding(.vertical, 6)
                    }.buttonStyle(.plain).tag(hit.id)
                }
            }
            HStack {
                Text("Saved files only · first 100 matches · literal terms and quoted phrases").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("Rebuild…") { dismiss(); session.runCommand(.rebuildSearch) }
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(22).frame(width: 760, height: 600)
        .onAppear { focused = true; search.search() }
        .onChange(of: search.query) { _, _ in selected = nil; search.search() }
        .onChange(of: search.scope) { _, _ in selected = nil; search.search() }
    }
    private func open(_ id: UUID) {
        dismiss()
        Task { await session.selectNote(id) } // Always opens current authoritative bytes, not the cached excerpt.
    }
}
