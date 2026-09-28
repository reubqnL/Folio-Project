import Foundation
import Observation
import FolioCore

@MainActor
@Observable
final class NoteSearchController {
    var query = ""
    var scope: NoteSearchScope = .everything
    var results: [NoteSearchHit] = []
    var isSearching = false
    var isIndexing = false
    var completed = 0
    var total = 0
    var skipped = 0
    var message = "Open a project to search."
    var failure: String?
    var profile: SearchProfile = .balanced
    var knownTags: [UUID: [String]] = [:]
    var cacheURL: URL?
    @ObservationIgnored private var index: LocalSearchIndex?
    @ObservationIgnored private var store: PlainVaultStore?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var queryTask: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var queryGeneration = UUID()
    @ObservationIgnored private var rebuildGeneration = UUID()
    @ObservationIgnored private var projectID: UUID?
    @ObservationIgnored private var cacheDirectory: URL?

    init() {
        profile = SearchProfile(rawValue: UserDefaults.standard.string(forKey: "searchProfile") ?? "") ?? .balanced
    }

    func disconnect() async {
        task?.cancel(); queryTask?.cancel(); generation = UUID(); rebuildGeneration = UUID(); queryGeneration = UUID()
        if let index { await index.close() }
        index = nil; store = nil; projectID = nil; cacheDirectory = nil; cacheURL = nil
        knownTags = [:]; results = []; query = ""; isSearching = false; isIndexing = false
        completed = 0; total = 0; skipped = 0; failure = nil; message = "Open a project to search."
    }

    func connect(store: PlainVaultStore, project: VaultProject, notes: [VaultNote], profile: SearchProfile) async {
        task?.cancel(); queryTask?.cancel(); generation = UUID(); rebuildGeneration = UUID()
        if let old = index { await old.close() }
        self.store = store; self.projectID = project.id; self.profile = profile; index = nil
        knownTags = [:]; results = []; query = ""; failure = nil; cacheURL = nil
        isSearching = false; isIndexing = false; completed = 0; total = notes.count; skipped = 0
        message = "Preparing local search…"
        let token = generation
        do {
            let base = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let directory = base.appendingPathComponent("Folio/Search", isDirectory: true)
            cacheDirectory = directory
            let opened = try await LocalSearchIndex.open(cacheDirectory: directory, vaultRoot: store.rootURL,
                projectID: project.id, rootIdentity: store.rootIdentity, profile: profile)
            guard token == generation else { await opened.close(); return }
            index = opened; cacheURL = opened.fileURL
            var cache = opened.fileURL
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try? cache.setResourceValues(values)
            rebuild(notes: notes)
        } catch {
            guard token == generation else { return }
            failure = error.localizedDescription
            message = "Search unavailable; notes and saving still work."
        }
    }

    func rebuild(notes: [VaultNote]) {
        guard let index, let store else { return }
        task?.cancel()
        let token = generation
        let job = UUID(); rebuildGeneration = job
        isIndexing = true; completed = 0; total = notes.count; skipped = 0; failure = nil
        message = "Indexing current project…"
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            var rebuild: IndexRebuildTicket?
            do {
                try Task.checkCancellation()
                let batch = try await index.beginRebuild(); rebuild = batch
                for note in notes {
                    try Task.checkCancellation()
                    // Lease precedes the read. A newer live save invalidates it.
                    let ticket = try await index.reserveUpdate(for: note.id)
                    do {
                        let snapshot = try await store.readNote(id: note.id)
                        try Task.checkCancellation()
                        let entry = await Task.detached(priority: .utility) { IndexedNote(snapshot: snapshot) }.value
                        let applied = try await index.upsert(entry, ticket: ticket, rebuild: batch)
                        guard token == self.generation, job == self.rebuildGeneration else { return }
                        if applied { self.knownTags[note.id] = entry.tags }
                    } catch is CancellationError { throw CancellationError() }
                    catch {
                        guard token == self.generation, job == self.rebuildGeneration else { return }
                        self.skipped += 1
                    }
                    self.completed += 1
                    if self.completed % self.profile.indexingBatchSize == 0 { await Task.yield() }
                }
                let finished = try await index.finishRebuild(batch)
                guard token == self.generation, job == self.rebuildGeneration, finished else { return }
                self.isIndexing = false
                self.message = self.skipped == 0 ? "Local search ready" : "Search ready with \(self.skipped) unreadable/unsupported note(s) omitted."
                self.search()
            } catch {
                if let rebuild { await index.cancelRebuild(rebuild) }
                guard token == self.generation, job == self.rebuildGeneration else { return }
                self.isIndexing = false
                if error is CancellationError { self.message = "Index update cancelled; results may be incomplete." }
                else { self.failure = error.localizedDescription; self.message = "Index update incomplete; notes are unchanged." }
            }
        }
    }

    /// Fire-and-forget AFTER a store acknowledgement; index failure never changes
    /// the file save result. Reservations protect against older rebuild reads.
    func observeSaved(_ snapshot: VaultSnapshot) {
        guard let index, let store else { return }
        let token = generation
        Task { @MainActor [weak self] in
            do {
                let lease = try await index.reserveUpdate(for: snapshot.note.id)
                // Re-read after reserving; delayed save notifications must not
                // put an older snapshot over a later acknowledgement.
                let fresh = try await store.readNote(id: snapshot.note.id)
                let entry = await Task.detached(priority: .utility) { IndexedNote(snapshot: fresh) }.value
                let applied = try await index.upsert(entry, ticket: lease)
                guard let self, token == self.generation, applied else { return }
                self.knownTags[snapshot.note.id] = entry.tags
                if !self.query.isEmpty { self.search() }
            } catch {
                guard let self, token == self.generation else { return }
                self.failure = error.localizedDescription
                self.message = "The note file is intact; its search entry could not be updated."
            }
        }
    }

    func reconcile(previous: [VaultNote], current: [VaultNote]) {
        guard let index, let store else { return }
        let old = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
        let ids = Set(current.map(\.id))
        let removed = previous.filter { !ids.contains($0.id) }.map(\.id)
        let changed = current.filter { old[$0.id] != $0 }
        let token = generation
        Task { @MainActor [weak self] in
            guard let self else { return }
            for id in removed {
                guard token == self.generation else { return }
                try? await index.remove(id); self.knownTags.removeValue(forKey: id)
            }
            for note in changed {
                guard token == self.generation else { return }
                do {
                    let lease = try await index.reserveUpdate(for: note.id)
                    let snapshot = try await store.readNote(id: note.id)
                    let entry = await Task.detached(priority: .utility) { IndexedNote(snapshot: snapshot) }.value
                    let applied = try await index.upsert(entry, ticket: lease)
                    if applied, token == self.generation { self.knownTags[note.id] = entry.tags }
                } catch {
                    guard token == self.generation else { return }
                    // A stale cache result must never authoritatively open a
                    // removed/unreadable file. Rebuilding remains available.
                    self.message = "Some search entries need a rebuild."
                }
            }
            if token == self.generation, !self.query.isEmpty { self.search() }
        }
    }

    func search() {
        queryTask?.cancel(); queryGeneration = UUID()
        let request = queryGeneration, token = generation
        let text = query, scope = scope
        guard let index, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            results = []; isSearching = false; return
        }
        isSearching = true; results = []
        queryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(150))
                let results = try await index.search(text, scope: scope)
                try Task.checkCancellation()
                guard let self, self.generation == token, self.queryGeneration == request else { return }
                self.results = results; self.isSearching = false; self.failure = nil
            } catch {
                guard let self, self.generation == token, self.queryGeneration == request else { return }
                self.isSearching = false
                if !(error is CancellationError) { self.failure = error.localizedDescription }
            }
        }
    }
    func setProfile(_ value: SearchProfile) {
        profile = value
        guard let index else { return }
        Task { @MainActor [weak self] in
            do { try await index.setProfile(value) }
            catch { self?.failure = error.localizedDescription }
        }
    }
    func cancelIndexing() { task?.cancel() }
    func clearAndRebuild(notes: [VaultNote]) async {
        guard let store, let projectID, let cacheDirectory else { return }
        let token = generation
        task?.cancel(); queryTask?.cancel(); rebuildGeneration = UUID()
        if let index { await index.close() }
        index = nil; results = []; knownTags = [:]
        do {
            try await LocalSearchIndex.discardCacheAfterConfirmation(cacheDirectory: cacheDirectory, vaultRoot: store.rootURL,
                projectID: projectID, rootIdentity: store.rootIdentity)
            let fresh = try await LocalSearchIndex.open(cacheDirectory: cacheDirectory, vaultRoot: store.rootURL,
                projectID: projectID, rootIdentity: store.rootIdentity, profile: profile)
            guard token == generation else { await fresh.close(); return }
            index = fresh; cacheURL = fresh.fileURL; failure = nil
            rebuild(notes: notes)
        } catch {
            guard token == generation else { return }
            failure = error.localizedDescription; isIndexing = false; message = "Search rebuild could not start; note files were not changed."
        }
    }
}
