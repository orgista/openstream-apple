import Foundation
import Testing
@testable import OpenStreamApple

/// Edge-case tests for AppleChannelVisibilityPolicy and AppleChannelProjection beyond the
/// dedup/scope/24x7/premier-guide coverage in AppleIPTVAndLibraryTests.
private func edgeChannel(
    _ name: String,
    id: String? = nil,
    group: String = "",
    sourceID: AppleSource.ID = UUID()
) -> AppleIPTVChannel {
    let identifier = id ?? name
    return AppleIPTVChannel(
        id: identifier,
        sourceID: sourceID,
        name: name,
        group: group,
        streamURL: URL(string: "https://fixture.example/\(identifier)")!
    )
}

@Test func matchingChannelsTreatsAWhitespaceOnlyQueryAsEmptyButStillSortsResults() {
    let channels = [
        edgeChannel("Zulu Sports", id: "zulu"),
        edgeChannel("Alpha News", id: "alpha"),
    ]
    #expect(AppleChannelProjection.matchingChannels(from: channels, query: "   ").map(\.id) == ["alpha", "zulu"])
    #expect(AppleChannelProjection.matchingChannels(from: channels, query: "").map(\.id) == ["alpha", "zulu"])
}

@Test func matchingChannelsSearchIsCaseInsensitiveButNotDiacriticInsensitive() {
    let channels = [
        edgeChannel("Café Deportes", id: "accented", group: "Sports"),
        edgeChannel("Cafeteria News", id: "plain", group: "News"),
    ]
    // Same accented letters, different case: matches.
    #expect(AppleChannelProjection.matchingChannels(from: channels, query: "CAFÉ").map(\.id) == ["accented"])
    // Unaccented query: only matches the unaccented name, not the accented one.
    #expect(AppleChannelProjection.matchingChannels(from: channels, query: "cafe").map(\.id) == ["plain"])
}

@Test func matchingChannelsMatchesOnGroupWhenTheNameDoesNotContainTheQuery() {
    let channel = edgeChannel("Channel A", id: "a", group: "Regional Sports Network")
    let other = edgeChannel("Channel B", id: "b", group: "News")
    #expect(AppleChannelProjection.matchingChannels(from: [channel, other], query: "regional sports").map(\.id) == ["a"])
}

@Test func matchingChannelsShow24x7ParameterHasNoEffect() {
    // Suspected bug: matchingChannels declares a show24x7 parameter but never reads it in
    // its body, and no call site in AppleIPTV.swift forwards a value into it (groupedChannels
    // relies entirely on AppleChannelVisibilityPolicy.visibleChannels for that filter).
    let filler = edgeChannel("24/7 Filler", id: "filler", group: "Movies")
    let withFlagTrue = AppleChannelProjection.matchingChannels(from: [filler], query: "", show24x7: true)
    let withFlagFalse = AppleChannelProjection.matchingChannels(from: [filler], query: "", show24x7: false)
    #expect(withFlagTrue.map(\.id) == withFlagFalse.map(\.id))
}

@Test func groupedChannelsInFavoritesScopeSortsAlphabeticallyRegardlessOfFavoriteInsertionOrder() {
    let sourceID = UUID()
    let zulu = edgeChannel("Zulu Sports", id: "zulu", group: "Channel Group A", sourceID: sourceID)
    let alpha = edgeChannel("Alpha News", id: "alpha", group: "Channel Group A", sourceID: sourceID)

    let groups = AppleChannelProjection.groupedChannels(
        from: [zulu, alpha],
        scope: .favorites,
        showPayPerView: true,
        favoriteIDs: ["zulu", "alpha"],
        query: ""
    )

    #expect(groups.map(\.name) == ["Channel Group A"])
    #expect(groups.first?.channels.map(\.id) == ["alpha", "zulu"])
}

@Test func favoritingAChannelDoesNotBypassThe24x7OrPayPerViewFilters() {
    let sourceID = UUID()
    let filler = edgeChannel("24/7 Filler", id: "filler", group: "Movies", sourceID: sourceID)
    let ppv = edgeChannel("PPV Main Event", id: "ppv", group: "Pay Per View", sourceID: sourceID)
    let favorites: Set<String> = ["filler", "ppv"]

    #expect(AppleChannelVisibilityPolicy.visibleChannels(
        from: [filler, ppv],
        scope: .favorites,
        showPayPerView: false,
        favoriteIDs: favorites
    ).isEmpty == true)

    #expect(AppleChannelVisibilityPolicy.visibleChannels(
        from: [filler, ppv],
        scope: .favorites,
        showPayPerView: true,
        favoriteIDs: favorites,
        show24x7: true
    ).map(\.id).sorted() == ["filler", "ppv"])
}

@Test func visibleChannelsAcceptsARegionalZIPCodeButNeverExcludesRegionalChannels() {
    // Suspected bug: regionalZIPCode is threaded from AppleSettingsStore through
    // groupedChannels into visibleChannels, but visibleChannels's filter closure never reads
    // it — AppleChannelVisibilityPolicy.isRegional(_:zipCode:) is never consulted here, so a
    // channel the policy itself calls regional for that ZIP still passes through.
    let regional = edgeChannel("Local News 90210", id: "regional", group: "Broadcast")

    #expect(AppleChannelVisibilityPolicy.isRegional(regional, zipCode: "90210") == true)
    #expect(AppleChannelVisibilityPolicy.visibleChannels(
        from: [regional],
        scope: .providerLineup,
        showPayPerView: true,
        favoriteIDs: [],
        regionalZIPCode: "90210"
    ).map(\.id) == ["regional"])
}

@Test func groupedChannelsOmitsGroupsThatBecomeEmptyAfterFiltering() {
    let sourceID = UUID()
    let ppvOnly = edgeChannel("PPV Only", id: "ppv-only", group: "Pay Per View", sourceID: sourceID)
    let news = edgeChannel("Local News", id: "news", group: "News", sourceID: sourceID)

    let groups = AppleChannelProjection.groupedChannels(
        from: [ppvOnly, news],
        scope: .providerLineup,
        showPayPerView: false,
        favoriteIDs: [],
        query: ""
    )

    #expect(groups.map(\.name) == ["News"])
}
