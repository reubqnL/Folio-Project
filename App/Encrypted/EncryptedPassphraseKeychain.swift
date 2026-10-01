import Foundation
#if canImport(Security)
import Security
#endif

/// Explicit, device-local convenience storage for an encrypted-project
/// passphrase. Recovery codes are never accepted by this adapter. Keychain use
/// is opt-in, non-synchronising and not a replacement for a reviewed recovery
/// design or an independent security assessment.
enum EncryptedPassphraseKeychain {
    enum Failure: Error, LocalizedError {
        case unavailable
        case operation(Int32)
        case invalidData
        var errorDescription: String? {
            switch self {
            case .unavailable: "This platform does not provide the Folio encrypted-project Keychain adapter."
            case .operation(let status): "The encrypted-project Keychain operation failed (status \(status))."
            case .invalidData: "The saved Keychain value was not a valid UTF-8 passphrase."
            }
        }

        /// True when the failure is the data protection keychain refusing the
        /// request, rather than a genuine keychain error worth reporting.
        var isDataProtectionRefusal: Bool {
            guard case .operation(let status) = self else { return false }
            return EncryptedPassphraseKeychain.dataProtectionRefusals.contains(status)
        }
    }

    private static let service = "Folio.EncryptedProject.Passphrase.v1"

    /// Status codes meaning "the data protection keychain is not available to
    /// this process", as opposed to a real keychain failure.
    ///
    /// -34018 is errSecMissingEntitlement: the process was signed with an
    /// identity that gives it no keychain access group. -25291 is
    /// errSecNotAvailable: there is no such keychain in this context.
    ///
    /// Written as literals rather than the Security constants so this file does
    /// not depend on a particular SDK version exporting them.
    private static let dataProtectionRefusals: Set<Int32> = [-34018, -25291]

    #if canImport(Security)
    /// macOS has two keychain implementations, and `SecItem` chooses between
    /// them from the query rather than from anything this code states.
    ///
    /// `kSecAttrAccessible` is only honoured by the data protection keychain.
    /// Apple's own header is explicit: the attribute "is currently not
    /// supported for OS X keychain items". An item written without
    /// `kSecUseDataProtectionKeychain` therefore stores no protection class at
    /// all — the add succeeds, the attribute is silently dropped, and a later
    /// read reports it absent. This adapter asks for
    /// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, so it has to ask for the
    /// keychain implementation that can actually enforce it.
    ///
    /// That keychain is not always reachable: it needs the process to be signed
    /// with an identity that provides an access group, and Folio's development
    /// builds are ad-hoc signed. When it refuses, the operation is retried
    /// against the file-based keychain, which never requires entitlements but
    /// will not enforce the protection class. That keeps the feature working on
    /// every build, without letting the weaker store masquerade as the stronger
    /// one — the caller still learns the difference if both fail.
    static func save(_ passphrase: String, for fileURL: URL) throws {
        guard !passphrase.isEmpty, !passphrase.contains("\0") else { throw Failure.invalidData }
        let value = Data(passphrase.utf8)
        var refusal: Failure = .unavailable
        for dataProtection in [true, false] {
            do {
                try save(value, for: fileURL, dataProtection: dataProtection)
                return
            } catch let failure as Failure where dataProtection && failure.isDataProtectionRefusal {
                refusal = failure
            }
        }
        throw refusal
    }

    static func load(for fileURL: URL) throws -> String? {
        for dataProtection in [true, false] {
            do {
                if let value = try load(for: fileURL, dataProtection: dataProtection) {
                    return value
                }
                // Not in this store. Ask the next one: a passphrase saved by a
                // build that could only reach the file-based keychain is still
                // a passphrase the user expects to find.
                continue
            } catch let failure as Failure where dataProtection && failure.isDataProtectionRefusal {
                // A refusal means there is nothing to find here anyway; the
                // file-based store is authoritative for this build.
                continue
            }
        }
        // Neither store holds it. When the data protection keychain was
        // refused, a miss in the fallback store means there genuinely is no
        // saved passphrase, so this returns nil rather than an error: turning
        // "type your passphrase" into a Keychain failure message would be
        // wrong, and the feature is optional convenience storage either way.
        return nil
    }

    static func remove(for fileURL: URL) throws {
        var refusal: Failure = .unavailable
        for dataProtection in [true, false] {
            do {
                try remove(for: fileURL, dataProtection: dataProtection)
                return
            } catch let failure as Failure where dataProtection && failure.isDataProtectionRefusal {
                refusal = failure
            }
        }
        throw refusal
    }

    private static func save(_ value: Data, for fileURL: URL, dataProtection: Bool) throws {
        let query = baseQuery(for: fileURL, dataProtection: dataProtection)
        // Only the value is updated here. The protection class and the
        // synchronizable flag are add-only attributes: Apple's guidance is to
        // set them when the item is added and never change them, and passing
        // kSecAttrAccessible to SecItemUpdate can fail the whole update with
        // errSecParam. Saving a replacement passphrase used to go through this
        // path and could fail for that reason.
        let update: [String: Any] = [kSecValueData as String: value]
        let updated = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw Failure.operation(Int32(updated)) }
        var item = query
        item[kSecValueData as String] = value
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw Failure.operation(Int32(added)) }
    }

    private static func load(for fileURL: URL, dataProtection: Bool) throws -> String? {
        var query = baseQuery(for: fileURL, dataProtection: dataProtection)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Failure.operation(Int32(status)) }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw Failure.invalidData
        }
        return value
    }

    private static func remove(for fileURL: URL, dataProtection: Bool) throws {
        let status = SecItemDelete(baseQuery(for: fileURL, dataProtection: dataProtection) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Failure.operation(Int32(status))
        }
    }

    private static func baseQuery(for fileURL: URL, dataProtection: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            // Binding convenience storage to the canonical file location avoids
            // silently carrying a saved credential to a copied/moved archive.
            kSecAttrAccount as String: fileURL.standardizedFileURL.path
        ]
        // `kSecAttrSynchronizable` is deliberately absent rather than false.
        //
        // The attribute is not a plain switch: its presence changes what other
        // attributes are legal. Apple's header states that when it is set
        // alongside `kSecAttrAccessible`, the accessibility value may only be
        // one whose name does not end in "ThisDeviceOnly", because such a class
        // cannot leave the device. This adapter asks for
        // `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, so passing the
        // synchronizable attribute as well was a contradiction — and the
        // documented answer to a contradictory SecItem dictionary is
        // errSecParam, which surfaces to the user as a Keychain failure.
        //
        // Omitting it expresses the same intent without the conflict: items are
        // not synchronised unless the attribute is set, and an item with no
        // access group and no synchronizable flag belongs to this device alone.
        if dataProtection { query[kSecUseDataProtectionKeychain as String] = true }
        return query
    }
    #else
    static func save(_ passphrase: String, for fileURL: URL) throws { throw Failure.unavailable }
    static func load(for fileURL: URL) throws -> String? { throw Failure.unavailable }
    static func remove(for fileURL: URL) throws { throw Failure.unavailable }
    #endif
}
