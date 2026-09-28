import SwiftUI

struct NewNoteSheet: View {
    @Bindable var session: WorkspaceSession
    @Environment(\.dismiss) private var dismiss
    @FocusState private var titleFocused: Bool
    @State private var title = ""
    @State private var folder = "Notes"
    @State private var errorMessage: String?
    @State private var creating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("New note").font(.title2.weight(.semibold))
            Text("Choose its title and location in \(session.project?.name ?? "this project").")
                .foregroundStyle(.secondary)
            Form {
                TextField("Title", text: $title).focused($titleFocused)
                TextField("Folder", text: $folder)
                Text("Relative to this project, for example Notes or Projects/Folio.")
                    .font(.caption).foregroundStyle(.secondary)
            }.disabled(creating)
            Text("Creates a real UTF-8 Markdown file after confirmation. Existing files are never silently replaced.")
                .font(.caption).foregroundStyle(FolioStyle.gold)
            if let errorMessage { Text(errorMessage).font(.callout).foregroundStyle(.red).lineLimit(4) }
            HStack {
                if creating { ProgressView().controlSize(.small); Text("Creating…").font(.caption) }
                Spacer()
                Button("Cancel") { session.creationSeed = nil; dismiss() }
                    .keyboardShortcut(.cancelAction).disabled(creating)
                Button("Create Note") {
                    creating = true
                    Task { @MainActor in
                        defer { creating = false }
                        do { try await session.createNote(title: title, folder: folder); dismiss() }
                        catch { errorMessage = error.localizedDescription }
                    }
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(creating || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || folder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(26).frame(width: 500)
        .onAppear {
            if let seed = session.creationSeed { title = seed.title; folder = seed.folder }
            titleFocused = true
        }
        .interactiveDismissDisabled(creating)
    }
}
