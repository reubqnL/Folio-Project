import SwiftUI
import FolioCore

/// Compact link repair (Increment 11; decision 12 — compact details, and the
/// original link is kept until its replacement is confirmed). Broken and
/// ambiguous note links are listed with their authored targets; each candidate
/// shows folder path, tags and modification date; replacing one link is one
/// explicit confirmation and a refusal never changes the note.
struct LinkRepairView: View {
    @Bindable var session: WorkspaceSession
    @Environment(\.dismiss) private var dismiss
    @State private var inspections: [NoteLinkInspection] = []
    @State private var expandedID: Int?
    @State private var filter = ""
    @State private var notice: String?
    @State private var healthyCount = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Repair note links").font(.title2.weight(.semibold))
            Text("Links with no matching note, or with several matching notes, are listed here. The original Markdown link stays unchanged until you confirm a replacement.")
                .font(.caption).foregroundStyle(.secondary)
            if healthyCount > 0 {
                Text("\(healthyCount) link\(healthyCount == 1 ? "" : "s") already resolve correctly and are not listed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let notice {
                Text(notice).font(.caption).foregroundStyle(FolioStyle.gold)
            }
            if inspections.isEmpty {
                ContentUnavailableView("No broken or ambiguous links", systemImage: "checkmark.circle",
                                       description: Text("Every authored note link in this note resolves to exactly one note."))
            } else {
                List(inspections) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        Button {
                            expandedID = expandedID == item.occurrence.id ? nil : item.occurrence.id
                        } label: {
                            HStack(alignment: .firstTextBaseline) {
                                Text(item.occurrence.target).font(.body.weight(.medium)).foregroundStyle(FolioStyle.gold)
                                Spacer()
                                Text(badge(for: item.resolution)).font(.caption.weight(.semibold))
                                    .foregroundStyle(item.resolution.isMissing ? .red : .orange)
                            }
                        }.buttonStyle(.plain)
                        if expandedID == item.occurrence.id {
                            TextField("Filter notes", text: $filter)
                                .textFieldStyle(.roundedBorder).controlSize(.small)
                            ForEach(candidateList(for: item)) { candidate in
                                Button {
                                    replace(item, with: candidate)
                                } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack {
                                            Text(candidate.title).font(.headline)
                                            Spacer()
                                            Text(candidate.modifiedAt, style: .date).font(.caption).foregroundStyle(.secondary)
                                        }
                                        Text(candidate.path).font(.callout)
                                        if !candidate.tags.isEmpty {
                                            Text(candidate.tags.map { "#" + $0 }.joined(separator: "  "))
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                        Text("Replace with this note").font(.caption.weight(.semibold)).foregroundStyle(FolioStyle.gold)
                                    }.padding(.vertical, 4)
                                }.buttonStyle(.plain)
                            }
                        }
                    }.padding(.vertical, 4)
                }
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(24).frame(minWidth: 560, minHeight: 420)
        .onAppear(perform: reload)
    }

    private func badge(for resolution: NoteLinkResolution) -> String {
        switch resolution {
        case .missing: "No matching note"
        case .ambiguous: "Several matching notes"
        case .unique: "Resolves"
        }
    }

    private func candidateList(for item: NoteLinkInspection) -> [NoteLinkCandidate] {
        let base: [NoteLinkCandidate]
        switch item.resolution {
        case .ambiguous(let matches): base = matches
        case .missing, .unique: base = session.notes.map {
            NoteLinkCandidate(id: $0.id, title: $0.title, path: $0.relativePath,
                              tags: session.search.knownTags[$0.id] ?? [], modifiedAt: $0.modifiedAt)
        }
        }
        let query = NoteSearchQuery.fold(filter.trimmingCharacters(in: .whitespaces))
        guard !query.isEmpty else { return base }
        return base.filter {
            NoteSearchQuery.fold($0.title).contains(query) || NoteSearchQuery.fold($0.path).contains(query)
        }
    }

    private func replace(_ item: NoteLinkInspection, with candidate: NoteLinkCandidate) {
        if let failure = session.applyLinkRepair(item, to: candidate) {
            notice = failure
            reload()
        } else {
            notice = "Replaced “\(item.occurrence.target)” with “\(NoteLinkRepair.replacementTarget(candidate, for: item.occurrence))”."
            reload()
        }
    }

    private func reload() {
        let all = session.linkRepairInspections()
        inspections = all.filter {
            switch $0.resolution {
            case .missing, .ambiguous: true
            case .unique: false
            }
        }
        healthyCount = all.count - inspections.count
    }
}

private extension NoteLinkResolution {
    var isMissing: Bool {
        if case .missing = self { return true }
        return false
    }
}
