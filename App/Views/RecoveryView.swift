import SwiftUI

struct RecoveryView: View {
    @Bindable var session: WorkspaceSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            Text("Recovery & preserved changes").font(.title2.weight(.semibold))
            Text("Uncertain or conflicting changes are not silently applied. These copies are plaintext because this is a plain vault.")
                .font(.callout).foregroundStyle(.secondary)
            if session.recoveryItems.isEmpty {
                ContentUnavailableView("No unresolved recovery items", systemImage: "checkmark.circle")
            } else {
                List(session.recoveryItems) { item in
                    VStack(alignment: .leading, spacing: 7) {
                        Text(item.relativePath ?? "Unrecognised recovery record").font(.headline)
                        Text(item.explanation).font(.caption).foregroundStyle(.secondary)
                        if item.proposedMarkdown != nil {
                            Button("Create Note from Preserved Text…") { session.restoreRecoveryAsNewNote(item) }
                        }
                    }.padding(.vertical, 6)
                }
            }
            HStack {
                Button("Show Recovery Folder") { session.revealRecoveryFolder() }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 660, height: 480)
    }
}
