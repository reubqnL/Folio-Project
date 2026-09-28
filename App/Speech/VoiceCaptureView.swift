import SwiftUI
import FolioCore

struct VoiceCaptureView: View {
    @Bindable var session: WorkspaceSession
    @Bindable var speech: SpeechController
    @Environment(\.dismiss) private var dismiss

    private var recording: Bool { speech.machine.microphoneActive }
    private var canReview: Bool { speech.machine.phase == .review && !speech.machine.isBusy }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Voice capture").font(.title2.weight(.semibold))
                    Text("Target: \(session.capture.targetTitle) · review before AI").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Label(recording ? "MICROPHONE ON" : "Microphone off", systemImage: recording ? "mic.fill" : "mic.slash")
                    .font(.caption.weight(.semibold)).foregroundStyle(recording ? .red : .secondary)
                    .accessibilityLabel(recording ? "Microphone is active" : "Microphone is off")
            }
            HStack {
                TextField("Language tag, for example en-GB", text: Binding(get: { speech.localeIdentifier }, set: { speech.setLocale($0) }))
                    .textFieldStyle(.roundedBorder).frame(width: 240)
                    .disabled(speech.machine.isBusy || speech.starting || speech.downloading)
                Button("Check On-Device Support") { Task { await speech.checkSupport() } }
                    .disabled(speech.machine.isBusy || speech.starting || speech.checking || speech.downloading)
                if speech.checking || speech.downloading { ProgressView().controlSize(.small) }
            }
            capability
            HStack {
                Button("Record") { Task { await session.startVoiceCapture() } }
                    .buttonStyle(.borderedProminent).disabled(!speech.mayStart || session.capture.isGenerating || session.capture.isApplying)
                Button("Stop & Review") { speech.stop() }.disabled(!speech.machine.isBusy && !speech.starting)
                Button("Discard Recording") { session.discardVoiceWithConfirmation() }
                    .disabled(!speech.hasWork)
                Spacer()
                Text(String(format: "%02d:%02d", speech.machine.elapsedMilliseconds / 60_000, (speech.machine.elapsedMilliseconds / 1000) % 60))
                    .font(.title3.monospacedDigit())
            }
            Text("Folio stops capture if it loses focus, the input changes, the Mac sleeps, or you close this recorder. No audio file is saved by Folio and there is no cloud-transcription fallback.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            if canReview {
                Text("Correct the transcript before using it").font(.headline)
                TextEditor(text: Binding(get: { speech.machine.transcript }, set: { speech.editTranscript($0) }))
                    .font(.system(size: 15)).frame(minHeight: 210)
                    .accessibilityLabel("Editable transcript awaiting human review")
                Text("Check words, names, punctuation and speaker ambiguity. This build does not perform speaker identification or claim confidence scores.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("LIVE TRANSCRIPT · NOT APPLIED").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(speech.machine.finalizedText).frame(maxWidth: .infinity, alignment: .leading)
                            if !speech.machine.volatileText.isEmpty {
                                Text(speech.machine.volatileText).foregroundStyle(.secondary)
                                Text("Provisional words may change.").font(.caption2).foregroundStyle(.secondary)
                            }
                        }.textSelection(.enabled)
                    }.frame(minHeight: 210)
                }
            }
            if !speech.machine.warnings.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(speech.machine.warnings, id: \.self) { Text("• " + $0).font(.caption).foregroundStyle(.orange) }
                    if canReview {
                        Toggle("I reviewed the text and understand that this recording may be incomplete", isOn: $speech.acknowledgesIncomplete)
                            .font(.caption)
                    }
                }
            }
            Text(speech.status).font(.caption).foregroundStyle(.secondary)
            if let failure = speech.failure { Text(failure).font(.caption).foregroundStyle(.orange).lineLimit(4) }
            HStack {
                Button("Close Recorder") { speech.haltForDisappearance(); dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Use Reviewed Transcript") { session.useReviewedVoice() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canReview || speech.machine.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (speech.machine.needsPartialAcknowledgement && !speech.acknowledgesIncomplete))
            }
            Text("The transcript is memory-only until you explicitly move it to Capture and later apply a reviewed proposal. Generation does not start when this button is pressed.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(24).frame(width: 810, height: 760)
        .onDisappear { speech.haltForDisappearance() }
    }
    @ViewBuilder private var capability: some View {
        switch speech.capability {
        case .ready(let locale):
            Label("Local language assets ready: \(locale)", systemImage: "checkmark.circle").font(.callout)
        case .needsAssets(let locale):
            HStack {
                Text("Apple language assets are needed for \(locale).").font(.caption)
                Button("Download Assets…") { Task { await speech.requestAssetDownload() } }
                    .disabled(speech.downloading || speech.machine.isBusy)
            }
        case .downloading(let locale):
            Text("macOS is downloading or waiting to download \(locale). Check again later; recording will not begin automatically.")
                .font(.caption).foregroundStyle(.secondary)
        case .unavailable(let reason):
            Text(reason + " You can continue using typed text.").font(.caption).foregroundStyle(.secondary)
        }
    }
}
