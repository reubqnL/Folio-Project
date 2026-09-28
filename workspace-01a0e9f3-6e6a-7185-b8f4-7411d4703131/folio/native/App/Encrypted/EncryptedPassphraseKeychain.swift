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
    }

    private static let service = "Folio.EncryptedProject.Passphrase.v1"

    #if canImport(Security)
    static func save(_ passphrase: String, for fileURL: URL) throws {
        guard !passphrase.isEmpty, !passphrase.contains("\0") else { throw Failure.invalidData }
        let query = baseQuery(for: fileURL)
        let value = Data(passphrase.utf8)
        let update: [String: Any] = [
            kSecValueData as String: value,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrSynchronizable as String: false
        ]
        let updated = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw Failure.operation(Int32(updated)) }
        var item = query
        item.merge(update) { _, new in new }
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw Failure.operation(Int32(added)) }
    }

    static func load(for fileURL: URL) throws -> String? {
        var query = baseQuery(for: fileURL)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Failure.operation(Int32(status)) }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else { throw Failure.invalidData }
        return value
    }

    static func remove(for fileURL: URL) throws {
        let status = SecItemDelete(baseQuery(for: fileURL) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.operation(Int32(status)) }
    }

    private static func baseQuery(for fileURL: URL) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            // Binding convenience storage to the canonical file location avoids
            // silently carrying a saved credential to a copied/moved archive.
            kSecAttrAccount as String: fileURL.standardizedFileURL.path,
            kSecAttrSynchronizable as String: false
        ]
    }
    #else
    static func save(_ passphrase: String, for fileURL: URL) throws { throw Failure.unavailable }
    static func load(for fileURL: URL) throws -> String? { throw Failure.unavailable }
    static func remove(for fileURL: URL) throws { throw Failure.unavailable }
    #endif
}
