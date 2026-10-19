import Foundation
import Security

/// Myna's own AES-128 key for a bracelet — "my device, my key".
///
/// The key is generated on this iPhone with the system CSPRNG, stored in the
/// Keychain as `AfterFirstUnlockThisDeviceOnly` (so a background BLE session can
/// read it while the phone is locked, and it never leaves this device or syncs
/// to iCloud), and installed on the bracelet through the device's own
/// SetEncryptionKey command. Myna then reads audio the bracelet encrypts with
/// that key. The key is kept per device id, so more than one bracelet can be
/// paired.
enum BeeKeyVault {
    private static func account(for deviceID: String) -> String {
        "bee.key.\(deviceID.isEmpty ? "default" : deviceID)"
    }

    /// The key already stored for this bracelet, if any.
    static func existingKey(deviceID: String) -> Data? {
        let data = Keychain.data(for: account(for: deviceID))
        return data?.count == BeeProtocol.keyLength ? data : nil
    }

    /// The stored key, or a freshly generated one saved to the Keychain.
    static func loadOrCreateKey(deviceID: String) throws -> Data {
        if let existing = existingKey(deviceID: deviceID) { return existing }
        let key = try randomKey()
        try Keychain.set(key, for: account(for: deviceID))
        return key
    }

    /// Forget a bracelet's key (e.g. after a factory reset, so the next pairing
    /// generates a new one).
    static func forget(deviceID: String) {
        Keychain.delete(account(for: deviceID))
    }

    enum KeyError: LocalizedError {
        case randomFailed(OSStatus)
        var errorDescription: String? { "Couldn't generate a secure key for the bracelet." }
    }

    private static func randomKey() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: BeeProtocol.keyLength)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw KeyError.randomFailed(status) }
        return Data(bytes)
    }
}
