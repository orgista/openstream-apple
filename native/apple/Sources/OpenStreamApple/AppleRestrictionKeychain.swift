import Foundation
import Security

/// Deliberately separate from the credential store's iCloud synchronization policy.
struct AppleRestrictionKeychain: AppleCredentialStoring {
    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.orgista.openstream.restrictions.device",
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }
    func string(for account: String) throws -> String? {
        if AppleKeychainStore.isBypassedForReview { return nil }
        if let memory = AppleKeychainStore.testMemory { return memory.value(service: "com.orgista.openstream.restrictions.device", account: account) }
        var item = query(account)
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(item as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw AppleKeychainStoreError.unexpectedStatus(status) }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else { throw AppleKeychainStoreError.invalidData }
        return value
    }
    func set(_ value: String, for account: String) throws {
        if AppleKeychainStore.isBypassedForReview { return }
        if let memory = AppleKeychainStore.testMemory { memory.set(value, service: "com.orgista.openstream.restrictions.device", account: account); return }
        let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8), kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query(account) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let item = query(account).merging(attributes) { _, new in new }
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw AppleKeychainStoreError.unexpectedStatus(added) }
        } else if status != errSecSuccess { throw AppleKeychainStoreError.unexpectedStatus(status) }
    }
    func remove(_ account: String) throws {
        if AppleKeychainStore.isBypassedForReview { return }
        if let memory = AppleKeychainStore.testMemory { memory.set(nil, service: "com.orgista.openstream.restrictions.device", account: account); return }
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AppleKeychainStoreError.unexpectedStatus(status) }
    }
}
