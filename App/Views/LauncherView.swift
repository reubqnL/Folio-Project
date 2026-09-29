import SwiftUI

struct LauncherView: View {
    @Bindable var session: WorkspaceSession
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(spacing: 26) {
            Spacer(minLength: 24)
            Image("FolioLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 104, height: 104)
                .accessibilityLabel("Folio")
            VStack(spacing: 11) {
                Text("A PLACE FOR WHAT COMES NEXT")
                    .font(.system(size: 10, weight: .semibold)).tracking(2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("Good ideas deserve a place.")
                    .font(.system(size: 34, weight: .semibold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .multilineTextAlignment(.center)
                Text("Write freely. Connect the dots. Make a plan.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 18) {
                moduleCard(
                    title: "FolioNotes", symbol: "book.closed",
                    subtitle: "Your notes, connections and roadmaps.",
                    badge: "Plain local projects", enabled: true
                ) { session.destination = .notes }
                moduleCard(
                    title: "Encrypted .rdm", symbol: "lock.doc",
                    subtitle: "Authenticated encrypted projects with local working drafts.",
                    badge: "Experimental", enabled: true
                ) {
                    if session.project == nil { session.openEncryptedWorkspace() }
                    else { session.preparePlainProjectForEncryptedCopy() }
                }
                moduleCard(
                    title: "FolioDev", symbol: "chevron.left.forwardslash.chevron.right",
                    subtitle: "Connect the plan to the code. Coming later.",
                    badge: "Unavailable", enabled: false
                ) {}
            }
            .frame(maxWidth: 1120)
            VStack(spacing: 6) {
                Text("Native development build · Increment 09")
                    .font(.caption).foregroundStyle(FolioStyle.gold)
                Text("Notes, planning, connections and reviewed capture are in development. Encrypted .rdm is an experimental preview with persistent local working drafts; native AI/speech execution and collaboration still need validation or implementation.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 24)
            Text("Local first  ·  Markdown underneath  ·  Made for Mac")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(36)
    }

    private func moduleCard(
        title: String, symbol: String, subtitle: String,
        badge: String, enabled: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 17) {
                HStack {
                    Image(systemName: symbol).font(.system(size: 22))
                    Spacer()
                    Text(badge).font(.caption)
                }
                .foregroundStyle(enabled ? FolioStyle.gold : .secondary)
                Text(title).font(.system(size: 23, weight: .semibold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
                    .fixedSize(horizontal: false, vertical: true)
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(24)
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 170, alignment: .leading)
            .background(enabled ? FolioStyle.gold.opacity(0.045) : Color.white.opacity(0.02))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(enabled ? FolioStyle.gold.opacity(contrast == .increased ? 1 : 0.5) : .white.opacity(contrast == .increased ? 0.5 : 0.1)))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
        .accessibilityLabel(title)
        .accessibilityHint(enabled ? "Open FolioNotes and choose a local project folder" : "Unavailable in the initial release")
    }
}
