import Foundation
import Security

enum KeychainStore {
    static let service = "com.nicklee.lights-menubar"

    static func set(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemCopyMatching(base as CFDictionary, nil)
        if status == errSecSuccess {
            let update: [String: Any] = [kSecValueData as String: data]
            let s = SecItemUpdate(base as CFDictionary, update as CFDictionary)
            if s != errSecSuccess { throw KeychainError(s) }
        } else if status == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            let s = SecItemAdd(add as CFDictionary, nil)
            if s != errSecSuccess { throw KeychainError(s) }
        } else {
            throw KeychainError(status)
        }
    }

    static func get(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

struct KeychainError: Error, CustomStringConvertible {
    let status: OSStatus
    init(_ status: OSStatus) { self.status = status }
    var description: String { "Keychain error \(status)" }
}
