import Foundation
import Testing
@testable import OpenStreamApple

@MainActor @Suite("Discover prepared rail cache")
struct AppleDiscoverRailCacheTests {
    private typealias Cache = AppleDiscoverRailCache<[String]>

    @Test func geometryAndRepeatedArtworkReadsReuseThePreparedRails() {
        let cache = Cache()
        let key = Cache.Key()
        var builds = 0
        let first = cache.value(for: key) { builds += 1; return ["first"] }
        let second = cache.value(for: key) { builds += 1; return ["unexpected"] }
        #expect(first == second)
        #expect(builds == 1)
    }

    @Test func sameIdentityPublicationsReplaceOldMetadataAndLoadingPayloads() {
        let cache = Cache()
        var key = Cache.Key()
        #expect(cache.value(for: key) { ["loading"] } == ["loading"])
        key.serverRowsPublication += 1
        #expect(cache.value(for: key) { ["title with refreshed art"] } == ["title with refreshed art"])
        key.recommendationsPublication += 1
        #expect(cache.value(for: key) { ["resume episode updated"] } == ["resume episode updated"])
        key.chartPublication += 1
        #expect(cache.value(for: key) { ["updated ranks"] } == ["updated ranks"])
    }

    @Test func sourceRoleOrderAndPresentationChangesInvalidateTheRows() {
        let initial = Cache.Key()
        let source = AppleSource(kind: .library, name: "Fixture", url: URL(fileURLWithPath: "/fixture"))
        var keys: [Cache.Key] = []
        var key = initial; key.sources = [source]; keys.append(key)
        key = initial; key.libraryRevision = 1; keys.append(key)
        key = initial; key.servicesRevision = 1; keys.append(key)
        key = initial; key.order = [.becauseWatched(1)]; keys.append(key)
        key = initial; key.hiddenRows = ["top10"]; keys.append(key)
        key = initial; key.rowNames = ["top10": "Weekly"]; keys.append(key)
        key = initial; key.hiddenServices = ["fixture"]; keys.append(key)
        key = initial; key.top10Enabled = true; keys.append(key)
        key = initial; key.top10Available = true; keys.append(key)
        for changed in keys {
            let cache = Cache()
            _ = cache.value(for: initial) { ["old"] }
            #expect(cache.value(for: changed) { ["new"] } == ["new"])
        }
    }
}
