import Foundation
import Testing
@testable import OpenStreamApple

/// Owner recording 2026-11-04: a big Movies poster changed under the viewer
/// ("Inception just switched to Holes") when a server reloaded its shelves.
struct AppleDiscoverFeaturedStabilityTests {
    private typealias Result = AppleDiscoverView.RecommendationResult
    private typealias Pass = AppleDiscoverView.FeaturedPass
    private let server = AppleSource(kind: .mediaServer, name: "Server", url: URL(string: "https://server.example")!)

    private func value(_ name: String, year: Int, source: AppleSource? = nil) -> AppleDiscoverView.IndexedCatalogItem {
        let source = source ?? server
        let item = AppleCatalogItem(mediaID: AppleMediaServerItemReference(sourceID: source.id, itemID: name).mediaID,
            type: "movie", name: name, year: year)
        return .init(record: AppleMediaIngestion.catalogRecord(instanceID: source.id, item: item), item: item, source: source)
    }

    /// One pass's Movies row, with every eligible title it had.
    private func pass(_ row: [AppleDiscoverView.IndexedCatalogItem],
                      alsoEligible: [AppleDiscoverView.IndexedCatalogItem] = []) -> Result {
        var result = Result()
        result.featuredMovies = row
        result.featuredIdentities = Set((row + alsoEligible).map { AppleCatalogShelfPolicy.identity($0.item) })
        return result
    }

    @Test func shownTitlesKeepTheirPlacesWhenARecomputeRanksOthersHigher() {
        let inception = value("Inception", year: 2010)
        let arrival = value("Arrival", year: 2016)
        let holes = value("Holes", year: 2003)
        // The reload dropped Inception's shelf and ranked Holes first.
        let row = AppleDiscoverView.sessionStableFeatured(shown: [inception, arrival], incoming: [holes, arrival],
                                                          sources: [server])
        #expect(row.map(\.item.name) == ["Inception", "Arrival", "Holes"])
    }

    @Test func aTitleLeavesWhenItsSourceIsTurnedOff() {
        var off = AppleSource(kind: .mediaServer, name: "Off", url: URL(string: "https://off.example")!)
        off.isEnabled = false
        let gone = value("Heat", year: 1995, source: off)
        let kept = value("Arrival", year: 2016)
        let row = AppleDiscoverView.sessionStableFeatured(shown: [gone, kept], incoming: [], sources: [server, off])
        #expect(row.map(\.item.name) == ["Arrival"])
    }

    @Test func newTitlesOnlyFillFreePlacesUpToTheLimit() {
        let shown = (0..<AppleDiscoverView.featuredLimit).map { value("Shown \($0)", year: 2000 + $0) }
        let row = AppleDiscoverView.sessionStableFeatured(shown: shown, incoming: [value("Newcomer", year: 2024)],
                                                          sources: [server])
        #expect(row.map(\.item.name) == shown.map(\.item.name))
    }

    /// The sequence the owner's trace had: shelves in, a reload down to one
    /// shelf, then a settled pass after a title was deleted.
    @Test func thePinHoldsThroughAReloadAndDropsATitleASettledPassNoLongerHas() {
        let inception = value("Inception", year: 2010)
        let arrival = value("Arrival", year: 2016)
        let holes = value("Holes", year: 2003)
        let heat = value("Heat", year: 1995)
        var pin = AppleDiscoverView.FeaturedPin()
        var shown = Result()

        var first = pass([inception, arrival])
        pin.apply(shown: shown, to: &first, scope: "a", sources: [server],
                  pass: Pass(hasServerShelves: true, isSettled: false))
        shown = first
        #expect(shown.featuredMovies.map(\.item.name) == ["Inception", "Arrival"])

        // Mid-reload: Inception's shelf is missing, but nothing leaves.
        var reload = pass([holes, arrival])
        pin.apply(shown: shown, to: &reload, scope: "a", sources: [server],
                  pass: Pass(hasServerShelves: true, isSettled: false))
        shown = reload
        #expect(shown.featuredMovies.map(\.item.name) == ["Inception", "Arrival", "Holes"])

        // Settled: Inception was deleted; Arrival ranks lower but is still there.
        var settled = pass([holes, heat], alsoEligible: [arrival])
        pin.apply(shown: shown, to: &settled, scope: "a", sources: [server],
                  pass: Pass(hasServerShelves: true, isSettled: true))
        #expect(settled.featuredMovies.map(\.item.name) == ["Arrival", "Holes", "Heat"])
    }

    @Test func aPartialPassPinsNothingSoTheFirstPassWithShelvesReplacesIt() {
        let library = value("Library Pick", year: 1999)
        let inception = value("Inception", year: 2010)
        var pin = AppleDiscoverView.FeaturedPin()
        var partial = pass([library])
        pin.apply(shown: Result(), to: &partial, scope: "a", sources: [server],
                  pass: Pass(hasServerShelves: false, isSettled: false))
        #expect(pin.scope == nil)
        var full = pass([inception])
        pin.apply(shown: partial, to: &full, scope: "a", sources: [server],
                  pass: Pass(hasServerShelves: true, isSettled: false))
        #expect(full.featuredMovies.map(\.item.name) == ["Inception"])
        #expect(pin.scope == "a")
    }

    /// A profile, source or metadata change is a new scope: the row starts over.
    @Test func aNewScopeStartsTheRowOver() {
        let oldProfile = value("Old Profile Pick", year: 2001)
        let newProfile = value("New Profile Pick", year: 2002)
        var pin = AppleDiscoverView.FeaturedPin(scope: "profile-a")
        var next = pass([newProfile])
        pin.apply(shown: pass([oldProfile]), to: &next, scope: "profile-b", sources: [server],
                  pass: Pass(hasServerShelves: true, isSettled: false))
        #expect(next.featuredMovies.map(\.item.name) == ["New Profile Pick"])
        #expect(pin.scope == "profile-b")
    }

    @Test func aPassHasTheServerShelvesWhenEveryEnabledServerListedSomeOrLoadingEnded() {
        let other = AppleSource(kind: .mediaServer, name: "Other", url: URL(string: "https://other.example")!)
        let shelf = AppleMediaServerLibraryStore.Shelf(id: "latest", title: "Latest", sourceID: server.id, items: [])
        let oneOfTwo = Pass(sources: [server, other], serverShelves: [shelf], serverIsLoading: true)
        #expect(!oneOfTwo.hasServerShelves && !oneOfTwo.isSettled)
        #expect(Pass(sources: [server], serverShelves: [shelf], serverIsLoading: true) == Pass(hasServerShelves: true, isSettled: false))
        #expect(Pass(sources: [server, other], serverShelves: [], serverIsLoading: false) == Pass(hasServerShelves: true, isSettled: true))
    }
}

/// The big Featured card is a 2:3 tile: a failed poster falls to the title
/// card, not to a 16:9 backdrop cropped to a third of its width.
@Test func featuredCardFallsToTheTitleCardWhenItsPosterFails() {
    let poster = URL(string: "https://image.tmdb.org/t/p/w780/poster.jpg")!
    let backdrop = URL(string: "https://image.tmdb.org/t/p/w1280/backdrop.jpg")!
    let item = AppleCatalogItem(mediaID: "tt0137523", type: "movie", name: "Fight Club",
                                posterURL: poster, backgroundURL: backdrop)
    #expect(AppleCatalogCard.resolvedPosterURL(item: item, sizing: .portraitPromo) == poster)
    #expect(AppleCatalogCard.resolvedPosterURL(item: item, sizing: .portraitPromo, failedArtworkURLs: [poster]) == nil)
    let lookedUp = URL(string: "https://image.tmdb.org/t/p/w780/other.jpg")!
    #expect(AppleCatalogCard.resolvedPosterURL(item: item, sizing: .portraitPromo,
        fallbackArtwork: .init(posterURL: lookedUp, backgroundURL: backdrop), failedArtworkURLs: [poster]) == lookedUp)
    // Smaller poster cards keep the backdrop as their last resort.
    #expect(AppleCatalogCard.resolvedPosterURL(item: item, sizing: .catalog, failedArtworkURLs: [poster]) == backdrop)
}
