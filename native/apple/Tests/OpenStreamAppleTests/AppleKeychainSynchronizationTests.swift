import Foundation
import Security
import Synchronization
import Testing
@testable import OpenStreamApple

struct AppleKeychainSynchronizationTests {
    @Test(arguments: [true, false], [true, false])
    func tvWritesLocalItemsAndRetiresTheBuild20Copy(preference: Bool, existingLocal: Bool) throws {
        let security = KeychainQueryFixture()
        security.seed("old-token", synchronizable: true)
        if existingLocal { security.seed("local-token", synchronizable: false) }
        let store = security.store(mode: .automaticReadOnly, preference: preference)

        try store.set("new-token", for: "session")

        #expect(try store.string(for: "session") == "new-token")
        #expect(security.items.count == 1)
        #expect(security.items.first?.synchronizable == false)
        #expect(security.items.first?.accessibility == (kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String))
        security.removeLocalItems()
        #expect(try store.string(for: "session") == nil)
    }

    @Test func tvReadsLocalFirstAndFallsBackToAnyForBuild20() throws {
        let security = KeychainQueryFixture()
        security.seed("build20-token", synchronizable: true)
        let store = security.store(mode: .automaticReadOnly)

        #expect(try store.string(for: "session") == "build20-token")
        #expect(security.reads == ["local", "any"])
        security.seed("local-token", synchronizable: false)
        #expect(try store.string(for: "session") == "local-token")
        #expect(security.reads == ["local", "any", "local"])
    }

    @Test func tvRemovalDeletesLocalAndSynchronizableCopies() throws {
        let security = KeychainQueryFixture()
        security.seed("build20-token", synchronizable: true)
        security.seed("local-token", synchronizable: false)
        let store = security.store(mode: .automaticReadOnly)

        try store.remove("session")

        #expect(security.deletes == ["any"])
        #expect(security.items.isEmpty)
        #expect(try store.string(for: "session") == nil)
        try store.remove("session")
    }

    @Test(arguments: [true, false])
    func viewerChoiceAndBackupKeysKeepTheirSyncAttributes(preference: Bool) throws {
        let security = KeychainQueryFixture()
        try security.store(mode: .viewerChoice, preference: preference).set("phone-token", for: "session")
        #expect(security.items.first?.synchronizable == preference)
        let backup = AppleKeychainStore(service: "backup", mode: .automaticReadOnly, storedPreference: false,
            operations: security.operations, alwaysSynchronizable: true)
        try backup.set("backup-key", for: "backup")
        #expect(security.items.first { $0.service == "backup" }?.synchronizable == true)
        #expect(security.items.first { $0.service == "backup" }?.accessibility == (kSecAttrAccessibleAfterFirstUnlock as String))
    }

    @Test(arguments: [true, false], [AppleConfigurationSyncMode.viewerChoice, .automaticReadOnly])
    func migrationMovesBothServicesOnlyWhereKeychainSyncIsSupported(enabled: Bool, mode: AppleConfigurationSyncMode) throws {
        let suite = "keychain-migration.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(!enabled, forKey: AppleKeychainStore.syncPreferenceKey)
        let security = KeychainQueryFixture()
        for service in ["com.orgista.openstream.settings", "com.orgista.openstream.instances"] {
            security.seed("saved-token", synchronizable: !enabled, service: service)
        }

        try AppleKeychainStore.migrateSynchronization(to: enabled, mode: mode, defaults: defaults, operations: security.operations)

        let expected = mode == .viewerChoice ? enabled : !enabled
        #expect(security.items.allSatisfy { $0.synchronizable == expected })
        #expect(defaults.bool(forKey: AppleKeychainStore.syncPreferenceKey) == expected)
        #expect(security.updateCount == (mode == .viewerChoice ? 2 : 0))
    }

    @Test func migrationFailureRestoresEarlierServicesAndThePreference() throws {
        let suite = "keychain-migration.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: AppleKeychainStore.syncPreferenceKey)
        let security = KeychainQueryFixture(failingService: "com.orgista.openstream.instances")
        for service in ["com.orgista.openstream.settings", "com.orgista.openstream.instances"] {
            security.seed("saved-token", synchronizable: false, service: service)
        }

        #expect(throws: AppleKeychainStoreError.self) {
            try AppleKeychainStore.migrateSynchronization(to: true, mode: .viewerChoice, defaults: defaults, operations: security.operations)
        }

        #expect(security.items.allSatisfy { $0.synchronizable == false })
        #expect(defaults.bool(forKey: AppleKeychainStore.syncPreferenceKey) == false)
    }
}

private final class KeychainQueryFixture: Sendable {
    struct Item: Sendable {
        var service: String
        var account: String
        var synchronizable: Bool
        var value: Data
        var accessibility: String?
    }
    private struct State {
        var items: [Item] = []
        var reads: [String] = []
        var deletes: [String] = []
        var updates = 0
    }
    private let state = Mutex(State())
    private let failingService: String?
    init(failingService: String? = nil) { self.failingService = failingService }
    var items: [Item] { state.withLock { $0.items } }
    var reads: [String] { state.withLock { $0.reads } }
    var deletes: [String] { state.withLock { $0.deletes } }
    var updateCount: Int { state.withLock { $0.updates } }

    func seed(_ value: String, synchronizable: Bool, service: String = "fixture-keychain") {
        state.withLock { $0.items.append(.init(service: service, account: "session", synchronizable: synchronizable, value: Data(value.utf8))) }
    }
    func removeLocalItems() { state.withLock { $0.items.removeAll { !$0.synchronizable } } }
    func store(mode: AppleConfigurationSyncMode, preference: Bool = true) -> AppleKeychainStore {
        AppleKeychainStore(service: "fixture-keychain", mode: mode, storedPreference: preference, operations: operations)
    }
    private static func syncAttribute(_ query: [String: Any]) -> String {
        if query[kSecAttrSynchronizable as String] as? String == kSecAttrSynchronizableAny as String { return "any" }
        return query[kSecAttrSynchronizable as String] as? Bool == true ? "sync" : "local"
    }
    private static func matches(_ item: Item, _ query: [String: Any]) -> Bool {
        item.service == query[kSecAttrService as String] as? String
            && (query[kSecAttrAccount as String] == nil || item.account == query[kSecAttrAccount as String] as? String)
            && (syncAttribute(query) == "any" || item.synchronizable == (syncAttribute(query) == "sync"))
    }
    var operations: AppleKeychainStore.SecurityOperations {
        .init(read: { query in
            self.state.withLock { state in
                state.reads.append(Self.syncAttribute(query))
                guard let item = state.items.first(where: { Self.matches($0, query) }) else { return (errSecItemNotFound, nil) }
                return (errSecSuccess, item.value as CFData)
            }
        }, update: { query, attributes in
            self.state.withLock { state in
                state.updates += 1
                if query[kSecAttrService as String] as? String == self.failingService { return errSecAuthFailed }
                let indices = state.items.indices.filter { Self.matches(state.items[$0], query) }
                for index in indices {
                    if let value = attributes[kSecValueData as String] as? Data { state.items[index].value = value }
                    if let sync = attributes[kSecAttrSynchronizable as String] as? Bool { state.items[index].synchronizable = sync }
                    state.items[index].accessibility = attributes[kSecAttrAccessible as String] as? String
                }
                return indices.isEmpty ? errSecItemNotFound : errSecSuccess
            }
        }, add: { item in
            guard let service = item[kSecAttrService as String] as? String,
                  let account = item[kSecAttrAccount as String] as? String,
                  let value = item[kSecValueData as String] as? Data else { return errSecParam }
            self.state.withLock { $0.items.append(.init(service: service, account: account,
                synchronizable: Self.syncAttribute(item) == "sync", value: value,
                accessibility: item[kSecAttrAccessible as String] as? String)) }
            return errSecSuccess
        }, delete: { query in
            self.state.withLock { state in
                state.deletes.append(Self.syncAttribute(query))
                let before = state.items.count
                state.items.removeAll { Self.matches($0, query) }
                return before == state.items.count ? errSecItemNotFound : errSecSuccess
            }
        })
    }
}
