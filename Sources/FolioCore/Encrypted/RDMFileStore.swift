import Foundation

public struct RDMCreatedProject: Sendable {
    public let store: RDMFileStore
    /// Display once and place in the user's secure recovery workflow; it is not
    /// written into the archive or ordinary project metadata by Folio.
    public let recoveryCode: String
}

/// Encrypted checkpoint file actor. The parent directory contains only a lock
/// and atomic staging member; no plaintext working objects are written. The
/// current v1 API keeps the authenticated snapshot in memory after opening.
public actor RDMFileStore {
    public nonisolated let fileURL: URL
    private var projectID: UUID
    private let files: VaultFileSystem
    private var keys: RDMProjectKeys
    private var snapshotID: String
    private var project: RDMProjectPayload
    private var closed = false

    public static func create(at fileURL: URL, project: RDMProjectPayload, passphrase: String) async throws -> RDMCreatedProject {
        let store = try RDMFileStore(fileURL: fileURL, projectID: project.id, createParent: true)
        do {
            let created = try await RDMCredentials.create(projectID: project.id, passphrase: passphrase)
            let archive = try RDMArchive.seal(project, keys: created.keys, credentialVerified: true)
            try await store.writeArchive(archive.bytes)
            await store.adopt(created: created.keys, archive: archive, project: project)
            return .init(store: store, recoveryCode: created.recoveryCode)
        } catch { await store.close(); throw error }
    }
    public static func open(at fileURL: URL, passphrase: String) async throws -> RDMFileStore {
        let store = try RDMFileStore(fileURL: fileURL, projectID: UUID(), createParent: false)
        do {
            let bytes = try await store.readArchive()
            let opened = try await RDMArchive.open(bytes, passphrase: passphrase)
            await store.adopt(opened: opened)
            return store
        } catch { await store.close(); throw error }
    }
    public static func open(at fileURL: URL, recoveryCode: String) async throws -> RDMFileStore {
        let store = try RDMFileStore(fileURL: fileURL, projectID: UUID(), createParent: false)
        do {
            let opened = try RDMArchive.open(try await store.readArchive(), recoveryCode: recoveryCode)
            await store.adopt(opened: opened)
            return store
        } catch { await store.close(); throw error }
    }
    private init(fileURL: URL, projectID: UUID, createParent: Bool) throws {
        guard fileURL.isFileURL, fileURL.pathExtension.lowercased() == "rdm" else { throw RDMError.invalidFormat }
        let parent = fileURL.deletingLastPathComponent()
        let fs = try VaultFileSystem(url: parent)
        do {
            try fs.directory(".folio")
            try fs.acquireLock()
            let destination = try fs.stat(fileURL.lastPathComponent)
            if createParent {
                // Creation is an explicit non-destructive operation. Never turn
                // a destination picker mistake into replacement of an existing
                // archive, directory or unrelated file.
                guard destination == nil else { throw RDMError.destinationExists }
            } else {
                guard destination != nil else { throw RDMError.invalidFormat }
            }
            self.fileURL = fileURL.standardizedFileURL; self.projectID = projectID; self.files = fs
            self.keys = try RDMSecret.random().asPlaceholderKeys(projectID: projectID)
            self.snapshotID = ""; self.project = .init(id: projectID, name: "", notes: [])
        } catch { fs.close(); throw error }
    }
    private func adopt(opened: RDMOpenedArchive) { projectID = opened.project.id; keys.lock(); keys = opened.keys; snapshotID = opened.snapshotID; project = opened.project }
    private func adopt(created: RDMProjectKeys, archive: RDMSealedArchive, project: RDMProjectPayload) { keys.lock(); keys = created; snapshotID = archive.snapshotID; self.project = project }
    public func makeWorkingIndex() throws -> EncryptedWorkingIndex {
        try requireOpen()
        return try EncryptedWorkingIndex(projectID: projectID)
    }
    public func currentProject() throws -> RDMProjectPayload { try requireOpen(); return project }
    public func currentSnapshotID() throws -> String { try requireOpen(); return snapshotID }
    public func lock() { keys.lock(); close() }
    public func close() { guard !closed else { return }; keys.lock(); files.close(); closed = true }

    public func checkpoint(_ next: RDMProjectPayload) throws -> RDMSealedArchive {
        try requireOpen()
        guard next.id == projectID else { throw RDMError.wrongProject }
        let current = try RDMArchive.inspect(readArchive())
        guard current.snapshotID == snapshotID else { throw RDMError.staleCheckpoint }
        let sealed = try RDMArchive.seal(next, keys: keys, parentSnapshotID: snapshotID, credentialVerified: true)
        try writeArchive(sealed.bytes)
        project = next; snapshotID = sealed.snapshotID
        return sealed
    }
    private func requireOpen() throws { if closed || keys.isLocked { throw RDMError.locked } }
    private func readArchive() throws -> Data {
        let raw = try files.read(fileURL.lastPathComponent, limit: RDMArchive.maximumArchiveBytes)
        return raw.data
    }
    private func writeArchive(_ data: Data) throws { guard data.count <= RDMArchive.maximumArchiveBytes else { throw RDMError.resourceLimit }; try files.writeAtomic(fileURL.lastPathComponent, bytes: data) }
}

private extension RDMSecret {
    func asPlaceholderKeys(projectID: UUID) throws -> RDMProjectKeys {
        .init(projectID: projectID, master: self, slots: [])
    }
}
