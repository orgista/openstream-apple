import Foundation
import Testing
@testable import OpenStreamApple

/// When Discover Rows re-reads the catalogue shelves from the cache.
@Suite("Discover Rows catalogue reload")
struct AppleDiscoverRowsCatalogPolicyTests {
    private func source(_ name: String) -> AppleSource {
        AppleSource(kind: .stremio, name: name,
                    url: URL(string: "https://\(name.lowercased()).fixture.example/manifest.json")!,
                    resources: ["catalog"],
                    catalogs: [AppleStremioCatalog(type: "movie", id: "top")])
    }

    private func section(_ source: AppleSource) -> AppleCatalogSection {
        AppleCatalogSection(source: source, catalog: AppleStremioCatalog(type: "movie", id: "top"), items: [])
    }

    @Test("Nothing loaded: read the cache")
    func emptyLoads() {
        #expect(AppleDiscoverRowsCatalogPolicy.needsCachedLoad(sections: [], sources: [source("One")]))
    }

    @Test("Shelves that match the sources are kept")
    func matchingKeeps() {
        let one = source("One")
        #expect(!AppleDiscoverRowsCatalogPolicy.needsCachedLoad(sections: [section(one)], sources: [one]))
    }

    @Test("A source added since Discover loaded: read the cache")
    func addedSourceLoads() {
        let one = source("One"), two = source("Two")
        #expect(AppleDiscoverRowsCatalogPolicy.needsCachedLoad(sections: [section(one)], sources: [one, two]))
    }

    @Test("A source removed since Discover loaded: read the cache")
    func removedSourceLoads() {
        let one = source("One"), two = source("Two")
        #expect(AppleDiscoverRowsCatalogPolicy.needsCachedLoad(sections: [section(one), section(two)], sources: [one]))
    }

    @Test("A source without catalogues never forces a reload")
    func catalogueLessSourceIgnored() {
        let one = source("One")
        let plain = AppleSource(kind: .stremio, name: "Streams",
                                url: URL(string: "https://streams.fixture.example/manifest.json")!)
        #expect(!AppleDiscoverRowsCatalogPolicy.needsCachedLoad(sections: [section(one)], sources: [one, plain]))
    }
}
