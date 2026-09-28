import Foundation
import Observation
import FolioCore

@MainActor
@Observable
final class CaptureController {
    var draft: CaptureDraft?
    var targetTitle = ""
    var proposal: CaptureProposal?
    var reviewMode: AIReviewMode?
    var selectedSections = Set<String>()
    var selectedChanges = Set<String>()
    var acknowledgesWarnings = false
    var isGenerating = false
    var isCancelling = false
    var isApplying = false
    var targetChanged = false
    var showingReview = false
    var showingComposer = false
    var showingContextPicker = false
    var availability: CaptureProviderAvailability = .unavailable("Not checked. No request has been made.")
    var status = "Capture stays local and unapplied until you review it."
    var failure: String?
    var preparedRequest: PreparedCapture?
    var undoReceipt: CaptureUndoReceipt?
    @ObservationIgnored private let broker = CaptureBroker(provider: AppleCaptureProvider())
    @ObservationIgnored private var job: Task<Void, Never>?
    @ObservationIgnored private var activeRequestID: UUID?
    @ObservationIgnored private var epoch = UUID()
    @ObservationIgnored private var appliedDraftRevision: UUID?
    @ObservationIgnored private var reviewAfterComposer = false

    var hasWork: Bool {
        if isGenerating || isApplying { return true }
        guard let draft else { return false }
        return !draft.input.isEmpty && appliedDraftRevision != draft.revision || proposal != nil
    }
    var context: [CaptureContextFragment] { draft?.contexts ?? [] }
    var input: String { draft?.input ?? "" }
    var sourceKind: CaptureSourceKind { draft?.sourceKind ?? .typed }
    var transcriptConfirmed: Bool { draft?.transcriptIsConfirmed ?? false }

    func begin(target: CaptureTargetSnapshot, title: String) {
        cancel()
        epoch = UUID(); draft = CaptureDraft(target: target.binding); targetTitle = title
        proposal = nil; preparedRequest = nil; undoReceipt = nil; appliedDraftRevision = nil
        resetReview(); failure = nil; targetChanged = false
        status = "No context is added automatically. Generate sends only the visible input and context snapshots to the local provider."
    }
    func editInput(_ value: String, kind: CaptureSourceKind? = nil) {
        guard !isGenerating, !isApplying, var valueDraft = draft else { return }
        valueDraft.editInput(value, kind: kind ?? valueDraft.sourceKind)
        draft = valueDraft; invalidateProposal()
    }
    func setDestination(_ value: CaptureDestination, target: CaptureTargetSnapshot) {
        guard !isGenerating, !isApplying, var current = draft else { return }
        current.setDestination(value, target: target); draft = current; invalidateProposal()
    }
    func confirmTranscript() {
        guard var current = draft else { return }
        do { try current.confirmTranscript(); draft = current; failure = nil }
        catch { failure = error.localizedDescription }
    }
    func addContext(_ value: CaptureContextFragment, target: CaptureTargetSnapshot, profile: SearchProfile) {
        guard !isGenerating, !isApplying, var candidate = draft else { return }
        do {
            try candidate.addContext(value)
            // Context is checked before replacing the approved visible list. A
            // transcript confirmation can be supplied later; no text is sent here.
            let budget = CaptureBudget(profile: profile)
            let count = candidate.contexts.reduce(0) { $0 + $1.text.utf8.count + $1.title.utf8.count }
            guard count <= budget.maximumContextBytes else { throw CaptureError.oversizedContext }
            guard candidate.target == target.binding else { throw CaptureError.wrongTarget }
            draft = candidate; invalidateProposal(); failure = nil
        } catch { failure = error.localizedDescription }
    }
    func removeContext(_ id: UUID) {
        guard !isGenerating, !isApplying, var current = draft else { return }
        current.removeContext(id); draft = current; invalidateProposal()
    }
    func permitsVoiceRecording() async -> Bool {
        let state = await broker.status
        if state == .idle { isCancelling = false }
        return state == .idle && !isGenerating && !isApplying
    }
    func importReviewedVoice(_ voice: ReviewedVoiceTranscript) throws {
        guard !isGenerating, !isApplying, var current = draft else { throw VoiceError.busy }
        try current.importReviewedVoice(voice)
        draft = current; invalidateProposal(); appliedDraftRevision = nil; undoReceipt = nil
        status = "Reviewed transcript imported into Capture. Generation has not started."
    }
    func checkAvailability() async {
        let state = await broker.status
        if case .cancelling = state {
            isCancelling = true; status = "Cancellation is still in progress. No second model job will be started."; return
        }
        isCancelling = false
        availability = await broker.availability()
    }
    func generate(target: CaptureTargetSnapshot, profile: SearchProfile) {
        guard !isGenerating, !isApplying, let draft else { return }
        do {
            let prepared = try CapturePreparation.prepare(draft, target: target, profile: profile)
            epoch = UUID(); let token = epoch
            preparedRequest = prepared; activeRequestID = prepared.id
            proposal = nil; resetReview(); failure = nil; undoReceipt = nil; targetChanged = false
            isGenerating = true; status = "Generating an unapplied draft with explicit context…"
            job = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let result = try await self.broker.generate(prepared)
                    guard token == self.epoch, self.draft?.revision == prepared.draftRevision, !Task.isCancelled else { return }
                    self.proposal = result; self.isGenerating = false; self.activeRequestID = nil
                    self.status = "Draft ready for your review. No note has changed."
                } catch {
                    guard token == self.epoch else { return }
                    self.isGenerating = false; self.activeRequestID = nil
                    if error is CancellationError { self.status = "Cancelled. Nothing was applied." }
                    else { self.failure = error.localizedDescription; self.status = "Request stopped. Input and explicit context remain available." }
                    await self.checkAvailability()
                }
            }
        } catch { failure = error.localizedDescription }
    }
    func cancel() {
        let hadActiveRequest = activeRequestID != nil
        if let id = activeRequestID {
            let broker = broker
            Task { await broker.cancel(requestID: id) }
        }
        job?.cancel(); job = nil; epoch = UUID(); activeRequestID = nil
        isGenerating = false
        status = "Cancellation requested. Late output will not be applied."
        if hadActiveRequest { Task { @MainActor [weak self] in await self?.checkAvailability() } }
    }
    func clear() {
        cancel(); draft = nil; proposal = nil; preparedRequest = nil; undoReceipt = nil
        targetTitle = ""; appliedDraftRevision = nil; failure = nil; resetReview()
    }
    func targetEdited(binding: CaptureDocumentBinding, generation: Int) {
        guard let expected = proposal?.target ?? preparedRequest?.target, expected.binding == binding else { return }
        if expected.generation != generation { targetChanged = true }
    }
    func compareCurrent(_ target: CaptureTargetSnapshot, explicitSelection: SourceSpan? = nil) {
        guard !isApplying, let proposal else { return }
        do {
            self.proposal = try proposal.comparingCurrent(target, newSelection: explicitSelection)
            targetChanged = false; resetReview(); failure = nil
            status = "Comparing the original model draft with the current note. Old approvals were cleared; approve again."
        } catch { failure = error.localizedDescription }
    }
    @discardableResult
    func editOutput(_ text: String) -> Bool {
        guard !isApplying, let proposal else { return false }
        do { self.proposal = try proposal.editingOutput(text); resetReview(); failure = nil; return true }
        catch { failure = error.localizedDescription; return false }
    }
    func presentReview() {
        guard proposal != nil else { return }
        if showingComposer { reviewAfterComposer = true; showingComposer = false }
        else { showingReview = true }
    }
    func composerDismissed() {
        if reviewAfterComposer { reviewAfterComposer = false; showingReview = true }
    }
    func approval() throws -> CaptureApproval {
        guard let proposal, let mode = reviewMode else { throw CaptureError.emptyApproval }
        let choice: CaptureApprovalSelection
        switch mode {
        case .wholeDraft: choice = .wholeDraft
        case .sections: choice = .sections(selectedSections)
        case .detailedComparison: choice = .changes(selectedChanges)
        }
        return .init(proposalID: proposal.id, selection: choice, acknowledgesWarnings: acknowledgesWarnings)
    }
    func didApply(_ edit: CaptureTextEdit, target: CaptureTargetSnapshot) {
        isApplying = false
        do {
            undoReceipt = try .init(edit: edit, applied: target)
            appliedDraftRevision = draft?.revision
            proposal = nil; preparedRequest = nil; showingReview = false; targetChanged = false
            status = "Applied to the native editor. Normal local saving still has to succeed; this is not a disk-save acknowledgement."
            failure = nil; resetReview()
        } catch { failure = error.localizedDescription }
    }
    func didUndo() {
        isApplying = false; undoReceipt = nil; failure = nil
        status = "Capture change reverted in the editor. Normal local saving still applies."
    }
    func mutationFailed(_ message: String) { isApplying = false; failure = message; targetChanged = true }
    func resetReview() { reviewMode = nil; selectedSections = []; selectedChanges = []; acknowledgesWarnings = false }
    private func invalidateProposal() { proposal = nil; preparedRequest = nil; resetReview(); failure = nil }
}
