import SwiftUI
import AppKit
import Observation
import FolioCore

@MainActor
@Observable
final class WorkspaceSession {
    enum Destination: Equatable { case launcher, notes, encrypted }
    enum WorkspaceSection: String, CaseIterable { case notes, roadmap, connections }
    var workspaceSection: WorkspaceSection = .notes
    /// Projects opened before, newest last, for the File → Open Recent menu.
    /// Loading this at construction is what makes the menu useful in a fresh
    /// launch, before any project has been opened in this session.
    var recentProjects: [KnownProjectIdentity] = []
    /// These panes are shown or hidden because the user asked, never because a
    /// window crossed a width threshold. `WorkspaceLayoutPolicy` only ever
    /// narrows them toward a minimum, so section switching and resizing cannot
    /// move the writing surface out from under the pointer.
    var showsExplorer = true
    var showsAssistant = true
    let encrypted = EncryptedProjectController()
    let planning = RoadmapController()
    let connections = GraphController()
    let experience = ExperiencePolicy()
    let editorPolicy = EditorNavigationPolicy()
    let aiPolicy = AIInteractionPolicy()
    // `var`, not `let`: SwiftUI needs a writable key path to build the
    // `$session.speech…` / `$session.capture…` sheet bindings.
    var speech = SpeechController()
    var capture = CaptureController()
    let search = NoteSearchController()
    let shortcuts = ShortcutPreferences()
    var showingSearch = false
    var showingCommands = false
    var showingLinkRepair = false
    var linkChoice: NoteLinkChoice?
    var findInNoteRequest: UUID?
    var destination: Destination = .launcher
    var project: VaultProject?
    var notes: [VaultNote] = []
    var documents: [UUID: OpenNoteDocument] = [:]
    var selectedNoteID: UUID?
    var showingNewNote = false
    var showingRecovery = false
    var isOpening = false
    var isRefreshing = false
    var recoveryItems: [RecoveryItem] = []
    var notice: String?
    var errorMessage: String?
    var pasteMessage: String?
    var creationSeed: NoteCreationSeed?
    var preparingEncryptedCopy = false
    var encryptedCopyCompleted = 0
    var encryptedCopyTotal = 0
    var encryptedCopyMessage = ""


    @ObservationIgnored private var store: PlainVaultStore?
    @ObservationIgnored private var folderGrant: ScopedProjectFolder?
    @ObservationIgnored private var sessionToken = UUID()
    @ObservationIgnored private var selectionRequest = UUID()
    @ObservationIgnored private var timers: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var activeSaves: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private let observation = ProjectFileObservation()
    @ObservationIgnored private var observationTask: Task<Void, Never>?
    @ObservationIgnored private var pasteUndoAction: (() -> Void)?
    @ObservationIgnored private var captureUndoCommands = Set<UUID>()
    @ObservationIgnored private var voiceAfterComposer = false
    @ObservationIgnored private var encryptedCopyTask: Task<Void, Never>?

    /// Loads Open Recent at construction so the menu is populated in a fresh
    /// launch, before any project has been opened in this process.
    init() {
        recentProjects = loadKnownProjects()
    }

    var selectedDocument: OpenNoteDocument? { selectedNoteID.flatMap { documents[$0] } }
    var rootURL: URL? { store?.rootURL }
    var canCreateNote: Bool { project != nil && !isOpening }
    var commandContext: CommandContext {
        .init(hasProject: project != nil, hasNote: selectedDocument != nil,
              busy: isOpening || showingNewNote || showingRecovery || planning.isSaving || planning.editRequest != nil || capture.isApplying || capture.showingReview,
              editorMode: selectedDocument?.editorPresentation ?? .source,
              canUndoRoadmap: planning.history.canUndo && !planning.hasUnwrittenChanges,
              canRedoRoadmap: planning.history.canRedo && !planning.hasUnwrittenChanges)
    }
    var hasUnwrittenChanges: Bool { speech.hasWork || capture.hasWork || planning.hasUnwrittenChanges || documents.values.contains { $0.isDirty || $0.isSaving || $0.pendingCaptureEdit != nil } }
    var hasOpenEncryptedProject: Bool { encrypted.hasOpenSession }

    func preparePlainProjectForEncryptedCopy() {
        guard !isOpening, !preparingEncryptedCopy, !showingNewNote, planning.editRequest == nil,
              let currentStore = store, let currentProject = project else {
            errorMessage = "Open a plain project before requesting an encrypted copy."
            return
        }
        encryptedCopyTask?.cancel()
        preparingEncryptedCopy = true
        encryptedCopyCompleted = 0
        encryptedCopyTotal = 0
        encryptedCopyMessage = "Preparing a non-destructive encrypted copy…"
        destination = .encrypted
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            isOpening = true
            defer {
                isOpening = false
                preparingEncryptedCopy = false
                encryptedCopyTask = nil
            }
            do {
                guard recoveryItems.isEmpty else {
                    throw VaultError.recoveryRequired
                }
                guard await flushAll() else {
                    throw VaultError.recoveryRequired
                }
                try Task.checkCancellation()
                let listed = try await currentStore.scan()
                guard listed.count <= RDMArchive.maximumNotes else { throw RDMError.resourceLimit }
                encryptedCopyTotal = listed.count
                encryptedCopyMessage = listed.isEmpty ? "Reading project metadata…" : "Reading Markdown without changing the source…"
                var encryptedNotes: [RDMNote] = []
                encryptedNotes.reserveCapacity(listed.count)
                for (offset, note) in listed.enumerated() {
                    try Task.checkCancellation()
                    let snapshot = try await currentStore.readNote(id: note.id)
                    encryptedNotes.append(.init(id: note.id, path: note.relativePath, markdown: snapshot.markdown))
                    encryptedCopyCompleted = offset + 1
                }
                try Task.checkCancellation()
                let roadmapSnapshot = try await currentStore.loadRoadmap()
                let payload = RDMProjectPayload(id: UUID(), name: currentProject.name,
                                                notes: encryptedNotes, roadmap: roadmapSnapshot.document)
                encryptedCopyMessage = "Copy prepared. Choose a destination and passphrase."
                encrypted.chooseToCreate(from: payload)
                if encrypted.phase == .creating { destination = .encrypted }
            } catch is CancellationError {
                encryptedCopyMessage = "Copy cancelled; the plain project was not changed."
            } catch {
                encryptedCopyMessage = "Copy not started; the plain project was not changed."
                errorMessage = "The encrypted copy was not started: \(error.localizedDescription)"
            }
        }
        encryptedCopyTask = task
    }

    func cancelEncryptedCopyPreparation() {
        encryptedCopyTask?.cancel()
    }

    func openEncryptedWorkspace() {
        guard !isOpening, !preparingEncryptedCopy, !showingNewNote, planning.editRequest == nil else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            isOpening = true
            defer { isOpening = false }
            guard await flushAll() else {
                errorMessage = "Resolve the current project's unsaved or conflicting edits before opening an encrypted project."
                return
            }
            observation.stop(); observationTask?.cancel()
            for timer in timers.values { timer.cancel() }; timers.removeAll()
            for save in activeSaves.values { save.cancel() }; activeSaves.removeAll()
            await search.disconnect()
            if let current = store { await current.close() }
            store = nil; folderGrant = nil; project = nil; notes = []
            documents.removeAll(); selectedNoteID = nil; recoveryItems = []
            capture.clear(); captureUndoCommands = []
            workspaceSection = .notes
            destination = .encrypted
        }
    }

    func chooseProject() async {
        guard !isOpening, !showingNewNote, planning.editRequest == nil else { return }
        isOpening = true
        defer { isOpening = false }
        guard await flushAll() else {
            errorMessage = "Resolve the current project's unsaved or conflicting edits before switching projects."
            return
        }
        let panel = NSOpenPanel()
        panel.title = "Open a Folio project folder"
        panel.message = "Development build: choose a disposable copy. Markdown and recovery files in a plain vault are not encrypted."
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = true; panel.allowsMultipleSelection = false
        let result = await withCheckedContinuation { continuation in
            panel.begin { response in continuation.resume(returning: response) }
        }
        guard result == .OK, let url = panel.url else { return }
        await openProject(at: url, grant: ScopedProjectFolder(url), mayCreate: true)
    }

    /// Reopens a project from File → Open Recent.
    ///
    /// Access comes from the stored security-scoped bookmark, so no panel is
    /// shown. A project whose folder has moved, been deleted or lost its
    /// permission is reported and forgotten rather than silently opening
    /// somewhere else or overwriting anything.
    func openRecentProject(_ known: KnownProjectIdentity) async {
        guard !isOpening, !showingNewNote, planning.editRequest == nil else { return }
        guard let url = known.resolveFolderURL() else {
            forgetRecentProject(known.projectID)
            errorMessage = "Folio can no longer reach “\(known.name)”. It was moved, deleted, or its permission was reset. Use Open Project Folder… and Folio will remember it again."
            return
        }
        isOpening = true
        defer { isOpening = false }
        guard await flushAll() else {
            errorMessage = "Resolve the current project's unsaved or conflicting edits before switching projects."
            return
        }
        await openProject(at: url, grant: ScopedProjectFolder(url), mayCreate: false)
    }

    /// Removes one entry from Open Recent. Used when a bookmark can no longer
    /// be resolved, so a permanently broken entry is not offered forever.
    func forgetRecentProject(_ id: UUID) {
        recentProjects.removeAll { $0.projectID == id }
        saveRecentProjects()
    }

    func clearRecentProjects() {
        recentProjects = []
        saveRecentProjects()
    }

    /// The shared body of opening a folder, used by both the open panel and
    /// Open Recent. `mayCreate` is false for Open Recent: Folio must never
    /// offer to initialise a project in a folder the user has not just chosen.
    private func openProject(at url: URL, grant: ScopedProjectFolder, mayCreate: Bool) async {
        do {
            let values = try url.resourceValues(forKeys: [.volumeIsLocalKey])
            guard values.volumeIsLocal == true else {
                errorMessage = "This development store supports local folders only, not network volumes."
                return
            }
            if let current = store, current.rootURL.standardizedFileURL == url.standardizedFileURL {
                destination = .notes; await refreshProject(); return
            }
            let opened: PlainVaultStore
            do { opened = try await PlainVaultStore.open(at: url) }
            catch VaultError.needsInitialization where mayCreate {
                let alert = NSAlert()
                alert.messageText = "Create a Folio project in this folder?"
                alert.informativeText = "Folio will add a .folio metadata/recovery directory. Existing Markdown is not rewritten during import. This build has not been validated on macOS yet; use a copy, not your only copy."
                alert.addButton(withTitle: "Create Project"); alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                opened = try await PlainVaultStore.open(at: url, createIfMissing: true)
            }
            do {
                var identity = try await opened.project()
                let known = recentProjects
                var fork = false
                if let previous = known.first(where: { $0.projectID == identity.id }), previous.rootIdentity != opened.rootIdentity {
                    let alert = NSAlert()
                    alert.messageText = "Is this a restored workspace or an independent copy?"
                    alert.informativeText = "This project identity was previously seen in another folder. Folio will not silently combine histories. A new workspace keeps copied content but gets a new project identity."
                    alert.addButton(withTitle: "Use as Restored Workspace")
                    alert.addButton(withTitle: "Make Independent Project")
                    alert.addButton(withTitle: "Cancel")
                    switch alert.runModal() {
                    case .alertFirstButtonReturn: break
                    case .alertSecondButtonReturn: fork = true
                    default: await opened.close(); return
                    }
                }
                let recovered = try await opened.recover(replay: !fork)
                if fork { identity = try await opened.forkIdentity() }
                let listed = try await opened.scan()
                observation.stop(); observationTask?.cancel()
                for timer in timers.values { timer.cancel() }; timers.removeAll()
                if let previous = store { await previous.close() }
                capture.clear(); captureUndoCommands = []
                folderGrant = grant; store = opened; sessionToken = UUID()
                project = identity; notes = listed; documents = [:]; selectedNoteID = nil
                workspaceSection = .notes
                connections.configure(store: opened, notes: listed, roadmap: .empty)
                planning.onChange = { [weak self] document in self?.connections.setRoadmap(document) }
                await planning.connect(opened)
                recoveryItems = recovered.review
                notice = recovered.replayed.isEmpty ? nil : "Recovered \(recovered.replayed.count) interrupted local write(s)."
                recordProject(identity, rootIdentity: opened.rootIdentity)
                destination = .notes; clearPasteNotice()
                let chosenProfile = SearchProfile(rawValue: UserDefaults.standard.string(forKey: "searchProfile") ?? "") ?? .balanced
                await search.connect(store: opened, project: identity, notes: listed, profile: chosenProfile)
                if let first = listed.first { await selectNote(first.id) }
            } catch { await opened.close(); throw error }
        } catch { errorMessage = error.localizedDescription }
    }

    func selectNote(_ id: UUID) async {
        guard let store else { return }
        workspaceSection = .notes
        clearPasteNotice()
        let request = UUID(); selectionRequest = request
        let token = sessionToken
        if documents[id] != nil { selectedNoteID = id; bindObservation(); return }
        do {
            let snapshot = try await store.readNote(id: id)
            guard token == sessionToken, request == selectionRequest else { return }
            documents[id] = OpenNoteDocument(snapshot)
            selectedNoteID = id; bindObservation()
        } catch { errorMessage = error.localizedDescription }
    }

    func createNote(title: String, folder: String) async throws {
        guard let store else { throw VaultError.closed }
        let result = try await store.createNote(title: title, folder: folder, markdown: creationSeed?.markdown)
        switch result {
        case .written(let snapshot):
            documents[snapshot.note.id] = OpenNoteDocument(snapshot, justWritten: true)
            updateRow(snapshot.note); selectedNoteID = snapshot.note.id
            showingNewNote = false; creationSeed = nil; clearPasteNotice(); bindObservation()
            search.observeSaved(snapshot)
            connections.reconcileNotes(notes)
        case .conflict(let conflict):
            recoveryItems.append(.initForApp(conflict))
            throw VaultError.recoveryRequired
        }
    }

    func textBinding(for document: OpenNoteDocument) -> Binding<String> {
        Binding(get: { document.text }, set: { [weak self, weak document] value in
            guard let self, let document, !self.isOpening, !document.isResolvingConflict else { return }
            guard value != document.text else { return }
            document.text = value; document.editGeneration += 1
            if let binding = self.captureBinding(for: document) { self.capture.targetEdited(binding: binding, generation: document.editGeneration) }
            if document.firstDirtyTime == nil { document.firstDirtyTime = ProcessInfo.processInfo.systemUptime }
            if document.conflict == nil { document.failure = nil; self.scheduleSave(document.id) }
        })
    }

    private func scheduleSave(_ id: UUID) {
        guard let document = documents[id], document.isDirty, document.conflict == nil else { return }
        timers[id]?.cancel()
        let now = ProcessInfo.processInfo.systemUptime
        let due = SaveCoalescing.deadline(firstDirty: document.firstDirtyTime ?? now, latestEdit: now)
        let delay = max(0, due - now)
        let token = sessionToken
        timers[id] = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, self.sessionToken == token, !Task.isCancelled else { return }
            self.timers.removeValue(forKey: id)
            _ = await self.persist(id)
        }
    }

    @discardableResult
    func persist(_ id: UUID, flush: Bool = false) async -> Bool {
        timers[id]?.cancel(); timers.removeValue(forKey: id)
        if let active = activeSaves[id] {
            await active.value
            if let pending = documents[id], pending.isDirty, pending.conflict == nil, pending.failure == nil {
                if flush { return await persist(id, flush: true) }
                // A timer can fire while the previous write is finishing. Keep
                // the follow-up edit scheduled rather than dropping that wakeup.
                scheduleSave(id)
            }
            return documents[id].map { !$0.isDirty && $0.conflict == nil && $0.failure == nil } ?? true
        }
        guard let document = documents[id] else { return true }
        guard document.conflict == nil else { return false }
        if !document.isDirty { return document.failure == nil }
        guard document.failure == nil || flush else { return false }
        let token = sessionToken
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.writeOne(id, token: token)
            if token == self.sessionToken { self.activeSaves.removeValue(forKey: id) }
        }
        activeSaves[id] = task
        await task.value
        guard token == sessionToken, let current = documents[id] else { return false }
        if flush, current.isDirty, current.conflict == nil, current.failure == nil {
            return await persist(id, flush: true)
        }
        return !current.isDirty && current.conflict == nil && current.failure == nil
    }

    private func writeOne(_ id: UUID, token: UUID) async {
        guard token == sessionToken, let store, let document = documents[id], document.isDirty else { return }
        let text = document.text, generation = document.editGeneration, base = document.baseline
        document.isSaving = true; document.failure = nil
        do {
            let result = try await store.save(base, markdown: text)
            guard token == sessionToken else { return }
            switch result {
            case .written(let snapshot):
                document.baseline = snapshot; document.committedGeneration = generation; document.lastWriteConfirmed = true
                updateRow(snapshot.note)
                search.observeSaved(snapshot)
                connections.reconcileNotes(notes)
                connections.refreshNote(snapshot.note.id)
                if !document.isDirty { document.firstDirtyTime = nil }
            case .conflict(let conflict):
                document.conflict = conflict
                recoveryItems.removeAll { $0.id == conflict.id }
                recoveryItems.append(.initForApp(conflict))
                timers[id]?.cancel(); timers.removeValue(forKey: id)
            }
        } catch { document.failure = error.localizedDescription }
        document.isSaving = false
        if document.isDirty, document.failure == nil, document.conflict == nil { scheduleSave(id) }
        if selectedNoteID == id { bindObservation() }
    }

    func saveSelected() async { if let id = selectedNoteID { _ = await persist(id, flush: true) } }
    func prepareToQuit() async -> Bool {
        guard !isOpening, !showingNewNote, planning.editRequest == nil, !planning.isSaving, !capture.isApplying else { return false }
        isOpening = true
        defer { isOpening = false }
        let saved = await flushAll()
        if saved { await encrypted.close() }
        return saved
    }
    func flushAll() async -> Bool {
        guard !planning.hasUnwrittenChanges, !capture.hasWork, !speech.hasWork else { return false }
        for id in Array(documents.keys) {
            guard await persist(id, flush: true) else { return false }
        }
        return true
    }

    /// Refresh on focus, manually, or active-file/parent notifications. A full
    /// recursive FSEvents indexer and large-vault database are later increments.
    func refreshProject() async {
        guard !isRefreshing, let store else { return }
        isRefreshing = true; defer { isRefreshing = false }
        let token = sessionToken
        do {
            let listed = try await store.scan()
            guard token == sessionToken else { return }
            let previousNotes = notes
            notes = listed
            search.reconcile(previous: previousNotes, current: listed)
            connections.reconcileNotes(listed)
            await planning.reload()
            for document in documents.values where !document.isSaving && document.conflict == nil {
                do {
                    let fresh = try await store.readNote(id: document.id)
                    guard token == sessionToken else { return }
                    switch DiskReconciliation.decide(base: document.baseline.bytes, buffer: document.text,
                                                     disk: fresh.bytes, hasLocalEdits: document.isDirty) {
                    case .unchanged:
                        document.baseline = fresh
                        if !document.isDirty { document.failure = nil }
                    case .reloadCleanBuffer:
                        document.reload(fresh)
                        search.observeSaved(fresh)
                        notice = "Updated \(fresh.note.title) from an external edit."
                    case .bufferAlreadyMatchesDisk:
                        document.baseline = fresh; document.committedGeneration = document.editGeneration
                        document.firstDirtyTime = nil; document.failure = nil; document.lastWriteConfirmed = false
                        search.observeSaved(fresh)
                    case .preserveConflict:
                        _ = await persist(document.id)
                    }
                } catch {
                    if document.isDirty { _ = await persist(document.id) }
                    else { document.failure = error.localizedDescription }
                }
            }
            for document in documents.values {
                if let binding = captureBinding(for: document) { capture.targetEdited(binding: binding, generation: document.editGeneration) }
            }
            bindObservation()
        } catch { notice = "Project refresh needs attention: " + error.localizedDescription }
    }

    func recoverProject() async {
        guard let store else { return }
        guard activeSaves.isEmpty else { notice = "Let the current write finish, then run the recovery check."; return }
        do {
            let report = try await store.recover()
            recoveryItems = report.review
            notice = "Recovery check complete: \(report.replayed.count) replayed; \(report.review.count) need review."
            for document in documents.values { document.failure = nil }
            await refreshProject()
            showingRecovery = true
        } catch { errorMessage = error.localizedDescription }
    }

    func reloadDiskAfterConflict() async {
        guard let store, let document = selectedDocument, let conflict = document.conflict, !document.isResolvingConflict else { return }
        document.isResolvingConflict = true
        defer { document.isResolvingConflict = false }
        do {
            if document.text != conflict.localMarkdown {
                let preserved = try await store.preserveDraft(document.baseline, markdown: document.text,
                    reason: "Newer local typing preserved before choosing the disk version.")
                recoveryItems.append(preserved)
            }
            let fresh = try await store.readNote(id: document.id)
            document.reload(fresh); clearPasteNotice(); bindObservation()
        } catch { errorMessage = error.localizedDescription }
    }
    func keepLocalAfterConflict() async {
        guard let store, let document = selectedDocument, document.conflict != nil, !document.isResolvingConflict else { return }
        document.isResolvingConflict = true
        defer { document.isResolvingConflict = false }
        do {
            // Explicit user approval changes the expected base; another race will
            // produce another conflict, not an unconditional overwrite.
            let fresh = try await store.readNote(id: document.id)
            guard let reviewed = document.conflict, reviewed.disk?.revision == fresh.revision else {
                if let old = document.conflict {
                    document.conflict = VaultConflict(id: old.id, relativePath: fresh.note.relativePath,
                        localMarkdown: document.text, disk: fresh, displacedMarkdown: old.displacedMarkdown,
                        explanation: "The file changed again after the comparison was shown. Review this version before choosing Keep My Text again.")
                }
                return
            }
            document.baseline = fresh; document.conflict = nil; document.failure = nil
            document.firstDirtyTime = ProcessInfo.processInfo.systemUptime
            _ = await persist(document.id, flush: true)
        } catch { errorMessage = error.localizedDescription }
    }
    func saveLocalAsNewNote() {
        guard let document = selectedDocument else { return }
        let folder = document.baseline.note.folder == "Project root" ? "Notes" : document.baseline.note.folder
        creationSeed = .init(title: document.baseline.note.title + " — recovered", folder: folder, markdown: document.text)
        showingNewNote = true
    }
    func restoreRecoveryAsNewNote(_ item: RecoveryItem) {
        guard let text = item.proposedMarkdown else { return }
        creationSeed = .init(title: "Recovered note", folder: "Notes", markdown: text)
        showingRecovery = false
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            showingNewNote = true
        }
    }
    func revealRecoveryFolder() {
        if let rootURL { NSWorkspace.shared.activateFileViewerSelecting([rootURL.appendingPathComponent(".folio", isDirectory: true)]) }
    }

    func runCommand(_ command: FolioCommandID) {
        guard commandContext.disabledReason(for: command) == nil else { return }
        switch command {
        case .openProject: Task { await chooseProject() }
        case .newNote: creationSeed = nil; showingNewNote = true
        case .save: Task { await saveSelected() }
        case .searchNotes: showingCommands = false; showingSearch = true
        case .commandPalette: showingSearch = false; showingCommands = true
        case .repairLinks: showingCommands = false; showingLinkRepair = true
        case .showSource: selectedDocument?.editorPresentation = .source
        case .showPreview: selectedDocument?.editorPresentation = .preview
        case .showSplit: selectedDocument?.editorPresentation = .split
        case .followCursor: followSourceCursor()
        case .refresh: Task { await refreshProject() }
        case .recovery: Task { await recoverProject() }
        case .showLauncher: destination = .launcher
        case .showRoadmap: setWorkspaceSection(.roadmap)
        case .showConnections: setWorkspaceSection(.connections)
        case .newRoadmapItem: workspaceSection = .roadmap; planning.beginNew()
        case .capture:
            if capture.draft == nil { beginCaptureForCurrentNote() }
            capture.showingComposer = true
        case .undoRoadmap: Task { await planning.undo() }
        case .redoRoadmap: Task { await planning.redo() }
        case .rebuildSearch:
            let alert = NSAlert()
            alert.messageText = "Rebuild the disposable search cache?"
            alert.informativeText = "Only derived search entries are cleared. Markdown notes and the recovery journal are not changed. Indexing can be paused."
            alert.addButton(withTitle: "Rebuild Search"); alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                Task { await search.clearAndRebuild(notes: notes) }
            }
        }
    }
    func setWorkspaceSection(_ section: WorkspaceSection) {
        workspaceSection = section
        if section == .connections {
            if let id = selectedNoteID { connections.focus = .note(id); connections.selected = .note(id) }
            connections.buildIfNeeded(); connections.project()
        }
    }
    func focusGraph(_ id: GraphEntityID) {
        connections.focus = id; connections.selected = id; connections.camera = .init(); connections.expanded = []
        workspaceSection = .connections; connections.buildIfNeeded(); connections.project()
    }
    func openGraphSelection() {
        guard let node = connections.selectedNode else { return }
        if node.kind == .cluster { connections.expandSelectedCluster(); return }
        guard !node.isMissing, let id = node.id.underlyingUUID else { return }
        if node.kind == .note { Task { await selectNote(id) } }
        else { planning.select(id); workspaceSection = .roadmap }
    }
    func openNoteFromPlanning(_ id: UUID) async { await selectNote(id) }

    func captureBinding(for document: OpenNoteDocument) -> CaptureDocumentBinding? {
        guard let project, let store, documents[document.id] === document else { return nil }
        let workspace = CaptureWorkspace(projectID: project.id, rootIdentity: store.rootIdentity, sessionID: sessionToken)
        return .init(workspace: workspace, noteID: document.id, editorID: document.editorInstanceID)
    }
    func captureSnapshot(for document: OpenNoteDocument) throws -> CaptureTargetSnapshot {
        guard let binding = captureBinding(for: document) else { throw CaptureError.wrongTarget }
        return try .init(binding: binding, generation: document.editGeneration, text: document.text)
    }
    func boundCaptureTarget() throws -> CaptureTargetSnapshot {
        guard let binding = capture.draft?.target, let document = documents[binding.noteID],
              let current = captureBinding(for: document), current == binding else { throw CaptureError.wrongTarget }
        return try captureSnapshot(for: document)
    }
    func beginCaptureForCurrentNote() {
        guard !speech.hasWork else { capture.failure = "Review/use or discard the current voice transcript before starting another capture."; return }
        guard let document = selectedDocument else { return }
        if capture.hasWork {
            let alert = NSAlert()
            alert.messageText = "Discard the current unapplied capture?"
            alert.informativeText = "Its input/context/proposal are kept only in memory until applied. This does not undo any text already accepted into a note."
            alert.addButton(withTitle: "Keep Current Capture"); alert.addButton(withTitle: "Discard and Start New")
            guard alert.runModal() == .alertSecondButtonReturn else { return }
        }
        do { capture.begin(target: try captureSnapshot(for: document), title: document.baseline.note.title) }
        catch { capture.failure = error.localizedDescription }
    }
    func setCaptureDestination(_ kind: Int) {
        guard !speech.blocksCaptureChanges else { return }
        do {
            let target = try boundCaptureTarget()
            let destination: CaptureDestination
            if kind == 1 {
                guard selectedNoteID == target.binding.noteID, let document = selectedDocument else { throw CaptureError.wrongTarget }
                let range = SourceSpan(location: document.selectedRange.location, length: document.selectedRange.length)
                _ = try CaptureTextRanges.targetRange(.selection(range), in: target.text)
                destination = .selection(range)
            } else { destination = kind == 2 ? .body : .append }
            capture.setDestination(destination, target: target)
        } catch { capture.failure = error.localizedDescription }
    }
    func useSelectionAsCaptureInput() {
        guard !speech.blocksCaptureChanges else { return }
        guard let document = selectedDocument else { return }
        do {
            if capture.draft == nil { beginCaptureForCurrentNote() }
            guard document.selectedRange.length > 0 else { throw CaptureError.invalidSelection }
            let range = SourceSpan(location: document.selectedRange.location, length: document.selectedRange.length)
            capture.editInput(try CaptureTextRanges.substring(document.text, span: range), kind: .typed)
        } catch { capture.failure = error.localizedDescription }
    }
    func addCurrentSelectionToCaptureContext() {
        guard !speech.blocksCaptureChanges else { return }
        guard let document = selectedDocument else { return }
        do {
            let target = try boundCaptureTarget()
            guard document.selectedRange.length > 0 else { throw CaptureError.invalidSelection }
            let source = try captureSnapshot(for: document)
            let fragment = try CaptureContextFragment(workspace: source.binding.workspace, noteID: document.id,
                title: document.baseline.note.title, source: document.text,
                range: .init(location: document.selectedRange.location, length: document.selectedRange.length))
            capture.addContext(fragment, target: target, profile: search.profile)
        } catch { capture.failure = error.localizedDescription }
    }
    func addNoteToCaptureContext(_ id: UUID) async {
        guard !speech.blocksCaptureChanges else { return }
        guard let store else { return }
        do {
            let expected = try boundCaptureTarget()
            let text: String, title: String
            if let open = documents[id] { text = open.text; title = open.baseline.note.title }
            else { let saved = try await store.readNote(id: id); text = saved.markdown; title = saved.note.title }
            let current = try boundCaptureTarget()
            guard !speech.blocksCaptureChanges else { throw VoiceError.busy }
            guard current.binding == expected.binding else { throw CaptureError.foreignWorkspace }
            let fragment = try CaptureContextFragment(workspace: expected.binding.workspace, noteID: id, title: title, source: text)
            capture.addContext(fragment, target: current, profile: search.profile)
        } catch { capture.failure = error.localizedDescription }
    }
    func inspectCaptureRequest() {
        guard let draft = capture.draft else { return }
        do {
            capture.preparedRequest = try CapturePreparation.prepare(draft, target: boundCaptureTarget(), profile: search.profile)
            capture.failure = nil; capture.status = "Request prepared for inspection only. Nothing was sent to a provider."
        } catch { capture.failure = error.localizedDescription }
    }
    func generateCapture() {
        guard !speech.blocksCaptureChanges else { capture.failure = "Stop and review or discard voice capture before generating a draft."; return }
        do { capture.generate(target: try boundCaptureTarget(), profile: search.profile) }
        catch { capture.failure = error.localizedDescription }
    }
    func compareCaptureWithCurrent(useCurrentSelection: Bool = false) {
        do {
            let target = try boundCaptureTarget()
            var selection: SourceSpan?
            if useCurrentSelection {
                guard selectedNoteID == target.binding.noteID, let document = selectedDocument, document.selectedRange.length > 0 else { throw CaptureError.invalidSelection }
                selection = .init(location: document.selectedRange.location, length: document.selectedRange.length)
            }
            capture.compareCurrent(target, explicitSelection: selection)
        } catch { capture.failure = error.localizedDescription }
    }
    func applyCaptureApproval() async {
        guard !speech.blocksCaptureChanges else { return }
        guard !capture.isApplying, let proposal = capture.proposal, let store else { return }
        capture.isApplying = true
        do {
            guard workspaceSection == .notes, selectedNoteID == proposal.target.binding.noteID,
                  let document = selectedDocument, document.editorPresentation != .preview,
                  document.conflict == nil, document.failure == nil, document.pendingCaptureEdit == nil else { throw CaptureError.wrongTarget }
            let disk = try await store.readNote(id: document.id)
            guard disk.revision == document.baseline.revision else {
                await refreshProject(); throw CaptureError.staleTarget
            }
            let current = try captureSnapshot(for: document)
            let edit = try proposal.plan(capture.approval(), current: current)
            // Only the native editor may perform this mutation. The model and
            // broker never receive a filesystem or application-action capability.
            document.pendingCaptureEdit = edit
        } catch { capture.mutationFailed(error.localizedDescription) }
    }
    func undoCaptureChange() {
        guard !capture.isApplying, let receipt = capture.undoReceipt, let document = selectedDocument else { return }
        do {
            guard workspaceSection == .notes, document.editorPresentation != .preview, document.pendingCaptureEdit == nil else { throw CaptureError.wrongTarget }
            let edit = try receipt.inverse(current: captureSnapshot(for: document))
            capture.isApplying = true; captureUndoCommands.insert(edit.id); document.pendingCaptureEdit = edit
        } catch { capture.failure = error.localizedDescription }
    }
    func captureMutationFinished(documentID: UUID, commandID: UUID, error: String?) {
        guard let document = documents[documentID], let edit = document.pendingCaptureEdit, edit.id == commandID else { return }
        document.pendingCaptureEdit = nil
        if let error { captureUndoCommands.remove(commandID); capture.mutationFailed(error); return }
        do {
            let actual = try captureSnapshot(for: document)
            guard actual.digest == edit.afterDigest else { throw CaptureError.invalidApproval }
            if captureUndoCommands.remove(commandID) != nil { capture.didUndo() }
            else { capture.didApply(edit, target: actual) }
        } catch { capture.mutationFailed(error.localizedDescription) }
    }

    func openVoiceRecorder() {
        guard !isOpening, !capture.isApplying else { return }
        if capture.draft == nil { beginCaptureForCurrentNote() }
        guard capture.draft != nil else { return }
        if capture.showingComposer { voiceAfterComposer = true; capture.showingComposer = false }
        else { speech.showingRecorder = true }
    }
    func captureComposerDidClose() {
        capture.composerDismissed()
        if voiceAfterComposer { voiceAfterComposer = false; speech.showingRecorder = true }
    }
    func startVoiceCapture() async {
        guard !isOpening, !capture.isGenerating, !capture.isApplying, let draft = capture.draft else { return }
        guard await capture.permitsVoiceRecording(), !capture.isGenerating, !capture.isApplying else {
            speech.failure = "The local text model is still running or cancelling. Finish it before microphone capture."; return
        }
        guard capture.draft?.id == draft.id, capture.draft?.revision == draft.revision else { speech.failure = VoiceError.staleReview.localizedDescription; return }
        speech.start(draft: draft, profile: search.profile)
    }
    func useReviewedVoice() {
        guard !capture.isGenerating, !capture.isApplying else { return }
        if !capture.input.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Replace the current capture input with this reviewed transcript?"
            alert.informativeText = "The existing capture input/proposal is not a saved note. It will be replaced only if you approve. No AI request or note edit starts automatically."
            alert.addButton(withTitle: "Keep Existing Input"); alert.addButton(withTitle: "Use Reviewed Transcript")
            guard alert.runModal() == .alertSecondButtonReturn else { return }
        }
        do {
            let reviewed = try speech.reviewedTranscript()
            try capture.importReviewedVoice(reviewed)
            speech.consumedTranscript()
        } catch { speech.failure = error.localizedDescription }
    }
    func discardVoiceWithConfirmation() {
        let alert = NSAlert()
        alert.messageText = "Discard this voice capture?"
        alert.informativeText = "The transcript is held only in memory. Folio has not saved an audio recording or applied the text to a note."
        alert.addButton(withTitle: "Keep"); alert.addButton(withTitle: "Stop and Discard")
        if alert.runModal() == .alertSecondButtonReturn { speech.discardAfterStopped() }
    }
    func stopVoiceBeforeQuit() { if speech.hasWork { speech.haltForDisappearance(.applicationInactive) } }

    func followSourceCursor() {
        guard let document = selectedDocument else { return }
        document.previewRequest = PreviewFollowRequest(sourceOffset: document.selectedRange.location, heading: nil)
    }
    func activatePreviewLink(_ link: MarkdownLink) {
        switch link {
        case .blocked: notice = "That link type is not allowed in the reading preview."
        case .external(let value):
            guard case .external = MarkdownLinkPolicy.classify(value), let url = URL(string: value) else { return }
            let alert = NSAlert()
            alert.messageText = "Open this link outside Folio?"
            alert.informativeText = value + "\n\nYour default browser or mail app may connect to a network service."
            alert.addButton(withTitle: "Open External Link"); alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(url) }
        case .anchor(let heading): selectedDocument?.previewRequest = .init(sourceOffset: nil, heading: heading)
        case .note(let target):
            let candidates = notes.map {
                NoteLinkCandidate(id: $0.id, title: $0.title, path: $0.relativePath,
                                  tags: search.knownTags[$0.id] ?? [], modifiedAt: $0.modifiedAt)
            }
            let result = NoteLinkResolver.resolve(target, from: selectedDocument?.baseline.note.relativePath ?? "", candidates: candidates)
            switch result {
            case .missing: linkChoice = .init(target: target, candidates: [], originMode: selectedDocument?.editorPresentation ?? .source)
            case .ambiguous(let matches): linkChoice = .init(target: target, candidates: matches, originMode: selectedDocument?.editorPresentation ?? .source)
            case .unique(let candidate):
                let mode = selectedDocument?.editorPresentation ?? .source
                Task {
                    await selectNote(candidate.id)
                    guard selectedNoteID == candidate.id else { return }
                    selectedDocument?.editorPresentation = mode
                    if let separator = target.firstIndex(of: "#") {
                        selectedDocument?.previewRequest = .init(sourceOffset: nil, heading: String(target[target.index(after: separator)...]))
                    }
                }
            }
        }
    }

    // MARK: - Compact link repair (Increment 11)

    private func linkCandidates() -> [NoteLinkCandidate] {
        notes.map {
            NoteLinkCandidate(id: $0.id, title: $0.title, path: $0.relativePath,
                              tags: search.knownTags[$0.id] ?? [], modifiedAt: $0.modifiedAt)
        }
    }

    /// Broken and ambiguous links in the open note, with the same resolution
    /// the preview link click uses. Nothing is rewritten by inspecting.
    func linkRepairInspections() -> [NoteLinkInspection] {
        guard let document = selectedDocument else { return [] }
        return NoteLinkRepair.inspect(source: document.text,
                                      sourcePath: document.baseline.note.relativePath,
                                      candidates: linkCandidates())
    }

    /// Applies one user-confirmed replacement. The original link is kept until
    /// this succeeds; on any refusal the note text is untouched and the reason
    /// is returned for display.
    func applyLinkRepair(_ inspection: NoteLinkInspection, to candidate: NoteLinkCandidate) -> String? {
        guard let document = selectedDocument else { return "Open a note first." }
        let replacement = NoteLinkRepair.replacementTarget(candidate, for: inspection.occurrence)
        do {
            let edit = try NoteLinkRepair.edit(replacing: inspection.occurrence, with: replacement, in: document.text)
            let repaired = try NoteLinkRepair.apply(edit, to: document.text)
            document.text = repaired
            document.editGeneration += 1
            return nil
        } catch let error as NoteLinkRepairError {
            switch error {
            case .staleSource:
                return "The note changed since this list was computed. Review the links again before replacing."
            case .spanMismatch:
                return "This link no longer matches the note text. Review the links again."
            case .blockedReplacement:
                return "That replacement would break the link syntax. The note was not changed."
            }
        } catch {
            return "The repair was not applied. The note was not changed."
        }
    }

    private func bindObservation() {
        guard let rootURL, let document = selectedDocument else { observation.stop(); return }
        let token = sessionToken
        observation.observe(file: rootURL.appendingPathComponent(document.baseline.note.relativePath)) { [weak self] in
            Task { @MainActor [weak self] in self?.scheduleObservedRefresh(token: token) }
        }
    }
    private func scheduleObservedRefresh(token: UUID) {
        guard token == sessionToken else { return }
        observationTask?.cancel()
        observationTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            guard let self, token == self.sessionToken else { return }
            await self.refreshProject()
        }
    }
    private func updateRow(_ note: VaultNote) {
        notes.removeAll { $0.id == note.id }; notes.append(note)
        notes.sort { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
    }
    func loadKnownProjects() -> [KnownProjectIdentity] {
        guard let data = UserDefaults.standard.data(forKey: "knownProjectIdentities") else { return [] }
        return (try? JSONDecoder().decode([KnownProjectIdentity].self, from: data)) ?? []
    }
    private func saveRecentProjects() {
        let bounded = Array(recentProjects.suffix(50))
        recentProjects = bounded
        if let data = try? JSONEncoder().encode(bounded) {
            UserDefaults.standard.set(data, forKey: "knownProjectIdentities")
        }
    }
    private func recordProject(_ project: VaultProject, rootIdentity: String) {
        // The bookmark is what allows Open Recent to reopen this folder without
        // asking the user to pick it again; the sandbox does not grant access to
        // a remembered path on its own.
        let bookmark = try? folderGrant?.url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        var known = recentProjects.filter { $0.projectID != project.id }
        known.append(.init(
            projectID: project.id,
            rootIdentity: rootIdentity,
            name: project.name,
            bookmark: bookmark,
            folderPath: folderGrant?.url.path
        ))
        recentProjects = known
        saveRecentProjects()
    }
    func showPasteNotice(_ message: String, undo: @escaping () -> Void) { pasteMessage = message; pasteUndoAction = undo }
    func clearPasteNotice() { pasteMessage = nil; pasteUndoAction = nil }
    func undoConvertedPaste() { let action = pasteUndoAction; clearPasteNotice(); action?() }
}

private extension RecoveryItem {
    static func initForApp(_ conflict: VaultConflict) -> RecoveryItem {
        .init(id: conflict.id, relativePath: conflict.relativePath,
              explanation: conflict.explanation, proposedMarkdown: conflict.localMarkdown)
    }
}
