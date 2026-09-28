import Foundation

struct RDMKDFParameters: Codable, Equatable, Sendable {
    let algorithm: String
    let version: Int
    let memoryKiB: Int
    let iterations: Int
    let lanes: Int
    static let portable = Self(algorithm: "argon2id", version: 19, memoryKiB: 65536, iterations: 3, lanes: 4)
}
enum RDMSlotKind: String, Codable, Sendable { case passphrase, recovery }
struct RDMKeySlot: Codable, Equatable, Sendable {
    let id: UUID
    let kind: RDMSlotKind
    let kdf: RDMKDFParameters?
    let salt: Data
    let sealed: RDMSealedBytes
}
struct RDMHeader: Codable, Equatable, Sendable {
    let format: Int
    let suite: String
    let projectID: UUID
    let snapshotID: Data
    let manifestRevision: Data
    let slots: [RDMKeySlot]
    static let suiteName = "AES-256-GCM+HKDF-SHA256+Argon2id13"

    func validate() throws {
        guard format == 1 else { throw RDMError.unsupportedVersion }
        guard suite == Self.suiteName else { throw RDMError.unsupportedSuite }
        guard snapshotID.count == 32, manifestRevision.count == 32,
              slots.count == 2, Set(slots.map(\.id)).count == 2,
              Set(slots.map(\.kind)) == Set([.passphrase, .recovery]) else { throw RDMError.invalidFormat }
        for slot in slots {
            guard slot.salt.count == 16, slot.sealed.nonce.count == 12, slot.sealed.ciphertext.count == 32, slot.sealed.tag.count == 16 else { throw RDMError.invalidFormat }
            if slot.kind == .passphrase { guard slot.kdf == .portable else { throw RDMError.invalidKDF } }
            else { guard slot.kdf == nil else { throw RDMError.invalidKDF } }
        }
    }
}

public final class RDMProjectKeys: @unchecked Sendable {
    public let projectID: UUID
    let master: RDMSecret
    let slots: [RDMKeySlot]
    init(projectID: UUID, master: RDMSecret, slots: [RDMKeySlot]) { self.projectID = projectID; self.master = master; self.slots = slots }
    public var isLocked: Bool { master.isLocked }
    public var protectedAllocationLocked: Bool { master.memoryWasLocked }
    public func lock() { master.lock() }
}
public struct RDMCreatedKeys: Sendable {
    public let keys: RDMProjectKeys
    /// Sensitive user-held recovery material; never encode/log/store in .rdm.
    public let recoveryCode: String
}
public enum RDMCredentials {
    public static func create(projectID: UUID, passphrase: String) async throws -> RDMCreatedKeys {
        try validateNewPassphrase(passphrase)
        let master = try RDMSecret.random()
        do {
            let passwordSlot = try await passphraseSlot(projectID: projectID, master: master, passphrase: passphrase)
            let recovery = try RDMSecret.random(); defer { recovery.lock() }
            let salt = try RDMCrypto.random(16), slotID = UUID(), nonce = try RDMCrypto.random(12)
            let key = try RDMCrypto.derive(recovery, salt: salt, info: RDMAssociatedData.slotKey(projectID, slot: slotID, kind: .recovery))
            defer { key.lock() }
            var raw = try master.withBytes { Data($0) }; defer { raw.resetBytes(in: 0..<raw.count) }
            let aad = RDMAssociatedData.slot(projectID, id: slotID, kind: .recovery, kdf: nil, salt: salt, nonce: nonce)
            let sealed = try RDMCrypto.seal(raw, key: key, aad: aad, nonce: nonce)
            let slot = RDMKeySlot(id: slotID, kind: .recovery, kdf: nil, salt: salt, sealed: sealed)
            let code = try recovery.withBytes { bytes in
                let hex = bytes.map { String(format: "%02X", $0) }.joined()
                let groups = stride(from: 0, to: 64, by: 8).map { index -> String in
                    let start = hex.index(hex.startIndex, offsetBy: index), end = hex.index(start, offsetBy: 8)
                    return String(hex[start..<end])
                }
                return "FOLIO-R1-" + groups.joined(separator: "-")
            }
            return .init(keys: .init(projectID: projectID, master: master, slots: [passwordSlot, slot]), recoveryCode: code)
        } catch { master.lock(); throw error }
    }
    /// Rewraps the same master key with fresh salt/nonce. It cannot revoke access
    /// to an already-copied older archive; full content rekey is separate work.
    public static func changingPassphrase(_ passphrase: String, keys: RDMProjectKeys) async throws -> RDMProjectKeys {
        try validateNewPassphrase(passphrase)
        guard !keys.isLocked else { throw RDMError.locked }
        let slot = try await passphraseSlot(projectID: keys.projectID, master: keys.master, passphrase: passphrase)
        guard let recovery = keys.slots.first(where: { $0.kind == .recovery }) else { throw RDMError.invalidFormat }
        return .init(projectID: keys.projectID, master: try keys.master.copy(), slots: [slot, recovery])
    }
    static func unwrap(header: RDMHeader, passphrase: String) async throws -> RDMProjectKeys {
        try header.validate() // Always BEFORE allocating Argon2 work from a header.
        guard let slot = header.slots.first(where: { $0.kind == .passphrase }) else { throw RDMError.invalidFormat }
        let seed = try await RDMPasswordKDF.shared.derive(passphrase, salt: slot.salt); defer { seed.lock() }
        let key = try RDMCrypto.derive(seed, salt: slot.salt, info: RDMAssociatedData.slotKey(header.projectID, slot: slot.id, kind: slot.kind)); defer { key.lock() }
        return try unwrap(header: header, slot: slot, key: key)
    }
    static func unwrap(header: RDMHeader, recoveryCode: String) throws -> RDMProjectKeys {
        try header.validate()
        guard let slot = header.slots.first(where: { $0.kind == .recovery }) else { throw RDMError.invalidFormat }
        let recovered = try decodeRecovery(recoveryCode); defer { recovered.lock() }
        let key = try RDMCrypto.derive(recovered, salt: slot.salt, info: RDMAssociatedData.slotKey(header.projectID, slot: slot.id, kind: slot.kind)); defer { key.lock() }
        return try unwrap(header: header, slot: slot, key: key)
    }
    private static func unwrap(header: RDMHeader, slot: RDMKeySlot, key: RDMSecret) throws -> RDMProjectKeys {
        let aad = RDMAssociatedData.slot(header.projectID, id: slot.id, kind: slot.kind, kdf: slot.kdf, salt: slot.salt, nonce: slot.sealed.nonce)
        var raw = try RDMCrypto.open(slot.sealed, key: key, aad: aad); defer { raw.resetBytes(in: 0..<raw.count) }
        guard raw.count == 32 else { throw RDMError.authenticationFailed }
        return .init(projectID: header.projectID, master: try RDMSecret(copying: raw), slots: header.slots)
    }
    private static func passphraseSlot(projectID: UUID, master: RDMSecret, passphrase: String) async throws -> RDMKeySlot {
        let salt = try RDMCrypto.random(16), slotID = UUID(), nonce = try RDMCrypto.random(12)
        let seed = try await RDMPasswordKDF.shared.derive(passphrase, salt: salt); defer { seed.lock() }
        let key = try RDMCrypto.derive(seed, salt: salt, info: RDMAssociatedData.slotKey(projectID, slot: slotID, kind: .passphrase)); defer { key.lock() }
        let aad = RDMAssociatedData.slot(projectID, id: slotID, kind: .passphrase, kdf: .portable, salt: salt, nonce: nonce)
        var raw = try master.withBytes { Data($0) }; defer { raw.resetBytes(in: 0..<raw.count) }
        return .init(id: slotID, kind: .passphrase, kdf: .portable, salt: salt, sealed: try RDMCrypto.seal(raw, key: key, aad: aad, nonce: nonce))
    }
    private static func decodeRecovery(_ text: String) throws -> RDMSecret {
        let code = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard code.utf8.count <= 100, code.range(of: #"^FOLIO-R1-(?:[0-9A-F]{8}-){7}[0-9A-F]{8}$"#, options: .regularExpression) != nil else { throw RDMError.invalidRecoveryCode }
        let hex = code.dropFirst(9).replacingOccurrences(of: "-", with: "")
        var bytes = Data(); defer { bytes.resetBytes(in: 0..<bytes.count) }
        var index = hex.startIndex
        while index < hex.endIndex {
            let end = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<end], radix: 16) else { throw RDMError.invalidRecoveryCode }
            bytes.append(byte); index = end
        }
        guard bytes.count == 32 else { throw RDMError.invalidRecoveryCode }
        return try RDMSecret(copying: bytes)
    }
    private static func validateNewPassphrase(_ value: String) throws {
        guard value.utf8.count <= 1024, value.count >= 12, !value.contains("\0") else { throw RDMError.weakPassphrase }
    }
}

/// Fixed-length / length-prefixed domain separation, not ad-hoc string joining.
enum RDMAssociatedData {
    static func uuid(_ value: UUID) -> Data { var tuple = value.uuid; return withUnsafeBytes(of: &tuple) { Data($0) } }
    static func field(_ value: Data, into data: inout Data) { append(UInt32(value.count), to: &data); data.append(value) }
    static func append(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value >> 24)); data.append(UInt8(truncatingIfNeeded: value >> 16))
        data.append(UInt8(truncatingIfNeeded: value >> 8)); data.append(UInt8(truncatingIfNeeded: value))
    }
    static func prefix(_ purpose: String) -> Data { var data = Data("FOLIO-RDM\0".utf8); append(1, to: &data); field(Data(purpose.utf8), into: &data); return data }
    static func slotKey(_ project: UUID, slot: UUID, kind: RDMSlotKind) -> Data {
        var data = prefix("credential-key"); data.append(uuid(project)); data.append(uuid(slot)); field(Data(kind.rawValue.utf8), into: &data); return data
    }
    static func slot(_ project: UUID, id: UUID, kind: RDMSlotKind, kdf: RDMKDFParameters?, salt: Data, nonce: Data) -> Data {
        var data = prefix("master-key-slot"); data.append(uuid(project)); data.append(uuid(id)); field(Data(kind.rawValue.utf8), into: &data)
        for value in [kdf?.version ?? 0, kdf?.memoryKiB ?? 0, kdf?.iterations ?? 0, kdf?.lanes ?? 0] { append(UInt32(value), to: &data) }
        field(salt, into: &data); field(nonce, into: &data); return data
    }
    static func object(project: UUID, snapshot: Data, kind: String, logicalID: UUID, revision: Data, headerDigest: Data) -> Data {
        var data = prefix("immutable-object"); data.append(uuid(project)); field(snapshot, into: &data)
        field(Data(kind.utf8), into: &data); data.append(uuid(logicalID)); field(revision, into: &data)
        append(0, to: &data); append(1, to: &data) // Chunk index and total; v1 spike is one bounded object per record.
        field(headerDigest, into: &data); return data
    }
}

enum RDMCanonical {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return try encoder.encode(value)
    }
    static func decode<T: Codable>(_ type: T.Type, from bytes: Data) throws -> T {
        do {
            let value = try JSONDecoder().decode(type, from: bytes)
            // Reject unknown/duplicate fields, alternate encodings and ambiguous
            // JSON forms instead of authenticating a lossy interpretation.
            guard try encode(value) == bytes else { throw RDMError.invalidFormat }
            return value
        } catch let error as RDMError { throw error }
        catch { throw RDMError.invalidFormat }
    }
}
