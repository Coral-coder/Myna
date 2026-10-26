import Foundation

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

    /// Save the AES key Myna derived from Bee's sealed token, so a bracelet we
    /// provisioned can be reused later without another round-trip.
    static func store(_ key: Data, deviceID: String) {
        try? Keychain.set(key, for: account(for: deviceID))
    }

    // The full Bee-signed key token, captured from the bracelet's BLE pairing
    // (the SetEncryptionKey 0xC018 write). Stored so Myna can install/reuse it
    // on its own, with no Bee server. The AES-CTR key is bytes 12..<28 of it.
    private static func tokenAccount(for deviceID: String) -> String {
        "bee.token.\(deviceID.isEmpty ? "default" : deviceID)"
    }

    static func existingToken(deviceID: String) -> Data? {
        Keychain.data(for: tokenAccount(for: deviceID))
    }

    static func storeToken(_ token: Data, deviceID: String) {
        try? Keychain.set(token, for: tokenAccount(for: deviceID))
    }

    /// Forget a bracelet's key (e.g. after a factory reset, so the next pairing
    /// generates a new one).
    static func forget(deviceID: String) {
        Keychain.delete(account(for: deviceID))
        Keychain.delete(tokenAccount(for: deviceID))
    }
}
