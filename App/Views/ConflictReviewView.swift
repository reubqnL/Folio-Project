import SwiftUI
import FolioCore

struct ConflictReviewView: View {
    @Bindable var session: WorkspaceSession
    @Bindable var document: OpenNoteDocument
    let conflict: VaultConflict
    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DisclosureGroup(isExpanded: $expanded) {
                HStack(alignment: .top, spacing: 12) {
                    preview("Your current buffer", document.text)
                    preview("Current file", conflict.disk?.markdown ?? "Missing, inaccessible or not valid UTF-8")
                    if let displaced = conflict.displacedMarkdown { preview("Preserved external version", displaced) }
                }
                .frame(height: 155)
                .padding(.top, 8)
            } label: {
                Label("External edit needs review", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                    .font(.callout.weight(.semibold))
            }
            Text(conflict.explanation).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Use Disk Version") { Task { await session.reloadDiskAfterConflict() } }
                    .disabled(conflict.disk == nil)
                Button("Keep My Text") { Task { await session.keepLocalAfterConflict() } }
                    .disabled(conflict.disk == nil)
                Button("Save My Text as New Note…") { session.saveLocalAsNewNote() }
            }
            .controlSize(.small).disabled(document.isResolvingConflict)
        }
        .padding(13).background(FolioStyle.gold.opacity(0.09))
    }
    private func preview(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption.weight(.semibold))
            ScrollView {
                Text(String(text.prefix(8000)))
                    .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if text.count > 8000 { Text("Preview limited to 8,000 characters; full text is retained.").font(.caption2) }
        }
        .frame(maxWidth: .infinity).padding(9)
        .background(FolioStyle.editor).clipShape(RoundedRectangle(cornerRadius: 5))
    }
}
