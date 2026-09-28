import Foundation
import FolioCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private actor FixtureProvider: CaptureTextProvider {
    nonisolated let displayName = "Fixed integration fixture — not AI inference"
    private(set) var received: [CaptureModelInput] = []
    func availability() async -> CaptureProviderAvailability { .available }
    func generate(_ request: CaptureModelInput) async throws -> String {
        received.append(request)
        return "## Summary\nReview the local design.\n\n## Actions\n- Inspect the selected plan.\n"
    }
}

/// Generated-data workflow check. This executable proves core capture/review
/// behaviour, not Foundation Models inference or native NSTextView undo.
@main
struct CaptureProbe {
    static func main() async {
        do { try await run() }
        catch { FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1) }
    }
    static func run() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("folio-capture-probe-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await PlainVaultStore.open(at: root, createIfMissing: true)
        let original = try written(try await store.createNote(title: "Capture target", folder: "Notes",
            markdown: "---\nid: PRIVATE_TARGET_METADATA\n---\nMy existing writing.\n"))
        let related = try written(try await store.createNote(title: "Context source", folder: "Notes",
            markdown: "Selected plan. PRIVATE_UNSELECTED_CONTEXT_CANARY"))
        let workspace = CaptureWorkspace(projectID: original.projectID, rootIdentity: original.rootIdentity, sessionID: UUID())
        let binding = CaptureDocumentBinding(workspace: workspace, noteID: original.note.id, editorID: UUID())
        let target = try CaptureTargetSnapshot(binding: binding, generation: 1, text: original.markdown)
        var draft = CaptureDraft(target: binding)
        draft.editInput("Review the local design and inspect the selected plan.", kind: .transcript)
        let context = try CaptureContextFragment(workspace: workspace, noteID: related.note.id, title: related.note.title,
            source: related.markdown, range: .init(location: 0, length: "Selected plan.".utf16.count))
        try draft.addContext(context)
        let provider = FixtureProvider(), broker = CaptureBroker(provider: provider)
        var checks: [String] = []
        do { _ = try CapturePreparation.prepare(draft, target: target, profile: .balanced); throw Failure.failed("Unconfirmed transcript was accepted") }
        catch CaptureError.transcriptNotConfirmed { }
        checks.append("Transcript restructuring blocked until explicit confirmation")
        try draft.confirmTranscript()
        let request = try CapturePreparation.prepare(draft, target: target, profile: .balanced)
        try require(!request.modelInput.payloadJSON.contains("PRIVATE_TARGET_METADATA"), "Target body leaked into request")
        try require(!request.modelInput.payloadJSON.contains("PRIVATE_UNSELECTED_CONTEXT_CANARY"), "Unselected context leaked")
        checks.append("Only explicit input and selected context were serialized; unselected canaries absent")
        let proposal = try await broker.generate(request)
        let calls = await provider.received
        try require(calls.count == 1 && calls[0].requestDigest == request.modelInput.requestDigest, "Provider request boundary")
        checks.append("Text-only provider received the inspected request, with no application tool capability")
        let unchanged = try await store.readNote(id: original.note.id)
        try require(unchanged.bytes == original.bytes, "Generation changed the file")
        checks.append("Generation and proposal creation left the actual note bytes unchanged")

        // Simulate the owner continuing to write while a proposal awaits review.
        let currentSaved = try written(try await store.save(original, markdown: original.markdown + "New writing while the draft waits.\n"))
        let current = try CaptureTargetSnapshot(binding: binding, generation: 2, text: currentSaved.markdown)
        let oldApproval = CaptureApproval(proposalID: proposal.id, selection: .wholeDraft)
        do { _ = try proposal.plan(oldApproval, current: current); throw Failure.failed("Stale proposal applied") }
        catch CaptureError.staleTarget { }
        checks.append("Stale review could not overwrite the owner's newer writing")
        let compared = try proposal.comparingCurrent(current)
        do { _ = try compared.plan(oldApproval, current: current); throw Failure.failed("Approval reused after rebase") }
        catch CaptureError.invalidApproval { }
        checks.append("Explicit comparison issued a new review identity and invalidated the old approval")
        guard let section = compared.sections.first(where: { $0.title == "Actions" }) else { throw Failure.failed("Missing fixture section") }
        let approval = CaptureApproval(proposalID: compared.id, selection: .sections([section.id]))
        let edit = try compared.plan(approval, current: current)
        try edit.validate(current: current)
        try require(edit.resultingText.hasPrefix(current.text), "New writing was lost")
        try require(!edit.resultingText.contains("## Summary"), "Unapproved section was applied")
        checks.append("Section approval kept newer writing and excluded the unselected section")
        let saved = try written(try await store.save(currentSaved, markdown: edit.resultingText))
        try require(saved.markdown.contains("PRIVATE_TARGET_METADATA"), "Original front matter changed")
        checks.append("Approved core edit passed through the real journalled store without changing front matter")
        let actual = try CaptureTargetSnapshot(binding: binding, generation: 3, text: saved.markdown)
        let receipt = try CaptureUndoReceipt(edit: edit, applied: actual)
        let newer = try CaptureTargetSnapshot(binding: binding, generation: 4, text: saved.markdown + "even newer")
        do { _ = try receipt.inverse(current: newer); throw Failure.failed("Stale undo accepted") }
        catch CaptureError.staleUndo { }
        checks.append("Stale undo could not delete intervening writing")
        let inverse = try receipt.inverse(current: actual)
        let restored = try written(try await store.save(saved, markdown: inverse.resultingText))
        try require(restored.bytes == currentSaved.bytes, "Undo did not restore exact reviewed base bytes")
        checks.append("Validated undo restored the exact current-before-apply bytes through real storage")
        await store.close()
        let reopened = try await PlainVaultStore.open(at: root)
        _ = try await reopened.recover()
        let persisted = try await reopened.readNote(id: restored.note.id)
        try require(persisted.bytes == currentSaved.bytes, "Reopen changed capture result")
        await reopened.close()
        checks.append("Reopening retained the final acknowledged bytes and stable note identity")

        let report: [String: Any] = [
            "status": "PASS", "platform": ProcessInfo.processInfo.operatingSystemVersionString,
            "check_count": checks.count, "checks": checks,
            "provider": "Fixed test fixture, not an LLM", "live_model_inference": false,
            "scope": "Generated temporary vault; actual preparation/broker/review/diff/application plan and file store",
            "not_proven": ["Foundation Models SDK/runtime behaviour or model output quality", "native editor transaction/undo", "microphone or speech recognition", "Mac sandbox/APFS/performance/accessibility", "independent security review"]
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        if CommandLine.arguments.count > 1 { try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1])) }
        print(String(decoding: data, as: UTF8.self))
    }
    enum Failure: Error, LocalizedError {
        case failed(String)
        var errorDescription: String? { if case .failed(let text) = self { return text }; return nil }
    }
    static func written(_ value: VaultSaveResult) throws -> VaultSnapshot {
        if case .written(let result) = value { return result }; throw Failure.failed("Unexpected fixture conflict")
    }
    static func require(_ value: Bool, _ reason: String) throws { if !value { throw Failure.failed(reason) } }
}
