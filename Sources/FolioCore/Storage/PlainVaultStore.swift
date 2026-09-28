import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private struct NoteIdentity: Codable, Equatable, Sendable {
    let id: UUID
    var fileIdentity: String
}
private struct ProjectManifest: Codable, Sendable {
    let version: Int
    var project: VaultProject
    var notes: [String: NoteIdentity]
}
private struct JournalIntent: Codable, Sendable {
    let version: Int
    let id: UUID
    let projectID: UUID
    let noteID: UUID
    let relativePath: String
    let beforeDigest: String?
    let proposedDigest: String
    let permissions: UInt32
    let createdAt: Double
}
private struct CommitReceipt: Codable, Sendable {
    let version: Int
    let id: UUID
    let proposedDigest: String
    let displacedDigest: String
}

/// Plaintext local-project store. Not an encrypted store or sync transport.
/// The actor serializes Folio writers; an advisory lock excludes other Folio
/// processes. Arbitrary external editors are not assumed to obey that lock.
public actor PlainVaultStore {
    public nonisolated let rootURL: URL
    public nonisolated let rootIdentity: String
    private let files: VaultFileSystem
    private let roadmapPersistence: RoadmapPersistence
    private let limits: VaultLimits
    private var manifest: ProjectManifest
    private var manifestBytes: Data
    private var pathsByID: [UUID: String]
    private var needsRecovery: Bool
    private var isClosed = false

    public static func open(at url: URL, createIfMissing: Bool = false, name: String? = nil,
                            limits: VaultLimits = .init()) async throws -> PlainVaultStore {
        try await Task.detached(priority: .userInitiated) {
            try PlainVaultStore(root: url, createIfMissing: createIfMissing, name: name, limits: limits)
        }.value
    }

    private init(root: URL, createIfMissing: Bool, name: String?, limits: VaultLimits) throws {
        guard (1...64 * 1024 * 1024).contains(limits.maximumNoteBytes),
              (1...1_000_000).contains(limits.maximumEntries),
              (1...128).contains(limits.maximumDepth),
              (1...64 * 1024 * 1024).contains(limits.maximumMetadataBytes),
              (1...512 * 1024 * 1024).contains(limits.maximumJournalBytes),
              (0...1000).contains(limits.retainedCommittedTransactions) else { throw VaultError.tooLarge }
        let fs = try VaultFileSystem(url: root)
        let existing = try fs.stat(".folio/project.json")
        if existing == nil && !createIfMissing { throw VaultError.needsInitialization }
        try fs.directory(".folio")
        try fs.acquireLock()
        try fs.directory(".folio/journal")
        let initial: ProjectManifest
        let bytes: Data
        if let value = try fs.readIfPresent(".folio/project.json", limit: limits.maximumMetadataBytes) {
            initial = try Self.decodeManifest(value.data, limits: limits)
            bytes = value.data
        } else {
            let cleaned = (name ?? root.lastPathComponent).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { throw VaultError.malformedMetadata }
            initial = ProjectManifest(version: 1, project: .init(id: UUID(), name: cleaned), notes: [:])
            bytes = try Self.encode(initial)
            let staging = ".folio/project-\(UUID().uuidString).tmp"
            try fs.writeNew(staging, bytes: bytes)
            try fs.linkNew(staging, to: ".folio/project.json")
            try fs.remove(staging)
        }
        self.rootURL = root
        self.rootIdentity = fs.rootIdentity
        self.files = fs
        self.roadmapPersistence = RoadmapPersistence(files: fs)
        self.limits = limits
        self.manifest = initial
        self.manifestBytes = bytes
        self.pathsByID = Dictionary(uniqueKeysWithValues: initial.notes.map { ($0.value.id, $0.key) })
        let noteRecovery = !(try fs.entries(".folio/journal", limit: 4096)).isEmpty
        let hasPlanningJournal = try fs.stat(".folio/roadmap-journal") != nil
        let planningRecovery = hasPlanningJournal ? !(try fs.entries(".folio/roadmap-journal", limit: 1024)).isEmpty : false
        self.needsRecovery = noteRecovery || planningRecovery
    }

    public func project() throws -> VaultProject { try requireOpen(); return manifest.project }
    public func close() { files.close(); isClosed = true }

    public func loadRoadmap() throws -> RoadmapSnapshot {
        try requireOpen()
        return try roadmapPersistence.load(projectID: manifest.project.id, rootIdentity: rootIdentity)
    }
    public func saveRoadmap(_ base: RoadmapSnapshot, document: RoadmapDocument,
                            hooks: VaultTestHooks = .init()) throws -> RoadmapSaveResult {
        try requireWritable()
        guard base.projectID == manifest.project.id, base.rootIdentity == rootIdentity else { throw PlanningError.wrongWorkspace }
        try RoadmapEngine.validateStructure(document)
        let issues = RoadmapEngine.issues(in: document)
        guard issues.isEmpty else { throw PlanningError.invalidChange(issues) }
        guard document.revision != base.document.revision else { throw PlanningError.staleRevision }
        do { return try roadmapPersistence.save(base: base, document: document, projectID: manifest.project.id, rootIdentity: rootIdentity, hooks: hooks) }
        catch { needsRecovery = true; throw error }
    }


    /// Called only after the user explicitly chooses a new workspace identity.
    /// Outstanding recovery must be processed first; old reviewed records remain
    /// private copies, not operations eligible to merge into the new identity.
    public func forkIdentity(name: String? = nil) throws -> VaultProject {
        try requireWritable()
        manifest.project = VaultProject(id: UUID(), name: name ?? manifest.project.name)
        try persistManifest()
        return manifest.project
    }

    public func scan() throws -> [VaultNote] {
        try requireWritable()
        var found: [(String, FileStamp)] = []
        var visited = 0
        func walk(_ directory: String, depth: Int) throws {
            guard depth <= limits.maximumDepth else { throw VaultError.tooLarge }
            for (name, stamp) in try files.entries(directory, limit: limits.maximumEntries) {
                visited += 1
                guard visited <= limits.maximumEntries else { throw VaultError.tooLarge }
                if name.hasPrefix(".") || stamp.kind == 3 { continue }
                let path = directory.isEmpty ? name : directory + "/" + name
                // Unsupported path spellings are never rewritten into "safe" names.
                guard (try? VaultPaths.validateRelative(path)) != nil else { continue }
                if stamp.kind == 2 { try walk(path, depth: depth + 1) }
                else if ["md", "markdown"].contains((path as NSString).pathExtension.lowercased()) { found.append((path, stamp)) }
            }
        }
        try walk("", depth: 0)
        let currentPaths = Set(found.map(\.0))
        let previous = manifest.notes
        var next = previous
        let absentByFileIdentity = Dictionary(grouping: previous.filter { !currentPaths.contains($0.key) }, by: { $0.value.fileIdentity })
        var usedIDs = Set<UUID>()
        var result: [VaultNote] = []
        for (path, stamp) in found.sorted(by: { $0.0 < $1.0 }) {
            var identity: NoteIdentity
            if let exact = previous[path] { identity = exact }
            else {
                // Only unambiguous, missing-path inode matches count as a move.
                // A copied/hard-linked file with its original still present is new.
                let candidates = (absentByFileIdentity[stamp.identity] ?? []).filter { !usedIDs.contains($0.value.id) }
                if candidates.count == 1, let moved = candidates.first {
                    identity = moved.value; next.removeValue(forKey: moved.key)
                } else { identity = NoteIdentity(id: UUID(), fileIdentity: stamp.identity) }
            }
            if usedIDs.contains(identity.id) { throw VaultError.malformedMetadata }
            identity.fileIdentity = stamp.identity
            usedIDs.insert(identity.id); next[path] = identity
            result.append(note(id: identity.id, path: path, stamp: stamp))
        }
        guard next.count <= limits.maximumEntries else { throw VaultError.tooLarge }
        if next != previous {
            manifest.notes = next
            pathsByID = Dictionary(uniqueKeysWithValues: next.map { ($0.value.id, $0.key) })
            try persistManifest()
        }
        return result.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
    }

    public func readNote(id: UUID) throws -> VaultSnapshot {
        try requireOpen()
        guard let path = pathsByID[id] else { throw VaultError.missingNote }
        return try readSnapshot(id: id, path: path)
    }

    public func createNote(title: String, folder: String, markdown: String? = nil,
                           hooks: VaultTestHooks = .init()) throws -> VaultSaveResult {
        try requireWritable()
        let request = try DraftNote(title: title, relativeFolder: folder)
        let filename = request.title.lowercased().hasSuffix(".md") ? request.title : request.title + ".md"
        let path = request.relativeFolder + "/" + filename
        try VaultPaths.validateNote(path)
        if try files.stat(path) != nil { throw VaultError.io(code: EEXIST, operation: "Create note", path: path) }
        return try write(id: UUID(), path: path, before: nil,
                         proposed: Data((markdown ?? request.markdown).utf8), permissions: 0o600, hooks: hooks)
    }

    public func save(_ base: VaultSnapshot, markdown: String,
                     hooks: VaultTestHooks = .init()) throws -> VaultSaveResult {
        try requireWritable()
        guard base.projectID == manifest.project.id, base.rootIdentity == rootIdentity else { throw VaultError.wrongWorkspace }
        guard let path = pathsByID[base.note.id] else { throw VaultError.missingNote }
        let proposed = Data(markdown.utf8)
        guard proposed.count <= limits.maximumNoteBytes else { throw VaultError.tooLarge }
        // A no-op still checks the disk: it must not falsely acknowledge stale data.
        if proposed == base.bytes,
           let disk = try files.readIfPresent(path, limit: limits.maximumNoteBytes), disk.data == base.bytes {
            return .written(snapshot(id: base.note.id, path: path, file: disk))
        }
        return try write(id: base.note.id, path: path, before: base.bytes,
                         proposed: proposed, permissions: base.permissions, hooks: hooks)
    }

    /// Persist a local buffer for explicit review without ever installing it.
    /// Used before discarding a buffer whose text changed after a conflict arose.
    public func preserveDraft(_ base: VaultSnapshot, markdown: String, reason: String) throws -> RecoveryItem {
        try requireWritable()
        guard base.projectID == manifest.project.id, base.rootIdentity == rootIdentity else { throw VaultError.wrongWorkspace }
        guard let path = pathsByID[base.note.id] else { throw VaultError.missingNote }
        let proposed = Data(markdown.utf8)
        guard proposed.count <= limits.maximumNoteBytes else { throw VaultError.tooLarge }
        try pruneCommittedHistory(reserving: base.bytes.count + proposed.count * 2 + 8192)
        let id = UUID(), dir = transactionPath(id)
        let intent = JournalIntent(version: 1, id: id, projectID: manifest.project.id,
            noteID: base.note.id, relativePath: path, beforeDigest: ContentDigest.sha256(base.bytes),
            proposedDigest: ContentDigest.sha256(proposed), permissions: base.permissions,
            createdAt: Date().timeIntervalSince1970)
        try files.directory(dir)
        // REVIEW precedes the seal: even a crash cannot turn this into an
        // automatically replayable save transaction.
        try files.writeNew(dir + "/REVIEW", bytes: Data(reason.prefix(4096).utf8))
        try files.writeNew(dir + "/base.md", bytes: base.bytes)
        try files.writeNew(dir + "/proposal.md", bytes: proposed)
        try files.writeNew(dir + "/install.md", bytes: proposed)
        try files.writeNew(dir + "/intent.json", bytes: Self.encode(intent))
        return RecoveryItem(id: id, relativePath: path, explanation: reason, proposedMarkdown: markdown)
    }

    private func write(id: UUID, path: String, before: Data?, proposed: Data,
                       permissions: UInt32, hooks: VaultTestHooks) throws -> VaultSaveResult {
        try VaultPaths.validateNote(path)
        guard proposed.count <= limits.maximumNoteBytes else { throw VaultError.tooLarge }
        let observedPermissions = try files.stat(path)?.permissions ?? permissions
        guard observedPermissions & 0o200 != 0 else { throw VaultError.readOnly }
        try pruneCommittedHistory(reserving: proposed.count * 2 + (before?.count ?? 0) + limits.maximumNoteBytes + 8192)
        let transactionID = UUID()
        let dir = transactionPath(transactionID)
        let intent = JournalIntent(version: 1, id: transactionID, projectID: manifest.project.id,
                                   noteID: id, relativePath: path,
                                   beforeDigest: before.map(ContentDigest.sha256),
                                   proposedDigest: ContentDigest.sha256(proposed), permissions: observedPermissions & 0o777,
                                   createdAt: Date().timeIntervalSince1970)
        do {
            try files.directory(dir)
            if let before { try files.writeNew(dir + "/base.md", bytes: before) }
            try files.writeNew(dir + "/proposal.md", bytes: proposed)
            try files.writeNew(dir + "/install.md", bytes: proposed, permissions: observedPermissions)
            // Written last. An incomplete/unsealed transaction is never replayed.
            try files.writeNew(dir + "/intent.json", bytes: Self.encode(intent))
            try hooks.onStage?(.journalSealed)
            let current = try files.readIfPresent(path, limit: limits.maximumNoteBytes)
            guard current?.data == before else {
                return try conflict(intent, disk: current, explanation: "The file changed outside Folio. Neither version was discarded.")
            }
            if let current, current.stamp.permissions & 0o200 == 0 {
                return try conflict(intent, disk: current, explanation: "The file became read-only. Local text was preserved without replacing it.")
            }
            try hooks.onStage?(.beforeInstall)
            try install(intent)
            try hooks.onStage?(.installed)
            let displaced = try files.read(dir + "/install.md", limit: limits.maximumNoteBytes)
            let expectedDisplaced = before ?? proposed
            guard displaced.data == expectedDisplaced else {
                return try conflict(intent, disk: try files.readIfPresent(path, limit: limits.maximumNoteBytes),
                                    explanation: "An external write raced the commit. Its displaced bytes are preserved in recovery; review both versions.",
                                    displaced: displaced.data)
            }
            let installed = try files.read(path, limit: limits.maximumNoteBytes)
            guard installed.data == proposed else {
                return try conflict(intent, disk: installed,
                                    explanation: "The file changed again during the commit. Local text remains in the recovery journal.")
            }
            registerIdentity(id, path: path, fileIdentity: installed.stamp.identity)
            try persistManifest()
            try hooks.onStage?(.metadataUpdated)
            try markCommitted(intent, displacedDigest: ContentDigest.sha256(displaced.data))
            try hooks.onStage?(.committed)
            return .written(snapshot(id: id, path: path, file: installed))
        } catch {
            // The caller keeps its editing buffer. Further writes wait for recovery,
            // rather than guessing whether a failed sync/rename reached storage.
            needsRecovery = true
            throw error
        }
    }

    private func install(_ intent: JournalIntent) throws {
        let parent = (intent.relativePath as NSString).deletingLastPathComponent
        if !parent.isEmpty { try files.directory(parent) }
        let staged = transactionPath(intent.id) + "/install.md"
        if intent.beforeDigest == nil { try files.linkNew(staged, to: intent.relativePath) }
        else {
            try files.copyMetadata(intent.relativePath, to: staged)
            try files.exchange(staged, with: intent.relativePath)
        }
        try files.syncParent(intent.relativePath)
    }

    private func conflict(_ intent: JournalIntent, disk: FileBytes?, explanation: String,
                          displaced: Data? = nil) throws -> VaultSaveResult {
        let dir = transactionPath(intent.id)
        if let disk, try files.stat(dir + "/external.md") == nil {
            try files.writeNew(dir + "/external.md", bytes: disk.data)
        }
        if try files.stat(dir + "/REVIEW") == nil {
            try files.writeNew(dir + "/REVIEW", bytes: Data(explanation.utf8))
        }
        let local = try files.read(dir + "/proposal.md", limit: limits.maximumNoteBytes).data
        return .conflict(VaultConflict(id: intent.id, relativePath: intent.relativePath,
                                      localMarkdown: String(decoding: local, as: UTF8.self),
                                      disk: disk.flatMap { String(data: $0.data, encoding: .utf8) != nil ? snapshot(id: intent.noteID, path: intent.relativePath, file: $0) : nil },
                                      displacedMarkdown: displaced.map { String(decoding: $0, as: UTF8.self) }, explanation: explanation))
    }

    /// Replays only a sealed, validated operation whose file is still at its
    /// recorded base. A changed head, invalid payload or REVIEW marker is never
    /// overwritten automatically. Committed records never roll a note backwards.
    public func recover(replay: Bool = true) throws -> RecoveryReport {
        try requireOpen()
        let reloaded = try files.read(".folio/project.json", limit: limits.maximumMetadataBytes).data
        let decoded = try Self.decodeManifest(reloaded, limits: limits)
        guard decoded.project.id == manifest.project.id else { throw VaultError.wrongWorkspace }
        manifest = decoded; manifestBytes = reloaded
        pathsByID = Dictionary(uniqueKeysWithValues: decoded.notes.map { ($0.value.id, $0.key) })
        var report = RecoveryReport()
        var ioRemainsUncertain = false
        for (name, stamp) in try files.entries(".folio/journal", limit: 4096).sorted(by: { $0.0 < $1.0 }) {
            guard stamp.kind == 2, let id = UUID(uuidString: name), id.uuidString == name else { continue }
            let dir = transactionPath(id)
            do {
                let intent = try readIntent(id)
                let proposed = try verifiedPayload(dir + "/proposal.md", digest: intent.proposedDigest)
                let base = try intent.beforeDigest.map { try verifiedPayload(dir + "/base.md", digest: $0) }
                if let receipt = try readReceipt(intent) {
                    // A late write through an old external descriptor may have
                    // altered the preserved displaced inode. Never prune that copy.
                    let displaced = try files.read(dir + "/install.md", limit: limits.maximumNoteBytes).data
                    if ContentDigest.sha256(displaced) != receipt.displacedDigest {
                        report.review.append(.init(id: id, relativePath: intent.relativePath,
                                                   explanation: "An external writer changed a preserved old version after commit.", proposedMarkdown: String(decoding: displaced, as: UTF8.self)))
                        if try files.stat(dir + "/REVIEW") == nil { try files.writeNew(dir + "/REVIEW", bytes: Data("Late displaced write".utf8)) }
                    }
                    continue
                }
                if try files.stat(dir + "/REVIEW") != nil || intent.projectID != manifest.project.id || !replay {
                    if !replay, try files.stat(dir + "/REVIEW") == nil {
                        try files.writeNew(dir + "/REVIEW", bytes: Data("Copied workspace proposal; explicit review required".utf8))
                    }
                    report.review.append(.init(id: id, relativePath: intent.relativePath,
                                               explanation: "This saved proposal requires explicit review; it was not applied.", proposedMarkdown: String(decoding: proposed, as: UTF8.self)))
                    continue
                }
                let current = try files.readIfPresent(intent.relativePath, limit: limits.maximumNoteBytes)
                if current?.data != proposed {
                    guard current?.data == base else {
                        _ = try conflict(intent, disk: current, explanation: "Recovery found a changed file. Both versions were retained.")
                        report.review.append(.init(id: id, relativePath: intent.relativePath, explanation: "The file no longer matches the recorded base.", proposedMarkdown: String(decoding: proposed, as: UTF8.self)))
                        continue
                    }
                    if let current, current.stamp.permissions & 0o200 == 0 {
                        _ = try conflict(intent, disk: current, explanation: "Recovery found a read-only file; no replacement was attempted.")
                        report.review.append(.init(id: id, relativePath: intent.relativePath, explanation: "The destination is read-only.", proposedMarkdown: String(decoding: proposed, as: UTF8.self)))
                        continue
                    }
                    // Before-install crashes leave this slot containing the proposal.
                    let staging = try files.read(dir + "/install.md", limit: limits.maximumNoteBytes).data
                    guard staging == proposed else { throw VaultError.invalidRecovery }
                    try install(intent)
                }
                let displaced = try files.read(dir + "/install.md", limit: limits.maximumNoteBytes).data
                guard displaced == (base ?? proposed) else {
                    _ = try conflict(intent, disk: try files.readIfPresent(intent.relativePath, limit: limits.maximumNoteBytes),
                                     explanation: "Recovery preserved an unexpected displaced version.", displaced: displaced)
                    report.review.append(.init(id: id, relativePath: intent.relativePath, explanation: "An external version raced the interrupted write.", proposedMarkdown: String(decoding: proposed, as: UTF8.self)))
                    continue
                }
                let installed = try files.read(intent.relativePath, limit: limits.maximumNoteBytes)
                guard installed.data == proposed else { throw VaultError.invalidRecovery }
                registerIdentity(intent.noteID, path: intent.relativePath, fileIdentity: installed.stamp.identity)
                try persistManifest()
                try markCommitted(intent, displacedDigest: ContentDigest.sha256(displaced))
                report.replayed.append(intent.relativePath)
            } catch {
                if case VaultError.io(let code, _, _) = error,
                   [EIO, ENOSPC, EACCES, EPERM, EROFS, EBADF].contains(code) { ioRemainsUncertain = true }
                if case VaultError.malformedMetadata = error { ioRemainsUncertain = true }
                report.review.append(.init(id: id, relativePath: nil,
                                           explanation: "Unsealed, invalid or inaccessible recovery item; no automatic repair was attempted. \(error.localizedDescription)", proposedMarkdown: nil))
            }
        }
        do {
            let planning = try roadmapPersistence.recover(projectID: manifest.project.id, replay: replay)
            report.replayed += Array(repeating: ".folio/roadmap.json", count: planning.replayed)
            report.review += planning.review
            ioRemainsUncertain = ioRemainsUncertain || planning.uncertainIO
        } catch {
            report.review.append(.init(id: UUID(), relativePath: ".folio/roadmap.json", explanation: "Roadmap recovery needs attention: " + error.localizedDescription, proposedMarkdown: nil))
            ioRemainsUncertain = true
        }
        needsRecovery = ioRemainsUncertain
        return report
    }

    private func markCommitted(_ intent: JournalIntent, displacedDigest: String) throws {
        let path = transactionPath(intent.id) + "/committed.json"
        if try files.stat(path) == nil {
            try files.writeNew(path, bytes: Self.encode(CommitReceipt(version: 1, id: intent.id,
                                                                    proposedDigest: intent.proposedDigest, displacedDigest: displacedDigest)))
        }
    }
    private func readReceipt(_ intent: JournalIntent) throws -> CommitReceipt? {
        guard let raw = try files.readIfPresent(transactionPath(intent.id) + "/committed.json", limit: 8192) else { return nil }
        let value = try JSONDecoder().decode(CommitReceipt.self, from: raw.data)
        guard value.version == 1, value.id == intent.id, value.proposedDigest == intent.proposedDigest else { throw VaultError.invalidRecovery }
        return value
    }
    private func readIntent(_ id: UUID) throws -> JournalIntent {
        let raw = try files.read(transactionPath(id) + "/intent.json", limit: 8192).data
        let value = try JSONDecoder().decode(JournalIntent.self, from: raw)
        guard value.version == 1, value.id == id, value.permissions & ~UInt32(0o777) == 0 else { throw VaultError.invalidRecovery }
        try VaultPaths.validateNote(value.relativePath)
        return value
    }
    private func verifiedPayload(_ path: String, digest: String) throws -> Data {
        let bytes = try files.read(path, limit: limits.maximumNoteBytes).data
        guard ContentDigest.sha256(bytes) == digest, String(data: bytes, encoding: .utf8) != nil else { throw VaultError.invalidRecovery }
        return bytes
    }

    private func pruneCommittedHistory(reserving: Int) throws {
        var total = 0
        var removable: [(UUID, Double, Int)] = []
        for (name, entry) in try files.entries(".folio/journal", limit: 4096) {
            guard entry.kind == 2, let id = UUID(uuidString: name), id.uuidString == name else { continue }
            let dir = transactionPath(id)
            var size = 0
            for (_, file) in try files.entries(dir, limit: 32) {
                guard file.size <= UInt64(limits.maximumJournalBytes) else { throw VaultError.journalFull }
                size += Int(file.size)
            }
            total += size
            if try files.stat(dir + "/REVIEW") != nil { continue }
            guard let intent = try? readIntent(id), let receipt = try? readReceipt(intent),
                  let displaced = try? files.read(dir + "/install.md", limit: limits.maximumNoteBytes),
                  ContentDigest.sha256(displaced.data) == receipt.displacedDigest else { continue }
            removable.append((id, intent.createdAt, size))
        }
        removable.sort { $0.1 < $1.1 }
        var remaining = removable.count
        for (id, _, size) in removable {
            if remaining <= limits.retainedCommittedTransactions && total + reserving <= limits.maximumJournalBytes { break }
            let dir = transactionPath(id)
            // Only our exact known private files are removed. Unknown material
            // makes directory removal fail instead of recursively deleting it.
            for name in ["base.md", "proposal.md", "install.md", "committed.json", "intent.json"] {
                try files.remove(dir + "/" + name)
            }
            try files.remove(dir, directory: true)
            total -= size; remaining -= 1
        }
        guard total + reserving <= limits.maximumJournalBytes else { throw VaultError.journalFull }
    }

    private func persistManifest() throws {
        let data = try Self.encode(manifest)
        guard data.count <= limits.maximumMetadataBytes else { throw VaultError.tooLarge }
        let current = try files.read(".folio/project.json", limit: limits.maximumMetadataBytes)
        guard current.data == manifestBytes else { needsRecovery = true; throw VaultError.malformedMetadata }
        let temp = ".folio/project-\(UUID().uuidString).tmp"
        try files.writeNew(temp, bytes: data)
        try files.exchange(temp, with: ".folio/project.json")
        let displaced = try files.read(temp, limit: limits.maximumMetadataBytes).data
        guard displaced == manifestBytes else { needsRecovery = true; throw VaultError.malformedMetadata }
        manifestBytes = data
        try files.remove(temp)
    }
    private func readSnapshot(id: UUID, path: String) throws -> VaultSnapshot {
        try VaultPaths.validateNote(path)
        let file = try files.read(path, limit: limits.maximumNoteBytes)
        guard String(data: file.data, encoding: .utf8) != nil else { throw VaultError.invalidUTF8 }
        return snapshot(id: id, path: path, file: file)
    }
    private func snapshot(id: UUID, path: String, file: FileBytes) -> VaultSnapshot {
        VaultSnapshot(projectID: manifest.project.id, rootIdentity: rootIdentity,
                      note: note(id: id, path: path, stamp: file.stamp), bytes: file.data,
                      revision: ContentDigest.sha256(file.data), permissions: file.stamp.permissions)
    }
    private func note(id: UUID, path: String, stamp: FileStamp) -> VaultNote {
        .init(id: id, relativePath: path, modifiedAt: stamp.date, byteCount: stamp.size)
    }
    private func registerIdentity(_ id: UUID, path: String, fileIdentity: String) {
        if let prior = manifest.notes[path], prior.id != id { pathsByID.removeValue(forKey: prior.id) }
        manifest.notes[path] = NoteIdentity(id: id, fileIdentity: fileIdentity)
        pathsByID[id] = path
    }
    private func transactionPath(_ id: UUID) -> String { ".folio/journal/" + id.uuidString }
    private func requireOpen() throws { if isClosed { throw VaultError.closed } }
    private func requireWritable() throws { try requireOpen(); if needsRecovery { throw VaultError.recoveryRequired } }
    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    private static func decodeManifest(_ data: Data, limits: VaultLimits) throws -> ProjectManifest {
        do {
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let object, Set(object.keys) == Set(["version", "project", "notes"]) else { throw VaultError.malformedMetadata }
            struct Version: Decodable { let version: Int }
            guard try JSONDecoder().decode(Version.self, from: data).version == 1 else { throw VaultError.unsupportedFormat }
            let value = try JSONDecoder().decode(ProjectManifest.self, from: data)
            guard value.notes.count <= limits.maximumEntries, !value.project.name.isEmpty,
                  value.project.name.utf8.count <= 512,
                  value.project.name.rangeOfCharacter(from: .controlCharacters) == nil,
                  Set(value.notes.values.map(\.id)).count == value.notes.count else { throw VaultError.malformedMetadata }
            for path in value.notes.keys { try VaultPaths.validateNote(path) }
            // Reject unknown owned-schema fields rather than dropping them on save.
            if let project = object["project"] as? [String: Any], Set(project.keys) != Set(["id", "name"]) { throw VaultError.malformedMetadata }
            if let records = object["notes"] as? [String: [String: Any]] {
                for record in records.values where Set(record.keys) != Set(["id", "fileIdentity"]) { throw VaultError.malformedMetadata }
            }
            return value
        } catch let error as VaultError { throw error }
        catch { throw VaultError.malformedMetadata }
    }
}
