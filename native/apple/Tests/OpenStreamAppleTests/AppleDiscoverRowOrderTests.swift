import Foundation
import Testing
@testable import OpenStreamApple

@Suite("Discover row order")
struct AppleDiscoverRowOrderTests {
    @Test func builtInNamesDescribeTheMediaAndCombinedChart() {
        #expect(AppleDiscoverRowOrder.title(forBuiltIn: "featuredMovies") == "Featured Movies")
        #expect(AppleDiscoverRowOrder.title(forBuiltIn: "featuredShows") == "Featured Shows")
        #expect(AppleDiscoverRowOrder.title(forBuiltIn: "top10") == "Top 10 This Week")
    }

    @Test func recentlyAddedUsesTheDesignMinimumAndBecauseWatchedUsesThePolicy() {
        #expect(AppleDiscoverRowOrder.rows([row("recentlyAdded", keys: (0..<5).map(String.init))]).isEmpty)
        #expect(AppleDiscoverRowOrder.rows([row("recentlyAdded", keys: (0..<6).map(String.init))]).count == 1)
        let minimum = AppleRecommendationRowPolicy.minimumItems
        #expect(AppleDiscoverRowOrder.rows([row("becauseWatched", keys: (0..<(minimum - 1)).map(String.init))]).isEmpty)
        #expect(AppleDiscoverRowOrder.rows([row("becauseWatched", keys: (0..<minimum).map(String.init))]).count == 1)
    }

    private func row(_ id: String, keys: [String]? = nil, loading: Bool = false) -> AppleDiscoverRowOrder.Row {
        .init(id: id, keys: keys ?? (0..<30).map { "\(id)-\($0)" }, isLoading: loading)
    }

    @Test func rowsFollowHomeOrderWithThreeServerRowsAndTwelveRowsOverall() {
        let builtIns = ["continueWatching", "services", "top10", "featuredMovies", "recentlyAdded",
                        "featuredShows", "becauseWatched", "popularMovies", "popularShows"]
        let servers = (0..<20).map { "server:fixture:\($0)" }
        let rows = AppleDiscoverRowOrder.rows((Array(builtIns.reversed()) + servers).map { row($0) })
        #expect(rows.map(\.id) == builtIns + Array(servers.prefix(3)))
        #expect(rows.map { $0.keys.count } == [20, 30, 10, 30, 30, 30, 30, 30, 30, 30, 30, 30])
    }

    @Test func servicesKeepEveryButton() {
        let keys = AppleStreamingService.allCases.map { "service:" + $0.rawValue }
        let rows = AppleDiscoverRowOrder.rows([row("services", keys: keys)])
        #expect(rows.first?.keys == keys)
    }

    @Test func hiddenAndSparseServerRowsDoNotUseTheThreeSlots() {
        let rows = AppleDiscoverRowOrder.rows([
            row("server:fixture:hidden"), row("server:fixture:sparse", keys: ["one"]),
            row("server:fixture:a"), row("server:fixture:b"), row("server:fixture:c"), row("server:fixture:d"),
        ], hidden: ["server:fixture:hidden"])
        #expect(rows.map(\.id) == ["server:fixture:a", "server:fixture:b", "server:fixture:c"])
    }

    @Test func hiddenRowsClaimNothingIncludingPendingRows() {
        let keys = (0..<8).map { "shared-\($0)" }
        let rows = AppleDiscoverRowOrder.rows([
            row("featuredMovies", keys: keys), row("popularMovies", keys: keys),
            row("server:fixture:pending", keys: keys, loading: true),
        ], hidden: ["featuredMovies", "server:fixture:pending"])
        #expect(rows.map(\.id) == ["popularMovies"])
        #expect(rows.first?.keys == keys)
    }

    @Test func topTenKeepsAllRanksAndClaimsTitlesForLaterRows() {
        let chart = (0..<10).map { "chart-\($0)" }
        let later = chart + (0..<8).map { "other-\($0)" }
        let rows = AppleDiscoverRowOrder.rows([
            row("continueWatching", keys: [chart[0]]), row("top10", keys: chart), row("popularMovies", keys: later),
        ])
        #expect(rows.map(\.keys) == [[chart[0]], chart, Array(later.suffix(8))])
    }

    @Test func sparseRowsAfterDedupeClaimNothing() {
        let keys = (0..<6).map { "shared-\($0)" }
        let rows = AppleDiscoverRowOrder.rows([
            row("continueWatching", keys: [keys[0]]), row("recentlyAdded", keys: keys),
            row("popularMovies", keys: keys + ["extra"]),
        ])
        #expect(rows.map(\.id) == ["continueWatching", "popularMovies"])
        #expect(rows.last?.keys == Array(keys.dropFirst()) + ["extra"])
    }

    @Test func onlyDisplayedItemsClaimAndEachRowIsUnique() {
        let keys = (0..<40).map { "title-\($0)" }
        let rows = AppleDiscoverRowOrder.rows([
            row("recentlyAdded", keys: keys + keys), row("popularMovies", keys: keys),
        ])
        #expect(rows.map(\.keys) == [Array(keys.prefix(30)), Array(keys.suffix(10))])
    }

    @Test(arguments: [false, true])
    func aMissingRecentRowSeparatesFeaturedRowsBeforeClaiming(hidden: Bool) {
        let shared = (0..<6).map { "shared-\($0)" }
        let rows = AppleDiscoverRowOrder.rows([
            row("featuredMovies"), row("recentlyAdded", keys: ["sparse"]),
            row("featuredShows", keys: shared + (0..<6).map { "show-\($0)" }),
            row("popularShows", keys: shared),
        ], hidden: hidden ? ["recentlyAdded"] : [])
        #expect(rows.map(\.id) == ["featuredMovies", "popularShows", "featuredShows"])
        #expect(rows.last?.keys == (0..<6).map { "show-\($0)" })
    }

    @Test func featuredRowsAreNeverAdjacentWhenNoSeparatorSurvives() {
        let rows = AppleDiscoverRowOrder.rows([row("featuredMovies"), row("featuredShows")])
        #expect(rows.map(\.id) == ["featuredMovies"])
    }

    @Test(arguments: ["recentlyAdded", "server:fixture:loading"])
    func loadingRowsKeepExistingItemsWithoutClaimingSparseItems(id: String) {
        let rows = AppleDiscoverRowOrder.rows([
            row(id, keys: ["shared"], loading: true),
            row("server:fixture:loaded", keys: ["shared"] + (0..<5).map { "other-\($0)" }),
        ])
        #expect(rows.map(\.id) == [id, "server:fixture:loaded"])
        #expect(rows.first?.keys == ["shared"])
        #expect(rows.last?.keys.first == "shared")
    }

    @Test func customNamesOverrideBuiltInAndCleanedNames() {
        let names = ["featuredMovies": "My Picks", "server:fixture:one": "Family", "recentlyAdded": " \n "]
        #expect(AppleDiscoverRowOrder.title(for: "featuredMovies", customNames: names) == "My Picks")
        #expect(AppleDiscoverRowOrder.title(for: "server:fixture:one", defaultTitle: "Kids Movies", customNames: names) == "Family")
        #expect(AppleDiscoverRowOrder.title(for: "recentlyAdded", customNames: names) == "Recently Added")
        #expect(AppleDiscoverRowOrder.title(for: "services", customNames: ["services": ""]) == "Services")
    }

    @MainActor @Test func savedOrdersAreRemovedAndCannotReturnThroughBackupRestore() throws {
        let name = "discover-row-order-tests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let key = "openstream.settings.discover.rowOrder.v1"
        defaults.set(["featuredMovies", "library"], forKey: key)
        let settings = AppleSettingsStore(defaults: defaults, keychain: RowOrderTestCredentials())
        #expect(defaults.object(forKey: key) == nil)
        #expect(AppleSettingsStore.configurationKeys.contains(key) == false)
        let oldBackup = try PropertyListSerialization.data(fromPropertyList: [["featuredMovies", "library"]], format: .binary, options: 0)
        try settings.restoreConfiguration([key: oldBackup])
        #expect(defaults.object(forKey: key) == nil)
        #expect(try settings.configurationValues()[key] == nil)
    }
}

private final class RowOrderTestCredentials: AppleCredentialStoring {
    func string(for account: String) throws -> String? { nil }
    func set(_ value: String, for account: String) throws {}
    func remove(_ account: String) throws {}
}
