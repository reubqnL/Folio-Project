import AppKit
import Foundation
import Observation
import FolioCore

/// Main-actor state for the explicit encrypted-project boundary. This is a
/// development UI adapter: it never writes a passphrase, recovery code or
/// plaintext note to disk, Keychain, clipboard, diagnostics or the plain-vault
/// search controller.
@MainActor
@Observable
final class EncryptedProjectController {
    enum Phase: Equatable {
        case idle
        case creating
        case opening
        case recoveryReview
        case unlocked
    }
    enum CredentialMode: Equatable { case passphrase, recoveryCode }

    var phase: Phase = .idle
    var credentialMode: CredentialMode = .passphrase
    var fileURL: URL?
    var project: RDMProjectPayload?
    var searchHits: [EncryptedIndexHit] = []
    var selectedNoteID: UUID?
    var editingNoteID: UUID?
    var draftPath = ""
    var draftMarkdown = ""
    var isNewDraft = false
    var isCheckpointing = false
    var query = ""
    var projectName = "Encrypted project"
    var passphrase = ""
    var confirmation = ""
    var recoveryCode = ""
    var rememberPassphrase = false
    var pendingRecoveryCode: String?
    var errorMessage: String?
    var notice: String?
    var needsWorkingReview = false

    @ObservationIgnored private var session: RDMProjectSession?
    @ObservationIgnored private var pendingCreationProject: RDMProjectPayload?
    @ObservationIgnored private var draftNoteID: UUID?
    @ObservationIgnored private var draftStageTask: Task<Void, Never>?

    var isUnlocked: Bool { phase == .unlocked || phase == .recoveryReview }
    var hasOpenSession: Bool { session != nil }
    var selectedNote: RDMNote? { project?.notes.first { $0.id == selectedNoteID } }
    var editingNote: RDMNote? { project?.notes.first { $0.id == editingNoteID } }
    var hasDraft: Bool { isNewDraft || editingNoteID != nil }
    var displayName: String { project?.name ?? fileURL?.deletingPathExtension().lastPathComponent ?? "Encrypted project" }

    func beginNewNote() {
        guard isUnlocked else { return }
        editingNoteID = nil
        isNewDraft = true
        draftNoteID = UUID()
        draftPath = "Notes/New note.md"
        draftMarkdown = ""
        errorMessage = nil
        notice = "New encrypted note is a draft. It stays in the encrypted local working copy until you choose Write encrypted checkpoint."
    }

    func beginEditingSelectedNote() {
        guard isUnlocked, let note = selectedNote else { return }
        editingNoteID = note.id
        isNewDraft = false
        draftNoteID = note.id
        draftPath = note.path
        draftMarkdown = note.markdown
        errorMessage = nil
        notice = "Draft only. It stays in the encrypted local working copy until you choose Write encrypted checkpoint."
    }

    func cancelEditing() {
        let discarded = editingNoteID ?? draftNoteID
        draftStageTask?.cancel()
        draftStageTask = nil
        editingNoteID = nil
        isNewDraft = false
        draftNoteID = nil
        draftPath = ""
        draftMarkdown = ""
        notice = "Encrypted draft discarded; the authenticated project is unchanged."
        if let discarded, let session {
            Task { [weak self] in
                do { try await session.discardDraft(id: discarded) }
                catch { self?.notice = "The draft was cleared here, but its local working copy needs review before it can be removed." }
            }
        }
    }

    /// Unsaved drafts are debounced into the encrypted local working copy so a
    /// crash cannot silently lose in-progress text. This is local durability,
    /// not a checkpoint: the authenticated archive changes only on approval.
    func draftTextDidChange() {
        guard isUnlocked, hasDraft, let session, let draftID = editingNoteID ?? draftNoteID else { return }
        draftStageTask?.cancel()
        let path = draftPath, markdown = draftMarkdown
        let stamped = Int64(Date().timeIntervalSince1970 * 1000)
        draftStageTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            do {
                try await session.stageDraft(.init(id: draftID, path: path, markdown: markdown, updatedAt: stamped))
            } catch RDMError.recoveryRequired {
                self?.needsWorkingReview = true
                self?.notice = "Local working copies need review before Folio can save more unsaved drafts."
            } catch {
                // The text stays in the editor; the next edit retries staging.
            }
        }
    }

    func checkpointDraft() async {
        guard !isCheckpointing, let session, let project, hasDraft,
              !draftPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let draftID = editingNoteID ?? draftNoteID ?? UUID()
        let replacement = RDMNote(id: draftID, path: draftPath, markdown: draftMarkdown)
        let nextNotes: [RDMNote]
        if isNewDraft {
            nextNotes = project.notes + [replacement]
        } else {
            guard project.notes.contains(where: { $0.id == draftID }) else { return }
            nextNotes = project.notes.map { note in note.id == draftID ? replacement : note }
        }
        let next = RDMProjectPayload(id: project.id, name: project.name, notes: nextNotes, roadmap: project.roadmap)
        isCheckpointing = true
        defer { isCheckpointing = false }
        do {
            _ = try await session.checkpoint(next)
            draftStageTask?.cancel()
            draftStageTask = nil
            // The draft is now durable inside the archive; its local working
            // copy is removed. A removal failure leaves it to surface at the
            // next open as a reviewed leftover instead of failing the write.
            do { try await session.discardDraft(id: draftID) } catch { }
            self.project = try await session.currentProject()
            self.selectedNoteID = draftID
            self.editingNoteID = nil
            self.isNewDraft = false
            self.draftNoteID = nil
            self.draftPath = ""
            self.draftMarkdown = ""
            notice = "Encrypted checkpoint written and memory-only search refreshed."
            await search()
        } catch {
            // Keep the draft visible for review. A stale or invalid checkpoint
            // never discards the user's uncommitted text.
            errorMessage = error.localizedDescription
        }
    }

    func chooseToCreate(from sourceProject: RDMProjectPayload? = nil) {
        guard phase == .idle else { return }
        pendingCreationProject = sourceProject
        let panel = NSSavePanel()
        panel.title = "Create an encrypted Folio project"
        panel.message = "Choose a local .rdm file. The recovery code will be shown once and will not be saved by Folio."
        panel.nameFieldStringValue = "Encrypted project.rdm"
        panel.canCreateDirectories = true
        panel.allowedFileTypes = ["rdm"]
        guard panel.runModal() == .OK, let url = panel.url else { pendingCreationProject = nil; return }
        fileURL = url.pathExtension.lowercased() == "rdm" ? url : url.appendingPathExtension("rdm")
        projectName = sourceProject?.name ?? fileURL?.deletingPathExtension().lastPathComponent ?? "Encrypted project"
        phase = .creating
        rememberPassphrase = false
        clearCredentials()
        clearMessages()
    }

    func chooseToOpen() {
        guard phase == .idle else { return }
        let panel = NSOpenPanel()
        panel.title = "Open an encrypted Folio project"
        panel.message = "Choose a local .rdm file. Folio will not import it into the plain-vault workspace."
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedFileTypes = ["rdm"]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        fileURL = url
        phase = .opening
        credentialMode = .passphrase
        rememberPassphrase = false
        clearCredentials()
        clearMessages()
    }

    func create() async {
        guard phase == .creating, let fileURL else { return }
        let name = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { errorMessage = "Enter an encrypted project name."; return }
        guard passphrase == confirmation else { errorMessage = "The passphrases do not match."; return }
        let secret = passphrase
        let remember = rememberPassphrase
        clearCredentials()
        do {
            let source = pendingCreationProject
            let payload = RDMProjectPayload(id: UUID(), name: name,
                                            notes: source?.notes ?? [], roadmap: source?.roadmap ?? .empty)
            let created = try await RDMProjectSession.create(at: fileURL, project: payload, passphrase: secret)
            session = created.session
            pendingCreationProject = nil
            project = payload
            pendingRecoveryCode = created.recoveryCode
            phase = .recoveryReview
            notice = "The encrypted project is open, but keep the recovery code visible until you have stored it securely."
            if remember {
                do { try EncryptedPassphraseKeychain.save(secret, for: fileURL) }
                catch { notice = "Project created, but the optional Keychain save failed: \(error.localizedDescription)" }
            }
        } catch {
            errorMessage = error.localizedDescription
            phase = .creating
        }
    }

    func unlock() async {
        guard phase == .opening else { return }
        let mode = credentialMode
        let credential = mode == .passphrase ? passphrase : recoveryCode
        let remember = mode == .passphrase && rememberPassphrase
        clearCredentials()
        await unlock(credential: credential, mode: mode, remember: remember)
    }

    func useSavedPassphrase() async {
        guard phase == .opening, let fileURL else { return }
        do {
            guard let saved = try EncryptedPassphraseKeychain.load(for: fileURL) else {
                errorMessage = "No saved passphrase was found for this exact file location."
                return
            }
            credentialMode = .passphrase
            await unlock(credential: saved, mode: .passphrase, remember: false)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func forgetSavedPassphrase() {
        guard let fileURL else { return }
        do { try EncryptedPassphraseKeychain.remove(for: fileURL); notice = "The optional saved passphrase was removed from this Mac." }
        catch { errorMessage = error.localizedDescription }
    }

    private func unlock(credential: String, mode: CredentialMode, remember: Bool) async {
        guard phase == .opening, let fileURL else { return }
        do {
            let opened: RDMProjectSession
            switch mode {
            case .passphrase: opened = try await RDMProjectSession.open(at: fileURL, passphrase: credential)
            case .recoveryCode: opened = try await RDMProjectSession.open(at: fileURL, recoveryCode: credential)
            }
            session = opened
            project = try await opened.currentProject()
            phase = .unlocked
            notice = "Unlocked in memory. Search results are not persisted."
            searchHits = []
            selectedNoteID = project?.notes.first?.id
            await restoreLocalDrafts()
            if remember {
                do { try EncryptedPassphraseKeychain.save(credential, for: fileURL) }
                catch { notice = "Unlocked, but the optional Keychain save failed: \(error.localizedDescription)" }
            }
        } catch {
            errorMessage = error.localizedDescription
            phase = .opening
        }
    }

    func useRecoveryCode() {
        guard phase == .opening else { return }
        credentialMode = .recoveryCode
        clearCredentials()
        errorMessage = nil
    }

    func usePassphrase() {
        guard phase == .opening else { return }
        credentialMode = .passphrase
        clearCredentials()
        errorMessage = nil
    }

    /// Explicit acknowledgement is required before the one-time recovery code
    /// leaves the review state. No automatic clipboard copy is offered.
    func acknowledgeRecoveryCode() {
        guard phase == .recoveryReview, pendingRecoveryCode != nil else { return }
        pendingRecoveryCode = nil
        phase = .unlocked
        notice = "Recovery code acknowledged. Folio will not show it again from this session."
    }

    func search() async {
        guard let session, isUnlocked else { return }
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { searchHits = []; return }
        do { searchHits = try await session.search(text); selectedNoteID = searchHits.first?.id }
        catch { errorMessage = error.localizedDescription }
    }

    /// Offers the most recent unsaved draft from the encrypted local working
    /// copy. Additional drafts stay preserved until reviewed or discarded.
    private func restoreLocalDrafts() async {
        guard let session else { return }
        do {
            switch try await session.restoreWorkingState() {
            case .empty:
                break
            case .current(let state):
                if let message = presentRestoredDrafts(state) {
                    notice = message
                }
            case .stale(let state, let reason):
                needsWorkingReview = true
                var message = "Local working copies need review: \(reason)"
                if let state, let restored = presentRestoredDrafts(state) {
                    message += " " + restored
                }
                notice = message
            }
        } catch {
            errorMessage = "Local working copies could not be read: \(error.localizedDescription)"
        }
    }

    /// Populates the single draft slot with the newest preserved draft.
    /// Returns nil when the state carries no drafts.
    private func presentRestoredDrafts(_ state: RDMWorkingState) -> String? {
        guard let newest = state.drafts.max(by: { ($0.updatedAt, $0.id.uuidString) < ($1.updatedAt, $1.id.uuidString) }) else { return nil }
        draftStageTask?.cancel()
        draftStageTask = nil
        draftNoteID = newest.id
        if project?.notes.contains(where: { $0.id == newest.id }) == true {
            editingNoteID = newest.id
            isNewDraft = false
        } else {
            editingNoteID = nil
            isNewDraft = true
        }
        draftPath = newest.path
        draftMarkdown = newest.markdown
        let extra = state.drafts.count > 1
            ? " \(state.drafts.count - 1) more unsaved draft(s) stay preserved in the encrypted working copy."
            : ""
        return "Restored your most recent unsaved draft from the encrypted local working copy." + extra
    }

    /// Explicit reviewed resolution of inconsistent local working copies.
    func resolveWorkingStateNow() async {
        guard let session, needsWorkingReview else { return }
        do {
            let accepted = try await session.resolveWorkingState()
            needsWorkingReview = false
            if let accepted, let message = presentRestoredDrafts(accepted) {
                notice = "Local working copies were reviewed and re-anchored. " + message
            } else {
                notice = "Local working copies were reviewed. Nothing was recoverable; the unreadable bytes were preserved in the project's private folder."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func lock() async {
        guard !isCheckpointing else { return }
        guard let session else { resetToIdle(); return }
        await session.lock()
        self.session = nil
        clearPlaintextState()
        phase = .idle
        notice = "Encrypted project locked. Its working index and in-memory project copy were cleared; unsaved drafts stay encrypted in the local working copy."
    }

    func close() async {
        guard !isCheckpointing else { return }
        guard let session else { resetToIdle(); return }
        await session.close()
        self.session = nil
        clearPlaintextState()
        phase = .idle
        notice = nil
    }

    private func resetToIdle() {
        clearPlaintextState()
        phase = .idle
    }

    private func clearPlaintextState() {
        project = nil
        pendingCreationProject = nil
        searchHits.removeAll(keepingCapacity: false)
        selectedNoteID = nil
        editingNoteID = nil
        draftNoteID = nil
        draftStageTask?.cancel()
        draftStageTask = nil
        draftPath = ""
        draftMarkdown = ""
        isNewDraft = false
        isCheckpointing = false
        needsWorkingReview = false
        query = ""
        pendingRecoveryCode = nil
        rememberPassphrase = false
        clearCredentials()
    }

    private func clearCredentials() {
        passphrase = ""
        confirmation = ""
        recoveryCode = ""
    }

    private func clearMessages() {
        errorMessage = nil
        notice = nil
    }
}
