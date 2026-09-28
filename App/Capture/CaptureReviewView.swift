import SwiftUI
import FolioCore

struct CaptureReviewView: View {
    @Bindable var session: WorkspaceSession
    @Bindable var capture: CaptureController
    @Environment(\.dismiss) private var dismiss
    @State private var editedOutput = ""
    @State private var editingDraft = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Review capture proposal").font(.title2.weight(.semibold))
                    Text("Target: \(capture.targetTitle) · no automatic application").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if capture.isApplying { ProgressView().controlSize(.small) }
            }
            if let proposal = capture.proposal {
                if capture.targetChanged || proposal.comparesNewerTarget {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(capture.targetChanged ? "The note changed after generation/review." : "You are comparing an older model draft with the current note.")
                            .font(.callout.weight(.medium)).foregroundStyle(.orange)
                        Text("No old approval is carried into a new comparison. Read the current target before approving again.")
                            .font(.caption).foregroundStyle(.secondary)
                        if case .selection = proposal.destination {
                            Text("To replace a different/current selection, close this review, select it in Source, then reopen and use the button below.")
                                .font(.caption).foregroundStyle(.secondary)
                            Button("Compare Using Current Source Selection") { session.compareCaptureWithCurrent(useCurrentSelection: true) }
                        } else {
                            Button("Compare Against Current Note") { session.compareCaptureWithCurrent() }
                        }
                    }.padding(12).background(Color.orange.opacity(0.08))
                }
                Picker("Approval control", selection: Binding(get: { capture.reviewMode }, set: {
                    capture.reviewMode = $0; capture.selectedSections = []; capture.selectedChanges = []; capture.acknowledgesWarnings = false
                })) {
                    Text("Choose a review mode…").tag(AIReviewMode?.none)
                    Text("Whole draft").tag(Optional(AIReviewMode.wholeDraft))
                    Text("Individual sections").tag(Optional(AIReviewMode.sections))
                    Text("Detailed comparison").tag(Optional(AIReviewMode.detailedComparison))
                }.disabled(capture.isApplying)
                if editingDraft {
                    TextEditor(text: $editedOutput).font(.system(size: 12, design: .monospaced)).frame(minHeight: 220)
                        .disabled(capture.isApplying).accessibilityLabel("Editable proposed Markdown, not the saved note")
                    HStack {
                        Button("Validate Edited Draft") { if capture.editOutput(editedOutput) { editingDraft = false } }
                        Button("Cancel Draft Edit") { editedOutput = proposal.rawOutput; editingDraft = false }
                        Text("Editing creates a new review identity and clears approvals.").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    reviewContent(proposal).frame(maxWidth: .infinity, maxHeight: .infinity)
                    Button("Edit the Proposed Markdown…") { editedOutput = proposal.rawOutput; editingDraft = true }.controlSize(.small)
                }
                if !proposal.warnings.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(proposal.warnings, id: \.self) { Text("• " + $0).font(.caption).foregroundStyle(.orange) }
                        Toggle("I reviewed these warnings and the draft text", isOn: $capture.acknowledgesWarnings)
                            .font(.caption).disabled(capture.isApplying)
                    }.padding(10).background(Color.orange.opacity(0.06))
                }
                if let failure = capture.failure { Text(failure).font(.caption).foregroundStyle(.orange).lineLimit(4) }
                Text("Apply edits the open Source/Split editor as one native undo operation. It does not claim the file is saved until the normal save pipeline succeeds.")
                    .font(.caption2).foregroundStyle(.secondary)
                HStack {
                    Button("Close Review") { dismiss() }.keyboardShortcut(.cancelAction).disabled(capture.isApplying)
                    Spacer()
                    Button("Apply Reviewed Change") { Task { await session.applyCaptureApproval() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(capture.reviewMode == nil || capture.isApplying || capture.targetChanged || editingDraft || !canSelect(proposal))
                }
            } else {
                ContentUnavailableView("No unapplied proposal", systemImage: "checkmark.circle", description: Text("Generate a draft or close this review. Nothing is applied automatically."))
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(24).frame(width: 900, height: 760)
        .interactiveDismissDisabled(capture.isApplying)
        .onAppear { editedOutput = capture.proposal?.rawOutput ?? "" }
        .onChange(of: capture.proposal?.id) { _, _ in editedOutput = capture.proposal?.rawOutput ?? ""; editingDraft = false }
    }
    private func canSelect(_ proposal: CaptureProposal) -> Bool {
        if !proposal.warnings.isEmpty && !capture.acknowledgesWarnings { return false }
        switch capture.reviewMode {
        case .wholeDraft: return !proposal.changes.isEmpty
        case .sections:
            if case .body = proposal.destination { return false }
            return !capture.selectedSections.isEmpty
        case .detailedComparison: return !capture.selectedChanges.isEmpty
        case .none: return false
        }
    }
    @ViewBuilder private func reviewContent(_ proposal: CaptureProposal) -> some View {
        switch capture.reviewMode {
        case .wholeDraft, .none:
            HStack(alignment: .top, spacing: 14) {
                textPanel("Current target passage", proposal.beforeTarget.isEmpty ? "Append at the end; existing text stays untouched." : proposal.beforeTarget)
                textPanel("Proposed Markdown", proposal.replacement)
            }
        case .sections:
            if case .body = proposal.destination {
                ContentUnavailableView("Choose detailed comparison for body revisions", systemImage: "text.badge.checkmark", description: Text("Section approval must not silently remove unselected original sections. It supports appending or replacing a deliberately chosen selection."))
            } else {
                VStack(alignment: .leading) {
                    Text("Only checked sections will be used, joined with blank lines. The destination remains the explicitly selected append/selection target.")
                        .font(.caption).foregroundStyle(.secondary)
                    List(proposal.sections) { section in
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle(section.title, isOn: membership(section.id, in: $capture.selectedSections))
                            Text(CaptureOutputValidation.visibleText(section.text)).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        }.padding(.vertical, 6)
                    }
                }
            }
        case .detailedComparison:
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text("Unselected changes leave their original lines intact.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Select All Changes") { capture.selectedChanges = Set(proposal.changes.map(\.id)) }.controlSize(.small)
                }
                List(proposal.changes) { change in
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Change at target offset \(change.range.location)", isOn: membership(change.id, in: $capture.selectedChanges))
                        HStack(alignment: .top, spacing: 14) {
                            Text(CaptureOutputValidation.visibleText(change.before.isEmpty ? "(insert)" : change.before))
                                .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                            Text(CaptureOutputValidation.visibleText(change.after.isEmpty ? "(delete)" : change.after))
                                .foregroundStyle(FolioStyle.gold).frame(maxWidth: .infinity, alignment: .leading)
                        }.font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    }.padding(.vertical, 8)
                }
            }
        }
    }
    private func membership(_ id: String, in values: Binding<Set<String>>) -> Binding<Bool> {
        Binding(get: { values.wrappedValue.contains(id) }, set: { selected in
            if selected { values.wrappedValue.insert(id) } else { values.wrappedValue.remove(id) }
        })
    }
    private func textPanel(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            ScrollView {
                Text(CaptureOutputValidation.visibleText(text)).font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(12).frame(maxWidth: .infinity, maxHeight: .infinity).background(FolioStyle.editor)
    }
}
