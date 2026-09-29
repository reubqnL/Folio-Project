import Foundation

public struct RDMNote: Equatable, Sendable, Identifiable, Codable {
    public let id: UUID
    public let path: String
    public let markdown: String
    public init(id: UUID, path: String, markdown: String) { self.id = id; self.path = path; self.markdown = markdown }
}
public struct RDMProjectPayload: Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let notes: [RDMNote]
    public let roadmap: RoadmapDocument
    public init(id: UUID, name: String, notes: [RDMNote], roadmap: RoadmapDocument = .empty) {
        self.id = id; self.name = name; self.notes = notes; self.roadmap = roadmap
    }
}
public struct RDMSealedArchive: Sendable {
    public let projectID: UUID
    public let snapshotID: String
    public let bytes: Data
}
public struct RDMOpenedArchive: Sendable {
    public let project: RDMProjectPayload
    public let snapshotID: String
    public let parentSnapshotID: String?
    public let keys: RDMProjectKeys
}
public struct RDMEnvelopeSummary: Equatable, Sendable {
    public let projectID: UUID
    public let snapshotID: String
    public let parentSnapshotID: String?
}
private enum RDMObjectKind: String, Codable { case note, roadmap, connections }
private struct RDMObjectDescription: Codable {
    let kind: RDMObjectKind
    let logicalID: UUID
    let path: String?
    let revision: Data
    let member: String
    let plaintextBytes: Int
    let sealedBytes: Int
    let plaintextDigest: String
    let sealedDigest: String
}
private struct RDMManifest: Codable {
    let version: Int
    let projectID: UUID
    let name: String
    let snapshotID: Data
    let parentSnapshotID: Data?
    let objects: [RDMObjectDescription]
}
private struct RDMConnectionMap: Codable, Equatable {
    struct Edge: Codable, Equatable { let from: String; let to: String; let kind: String }
    let version: Int
    let unresolvedLinks: Int
    let omittedNoteBodies: Int
    let edges: [Edge]
}

/// Experimental v1 transport foundation, not a reviewed production cryptosystem.
/// Parsing/decryption is in memory. No archive member is extracted to a path.
public enum RDMArchive {
    private static let roadmapID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private static let connectionsID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private static let manifestID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    public static let maximumNotes = 2048
    public static let maximumPlaintextBytes = 64 * 1024 * 1024
    public static let maximumArchiveBytes = 96 * 1024 * 1024

    public static func seal(_ project: RDMProjectPayload, keys: RDMProjectKeys,
                            parentSnapshotID: String? = nil, credentialVerified: Bool) throws -> RDMSealedArchive {
        guard credentialVerified else { throw RDMError.authenticationFailed }
        guard keys.projectID == project.id else { throw RDMError.wrongProject }
        guard !keys.isLocked else { throw RDMError.locked }
        try validateContent(project)
        let parent = try parentSnapshotID.map { try decodeHex($0, count: 32) }
        let snapshot = try RDMCrypto.random(32), manifestRevision = try RDMCrypto.random(32)
        let header = RDMHeader(format: 1, suite: RDMHeader.suiteName, projectID: project.id,
                               snapshotID: snapshot, manifestRevision: manifestRevision, slots: keys.slots)
        try header.validate()
        let rawHeader = try RDMCanonical.encode(header)
        guard rawHeader.count <= 32 * 1024 else { throw RDMError.resourceLimit }
        let headerHash = try decodeHex(ContentDigest.sha256(rawHeader), count: 32)
        var files: [String: Data] = ["header.json": rawHeader]
        var descriptions: [RDMObjectDescription] = []
        var revisions: Set<Data> = [manifestRevision]
        func add(_ kind: RDMObjectKind, id: UUID, path: String?, data: Data) throws {
            guard data.count <= 8 * 1024 * 1024 else { throw RDMError.resourceLimit }
            let revision = try RDMCrypto.random(32)
            guard revisions.insert(revision).inserted else { throw RDMError.duplicateIdentity }
            let aad = RDMAssociatedData.object(project: project.id, snapshot: snapshot, kind: kind.rawValue,
                logicalID: id, revision: revision, headerDigest: headerHash)
            let key = try objectKey(master: keys.master, project: project.id, revision: revision, purpose: kind.rawValue)
            defer { key.lock() }
            let sealed = try RDMCrypto.seal(data, key: key, aad: aad)
            let record = encodeRecord(revision: revision, sealed: sealed)
            let name = "objects/" + hex(revision)
            guard files[name] == nil else { throw RDMError.duplicateIdentity }
            files[name] = record
            descriptions.append(.init(kind: kind, logicalID: id, path: path, revision: revision, member: name,
                plaintextBytes: data.count, sealedBytes: record.count,
                plaintextDigest: ContentDigest.sha256(data), sealedDigest: ContentDigest.sha256(record)))
        }
        for note in project.notes { try add(.note, id: note.id, path: note.path, data: Data(note.markdown.utf8)) }
        try add(.roadmap, id: roadmapID, path: nil, data: RoadmapCodec.encode(project.roadmap))
        try add(.connections, id: connectionsID, path: nil, data: RDMCanonical.encode(connectionMap(project)))
        let manifest = RDMManifest(version: 1, projectID: project.id, name: project.name,
            snapshotID: snapshot, parentSnapshotID: parent, objects: descriptions)
        var manifestData = try RDMCanonical.encode(manifest)
        defer { manifestData.resetBytes(in: 0..<manifestData.count) }
        guard manifestData.count <= 4 * 1024 * 1024 else { throw RDMError.resourceLimit }
        let key = try objectKey(master: keys.master, project: project.id, revision: manifestRevision, purpose: "manifest")
        defer { key.lock() }
        let aad = RDMAssociatedData.object(project: project.id, snapshot: snapshot, kind: "manifest", logicalID: manifestID,
            revision: manifestRevision, headerDigest: headerHash)
        files["manifest.enc"] = encodeRecord(revision: manifestRevision, sealed: try RDMCrypto.seal(manifestData, key: key, aad: aad))
        return .init(projectID: project.id, snapshotID: hex(snapshot), bytes: try RDMZip.encode(files))
    }

    public static func inspect(_ data: Data) throws -> RDMEnvelopeSummary {
        let parsed = try parsePublicEnvelope(data)
        // Parent is encrypted in the manifest; the public summary intentionally
        // exposes only the current snapshot/project identity needed for stale-write checks.
        return .init(projectID: parsed.header.projectID, snapshotID: hex(parsed.header.snapshotID), parentSnapshotID: nil)
    }

    public static func open(_ data: Data, passphrase: String) async throws -> RDMOpenedArchive {
        let parsed = try parsePublicEnvelope(data)
        let keys = try await RDMCredentials.unwrap(header: parsed.header, passphrase: passphrase)
        do { return try authenticate(parsed, keys: keys) }
        catch { keys.lock(); throw error }
    }
    public static func open(_ data: Data, recoveryCode: String) throws -> RDMOpenedArchive {
        let parsed = try parsePublicEnvelope(data)
        let keys = try RDMCredentials.unwrap(header: parsed.header, recoveryCode: recoveryCode)
        do { return try authenticate(parsed, keys: keys) }
        catch { keys.lock(); throw error }
    }
    /// Useful for authenticated checkpoint recovery while an existing key handle
    /// is unlocked. This does not authenticate or enrol an additional device.
    public static func open(_ data: Data, keys: RDMProjectKeys) throws -> RDMOpenedArchive {
        let parsed = try parsePublicEnvelope(data)
        guard keys.projectID == parsed.header.projectID else { throw RDMError.wrongProject }
        guard !keys.isLocked else { throw RDMError.locked }
        let bound = RDMProjectKeys(projectID: keys.projectID, master: try keys.master.copy(), slots: parsed.header.slots)
        do { return try authenticate(parsed, keys: bound) }
        catch { bound.lock(); throw error }
    }
    private struct ParsedEnvelope { let header: RDMHeader; let rawHeader: Data; let files: [String: Data] }
    private static func parsePublicEnvelope(_ data: Data) throws -> ParsedEnvelope {
        let files = try RDMZip.decode(data)
        guard let raw = files["header.json"], raw.count <= 32 * 1024,
              let manifest = files["manifest.enc"], manifest.count <= 4 * 1024 * 1024 + 72 else { throw RDMError.invalidFormat }
        let header = try RDMCanonical.decode(RDMHeader.self, from: raw)
        try header.validate()
        return .init(header: header, rawHeader: raw, files: files)
    }
    private static func authenticate(_ parsed: ParsedEnvelope, keys: RDMProjectKeys) throws -> RDMOpenedArchive {
        let header = parsed.header
        let headerHash = try decodeHex(ContentDigest.sha256(parsed.rawHeader), count: 32)
        let record = try decodeRecord(parsed.files["manifest.enc"]!, expectedRevision: header.manifestRevision)
        let manifestKey = try objectKey(master: keys.master, project: header.projectID, revision: header.manifestRevision, purpose: "manifest")
        defer { manifestKey.lock() }
        let aad = RDMAssociatedData.object(project: header.projectID, snapshot: header.snapshotID, kind: "manifest",
            logicalID: manifestID, revision: header.manifestRevision, headerDigest: headerHash)
        var raw = try RDMCrypto.open(record, key: manifestKey, aad: aad)
        defer { raw.resetBytes(in: 0..<raw.count) }
        guard raw.count <= 4 * 1024 * 1024 else { throw RDMError.resourceLimit }
        let manifest = try RDMCanonical.decode(RDMManifest.self, from: raw)
        guard manifest.version == 1, manifest.projectID == header.projectID, manifest.snapshotID == header.snapshotID,
              manifest.parentSnapshotID == nil || manifest.parentSnapshotID?.count == 32,
              manifest.objects.count >= 2, manifest.objects.count <= maximumNotes + 2,
              Set(manifest.objects.map(\.member)).count == manifest.objects.count else { throw RDMError.invalidContent }
        let expectedMembers = Set(manifest.objects.map(\.member)).union(["header.json", "manifest.enc"])
        guard expectedMembers == Set(parsed.files.keys) else { throw RDMError.invalidContent }
        var notes: [RDMNote] = [], roadmap: RoadmapDocument?, connections: RDMConnectionMap?
        var revisions: Set<Data> = [header.manifestRevision]
        var identities = Set<String>(), totalPlaintext = 0
        for object in manifest.objects {
            guard object.revision.count == 32, object.member == "objects/" + hex(object.revision),
                  revisions.insert(object.revision).inserted,
                  identities.insert(object.kind.rawValue + ":" + object.logicalID.uuidString).inserted,
                  object.plaintextBytes >= 0, object.plaintextBytes <= 8 * 1024 * 1024,
                  object.sealedBytes == object.plaintextBytes + 72,
                  let sealedBytes = parsed.files[object.member], sealedBytes.count == object.sealedBytes,
                  ContentDigest.sha256(sealedBytes) == object.sealedDigest else { throw RDMError.invalidContent }
            totalPlaintext += object.plaintextBytes
            guard totalPlaintext <= maximumPlaintextBytes else { throw RDMError.resourceLimit }
            let sealed = try decodeRecord(sealedBytes, expectedRevision: object.revision)
            let key = try objectKey(master: keys.master, project: header.projectID, revision: object.revision, purpose: object.kind.rawValue)
            defer { key.lock() }
            let aad = RDMAssociatedData.object(project: header.projectID, snapshot: header.snapshotID, kind: object.kind.rawValue,
                logicalID: object.logicalID, revision: object.revision, headerDigest: headerHash)
            var plain = try RDMCrypto.open(sealed, key: key, aad: aad)
            defer { plain.resetBytes(in: 0..<plain.count) }
            guard plain.count == object.plaintextBytes, ContentDigest.sha256(plain) == object.plaintextDigest else { throw RDMError.invalidContent }
            switch object.kind {
            case .note:
                guard let path = object.path, let text = String(data: plain, encoding: .utf8) else { throw RDMError.invalidContent }
                // Use UTF8 decoding only after validation, preserving BOM/CRLF bytes.
                _ = text
                notes.append(.init(id: object.logicalID, path: path, markdown: String(decoding: plain, as: UTF8.self)))
            case .roadmap:
                guard object.logicalID == roadmapID, object.path == nil, roadmap == nil else { throw RDMError.invalidContent }
                roadmap = try RoadmapCodec.decode(plain)
            case .connections:
                guard object.logicalID == connectionsID, object.path == nil, connections == nil else { throw RDMError.invalidContent }
                connections = try RDMCanonical.decode(RDMConnectionMap.self, from: plain)
            }
        }
        guard let roadmap, let connections else { throw RDMError.invalidContent }
        let project = RDMProjectPayload(id: header.projectID, name: manifest.name, notes: notes, roadmap: roadmap)
        try validateContent(project)
        guard try connectionMap(project) == connections else { throw RDMError.invalidContent }
        return .init(project: project, snapshotID: hex(header.snapshotID), parentSnapshotID: manifest.parentSnapshotID.map(hex), keys: keys)
    }
    private static func validateContent(_ project: RDMProjectPayload) throws {
        guard !project.name.isEmpty, project.name.utf8.count <= 512,
              project.name.rangeOfCharacter(from: .controlCharacters) == nil,
              project.notes.count <= maximumNotes, Set(project.notes.map(\.id)).count == project.notes.count else { throw RDMError.invalidContent }
        var paths = Set<String>(), total = 0
        for note in project.notes {
            try VaultPaths.validateNote(note.path)
            let normal = note.path.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            guard paths.insert(normal).inserted else { throw RDMError.duplicateIdentity }
            guard note.markdown.utf8.count <= 8 * 1024 * 1024, !note.markdown.contains("\0") else { throw RDMError.resourceLimit }
            total += note.markdown.utf8.count
            guard total <= maximumPlaintextBytes else { throw RDMError.resourceLimit }
        }
        try RoadmapEngine.validateStructure(project.roadmap)
        guard RoadmapEngine.issues(in: project.roadmap).isEmpty else { throw RDMError.invalidContent }
    }
    private static func connectionMap(_ project: RDMProjectPayload) throws -> RDMConnectionMap {
        let records = project.notes.map { note -> GraphNoteInput in
            let links = GraphLinkExtractor.targets(in: note.markdown)
            return .init(id: note.id, title: (note.path as NSString).lastPathComponent.replacingOccurrences(of: #"\.(md|markdown)$"#, with: "", options: [.regularExpression, .caseInsensitive]),
                         path: note.path, targets: links.targets, omittedBody: links.omitted)
        }
        let graph = KnowledgeGraph(notes: records, roadmap: project.roadmap)
        return .init(version: 1, unresolvedLinks: graph.unresolvedLinks, omittedNoteBodies: graph.omittedNoteBodies,
                     edges: graph.edges.map { .init(from: $0.from.rawValue, to: $0.to.rawValue, kind: $0.kind.rawValue) })
    }
    private static func objectKey(master: RDMSecret, project: UUID, revision: Data, purpose: String) throws -> RDMSecret {
        var info = RDMAssociatedData.prefix("object-key"); RDMAssociatedData.field(Data(purpose.utf8), into: &info); RDMAssociatedData.field(revision, into: &info)
        return try RDMCrypto.derive(master, salt: RDMAssociatedData.uuid(project), info: info)
    }
    static func encodeRecord(revision: Data, sealed: RDMSealedBytes) -> Data {
        var data = Data("FRB1".utf8); data.append(revision); data.append(sealed.nonce)
        let length = UInt64(sealed.ciphertext.count)
        for shift in stride(from: 56, through: 0, by: -8) { data.append(UInt8(truncatingIfNeeded: length >> UInt64(shift))) }
        data.append(sealed.ciphertext); data.append(sealed.tag); return data
    }
    static func decodeRecord(_ data: Data, expectedRevision: Data) throws -> RDMSealedBytes {
        guard data.count >= 72, data.prefix(4) == Data("FRB1".utf8), expectedRevision.count == 32,
              data.subdata(in: 4..<36) == expectedRevision else { throw RDMError.invalidFormat }
        var length: UInt64 = 0
        for byte in data[48..<56] { length = (length << 8) | UInt64(byte) }
        guard length <= 8 * 1024 * 1024, length == UInt64(data.count - 72) else { throw RDMError.resourceLimit }
        let end = 56 + Int(length)
        return .init(nonce: data.subdata(in: 36..<48), ciphertext: data.subdata(in: 56..<end), tag: data.subdata(in: end..<data.count))
    }
    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
    static func decodeHex(_ text: String, count: Int) throws -> Data {
        guard text.utf8.count == count * 2, text.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw RDMError.invalidFormat }
        var value = Data(), index = text.startIndex
        while index < text.endIndex {
            let end = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<end], radix: 16) else { throw RDMError.invalidFormat }
            value.append(byte); index = end
        }
        return value
    }
}
