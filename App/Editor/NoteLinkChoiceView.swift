import SwiftUI
import FolioCore

struct NoteLinkChoice: Identifiable {
    let id = UUID()
    let target: String
    let candidates: [NoteLinkCandidate]
    var originMode: EditorPresentation = .source
}
struct NoteLinkChoiceView: View {
    @Bindable var session: WorkspaceSession
    let choice: NoteLinkChoice
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(choice.candidates.isEmpty ? "No matching note" : "Choose the note you meant").font(.title2.weight(.semibold))
            Text(choice.target).foregroundStyle(FolioStyle.gold)
            Text("The original Markdown link remains unchanged.").font(.caption).foregroundStyle(.secondary)
            if choice.candidates.isEmpty {
                ContentUnavailableView("No target in this project", systemImage: "link.badge.plus", description: Text("Folio did not open a file outside the project or create a note automatically."))
            } else {
                List(choice.candidates) { candidate in
                    Button {
                        dismiss()
                        Task {
                            await session.selectNote(candidate.id)
                            guard session.selectedNoteID == candidate.id else { return }
                            session.selectedDocument?.editorPresentation = choice.originMode
                            if let separator = choice.target.firstIndex(of: "#") {
                                session.selectedDocument?.previewRequest = .init(sourceOffset: nil, heading: String(choice.target[choice.target.index(after: separator)...]))
                            }
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack { Text(candidate.title).font(.headline); Spacer(); Text(candidate.modifiedAt, style: .date).font(.caption).foregroundStyle(.secondary) }
                            Text(candidate.path).font(.callout)
                            Text(candidate.tags.map { "#" + $0 }.joined(separator: "  ")).font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 5)
                    }.buttonStyle(.plain)
                }
            }
            HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(24).frame(width: 640, height: 420)
    }
}
