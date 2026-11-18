import Foundation
import Security

protocol SecretStoring: Sendable {
    func save(value: String, forKey key: String)
    func load(forKey key: String) -> String
    func delete(forKey key: String)
}

final class KeychainSecretStore: SecretStoring, @unchecked Sendable {
    private let service = "com.wenjinliu.agy.credentials"

    func save(value: String, forKey key: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var newItem = query
            newItem[kSecValueData as String] = data
            newItem[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(newItem as CFDictionary, nil)
        }
    }

    func load(forKey key: String) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let decoded = String(data: data, encoding: .utf8) else {
            return ""
        }
        return decoded
    }

    func delete(forKey key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

final class InMemorySecretStore: SecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String] = [:]

    init(initial: [String: String] = [:]) {
        self.storage = initial
    }

    func save(value: String, forKey key: String) {
        lock.withLock { storage[key] = value }
    }

    func load(forKey key: String) -> String {
        lock.withLock { storage[key] ?? "" }
    }

    func delete(forKey key: String) {
        lock.withLock { _ = storage.removeValue(forKey: key) }
    }
}
