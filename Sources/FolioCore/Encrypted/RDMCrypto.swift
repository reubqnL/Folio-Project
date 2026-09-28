import Foundation
import FolioRDMPrimitives
#if canImport(CryptoKit)
import CryptoKit
#endif

public enum RDMError: Error, LocalizedError, Equatable, Sendable {
    case invalidFormat, unsupportedVersion, unsupportedSuite, invalidKDF, resourceLimit
    case authenticationFailed, weakPassphrase, invalidRecoveryCode, locked, cryptoUnavailable
    case invalidContent, duplicateIdentity, wrongProject, staleCheckpoint, conflict, recoveryRequired, destinationExists
    public var errorDescription: String? {
        switch self {
        case .invalidFormat: "The encrypted container failed its bounded format checks. No project was opened."
        case .unsupportedVersion: "This .rdm version is not supported. No downgrade or migration was attempted."
        case .unsupportedSuite: "This container requests an unsupported cryptographic suite."
        case .invalidKDF: "The passphrase parameters are not in the supported bounded profile. No expensive derivation was attempted."
        case .resourceLimit: "This development container exceeds the current resource bounds."
        case .authenticationFailed: "The credential is incorrect or the authenticated container was altered. No plaintext project was returned."
        case .weakPassphrase: "Use at least 12 characters, within 1,024 UTF-8 bytes. A length floor is not a guarantee of password strength."
        case .invalidRecoveryCode: "The recovery code is malformed or does not belong to this project."
        case .locked: "The key handle has been locked/erased. Unlock through a valid credential first."
        case .cryptoUnavailable: "A required cryptographic operation failed. No weaker fallback was used."
        case .invalidContent: "The authenticated project content is not a supported, internally consistent snapshot."
        case .duplicateIdentity: "Duplicate object, note, revision or nonce identities are not permitted."
        case .wrongProject: "This key or snapshot belongs to a different project."
        case .staleCheckpoint: "The checkpoint changed since this operation began. Review the current file instead of overwriting it."
        case .conflict: "A concurrent checkpoint version was preserved; the write was not acknowledged as successful."
        case .recoveryRequired: "A checkpoint transaction needs authenticated recovery review."
        case .destinationExists: "The selected encrypted destination already exists. Choose a new destination; no existing file was replaced."
        }
    }
}

/// Owns one small dedicated allocation. Erasure prevents further API use; the
/// platform crypto library and Swift caller may still have transient copies.
/// mlock/dump exclusion are best effort, not protection from a compromised OS.
public final class RDMSecret: @unchecked Sendable {
    private let mutex = NSLock()
    private var pointer: OpaquePointer?
    public let count: Int
    public let memoryWasLocked: Bool
    init(count: Int) throws {
        guard (1...4096).contains(count), let value = folio_secret_create(count) else { throw RDMError.cryptoUnavailable }
        pointer = value; self.count = count; memoryWasLocked = folio_secret_memory_locked(value) != 0
    }
    convenience init(copying bytes: Data) throws {
        try self.init(count: bytes.count)
        _ = try withMutableBytes { output in bytes.copyBytes(to: output.bindMemory(to: UInt8.self)) }
    }
    deinit { folio_secret_destroy(pointer) }
    public var isLocked: Bool { mutex.lock(); defer { mutex.unlock() }; return pointer == nil }
    public func lock() {
        mutex.lock(); defer { mutex.unlock() }
        folio_secret_destroy(pointer); pointer = nil
    }
    func withBytes<T>(_ body: (UnsafeRawBufferPointer) throws -> T) throws -> T {
        mutex.lock(); defer { mutex.unlock() }
        guard let pointer, let bytes = folio_secret_bytes(pointer) else { throw RDMError.locked }
        return try body(.init(start: bytes, count: count))
    }
    func withMutableBytes<T>(_ body: (UnsafeMutableRawBufferPointer) throws -> T) throws -> T {
        mutex.lock(); defer { mutex.unlock() }
        guard let pointer, let bytes = folio_secret_bytes(pointer) else { throw RDMError.locked }
        return try body(.init(start: bytes, count: count))
    }
    static func random(count: Int = 32) throws -> RDMSecret {
        let secret = try RDMSecret(count: count)
        let ok = try secret.withMutableBytes { folio_crypto_random($0.bindMemory(to: UInt8.self).baseAddress, count) }
        guard ok == 1 else { secret.lock(); throw RDMError.cryptoUnavailable }
        return secret
    }
    func copy() throws -> RDMSecret {
        let other = try RDMSecret(count: count)
        try withBytes { source in try other.withMutableBytes { target in target.copyMemory(from: source) } }
        return other
    }
}

struct RDMSealedBytes: Equatable, Codable, Sendable {
    let nonce: Data
    let ciphertext: Data
    let tag: Data
}

enum RDMCrypto {
    static func random(_ count: Int) throws -> Data {
        guard (1...4096).contains(count) else { throw RDMError.resourceLimit }
        var data = Data(count: count)
        let ok = data.withUnsafeMutableBytes { folio_crypto_random($0.bindMemory(to: UInt8.self).baseAddress, count) }
        guard ok == 1 else { throw RDMError.cryptoUnavailable }
        return data
    }
    static func derive(_ key: RDMSecret, salt: Data, info: Data, count: Int = 32) throws -> RDMSecret {
        guard (1...64).contains(count), salt.count <= 1024, info.count <= 4096 else { throw RDMError.resourceLimit }
        let result = try RDMSecret(count: count)
        #if canImport(CryptoKit)
        try key.withBytes { input in
            let derived = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: input), salt: salt, info: info, outputByteCount: count)
            try derived.withUnsafeBytes { bytes in try result.withMutableBytes { $0.copyMemory(from: bytes) } }
        }
        #else
        let ok = try key.withBytes { input in
            try result.withMutableBytes { output in
                salt.withUnsafeBytes { salt in info.withUnsafeBytes { info in
                    folio_hkdf_sha256(input.bindMemory(to: UInt8.self).baseAddress, input.count,
                        salt.bindMemory(to: UInt8.self).baseAddress, salt.count,
                        info.bindMemory(to: UInt8.self).baseAddress, info.count,
                        output.bindMemory(to: UInt8.self).baseAddress, output.count)
                } }
            }
        }
        guard ok == 1 else { result.lock(); throw RDMError.cryptoUnavailable }
        #endif
        return result
    }
    static func seal(_ plaintext: Data, key: RDMSecret, aad: Data, nonce: Data? = nil) throws -> RDMSealedBytes {
        guard key.count == 32, plaintext.count <= 64 * 1024 * 1024, aad.count <= 65536 else { throw RDMError.resourceLimit }
        let iv = try nonce ?? random(12)
        guard iv.count == 12 else { throw RDMError.invalidFormat }
        #if canImport(CryptoKit)
        return try key.withBytes { bytes in
            let result = try AES.GCM.seal(plaintext, using: SymmetricKey(data: bytes), nonce: AES.GCM.Nonce(data: iv), authenticating: aad)
            return .init(nonce: iv, ciphertext: result.ciphertext, tag: result.tag)
        }
        #else
        var cipher = Data(count: plaintext.count), tag = Data(count: 16)
        let length = plaintext.count
        let ok = try key.withBytes { key in iv.withUnsafeBytes { iv in plaintext.withUnsafeBytes { plain in aad.withUnsafeBytes { aad in
            cipher.withUnsafeMutableBytes { cipher in tag.withUnsafeMutableBytes { tag in
                folio_aes256gcm_seal(key.bindMemory(to: UInt8.self).baseAddress, iv.bindMemory(to: UInt8.self).baseAddress,
                    plain.bindMemory(to: UInt8.self).baseAddress, length, aad.bindMemory(to: UInt8.self).baseAddress, aad.count,
                    cipher.bindMemory(to: UInt8.self).baseAddress, tag.bindMemory(to: UInt8.self).baseAddress)
            } }
        } } } }
        guard ok == 1 else { throw RDMError.cryptoUnavailable }
        return .init(nonce: iv, ciphertext: cipher, tag: tag)
        #endif
    }
    static func open(_ sealed: RDMSealedBytes, key: RDMSecret, aad: Data) throws -> Data {
        guard key.count == 32, sealed.nonce.count == 12, sealed.tag.count == 16,
              sealed.ciphertext.count <= 64 * 1024 * 1024, aad.count <= 65536 else { throw RDMError.invalidFormat }
        #if canImport(CryptoKit)
        do {
            return try key.withBytes { bytes in
                let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: sealed.nonce), ciphertext: sealed.ciphertext, tag: sealed.tag)
                return try AES.GCM.open(box, using: SymmetricKey(data: bytes), authenticating: aad)
            }
        } catch RDMError.locked { throw RDMError.locked }
        catch { throw RDMError.authenticationFailed }
        #else
        var plaintext = Data(count: sealed.ciphertext.count)
        let length = sealed.ciphertext.count
        let ok = try key.withBytes { key in sealed.nonce.withUnsafeBytes { iv in sealed.ciphertext.withUnsafeBytes { cipher in aad.withUnsafeBytes { aad in sealed.tag.withUnsafeBytes { tag in
            plaintext.withUnsafeMutableBytes { plain in
                folio_aes256gcm_open(key.bindMemory(to: UInt8.self).baseAddress, iv.bindMemory(to: UInt8.self).baseAddress,
                    cipher.bindMemory(to: UInt8.self).baseAddress, length, aad.bindMemory(to: UInt8.self).baseAddress, aad.count,
                    tag.bindMemory(to: UInt8.self).baseAddress, plain.bindMemory(to: UInt8.self).baseAddress)
            }
        } } } } }
        guard ok == 1 else { plaintext.resetBytes(in: 0..<plaintext.count); throw RDMError.authenticationFailed }
        return plaintext
        #endif
    }
}

/// Fixed compatible profile; untrusted archive headers cannot ask for arbitrary
/// memory/time/lanes. The actor serializes app KDF work rather than allowing an
/// archive to create many concurrent memory-hard jobs.
actor RDMPasswordKDF {
    static let shared = RDMPasswordKDF()
    func derive(_ passphrase: String, salt: Data) throws -> RDMSecret {
        guard !passphrase.isEmpty, passphrase.utf8.count <= 1024, !passphrase.contains("\0"), salt.count == 16 else { throw RDMError.authenticationFailed }
        var password = Data(passphrase.utf8)
        defer { password.resetBytes(in: 0..<password.count) }
        let key = try RDMSecret(count: 32)
        let ok = try key.withMutableBytes { output in password.withUnsafeBytes { password in salt.withUnsafeBytes { salt in
            folio_argon2id(password.bindMemory(to: UInt8.self).baseAddress, password.count,
                salt.bindMemory(to: UInt8.self).baseAddress, salt.count, 65536, 3, 4,
                output.bindMemory(to: UInt8.self).baseAddress, output.count)
        } } }
        guard ok == 1 else { key.lock(); throw RDMError.cryptoUnavailable }
        return key
    }
}
