import Foundation
import Security

/// Myna's secrets — saved places today, device keys tomorrow — kept as
/// generic-password items in the data-protection Keychain.
///
/// Every item is `AfterFirstUnlockThisDeviceOnly`: background work (a
/// conversation composed while the phone is locked, a Bluetooth wearable
/// streaming in the background) can read it once the phone has been unlocked
/// since boot, and it is never synced to iCloud Keychain or restored onto
/// another device from a backup.
enum Keychain {
    static let service = "com.lightwave.myna"

    enum KeychainError: LocalizedError {
        case unexpectedStatus(OSStatus)

        var errorDescription: String? {
            switch self {
            case .unexpectedStatus(let status):
                let message = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
                return "Keychain error: \(message)"
            }
        }
    }

    static func data(for account: String) -> Data? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func set(_ data: Data, for account: String) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(baseQuery(account) as CFDictionary, attributes as CFDictionary)
        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var query = baseQuery(account)
            query.merge(attributes) { _, new in new }
            let added = SecItemAdd(query as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainError.unexpectedStatus(added) }
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    static func delete(_ account: String) {
        SecItemDelete(baseQuery(account) as CFDictionary)
    }

    // MARK: - Codable convenience

    static func value<T: Decodable>(_ type: T.Type, for account: String) -> T? {
        data(for: account).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    static func set<T: Encodable>(_ value: T, for account: String) throws {
        try set(JSONEncoder().encode(value), for: account)
    }

    private static func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }
}
