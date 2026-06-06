import Foundation
import Security

enum KeychainStore {
    static let service = "com.nicklee.lights-menubar"

    // The legacy macOS keychain attaches a per-app ACL to each item and prompts
    // the user when an app whose code signature doesn't match the ACL reads it.
    // For an ad-hoc-signed app like this one the signature changes on every
    // rebuild, so "Always Allow" only sticks until the next build. To keep that
    // from compounding into a flurry of prompts whenever the schedule generator
    // runs (it pulls multiple credentials in quick succession), cache reads in
    // memory for the lifetime of the process.
    private static let cacheQueue = DispatchQueue(label: "com.nicklee.lights-menubar.keychain-cache")
    private static var cache: [String: String] = [:]

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
        cacheQueue.sync { cache[account] = value }
    }

    /// Returns the stored value, or `nil` if no item exists for `account`.
    ///
    /// Throws if an item *does* exist but can't be read — most commonly because
    /// the per-app ACL no longer matches this build's code signature, so the OS
    /// would prompt for access and that fails when running unattended. Callers
    /// must distinguish this from "no item" so a Keychain-access failure can be
    /// surfaced as a clear error instead of silently degrading (e.g. an empty
    /// password that then 401s against InfluxDB).
    static func read(account: String) throws -> String? {
        if let cached = cacheQueue.sync(execute: { cache[account] }) {
            return cached
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                  let value = String(data: data, encoding: .utf8) else {
                throw KeychainError(errSecDecode)
            }
            cacheQueue.sync { cache[account] = value }
            return value
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError(status)
        }
    }

    /// Convenience wrapper that collapses any failure to `nil`. Use `read` when
    /// you need to tell "not stored" apart from "couldn't be read".
    static func get(account: String) -> String? {
        try? read(account: account)
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        _ = cacheQueue.sync { cache.removeValue(forKey: account) }
    }
}

struct KeychainError: Error, CustomStringConvertible {
    let status: OSStatus
    init(_ status: OSStatus) { self.status = status }
    var description: String { "Keychain error \(status)" }
}
