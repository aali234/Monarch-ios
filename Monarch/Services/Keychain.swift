import Foundation
import Security
import MonarchCore

enum SecureStore {
    private static let service = "app.monarch.personal"
    static func set(_ value: String, for key: String) throws { try setData(Data(value.utf8), for: key) }
    static func setData(_ value: Data, for key: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key]
        let changes: [String: Any] = [kSecValueData as String: value, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let update = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
        if update == errSecItemNotFound {
            let result = SecItemAdd(query.merging(changes) { _, new in new } as CFDictionary, nil)
            guard result == errSecSuccess else { throw failure(result) }
        } else if update != errSecSuccess { throw failure(update) }
    }
    static func data(for key: String) throws -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw failure(status) }
        return item as? Data
    }
    static func string(for key: String) throws -> String? { try data(for: key).flatMap { String(data: $0, encoding: .utf8) } }
    static func delete(_ key: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status) }
    }
    private static func failure(_ status: OSStatus) -> ProxyError {
        .init(errorCode: "KEYCHAIN_\(status)", message: "Secure storage is unavailable. Unlock the device and try again.")
    }
}

struct PendingConnection: Codable {
    var id: String
    var name: String
    var institutionID: String
    var itemID: String
    var masks: [String]
    var product: String
    var accessToken: String
    // This whole record lives only in Keychain, and is written atomically.
}
