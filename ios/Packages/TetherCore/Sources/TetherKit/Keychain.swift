#if os(iOS) && canImport(ManagedSettings)
import Foundation
import Security
import TetherCore

/// Minimal generic-password Keychain wrapper shared by the app and extensions through
/// the keychain access group from Info.plist `TetherKeychainGroup`.
/// Items use `kSecAttrAccessibleAfterFirstUnlock` so extensions can read while the
/// device is locked (after the first unlock since boot).
public enum Keychain {
    public enum KeychainError: Error, Equatable { case unexpectedStatus(OSStatus), encoding }

    static let service = "com.newwestsite.tether"

    public enum Account {
        public static let deviceToken = "device.apiToken"
        public static let pinRecord = "protection.pinRecord"
    }

    private static func baseQuery(account: String) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let group = AppGroup.keychainGroup { q[kSecAttrAccessGroup as String] = group }
        return q
    }

    public static func setData(_ data: Data, account: String) throws {
        var query = baseQuery(account: account)
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecSuccess { return }
        if status == errSecItemNotFound {
            query.merge(attrs) { $1 }
            let add = SecItemAdd(query as CFDictionary, nil)
            guard add == errSecSuccess else {
                TLog.keychain.error("SecItemAdd failed: \(add)")
                throw KeychainError.unexpectedStatus(add)
            }
            return
        }
        TLog.keychain.error("SecItemUpdate failed: \(status)")
        throw KeychainError.unexpectedStatus(status)
    }

    public static func data(account: String) -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        guard status == errSecSuccess else { return nil }
        return out as? Data
    }

    public static func delete(account: String) {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            TLog.keychain.error("SecItemDelete failed: \(status)")
        }
    }

    public static func setString(_ s: String, account: String) throws {
        guard let d = s.data(using: .utf8) else { throw KeychainError.encoding }
        try setData(d, account: account)
    }

    public static func string(account: String) -> String? {
        data(account: account).flatMap { String(data: $0, encoding: .utf8) }
    }

    // MARK: Typed items

    /// Device API token (bearer `td_…`) obtained at enrollment.
    public static var deviceToken: String? {
        get { string(account: Account.deviceToken) }
        set {
            if let v = newValue { try? setString(v, account: Account.deviceToken) }
            else { delete(account: Account.deviceToken) }
        }
    }

    /// Partner PIN record (PBKDF2 hash + salt + iterations), JSON-encoded.
    public static func savePINRecord(_ record: PINRecord) throws {
        let data = try JSONEncoder().encode(record)
        try setData(data, account: Account.pinRecord)
    }

    public static func loadPINRecord() -> PINRecord? {
        guard let d = data(account: Account.pinRecord) else { return nil }
        return try? JSONDecoder().decode(PINRecord.self, from: d)
    }

    public static func deletePINRecord() { delete(account: Account.pinRecord) }
}
#endif
