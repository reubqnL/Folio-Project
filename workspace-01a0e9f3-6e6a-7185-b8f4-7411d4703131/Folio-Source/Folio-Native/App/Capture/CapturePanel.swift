import SwiftUI
import FolioCore

struct CapturePanel: View {
    @Bindable var session: WorkspaceSession
    @Bindable var capture: CaptureController
    @State private var contextPicker = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Label("Capture & review", systemImage: "sparkles").font(.headline)
                Text("Local model · no application tools").font(.caption).foregroundStyle(FolioStyle.gold)
                if capture.draft == nil {
                    Text("Open a note, then start a capture. No note content or linked material is included automatically.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Start for Current Note") { session.beginCaptureForCurrentNote() }
                        .disabled(session.selectedDocument == nil || session.isOpening)
                } else {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("TARGET NOTE").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                            Text(capture.targetTitle).font(.callout.weight(.semibold)).lineLimit(2)
                        }
                        Spacer()
                        Button("New") { session.beginCaptureForCurrentNote() }.controlSize(.small)
                            .disabled(capture.isGenerating || capture.isApplying || session.speech.blocksCaptureChanges)
                    }
                    Picker("Input kind", selection: Binding(get: { capture.sourceKind }, set: { capture.editInput(capture.input, kind: $0) })) {
                        Text("Text").tag(CaptureSourceKind.typed)
                        Text("Transcript").tag(CaptureSourceKind.transcript)
                    }.pickerStyle(.segmented).disabled(capture.isGenerating || capture.isApplying || session.speech.blocksCaptureChanges)
                    TextEditor(text: Binding(get: { capture.input }, set: { capture.editInput($0) }))
                        .font(.system(size: 13)).frame(minHeight: 130)
                        .disabled(capture.isGenerating || capture.isApplying || session.speech.blocksCaptureChanges)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.white.opacity(0.1)))
                        .accessibilityLabel("Capture input, not yet applied to a note")
                    Button("Use Current Selection as Input") { session.useSelectionAsCaptureInput() }
                        .controlSize(.small).disabled(capture.isGenerating || capture.isApplying || session.speech.blocksCaptureChanges)
                    if capture.sourceKind == .transcript {
                        Text("Correct a pasted transcript or explicitly open Voice Capture. Nothing is restructured until you confirm the transcript.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("Voice Capture…") { session.openVoiceRecorder() }
                            .disabled(capture.isGenerating || capture.isApplying)
                        if session.speech.isMicrophoneActive { Label("Mic on", systemImage: "mic.fill").font(.caption).foregroundStyle(.red) }
                    }
                    Divider()
                    HStack {
                        Text("INCLUDED CONTEXT · \(capture.context.count)").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        Spacer()
                        Button { contextPicker = true } label: { Image(systemName: "plus") }
                            .buttonStyle(.plain).accessibilityLabel("Explicitly add a note to model context")
                            .disabled(capture.isGenerating || capture.isApplying || session.speech.blocksCaptureChanges)
                            .popover(isPresented: $contextPicker) { CaptureContextPicker(session: session, presented: $contextPicker) }
                    }
                    Text("These are frozen snapshots. Remove/re-add to include newer text; no hidden context expansion.")
                        .font(.caption2).foregroundStyle(.secondary)
                    ForEach(capture.context) { fragment in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Label(fragment.title, systemImage: "doc.text").font(.caption.weight(.medium))
                                Spacer()
                                Button { capture.removeContext(fragment.id) } label: { Image(systemName: "minus.circle") }
                                    .buttonStyle(.plain).disabled(capture.isGenerating || capture.isApplying || session.speech.blocksCaptureChanges)
                                    .accessibilityLabel("Remove \(fragment.title) from context")
                            }
                            Text(fragment.range == nil ? "Whole note snapshot" : "Selected excerpt only").font(.caption2).foregroundStyle(FolioStyle.gold)
                            DisclosureGroup("Inspect exact text") {
                                Text(CaptureOutputValidation.visibleText(fragment.text)).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                            }.font(.caption)
                        }.padding(9).background(Color.white.opacity(0.035)).clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                    Button("Add Current Selection as Context") { session.addCurrentSelectionToCaptureContext() }
                        .controlSize(.small).disabled(capture.isGenerating || capture.isApplying || session.speech.blocksCaptureChanges)
                    Divider()
                    Text("APPLICATION TARGET").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    Menu(destinationLabel) {
                        Button("Append to the note") { session.setCaptureDestination(0) }
                        Button("Replace the current source selection") { session.setCaptureDestination(1) }
                        Button("Revise the note body; preserve front matter") { session.setCaptureDestination(2) }
                    }.disabled(capture.isGenerating || capture.isApplying || session.speech.blocksCaptureChanges)
                    if case .selection = capture.draft?.destination {
                        Button("Refresh Target Selection") { session.setCaptureDestination(1) }.controlSize(.small)
                            .disabled(capture.isGenerating || capture.isApplying || session.speech.blocksCaptureChanges)
                    }
                    if capture.sourceKind == .transcript {
                        Button(capture.transcriptConfirmed ? "Transcript confirmed" : "Confirm Reviewed Transcript") { capture.confirmTranscript() }
                            .disabled(capture.transcriptConfirmed || capture.isGenerating || capture.input.isEmpty)
                        Text("Changing input, destination or context requires a fresh confirmation.").font(.caption2).foregroundStyle(.secondary)
                    }
                    Button("Inspect Request Before Generation") { session.inspectCaptureRequest() }
                        .controlSize(.small).disabled(capture.isGenerating || capture.isApplying || session.speech.blocksCaptureChanges)
                    if let prepared = capture.preparedRequest {
                        DisclosureGroup("Exact request data") {
                            Text(CaptureOutputValidation.visibleText(prepared.modelInput.payloadJSON)).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                        }.font(.caption)
                        Text("\(prepared.modelInput.payloadJSON.utf8.count) request-data bytes · output ceiling \(prepared.budget.maximumOutputTokens) tokens")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Divider()
                providerStatus
                HStack {
                    Button("Check Local Model") { Task { await capture.checkAvailability() } }
                        .controlSize(.small).disabled(capture.isGenerating)
                    Spacer()
                    if capture.isGenerating { Button("Cancel") { capture.cancel() }.controlSize(.small) }
                }
                if capture.draft != nil {
                    Button(capture.isGenerating ? "Generating…" : "Generate Draft") { session.generateCapture() }
                        .buttonStyle(.borderedProminent)
                        .disabled(capture.isGenerating || capture.isApplying || session.speech.blocksCaptureChanges || capture.isCancelling || capture.input.isEmpty || !capture.transcriptConfirmed || capture.availability != .available)
                    if capture.proposal != nil {
                        Button("Review Draft…") { capture.presentReview() }.disabled(capture.isApplying)
                        if capture.targetChanged { Text("The note changed. Compare against its current version before applying.").font(.caption).foregroundStyle(.orange) }
                    }
                    if capture.undoReceipt != nil {
                        Button("Undo Capture Change") { session.undoCaptureChange() }.disabled(capture.isApplying)
                            .help("Only available if no newer text edit intervened. Native Undo remains available.")
                    }
                }
                Text(capture.status).font(.caption).foregroundStyle(.secondary)
                if let failure = capture.failure { Text(failure).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
                Text("Capture input and proposals are memory-only until applied. Model output may be inaccurate or cut short by its token ceiling. Always review it.")
                    .font(.caption2).foregroundStyle(.secondary)
            }.padding(16)
        }.background(FolioStyle.sidebar)
    }
    private var destinationLabel: String {
        switch capture.draft?.destination {
        case .append: "Append to note"
        case .selection: "Replace chosen selection"
        case .body: "Revise body; keep front matter"
        case .none: "Choose a target"
        }
    }
    @ViewBuilder private var providerStatus: some View {
        if capture.isGenerating { ProgressView().controlSize(.small) }
        switch capture.availability {
        case .available: Label("Apple on-device model is available", systemImage: "desktopcomputer").font(.caption)
        case .unavailable(let reason): Text(reason).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct CaptureContextPicker: View {
    @Bindable var session: WorkspaceSession
    @Binding var presented: Bool
    @State private var filter = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add explicit note context").font(.headline)
            Text("Only the selected note is read. Oversized notes are rejected rather than silently truncated.").font(.caption).foregroundStyle(.secondary)
            TextField("Filter note titles or paths", text: $filter).textFieldStyle(.roundedBorder)
            List(session.notes.filter { filter.isEmpty || $0.relativePath.localizedStandardContains(filter) }) { note in
                Button {
                    presented = false
                    Task { await session.addNoteToCaptureContext(note.id) }
                } label: {
                    VStack(alignment: .leading) { Text(note.title); Text(note.relativePath).font(.caption2).foregroundStyle(.secondary) }
                }.buttonStyle(.plain)
            }
        }.padding(18).frame(width: 450, height: 430)
    }
}
