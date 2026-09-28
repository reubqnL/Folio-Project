import Foundation
import FolioCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private actor SpeechFixtureModel: CaptureTextProvider {
    nonisolated let displayName = "Fixed speech-workflow fixture — not inference"
    private(set) var calls: [CaptureModelInput] = []
    func availability() async -> CaptureProviderAvailability { .available }
    func generate(_ input: CaptureModelInput) async throws -> String {
        calls.append(input); return "## Reviewed voice fixture\n- Review the design locally.\n"
    }
}

/// Synthetic PCM and transcript events, never actual microphone/ASR. Real file
/// persistence is used only after explicit transcript and capture approval.
@main
struct SpeechProbe {
    static func main() async {
        do { try await run() }
        catch { FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1) }
    }
    static func run() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("folio-speech-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await PlainVaultStore.open(at: root, createIfMissing: true)
        guard case .written(let note) = try await store.createNote(title: "Voice target", folder: "Notes", markdown: "# Existing private note\nPRIVATE_NOT_IN_CONTEXT\n") else { throw Failure.failed("Fixture note creation") }
        let workspace = CaptureWorkspace(projectID: note.projectID, rootIdentity: note.rootIdentity, sessionID: UUID())
        let binding = CaptureDocumentBinding(workspace: workspace, noteID: note.note.id, editorID: UUID())
        var draft = CaptureDraft(target: binding)
        var voice = SpeechCaptureMachine(), checks: [String] = []
        do { _ = try SpeechAssetConsent.approve(capability: .needsAssets(locale: "en-GB"), displayedLocale: "en-GB", userConfirmedDownload: false); throw Failure.failed("Implicit download consent") }
        catch VoiceError.consentRequired { }
        checks.append("Language-asset download requires an independent explicit consent")
        let run = try voice.begin(binding: .init(draft: draft), capability: .ready(locale: "en-GB"), permission: .notDetermined, profile: .balanced, userPressedRecord: true)
        try require(!voice.mayStartMicrophone(runID: run.id) && !voice.microphoneActive, "Permission gate")
        _ = try voice.permissionResolved(runID: run.id, result: .granted)
        try require(voice.mayStartMicrophone(runID: run.id), "Permission authorisation")
        checks.append("Recording preparation cannot bypass the microphone-permission state")
        try voice.microphoneDidStart(runID: run.id)

        let queue = try PCMFrameQueue(channels: 1, maximumFrames: 512, slots: 4)
        var received = [Float](repeating: 0, count: 512)
        for block in 0..<100 {
            let samples = (0..<256).map { Float(sin(Double(block * 256 + $0) * 0.02)) * 0.1 }
            try require(queue.offer(samples: samples, frames: 256) == .accepted, "PCM push")
            let frames = try received.withUnsafeMutableBufferPointer { try queue.read(into: $0) }
            try require(frames == 256 && Array(received.prefix(256)) == samples, "PCM copy")
        }
        queue.closeInput(); try require(queue.isDrained, "PCM drain"); try queue.scrubAfterStopped()
        checks.append("100 generated PCM chunks pass through the bounded queue without borrowed-buffer corruption")
        try voice.accept(.init(startMilliseconds: 0, endMilliseconds: 1500, text: "Review a wrong phrase", isFinal: false), runID: run.id)
        try voice.accept(.init(startMilliseconds: 0, endMilliseconds: 1600, text: "Review the design", isFinal: true), runID: run.id)
        try voice.accept(.init(startMilliseconds: 1600, endMilliseconds: 2100, text: "locally.", isFinal: false), runID: run.id)
        try require(voice.transcript == "Review the design locally.", "Hypothesis replacement")
        checks.append("Volatile hypotheses are replaced rather than duplicated in the transcript")
        try voice.requestStop(runID: run.id, discard: false)
        try require(voice.microphoneActive, "No false microphone-off indicator")
        try voice.microphoneDidStop(runID: run.id)
        try require(!voice.microphoneActive && voice.resourcesHeld, "Analyzer still owns resources")
        try voice.providerDidClose(runID: run.id)
        checks.append("Stop request, microphone-off acknowledgement and analyzer closure are distinct states")
        do { _ = try voice.approveForUse(expectedRevision: voice.reviewRevision, acknowledgesIncomplete: false); throw Failure.failed("Partial result silently approved") }
        catch VoiceError.partialAcknowledgementRequired { }
        checks.append("A provisional tail requires explicit incomplete-transcript acknowledgement")
        let old = voice.reviewRevision
        try voice.editTranscript("Review the design locally after checking each word.")
        do { _ = try voice.approveForUse(expectedRevision: old, acknowledgesIncomplete: true); throw Failure.failed("Stale transcript review") }
        catch VoiceError.staleReview { }
        let reviewed = try voice.approveForUse(expectedRevision: voice.reviewRevision, acknowledgesIncomplete: true)
        checks.append("Manual correction invalidates the earlier transcript review identity")
        var changedCapture = draft; changedCapture.editInput("New typed input", kind: .typed)
        do { try changedCapture.importReviewedVoice(reviewed); throw Failure.failed("Retargeted voice overwrite") }
        catch VoiceError.staleReview { }
        checks.append("Reviewed speech cannot overwrite a changed capture draft")
        try draft.importReviewedVoice(reviewed)
        try require(draft.transcriptIsConfirmed && draft.sourceKind == .transcript, "Reviewed transcript import")
        let untouched = try await store.readNote(id: note.note.id)
        try require(untouched.bytes == note.bytes, "Transcription modified the note")
        checks.append("Using a reviewed transcript still does not generate AI or write the target note")
        let target = try CaptureTargetSnapshot(binding: binding, generation: 1, text: note.markdown)
        let prepared = try CapturePreparation.prepare(draft, target: target, profile: .balanced)
        let model = SpeechFixtureModel(), broker = CaptureBroker(provider: model)
        let proposal = try await broker.generate(prepared)
        let calls = await model.calls
        try require(calls.count == 1 && !calls[0].payloadJSON.contains("PRIVATE_NOT_IN_CONTEXT"), "Explicit model context")
        checks.append("Only the approved transcript enters the fixture model; unselected note text stays outside")
        let edit = try proposal.plan(.init(proposalID: proposal.id, selection: .wholeDraft), current: target)
        guard case .written(let saved) = try await store.save(note, markdown: edit.resultingText) else { throw Failure.failed("Approved storage write") }
        try require(saved.markdown.hasPrefix(note.markdown), "Original note preserved")
        checks.append("A separately approved capture edit reaches the real journalled note store")
        try voice.resetAfterClosed()
        do { try voice.accept(.init(startMilliseconds: 0, endMilliseconds: 100, text: "late callback", isFinal: true), runID: run.id); throw Failure.failed("Late callback retained") }
        catch VoiceError.staleRun { }
        checks.append("Reset session rejects late transcription events from the old run")
        await store.close()
        let report: [String: Any] = [
            "status": "PASS", "check_count": checks.count, "checks": checks,
            "platform": ProcessInfo.processInfo.operatingSystemVersionString,
            "synthetic_audio": true, "live_microphone": false, "live_speech_recognition": false, "live_model_inference": false,
            "scope": "Generated PCM/transcript events; actual lifecycle, consent, reviewed capture and temporary vault store",
            "not_proven": ["Mac TCC microphone permission", "AVAudioEngine/tap/conversion lifecycle", "SpeechAnalyzer assets/results/accuracy", "real-time callback performance", "native UI/accessibility", "independent security approval"]
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        if CommandLine.arguments.count > 1 { try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1])) }
        print(String(decoding: data, as: UTF8.self))
    }
    enum Failure: Error, LocalizedError {
        case failed(String)
        var errorDescription: String? { if case .failed(let value) = self { return value }; return nil }
    }
    static func require(_ value: Bool, _ label: String) throws { if !value { throw Failure.failed(label) } }
}
