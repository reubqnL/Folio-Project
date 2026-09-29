import Foundation

/// One unsaved encrypted-project draft note, persisted only inside the
/// authenticated working record. It is local durability for in-progress text,
/// not a checkpoint; the `.rdm` archive stays the durable project state.
public struct RDMWorkingDraft: Equatable, Sendable, Identifiable, Codable {
    public let id: UUID
    public var path: String
    public var markdown: String
    /// Milliseconds since 1970. Integer timestamps keep canonical encoding exact.
    public var updatedAt: Int64
    public init(id: UUID, path: String, markdown: String, updatedAt: Int64) {
        self.id = id; self.path = path; self.markdown = markdown; self.updatedAt = updatedAt
    }
}

/// The decrypted working state a session may restore after a crash or reopen.
public struct RDMWorkingState: Equatable, Sendable {
    public let projectID: UUID
    /// Archive snapshot the drafts were last recorded against; lineage only.
    public let baseSnapshotID: String
    public var drafts: [RDMWorkingDraft]
    public var updatedAt: Int64
    public init(projectID: UUID, baseSnapshotID: String, drafts: [RDMWorkingDraft], updatedAt: Int64) {
        self.projectID = projectID; self.baseSnapshotID = baseSnapshotID
        self.drafts = drafts; self.updatedAt = updatedAt
    }
}

/// Result of reading the local working copies. `.stale` is never silently
/// trusted: further draft writes wait until the user explicitly resolves it.
public enum RDMWorkingRestore: Equatable, Sendable {
    case empty
    case current(RDMWorkingState)
    case stale(RDMWorkingState?, reason: String)
}

public struct RDMWorkingLimits: Sendable {
    public var maximumDrafts: Int = 256
    public var maximumDraftMarkdownBytes: Int = 8 * 1024 * 1024
    public var maximumRecordBytes: Int = 32 * 1024 * 1024
    public init() {}
}

private struct RDMWorkingPayload: Codable, Equatable, Sendable {
    let version: Int
    let projectID: UUID
    let baseSnapshotID: String
    let previousGeneration: Int
    let previousRecordDigest: String
    let updatedAt: Int64
    let drafts: [RDMWorkingDraft]
}

private struct RDMIndexCachePayload: Codable, Equatable, Sendable {
    let version: Int
    let projectID: UUID
    let snapshotID: String
    let notes: [RDMNote]
}

/// Persistent encrypted working store for one open `.rdm` project.
///
/// Design (v1):
/// - Unsaved drafts live in two alternating slot files, each one sealed
///   AES-256-GCM record. A record chains to the previous generation's exact
///   bytes, so torn writes, single-slot rollback and mixed copies surface as
///   `.stale` instead of being silently accepted. A consistent restore of both
///   slots from one older backup is not locally detectable; the archive
///   checkpoint remains the durable trust anchor.
/// - The derived search index cache is one sealed record bound to the archive
///   snapshot it was built from. Any absent, stale or invalid cache falls back
///   to an in-memory rebuild; it can never corrupt search.
/// - No plaintext draft, note, title or index byte is written outside
///   authenticated ciphertext. Staging uses the private `.folio` atomic-write
///   path; no SQLite, WAL, preview or diagnostic plaintext cache exists.
///
/// The store deliberately does not take the project advisory lock; the owning
/// `RDMFileStore` session holds `.folio/session.lock` while it is open.
public actor RDMWorkingStore {
    public nonisolated let projectID: UUID
    private let files: VaultFileSystem
    private let baseName: String
    private let workingKey: RDMSecret
    private let indexKey: RDMSecret
    private let limits: RDMWorkingLimits
    private var closed = false

    static let workingMagic = Data("FRW1".utf8)
    static let indexMagic = Data("FRX1".utf8)
    /// magic(4) + format(1) + slot(1) + reserved(2) + generation(8) + fileID(16) + nonce(12) + length(8) + tag(16)
    private static let recordOverhead = 68
    /// magic(4) + format(1) + reserved(3) + fileID(16) + nonce(12) + length(8) + tag(16)
    private static let indexOverhead = 60

    private struct Candidate {
        let slot: Int
        let generation: Int
        let fileID: Data
        let bytes: Data
        let payload: RDMWorkingPayload
        var state: RDMWorkingState {
            .init(projectID: payload.projectID, baseSnapshotID: payload.baseSnapshotID,
                  drafts: payload.drafts.sorted { ($0.updatedAt, $0.id.uuidString) < ($1.updatedAt, $1.id.uuidString) },
                  updatedAt: payload.updatedAt)
        }
    }

    init(parent: URL, baseName: String, keys: RDMProjectKeys, limits: RDMWorkingLimits = .init()) throws {
        guard !baseName.isEmpty, baseName.utf8.count <= 255,
              baseName.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\\0")) == nil,
              (1...1024).contains(limits.maximumDrafts),
              (1...64 * 1024 * 1024).contains(limits.maximumDraftMarkdownBytes),
              (1...128 * 1024 * 1024).contains(limits.maximumRecordBytes) else { throw RDMError.invalidContent }
        guard !keys.isLocked else { throw RDMError.locked }
        let files = try VaultFileSystem(url: parent)
        do {
            try files.directory(".folio")
            self.projectID = keys.projectID
            self.files = files
            self.baseName = baseName
            self.limits = limits
            self.workingKey = try RDMCrypto.derive(keys.master, salt: RDMAssociatedData.uuid(keys.projectID),
                                                   info: RDMAssociatedData.workingKey(keys.projectID))
            self.indexKey = try RDMCrypto.derive(keys.master, salt: RDMAssociatedData.uuid(keys.projectID),
                                                 info: RDMAssociatedData.workingIndexKey(keys.projectID))
        } catch {
            files.close()
            throw error
        }
    }

    public func close() {
        guard !closed else { return }
        workingKey.lock(); indexKey.lock(); files.close(); closed = true
    }

    // MARK: - Draft records

    /// Reads and classifies the two local working copies. Classification never
    /// guesses: inconsistent copies return `.stale` with the best available
    /// state for explicit review.
    public func restore() throws -> RDMWorkingRestore {
        try requireOpen()
        let (rawPresent, candidates) = try readCandidates()
        return Self.classify(rawPresent: rawPresent, candidates: candidates)
    }

    /// Persists the draft set as a new chained generation. Refuses to write
    /// over an unresolved stale state.
    public func save(drafts: [RDMWorkingDraft], baseSnapshotID: String) throws {
        try requireOpen()
        let state = try validated(drafts: drafts, baseSnapshotID: baseSnapshotID)
        let (rawPresent, candidates) = try readCandidates()
        let anchor: Candidate?
        switch Self.classify(rawPresent: rawPresent, candidates: candidates) {
        case .empty:
            anchor = nil
        case .current:
            anchor = candidates.max(by: { $0.generation < $1.generation })
        case .stale:
            throw RDMError.recoveryRequired
        }
        let generation = (anchor?.generation ?? 0) + 1
        let slot = (generation - 1) % 2
        let fileID: Data
        if let anchor { fileID = anchor.fileID } else { fileID = try RDMCrypto.random(16) }
        let payload = RDMWorkingPayload(version: 1, projectID: projectID, baseSnapshotID: state.baseSnapshotID,
                                        previousGeneration: anchor?.generation ?? 0,
                                        previousRecordDigest: anchor.map { ContentDigest.sha256($0.bytes) } ?? "",
                                        updatedAt: currentMilliseconds(), drafts: state.drafts)
        let record = try sealRecord(payload: payload, fileID: fileID, slot: slot, generation: generation)
        try files.writeAtomic(slotPath(slot), bytes: record)
    }

    /// Explicit reviewed recovery: accept the best available state (or an empty
    /// state when nothing is readable), preserve the bytes being set aside as
    /// private `.folio` copies, and re-anchor the chain as a fresh epoch.
    /// Returns the accepted state, nil when no drafts remain.
    @discardableResult
    public func resolve() throws -> RDMWorkingState? {
        try requireOpen()
        let (rawPresent, candidates) = try readCandidates()
        let accepted: RDMWorkingState?
        switch Self.classify(rawPresent: rawPresent, candidates: candidates) {
        case .empty:
            return nil
        case .current(let value):
            return value
        case .stale(let value, _):
            accepted = value
        }
        // Preserve the exact bytes being set aside before anything is replaced.
        // If preservation cannot be written, nothing is destroyed.
        let limit = limits.maximumRecordBytes + Self.recordOverhead
        for slot in 0..<2 {
            if let raw = try files.readIfPresent(slotPath(slot), limit: limit) {
                try files.writeNew(discardedPath(), bytes: raw.data)
            }
        }
        try files.remove(slotPath(0))
        try files.remove(slotPath(1))
        guard let accepted, !accepted.drafts.isEmpty else { return nil }
        let fileID = try RDMCrypto.random(16)
        let payload = RDMWorkingPayload(version: 1, projectID: projectID, baseSnapshotID: accepted.baseSnapshotID,
                                        previousGeneration: 0, previousRecordDigest: "",
                                        updatedAt: accepted.updatedAt, drafts: accepted.drafts)
        let record = try sealRecord(payload: payload, fileID: fileID, slot: 0, generation: 1)
        try files.writeAtomic(slotPath(0), bytes: record)
        return accepted
    }

    /// Removes the local draft copies. Used when drafts were explicitly
    /// discarded or absorbed into a reviewed checkpoint.
    public func clear() throws {
        try requireOpen()
        try files.remove(slotPath(0))
        try files.remove(slotPath(1))
    }

    // MARK: - Encrypted index cache

    /// Writes the derived-index cache for one archive snapshot. Failure is not
    /// project-data loss: the cache is derived data and any absent, stale or
    /// invalid cache falls back to an in-memory rebuild on open.
    public func writeIndexCache(snapshotID: String, notes: [RDMNote]) throws {
        try requireOpen()
        guard (try? RDMArchive.decodeHex(snapshotID, count: 32)) != nil else { throw RDMError.invalidFormat }
        guard notes.count <= RDMArchive.maximumNotes else { throw RDMError.resourceLimit }
        var total = 0
        for note in notes {
            try VaultPaths.validateNote(note.path)
            guard !note.markdown.contains("\0"), note.markdown.utf8.count <= 8 * 1024 * 1024 else { throw RDMError.invalidContent }
            total += note.markdown.utf8.count
            guard total <= RDMArchive.maximumPlaintextBytes else { throw RDMError.resourceLimit }
        }
        let payload = RDMIndexCachePayload(version: 1, projectID: projectID, snapshotID: snapshotID, notes: notes)
        var plaintext = try RDMCanonical.encode(payload)
        defer { plaintext.resetBytes(in: 0..<plaintext.count) }
        guard plaintext.count <= RDMArchive.maximumPlaintextBytes else { throw RDMError.resourceLimit }
        let fileID = try RDMCrypto.random(16)
        let aad = RDMAssociatedData.workingIndexRecord(projectID, fileID: fileID)
        let sealed = try RDMCrypto.seal(plaintext, key: indexKey, aad: aad)
        var record = Self.indexMagic
        record.append(1) // format
        record.append(contentsOf: [0, 0, 0]) // reserved
        record.append(fileID)
        record.append(sealed.nonce)
        appendBigEndian(UInt64(sealed.ciphertext.count), to: &record)
        record.append(sealed.ciphertext)
        record.append(sealed.tag)
        try files.writeAtomic(indexCachePath(), bytes: record)
    }

    /// Returns the cached note set only when it authenticates and matches the
    /// requested archive snapshot. Every failure mode returns nil (rebuild).
    public func loadIndexCache(snapshotID: String) -> [RDMNote]? {
        guard !closed, let raw = try? files.readIfPresent(indexCachePath(), limit: RDMArchive.maximumArchiveBytes),
              raw.data.count >= Self.indexOverhead, raw.data.prefix(4) == Self.indexMagic, raw.data[4] == 1 else { return nil }
        let fileID = raw.data.subdata(in: 8..<24)
        let nonce = raw.data.subdata(in: 24..<36)
        let length = decodeBigEndian(raw.data.subdata(in: 36..<44))
        guard length <= UInt64(RDMArchive.maximumPlaintextBytes + 64),
              length == UInt64(raw.data.count - Self.indexOverhead) else { return nil }
        let end = 44 + Int(length)
        let sealed = RDMSealedBytes(nonce: nonce, ciphertext: raw.data.subdata(in: 44..<end),
                                    tag: raw.data.subdata(in: end..<raw.data.count))
        let aad = RDMAssociatedData.workingIndexRecord(projectID, fileID: fileID)
        guard let plain = try? RDMCrypto.open(sealed, key: indexKey, aad: aad),
              let payload = try? RDMCanonical.decode(RDMIndexCachePayload.self, from: plain),
              payload.version == 1, payload.projectID == projectID, payload.snapshotID == snapshotID,
              payload.notes.count <= RDMArchive.maximumNotes else { return nil }
        return payload.notes
    }

    public func removeIndexCache() throws {
        try requireOpen()
        try files.remove(indexCachePath())
    }

    // MARK: - Classification, validation and record handling

    private static func classify(rawPresent: Bool, candidates: [Candidate]) -> RDMWorkingRestore {
        if !rawPresent { return .empty }
        guard !candidates.isEmpty else {
            return .stale(nil, reason: "Local working copies failed authentication or validation. Nothing was restored.")
        }
        let high = candidates.max(by: { $0.generation < $1.generation })!
        if candidates.count == 1 {
            // One intact copy is trusted only as a fresh epoch origin. A record
            // that references missing previous history is incomplete.
            if high.payload.previousGeneration == 0, high.payload.previousRecordDigest.isEmpty {
                return .current(high.state)
            }
            return .stale(high.state, reason: "Only one of the two local working copies is intact; review the recovered drafts before saving.")
        }
        let low = candidates.min(by: { $0.generation < $1.generation })!
        if high.generation == low.generation + 1,
           high.fileID == low.fileID,
           high.payload.previousGeneration == low.generation,
           high.payload.previousRecordDigest == ContentDigest.sha256(low.bytes) {
            return .current(high.state)
        }
        return .stale(high.state, reason: "The two local working copies disagree; review the recovered drafts before saving.")
    }

    private func validated(drafts: [RDMWorkingDraft], baseSnapshotID: String) throws -> RDMWorkingState {
        guard (try? RDMArchive.decodeHex(baseSnapshotID, count: 32)) != nil else { throw RDMError.invalidFormat }
        guard drafts.count <= limits.maximumDrafts else { throw RDMError.resourceLimit }
        var seen = Set<UUID>(), total = 0
        for draft in drafts {
            guard seen.insert(draft.id).inserted else { throw RDMError.duplicateIdentity }
            try VaultPaths.validateNote(draft.path)
            guard draft.updatedAt >= 0,
                  draft.markdown.utf8.count <= limits.maximumDraftMarkdownBytes,
                  !draft.markdown.contains("\0") else { throw RDMError.invalidContent }
            total += draft.markdown.utf8.count
            guard total <= limits.maximumRecordBytes else { throw RDMError.resourceLimit }
        }
        return .init(projectID: projectID, baseSnapshotID: baseSnapshotID,
                     drafts: drafts.sorted { ($0.updatedAt, $0.id.uuidString) < ($1.updatedAt, $1.id.uuidString) },
                     updatedAt: currentMilliseconds())
    }

    private func readCandidates() throws -> (rawPresent: Bool, candidates: [Candidate]) {
        let limit = limits.maximumRecordBytes + Self.recordOverhead
        let raw0 = try files.readIfPresent(slotPath(0), limit: limit)
        let raw1 = try files.readIfPresent(slotPath(1), limit: limit)
        var candidates: [Candidate] = []
        for (slot, raw) in [(0, raw0), (1, raw1)] {
            guard let raw else { continue }
            guard let record = try? parseRecord(raw.data, expectedSlot: slot),
                  let payload = try? openPayload(record.sealed, fileID: record.fileID, slot: slot, generation: record.generation),
                  payload.previousGeneration >= 0, payload.previousGeneration < record.generation,
                  (payload.previousGeneration == 0) == payload.previousRecordDigest.isEmpty else { continue }
            candidates.append(.init(slot: slot, generation: record.generation, fileID: record.fileID,
                                    bytes: raw.data, payload: payload))
        }
        return (raw0 != nil || raw1 != nil, candidates)
    }

    private func sealRecord(payload: RDMWorkingPayload, fileID: Data, slot: Int, generation: Int) throws -> Data {
        var plaintext = try RDMCanonical.encode(payload)
        defer { plaintext.resetBytes(in: 0..<plaintext.count) }
        guard plaintext.count <= limits.maximumRecordBytes, fileID.count == 16,
              (0...1).contains(slot), generation >= 1 else { throw RDMError.invalidContent }
        let aad = RDMAssociatedData.workingRecord(projectID, fileID: fileID, slot: slot, generation: UInt64(generation))
        let sealed = try RDMCrypto.seal(plaintext, key: workingKey, aad: aad)
        var record = Self.workingMagic
        record.append(1) // format
        record.append(UInt8(slot))
        record.append(contentsOf: [0, 0]) // reserved
        appendBigEndian(UInt64(generation), to: &record)
        record.append(fileID)
        record.append(sealed.nonce)
        appendBigEndian(UInt64(sealed.ciphertext.count), to: &record)
        record.append(sealed.ciphertext)
        record.append(sealed.tag)
        guard record.count == Self.recordOverhead + sealed.ciphertext.count else { throw RDMError.invalidFormat }
        return record
    }

    private func parseRecord(_ data: Data, expectedSlot: Int) throws -> (generation: Int, fileID: Data, sealed: RDMSealedBytes) {
        guard data.count >= Self.recordOverhead, data.prefix(4) == Self.workingMagic,
              data[4] == 1, data[5] == UInt8(expectedSlot), data[6] == 0, data[7] == 0 else { throw RDMError.invalidFormat }
        let generationValue = decodeBigEndian(data.subdata(in: 8..<16))
        guard generationValue >= 1, generationValue <= UInt64(Int.max) else { throw RDMError.invalidFormat }
        // The writer's parity rule is part of the format; a record found in the
        // wrong slot is treated as untrusted material.
        guard (Int(generationValue) - 1) % 2 == expectedSlot else { throw RDMError.invalidFormat }
        let fileID = data.subdata(in: 16..<32)
        let nonce = data.subdata(in: 32..<44)
        let length = decodeBigEndian(data.subdata(in: 44..<52))
        guard length <= UInt64(limits.maximumRecordBytes), length == UInt64(data.count - Self.recordOverhead) else { throw RDMError.resourceLimit }
        let end = 52 + Int(length)
        return (Int(generationValue), fileID,
                .init(nonce: nonce, ciphertext: data.subdata(in: 52..<end), tag: data.subdata(in: end..<data.count)))
    }

    private func openPayload(_ sealed: RDMSealedBytes, fileID: Data, slot: Int, generation: Int) throws -> RDMWorkingPayload {
        let aad = RDMAssociatedData.workingRecord(projectID, fileID: fileID, slot: slot, generation: UInt64(generation))
        var plain = try RDMCrypto.open(sealed, key: workingKey, aad: aad)
        defer { plain.resetBytes(in: 0..<plain.count) }
        guard plain.count <= limits.maximumRecordBytes else { throw RDMError.resourceLimit }
        let payload = try RDMCanonical.decode(RDMWorkingPayload.self, from: plain)
        guard payload.version == 1, payload.projectID == projectID,
              (try? RDMArchive.decodeHex(payload.baseSnapshotID, count: 32)) != nil else { throw RDMError.invalidContent }
        var seen = Set<UUID>(), total = 0
        for draft in payload.drafts {
            guard seen.insert(draft.id).inserted, draft.updatedAt >= 0 else { throw RDMError.invalidContent }
            try VaultPaths.validateNote(draft.path)
            guard draft.markdown.utf8.count <= limits.maximumDraftMarkdownBytes, !draft.markdown.contains("\0") else { throw RDMError.invalidContent }
            total += draft.markdown.utf8.count
            guard total <= limits.maximumRecordBytes else { throw RDMError.resourceLimit }
        }
        return payload
    }

    private func appendBigEndian(_ value: UInt64, to data: inout Data) {
        for shift in stride(from: 56, through: 0, by: -8) { data.append(UInt8(truncatingIfNeeded: value >> UInt64(shift))) }
    }
    private func decodeBigEndian(_ data: Data) -> UInt64 {
        var value: UInt64 = 0
        for byte in data { value = (value << 8) | UInt64(byte) }
        return value
    }

    private func slotPath(_ slot: Int) -> String { ".folio/" + baseName + ".rdmworking." + String(slot) }
    private func discardedPath() -> String {
        ".folio/" + baseName + ".rdmworking.discarded-" + UUID().uuidString.lowercased()
    }
    private func indexCachePath() -> String { ".folio/" + baseName + ".rdmindex" }
    private func currentMilliseconds() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
    private func requireOpen() throws { if closed { throw RDMError.locked } }
}
