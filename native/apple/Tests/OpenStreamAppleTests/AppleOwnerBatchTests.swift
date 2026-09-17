import Foundation
import Testing
@testable import OpenStreamApple

@Test func regionalFilteringRequiresAValidZIPAndUsesLocalLineupMatches() {
    let sourceID = UUID()
    let local = AppleIPTVChannel(
        id: "local",
        sourceID: sourceID,
        name: "WGN-TV",
        group: "Local",
        streamURL: URL(string: "https://tv.example/wgn.m3u8")!
    )
    let merelyRegional = AppleIPTVChannel(
        id: "regional",
        sourceID: sourceID,
        name: "Regional Sports",
        group: "Sports",
        streamURL: URL(string: "https://tv.example/rsn.m3u8")!
    )

    #expect(!AppleZIPCodePolicy.isValid("6061"))
    #expect(AppleZIPCodePolicy.normalize(" 60614 ") == "60614")
    #expect(AppleChannelVisibilityPolicy.isRegional(local, zipCode: "60614"))
    #expect(!AppleChannelVisibilityPolicy.isRegional(merelyRegional, zipCode: "60614"))
    #expect(AppleChannelProjection.groupedChannels(from: [local, merelyRegional], scope: .regional,
        showPayPerView: true, favoriteIDs: [], query: "", regionalZIPCode: "60614")
        .flatMap(\.channels).map(\.id) == ["local"])
}

@Test func catalogShelvesSplitProviderNamesByMediaType() {
    #expect(appleCatalogShelfTitle(sourceName: "Netflix", catalogType: "series") == "Netflix Shows")
    #expect(appleCatalogShelfTitle(sourceName: "Netflix", catalogType: "movie") == "Netflix Movies")
    #expect(appleCatalogShelfTitle(sourceName: "Featured", catalogType: "movie") != appleCatalogShelfTitle(sourceName: "Featured", catalogType: "series"))
    #expect(appleCatalogShelfTitle(sourceName: "Prime Video", catalogType: "other") == "Prime Video")
    #expect(appleCatalogShelfTitle(sourceName: "Cinemeta", catalogType: "movie", catalogName: "Popular") == "Popular Movies")
    #expect(appleCatalogShelfTitle(sourceName: "Cinemeta", catalogType: "series", catalogName: "Popular") == "Popular Shows")
    #expect(appleCatalogShelfTitle(sourceName: "Cinemeta", catalogType: "movie", catalogName: "Top") == "Popular Movies")
    #expect(appleCatalogShelfTitle(sourceName: "Cinemeta", catalogType: "series", catalogName: "Top") == "Popular Shows")
}

@Test func titleRatingsPersistAllThreeStates() {
    let defaults = UserDefaults(suiteName: "openstream-rating-\(UUID().uuidString)")!
    let store = AppleTitleRatingStore(defaults: defaults)
    for value in AppleTitleRating.selectableCases {
        store.set(value, for: "tt1234567")
        #expect(store.rating(for: "tt1234567") == value)
    }
    store.set(nil, for: "tt1234567")
    #expect(store.rating(for: "tt1234567") == nil)
}

@Test func userFacingCopyContainsNoRemovedServiceOrProtocolBranding() throws {
    let sourceDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/OpenStreamApple")
    let files = [
        "AppleStremioStreamingServer.swift",
        "AppleSettingsViews.swift",
        "OpenStreamRootView.swift",
        "AppleSourcesSettingsView.swift",
        "AppleSourceStore.swift",
    ]
    let uiMarkers = ["Text(\"", "Label(\"", "Section(\"", "navigationTitle(\"", "success(\""]
    let forbidden = ["stremio", "torrentio", "torrent", "magnet"]
    for file in files {
        let contents = try String(contentsOf: sourceDirectory.appendingPathComponent(file), encoding: .utf8)
        for line in contents.split(separator: "\n") where uiMarkers.contains(where: line.contains) {
            let lowercased = line.lowercased()
            #expect(forbidden.allSatisfy { !lowercased.contains($0) }, "Forbidden user-facing copy in \(file): \(line)")
        }
    }
}

@Test func shelfTitlesCollapseProviderWhitespace() {
    #expect(appleCatalogShelfTitle(sourceName: "Streaming Catalogs", catalogType: "movie", catalogName: "Prime  Video") == "Prime Movies")
    #expect(appleCatalogShelfTitle(sourceName: "Streaming Catalogs", catalogType: "series", catalogName: " Prime\u{00a0} Video Catalog ") == "Prime Shows")
    #expect(appleCatalogShelfTitle(sourceName: " Prime\tVideo ", catalogType: "movie") == "Prime Video Movies")
}
