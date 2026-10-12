import Foundation
import Testing
@testable import OpenStreamApple

/// Owner, 2026-09-24: every tab's toolbar the same (Search, then Refresh), no
/// Sort on Library, and Library's posters from Discover's artwork lookup.
@Suite("Tab toolbar and shared artwork lookup")
struct AppleTabToolbarAndArtworkTests {
    @Test func discoverAndLibraryCarryTheSameItemsInTheSameOrder() {
        #expect(AppleTabToolbarPolicy.items(for: .home, isTV: false) == [.search, .refresh])
        #expect(AppleTabToolbarPolicy.items(for: .library, isTV: false) == [.search, .refresh])
        #expect(AppleTabToolbarPolicy.items(for: .home, isTV: false) == AppleTabToolbarPolicy.items(for: .library, isTV: false))
    }

    @Test(arguments: [OpenStreamTab.home, .library])
    func titlePagesKeepSearchAndLeaveRefreshAtTheRoot(tab: OpenStreamTab) {
        #expect(AppleTabToolbarPolicy.items(for: tab, isTV: false, isTitlePage: true) == [.search])
        #expect(AppleTabToolbarPolicy.items(for: tab, isTV: true, isTitlePage: true).isEmpty)
    }

    @Test func libraryHasNoSortControl() {
        #expect(AppleTabToolbarPolicy.Item.allCases.map(\.rawValue) == ["search", "refresh"])
    }

    @Test(arguments: OpenStreamTab.allCases)
    func appleTVDrawsNoToolbarItems(tab: OpenStreamTab) {
        #expect(AppleTabToolbarPolicy.items(for: tab, isTV: true).isEmpty)
    }

    @Test func otherTabsKeepTheirOwnToolbars() {
        for tab in [OpenStreamTab.search, .live, .settings] {
            #expect(AppleTabToolbarPolicy.items(for: tab, isTV: false).isEmpty)
        }
    }

    @Test func refreshKeepsOneIdentityWhileLoadingOffTheMac() {
        let idle = AppleTabToolbarPolicy.slotID(scope: "tab", item: .refresh, isRefreshing: false, rekeysBusyItem: false)
        let busy = AppleTabToolbarPolicy.slotID(scope: "tab", item: .refresh, isRefreshing: true, rekeysBusyItem: false)
        #expect(idle == busy)
    }

    @Test func macRekeysOnlyTheBusyRefreshItem() {
        #expect(AppleTabToolbarPolicy.slotID(scope: "tab", item: .refresh, isRefreshing: true, rekeysBusyItem: true) == "tab.refresh.busy")
        #expect(AppleTabToolbarPolicy.slotID(scope: "tab", item: .refresh, isRefreshing: false, rekeysBusyItem: true) == "tab.refresh")
        #expect(AppleTabToolbarPolicy.slotID(scope: "tab", item: .search, isRefreshing: true, rekeysBusyItem: true) == "tab.search")
    }

    @MainActor
    @Test func libraryAndDiscoverShareOneTMDBConfiguration() {
        let name = "openstream.tests.artwork.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppleSettingsStore(defaults: defaults, keychain: NoCredentials())
        settings.metadataEnabled = true
        settings.tmdbAPIKey = ""
        #expect(settings.tmdbConfiguration == nil)
        settings.tmdbAPIKey = "fixture-key"
        #expect(settings.tmdbConfiguration != nil)
        settings.metadataEnabled = false
        #expect(settings.tmdbConfiguration == nil)
    }
}

/// Never the keychain (see `AppleSettingsStoreTests`).
private struct NoCredentials: AppleCredentialStoring {
    func string(for account: String) throws -> String? { nil }
    func set(_ value: String, for account: String) throws {}
    func remove(_ account: String) throws {}
}

@Suite("Catalog card artwork retry")
struct AppleCatalogArtworkRetryTests {
    @Test func aFailedCardTriesTwiceMoreThenStops() {
        #expect(AppleCatalogArtworkPolicy.retryDelay(afterRetries: 0) == .seconds(3))
        #expect(AppleCatalogArtworkPolicy.retryDelay(afterRetries: 1) == .seconds(10))
        #expect(AppleCatalogArtworkPolicy.retryDelay(afterRetries: 2) == nil)
    }

    @Test func libraryAndDiscoverCardsTryTheSameCandidates() {
        // One policy for both screens: a Library tile and a Your Library tile
        // for the same title ask for the same art in the same order.
        let item = AppleCatalogItem(mediaID: "tt0000001", type: "movie", name: "Fixture",
                                    posterURL: URL(string: "https://fixture.example/poster.jpg"))
        let candidates = AppleCatalogArtworkPolicy.candidates(item: item, landscape: false)
        #expect(candidates.first == URL(string: "https://fixture.example/poster.jpg"))
        #expect(candidates.count == 3)
        #expect(AppleCatalogArtworkPolicy.next(in: candidates, failed: Set(candidates)) == nil)
    }
}
