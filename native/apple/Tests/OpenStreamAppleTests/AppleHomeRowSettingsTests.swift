import Foundation
import Testing
@testable import OpenStreamApple

@MainActor
struct AppleHomeRowSettingsTests {
    @Test func rowContextComparesValuesAndStableStoreIdentities() throws {
        let domain = "home-row-context.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let settings = AppleSettingsStore(defaults: defaults, keychain: HomeRowTestCredentials())
        let library = AppleMediaServerLibraryStore(progressDefaults: defaults)
        let row = AppleHomeRowSetting(id: "recentlyAdded", defaultName: "Recently Added")
        let first = AppleHomeRowContext(row: row, settings: settings, mediaServerLibrary: library, shelfIDs: ["latest"])
        let rebuilt = AppleHomeRowContext(row: row, settings: settings, mediaServerLibrary: library, shelfIDs: ["latest"])
        #expect(first == rebuilt)
        #expect(first != AppleHomeRowContext(row: row, settings: settings, mediaServerLibrary: library, shelfIDs: ["other"]))
        #expect(first != AppleHomeRowContext(row: .init(id: row.id, defaultName: "New Name"),
            settings: settings, mediaServerLibrary: library, shelfIDs: ["latest"]))
    }

    @Test func settingsInventoryKeepsHiddenRowsAndSeenServerLibrariesInHomeOrder() {
        let server = AppleDiscoverServerRows.Row(id: "server:fixture:kids", title: "Kids", items: [], shelfIDs: [], isLoading: false)
        let rows = AppleHomeRowSetting.rows(serverRows: [server])
        #expect(rows.map(\.id) == AppleDiscoverRowOrder.builtInIDs + [server.id])
        #expect(rows.last?.defaultName == "Kids")
        #expect(rows.first { $0.id == AppleDiscoverRowOrder.services }?.defaultName == "Services")
    }

    @Test func serviceSettingsReuseLibraryClassificationAndKeepOneEntryPerService() {
        let source = UUID()
        let shelves = ["Netflix Movies", "Netflix Series", "Disney Plus Movies", "Mad Max Collection"].enumerated().map {
            AppleMediaServerLibraryStore.Shelf(id: "fixture-\($0.offset)", title: $0.element, sourceID: source, items: [])
        }
        let services = AppleHomeRowSetting.services(shelves: shelves)
        #expect(services.map(\.id) == ["disneyPlus", "netflix"])
        #expect(services.allSatisfy { $0.isService })
    }

    @Test func rowEditorWritesTheSyncedKeysAndResetAllRestoresRowsAndServices() throws {
        let domain = "home-row-editor.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let settings = AppleSettingsStore(defaults: defaults, keychain: HomeRowTestCredentials())
        let row = AppleHomeRowSetting(id: "featuredMovies", defaultName: "Featured Movies")
        let service = AppleHomeRowSetting(id: "netflix", defaultName: "Netflix", isService: true)
        row.setShown(false, in: settings)
        service.setShown(false, in: settings)
        row.setName("  My Picks  ", in: settings)
        service.setName("Weekend", in: settings)
        #expect(settings.homeRowsHidden == [row.id])
        #expect(settings.homeServicesHidden == [service.id])
        #expect(row.title(in: settings) == "My Picks")
        row.setName("\n ", in: settings)
        #expect(settings.homeRowNames[row.id] == nil)
        #expect(row.title(in: settings) == row.defaultName)
        row.setName(row.defaultName, in: settings)
        #expect(settings.homeRowNames[row.id] == nil)
        AppleHomeRowSetting.resetAll(in: settings)
        #expect(settings.homeRowsHidden.isEmpty && settings.homeServicesHidden.isEmpty && settings.homeRowNames.isEmpty)
    }

    @Test func defaultsShowEveryRowWithItsDefaultName() throws {
        let name = "home-row-settings.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppleSettingsStore(defaults: defaults, keychain: HomeRowTestCredentials())
        #expect(settings.homeRowsHidden.isEmpty)
        #expect(settings.homeRowNames.isEmpty)
        #expect(settings.homeServicesHidden.isEmpty)
    }

    @Test func hiddenRowsNamesAndServicesPersistAcrossStoreInstances() throws {
        let name = "home-row-settings.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppleSettingsStore(defaults: defaults, keychain: HomeRowTestCredentials())
        settings.homeRowsHidden = ["continueWatching", "popularMovies"]
        settings.homeRowNames = ["featuredMovies": "My Picks", "services": "Browse"]
        settings.homeServicesHidden = [AppleStreamingService.netflix.rawValue]
        let reread = AppleSettingsStore(defaults: defaults, keychain: HomeRowTestCredentials())
        #expect(reread.homeRowsHidden == settings.homeRowsHidden)
        #expect(reread.homeRowNames == settings.homeRowNames)
        #expect(reread.homeServicesHidden == settings.homeServicesHidden)
    }

    @Test func deletingASourcePrunesOnlyItsRowIDsBeforeSyncCapture() throws {
        let name = "home-row-settings.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let credentials = HomeRowTestCredentials()
        let settings = AppleSettingsStore(defaults: defaults, keychain: credentials)
        let sources = AppleSourceStore(defaults: defaults, keychain: credentials)
        let deleted = AppleSource(kind: .mediaServer, name: "Removed", url: URL(fileURLWithPath: "/fixture/removed"))
        let retained = AppleSource(kind: .mediaServer, name: "Retained", url: URL(fileURLWithPath: "/fixture/retained"))
        try sources.restoreConfigurationSources([deleted, retained], secrets: nil)
        let deletedRow = "server:\(deleted.id.uuidString):library"
        let retainedRow = "server:\(retained.id.uuidString.lowercased()):library"
        settings.homeRowsHidden = [deletedRow, retainedRow, "top10"]
        settings.homeRowNames = [deletedRow: "Old", retainedRow: "Keep", "services": "Browse"]
        settings.homeServicesHidden = ["netflix"]
        #expect(sources.remove(id: deleted.id))
        let index = AppleMediaIndexStore(repository: AppleMediaIndexRepository(fileURL: root.appendingPathComponent("index.json")))
        let controller = AppleConfigurationController(sources: sources, settings: settings, mediaIndex: index, defaults: defaults)
        let snapshot = try controller.setupTransferPayload(sender: "Fixture").snapshot
        #expect(settings.homeRowsHidden == [retainedRow, "top10"])
        #expect(settings.homeRowNames == [retainedRow: "Keep", "services": "Browse"])
        #expect(settings.homeServicesHidden == ["netflix"])
        let reread = AppleSettingsStore(defaults: defaults, keychain: credentials)
        #expect(reread.homeRowsHidden == settings.homeRowsHidden)
        #expect(snapshot.settings == (try settings.configurationValues()))
    }
}

private struct HomeRowTestCredentials: AppleCredentialStoring {
    func string(for account: String) throws -> String? { nil }
    func set(_ value: String, for account: String) throws {}
    func remove(_ account: String) throws {}
}
