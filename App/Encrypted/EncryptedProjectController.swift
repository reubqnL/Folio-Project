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
    /// True while a debounced working-copy write is scheduled or in flight.
    var isStagingDraft = false
    /// True when the current draft text is confirmed in the encrypted working
    /// copy (or was restored from it). Cleared by every further edit.
    var draftStagedConfirmed = false
    /// Set when an approved checkpoint write failed; cleared on success.
    var checkpointFailure: String?
    /// Generation counter so a superseded staging write cannot confirm or
    /// clear state belonging to a newer edit.
    @ObservationIgnored private var draftStageGeneration = 0

    @ObservationIgnored private var session: RDMProjectSession?
    @ObservationIgnored private var pendingCreationProject: RDMProjectPayload?
    @ObservationIgnored private var draftNoteID: UUID?
    @ObservationIgnored private var draftStageTask: Task<Void, Never>?

    /// The folder the user granted access to, and the reason this controller
    /// asks for a folder at all.
    ///
    /// A `.rdm` project is not one file on disk. Writing it also creates a
    /// `.folio` folder beside the archive, holding the advisory lock, the
    /// atomic staging area and the encrypted working drafts. macOS extends a
    /// panel-selected *file* grant to that file alone — Apple's own guidance is
    /// explicit that "that extension does not apply to the directory containing
    /// that file", so creating a sibling directory there is blocked by the
    /// sandbox. Creating and opening an encrypted project therefore failed on
    /// the folder write, before any cryptography ran.
    ///
    /// Asking the user for the containing folder is the grant that covers
    /// everything the format writes, and it is what Apple recommends for output
    /// that is more than one file. The scope is held for as long as the project
    /// is open, because checkpoints and working-copy writes happen throughout
    /// the session.
    @ObservationIgnored private var grantedFolder: URL?

    /// The folder chosen for the current create or open operation.
    var chosenFolder: URL?

    /// More than one `.rdm` was found in the chosen folder; the user picks one.
    var rdmChoices: [URL] = []

    /// Every unsaved draft the encrypted working copy holds, newest first.
    ///
    /// The editor holds one draft at a time, but the working store holds up to
    /// 256 of them, and `restoreWorkingState()` returns all of them. Before
    /// this list existed the UI restored the newest into its single slot and
    /// reported that others were preserved without offering any way to reach
    /// them — and because discarding a draft removes it from the store, the
    /// only way to reach an older one was to destroy the newer ones in front
    /// of it. This is the index that makes all of them reachable.
    var preservedDrafts: [RDMWorkingDraft] = []

    var isUnlocked: Bool { phase == .unlocked || phase == .recoveryReview }
    var hasOpenSession: Bool { session != nil }
    var selectedNote: RDMNote? { project?.notes.first { $0.id == selectedNoteID } }
    var editingNote: RDMNote? { project?.notes.first { $0.id == editingNoteID } }
    var hasDraft: Bool { isNewDraft || editingNoteID != nil }
    var displayName: String { project?.name ?? fileURL?.deletingPathExtension().lastPathComponent ?? "Encrypted project" }

    /// The identity of the draft currently in the editor, if one is open.
    var openDraftID: UUID? { editingNoteID ?? draftNoteID }

    /// Every preserved draft, newest first.
    ///
    /// The draft open in the editor is included. The list is the complete set
    /// of what the working copy holds, so the count in its header always
    /// matches the rows beneath it, and no draft is ever silently absent from
    /// a list that claims to show them.
    var preservedDraftsNewestFirst: [RDMWorkingDraft] {
        preservedDrafts.sorted { ($0.updatedAt, $0.id.uuidString) > ($1.updatedAt, $1.id.uuidString) }
    }

    /// Preserved drafts other than the one in the editor: the ones that
    /// previously could not be reached at all. Drives whether the list is
    /// worth showing, since a list holding only the open draft adds nothing.
    var draftsPendingReview: [RDMWorkingDraft] {
        preservedDrafts.filter { $0.id != openDraftID }
    }

    /// Non-nil when switching drafts would drop text.
    ///
    /// A draft's text is safe to leave only once it is confirmed in the
    /// encrypted working copy. Until then the editor holds the only copy, so
    /// opening a different draft is refused rather than silently losing it.
    var draftSwitchBlockedReason: String? {
        guard hasDraft, draftHasUnsavedChanges, !draftStagedConfirmed else { return nil }
        return "This draft has text that is not yet confirmed in the encrypted working copy. Approve a checkpoint, or discard it, before opening another draft."
    }

    /// Initial placeholder path for a new draft; empty content with this path
    /// is an untouched draft with nothing to lose.
    static let defaultDraftPath = "Notes/New note.md"

    /// True when the open draft differs from the archived note (or holds
    /// content of its own). An untouched new draft (default path, empty text)
    /// has nothing to lose and is not described as unsaved work.
    private var draftHasUnsavedChanges: Bool {
        guard hasDraft else { return false }
        if isNewDraft { return !draftMarkdown.isEmpty || draftPath != Self.defaultDraftPath }
        return draftMarkdown != editingNote?.markdown || draftPath != editingNote?.path
    }

    /// N01 axes for the encrypted workspace: unsaved-text durability in the
    /// working copy is displayed separately from the archive checkpoint, and
    /// neither is conflated with sync (which does not exist in this build).
    var draftCopyLabel: String {
        if !hasDraft { return "No unsaved draft" }
        if isStagingDraft { return "Unsaved text — write pending" }
        if !draftHasUnsavedChanges { return "No unsaved changes" }
        return draftStagedConfirmed
            ? "Unsaved text durable in the working copy"
            : "Unsaved text — editor only"
    }

    var draftCopyExplanation: String {
        switch draftCopyLabel {
        case "No unsaved draft":
            "The draft editor is closed. The authenticated archive is the only copy."
        case "Unsaved text — write pending":
            "Your unsaved text is being written to the encrypted local working copy (250 ms coalescing). It is not confirmed durable yet."
        case "No unsaved changes":
            "The draft matches the archived note; there is nothing unsaved to lose."
        case "Unsaved text durable in the working copy":
            "Your unsaved text is confirmed in the encrypted local working copy (acknowledged after the storage barrier). It joins the archive only when you approve a checkpoint."
        default:
            "Your unsaved text is not yet confirmed in the encrypted local working copy. Keep Folio open so the next edit can retry the write; approving a checkpoint writes it into the archive."
        }
    }

    var checkpointState: VaultCheckpointState {
        guard isUnlocked, session != nil else { return .noArchive }
        if let checkpointFailure, hasDraft, draftHasUnsavedChanges { return .failed(checkpointFailure) }
        return draftHasUnsavedChanges ? .draftOutstanding : .current
    }

    var durabilitySummary: String {
        "\(draftCopyLabel) · \(checkpointState.label) · \(VaultRemoteState.unavailable.label)"
    }

    var durabilityExplanation: String {
        draftCopyExplanation + "\n\n" + checkpointState.explanation + "\n\n" + VaultRemoteState.unavailable.explanation
    }

    func beginNewNote() {
        guard isUnlocked else { return }
        editingNoteID = nil
        isNewDraft = true
        draftNoteID = UUID()
        draftPath = Self.defaultDraftPath
        draftMarkdown = ""
        isStagingDraft = false
        draftStagedConfirmed = false
        checkpointFailure = nil
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
        isStagingDraft = false
        draftStagedConfirmed = false
        checkpointFailure = nil
        errorMessage = nil
        notice = "Draft only. It stays in the encrypted local working copy until you choose Write encrypted checkpoint."
    }

    func cancelEditing() {
        let discarded = editingNoteID ?? draftNoteID
        draftStageTask?.cancel()
        draftStageTask = nil
        isStagingDraft = false
        draftStagedConfirmed = false
        checkpointFailure = nil
        editingNoteID = nil
        isNewDraft = false
        draftNoteID = nil
        draftPath = ""
        draftMarkdown = ""
        notice = "Encrypted draft discarded; the authenticated project is unchanged."
        if let discarded, let session {
            Task { [weak self] in
                do {
                    try await session.discardDraft(id: discarded)
                    guard let self else { return }
                    await self.refreshPreservedDrafts()
                    // Other unsaved drafts may still be preserved. Say so, and
                    // say where they are, rather than leaving them invisible.
                    let remaining = self.preservedDrafts.count
                    if remaining > 0 {
                        self.notice = "Encrypted draft discarded. \(remaining) preserved draft(s) remain; use Preserved drafts to open or discard them."
                    }
                } catch {
                    self?.notice = "The draft was cleared here, but its local working copy needs review before it can be removed."
                }
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
        // This edit is only in the editor until the staged write is confirmed.
        draftStagedConfirmed = false
        isStagingDraft = true
        draftStageGeneration += 1
        let generation = draftStageGeneration
        draftStageTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self, self.draftStageGeneration == generation else { return }
            defer {
                if self.draftStageGeneration == generation { self.isStagingDraft = false }
            }
            do {
                try await session.stageDraft(.init(id: draftID, path: path, markdown: markdown, updatedAt: stamped))
                if self.draftStageGeneration == generation {
                    self.draftStagedConfirmed = true
                    // The staged copy is now in the working store, so the
                    // preserved list has to include it.
                    await self.refreshPreservedDrafts()
                }
            } catch RDMError.recoveryRequired {
                self.needsWorkingReview = true
                self.notice = "Local working copies need review before Folio can save more unsaved drafts."
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
            isStagingDraft = false
            draftStagedConfirmed = false
            checkpointFailure = nil
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
            notice = "Encrypted checkpoint written and search refreshed."
            await refreshPreservedDrafts()
            await search()
        } catch {
            // Keep the draft visible for review. A stale or invalid checkpoint
            // never discards the user's uncommitted text.
            checkpointFailure = error.localizedDescription
            errorMessage = error.localizedDescription
        }
    }

    func chooseToCreate(from sourceProject: RDMProjectPayload? = nil) {
        guard phase == .idle else { return }
        pendingCreationProject = sourceProject
        let panel = NSOpenPanel()
        panel.title = "Choose a folder for the encrypted project"
        panel.message = "Folio creates the .rdm file and its encrypted working copy inside this folder, so it asks for the folder rather than for a single file."
        panel.prompt = "Choose Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let folder = panel.url else {
            pendingCreationProject = nil
            return
        }
        grant(folder)
        chosenFolder = folder
        projectName = sourceProject?.name ?? "Encrypted project"
        fileURL = folder.appendingPathComponent(Self.archiveFileName(for: projectName))
        phase = .creating
        rememberPassphrase = false
        clearCredentials()
        clearMessages()
    }

    func chooseToOpen() {
        guard phase == .idle else { return }
        let panel = NSOpenPanel()
        panel.title = "Open an encrypted Folio project"
        panel.message = "Choose the folder that contains the .rdm file. Folio needs the folder, not the file alone, because the project keeps its encrypted working copy beside it."
        panel.prompt = "Choose Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        grant(folder)
        chosenFolder = folder
        let archives = Self.archives(in: folder)
        guard let first = archives.first else {
            errorMessage = "That folder has no .rdm project in it. Choose the folder that holds the encrypted project."
            releaseGrant()
            chosenFolder = nil
            return
        }
        // One archive opens straight away; several are offered to the user
        // rather than guessed at.
        rdmChoices = archives.count > 1 ? archives : []
        beginOpen(at: first)
    }

    /// Chooses one archive from a folder that holds several.
    func selectArchive(_ url: URL) {
        guard phase == .opening else { return }
        rdmChoices = []
        beginOpen(at: url)
    }

    private func beginOpen(at url: URL) {
        fileURL = url
        phase = .opening
        credentialMode = .passphrase
        rememberPassphrase = false
        clearCredentials()
        clearMessages()
    }

    /// The file name a new project will be given, derived from its name.
    ///
    /// Shown in the create card and used to build the destination, so what the
    /// card says and what gets written cannot disagree.
    var plannedArchiveName: String { Self.archiveFileName(for: projectName) }

    /// Turns a project name into a safe single-component file name.
    static func archiveFileName(for projectName: String) -> String {
        var name = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.lowercased().hasSuffix(".rdm") { name = String(name.dropLast(4)) }
        for bad in ["/", ":", "\\", "\n", "\r", "\0"] {
            name = name.replacingOccurrences(of: bad, with: "-")
        }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        if name.isEmpty { name = "Encrypted project" }
        if name.count > 80 { name = String(name.prefix(80)) }
        return name + ".rdm"
    }

    private static func archives(in folder: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])) ?? []
        return contents
            .filter { $0.pathExtension.lowercased() == "rdm" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Holds the sandbox grant for a chosen folder for as long as the project
    /// is open. Calling this on a URL that carries no security scope is
    /// harmless: it reports false and grants nothing extra.
    private func grant(_ folder: URL) {
        releaseGrant()
        _ = folder.startAccessingSecurityScopedResource()
        grantedFolder = folder
    }

    private func releaseGrant() {
        grantedFolder?.stopAccessingSecurityScopedResource()
        grantedFolder = nil
    }

    func create() async {
        guard phase == .creating else { return }
        let name = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { errorMessage = "Enter an encrypted project name."; return }
        guard passphrase == confirmation else { errorMessage = "The passphrases do not match."; return }
        guard let folder = chosenFolder else {
            errorMessage = "Choose a folder for the encrypted project first."
            return
        }
        // Rebuilt from the folder and the name as they stand now, so a project
        // renamed after the folder was chosen writes to the new name rather
        // than to the one previewed at the time.
        let destination = folder.appendingPathComponent(Self.archiveFileName(for: name))
        fileURL = destination
        let secret = passphrase
        let remember = rememberPassphrase
        clearCredentials()
        do {
            let source = pendingCreationProject
            let payload = RDMProjectPayload(id: UUID(), name: name,
                                            notes: source?.notes ?? [], roadmap: source?.roadmap ?? .empty)
            let created = try await RDMProjectSession.create(at: destination, project: payload, passphrase: secret)
            session = created.session
            pendingCreationProject = nil
            project = payload
            pendingRecoveryCode = created.recoveryCode
            phase = .recoveryReview
            notice = "The encrypted project is open, but keep the recovery code visible until you have stored it securely."
            if remember {
                do { try EncryptedPassphraseKeychain.save(secret, for: destination) }
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
            notice = "Unlocked in memory. Unsaved drafts and the derived search index persist only in encrypted local storage; no plaintext project bytes are written."
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
    /// copy, and records every preserved draft so the rest stay reachable.
    private func restoreLocalDrafts() async {
        guard let session else { return }
        do {
            switch try await session.restoreWorkingState() {
            case .empty:
                preservedDrafts = []
            case .current(let state):
                preservedDrafts = state.drafts
                if let message = presentRestoredDrafts(state) {
                    notice = message
                }
            case .stale(let state, let reason):
                needsWorkingReview = true
                if let state {
                    preservedDrafts = state.drafts
                }
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

    /// Re-reads the full preserved-draft list from the encrypted working copy.
    ///
    /// Called after anything that changes it. A stale or unreadable result
    /// deliberately leaves the last known list in place rather than replacing
    /// it with an empty one: showing no drafts implies the drafts are gone,
    /// which is exactly the wrong thing to say when the truth is that Folio
    /// cannot currently read them.
    func refreshPreservedDrafts() async {
        guard let session, isUnlocked else {
            preservedDrafts = []
            return
        }
        do {
            switch try await session.restoreWorkingState() {
            case .empty:
                preservedDrafts = []
            case .current(let state):
                preservedDrafts = state.drafts
            case .stale:
                needsWorkingReview = true
            }
        } catch {
            // Keep the last known list.
        }
    }

    /// Opens one of the preserved drafts in the editor.
    func openPreservedDraft(_ id: UUID) {
        guard isUnlocked, let draft = preservedDrafts.first(where: { $0.id == id }) else { return }
        // Refuse rather than replace: the open draft may hold the only copy of
        // its text.
        guard draftSwitchBlockedReason == nil else { return }
        draftStageTask?.cancel()
        draftStageTask = nil
        isStagingDraft = false
        draftStagedConfirmed = true
        checkpointFailure = nil
        errorMessage = nil
        draftNoteID = draft.id
        if project?.notes.contains(where: { $0.id == draft.id }) == true {
            editingNoteID = draft.id
            isNewDraft = false
        } else {
            editingNoteID = nil
            isNewDraft = true
        }
        draftPath = draft.path
        draftMarkdown = draft.markdown
        notice = "Opened a preserved draft from the encrypted working copy. It still joins the project only when you approve a checkpoint."
    }

    /// Removes one preserved draft from the encrypted working copy.
    ///
    /// This is the only way drafts are removed other than checkpointing them,
    /// so it is offered per draft and never in bulk.
    func discardPreservedDraft(_ id: UUID) async {
        guard isUnlocked, let session else { return }
        do {
            try await session.discardDraft(id: id)
            notice = "Preserved draft discarded; the authenticated project is unchanged."
            await refreshPreservedDrafts()
        } catch {
            errorMessage = error.localizedDescription
            await refreshPreservedDrafts()
        }
    }

    /// Populates the draft editor with the newest preserved draft, and records
    /// the full list so the others stay reachable. Returns nil when the state
    /// carries no drafts.
    private func presentRestoredDrafts(_ state: RDMWorkingState) -> String? {
        preservedDrafts = state.drafts
        guard let newest = state.drafts.max(by: { ($0.updatedAt, $0.id.uuidString) < ($1.updatedAt, $1.id.uuidString) }) else { return nil }
        draftStageTask?.cancel()
        draftStageTask = nil
        isStagingDraft = false
        draftStagedConfirmed = true
        checkpointFailure = nil
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
            ? " \(state.drafts.count - 1) more unsaved draft(s) are preserved; use Preserved drafts to open or discard them."
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
        // The drafts themselves stay encrypted in the working copy; only the
        // in-memory index of them is dropped with the rest of the plaintext.
        preservedDrafts = []
        // The folder grant is released with everything else: nothing must keep
        // access to an encrypted project's folder after it is locked.
        releaseGrant()
        chosenFolder = nil
        rdmChoices = []
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
