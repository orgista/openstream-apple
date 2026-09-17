import Foundation
import Testing
@testable import OpenStreamApple

/// The owner's rules for "where to watch", 2026-09-16. The purchase exclusion
/// in particular is a deliberate product position, not an oversight, so it is
/// pinned here.
@Suite("Where to watch")
struct AppleWatchProviderTests {
    private let netflix = AppleWatchProvider(id: 8, name: "Netflix", offer: .subscription)
    private let prime = AppleWatchProvider(id: 9, name: "Prime Video", offer: .subscription)
    private let tubi = AppleWatchProvider(id: 73, name: "Tubi", offer: .ads)
    private let primeRent = AppleWatchProvider(id: 9, name: "Prime Video", offer: .rent)
    private let appleBuy = AppleWatchProvider(id: 2, name: "Apple TV", offer: .buy)

    // MARK: Never purchase

    /// "not purchase options cause prime does that a lot".
    @Test func rentAndBuyAreNeverOffered() {
        #expect(!AppleWatchProviderOffer.rent.isOffered)
        #expect(!AppleWatchProviderOffer.buy.isOffered)
        let visible = AppleWatchProviderPolicy.visible([primeRent, appleBuy], enabledProviderIDs: [9, 2])
        #expect(visible.isEmpty)
    }

    @Test func subscriptionFreeAndAdsAreOffered() {
        for offer in [AppleWatchProviderOffer.subscription, .free, .ads] {
            #expect(offer.isOffered, "\(offer) should be offered")
        }
    }

    // MARK: Opt-in

    /// Nothing appears until the viewer has added a service. A fresh install
    /// must never advertise a service at somebody.
    @Test func nothingShowsUntilAServiceIsAdded() {
        #expect(AppleWatchProviderPolicy.visible([netflix, tubi], enabledProviderIDs: []).isEmpty)
    }

    /// Only the services they signed into — not everything the catalogue says
    /// the title is on.
    @Test func onlySignedInServicesAreShown() {
        let visible = AppleWatchProviderPolicy.visible([netflix, prime, tubi], enabledProviderIDs: [8])
        #expect(visible.map(\.name) == ["Netflix"])
    }

    // MARK: Saying which it is

    @Test func adsAreNamedRatherThanImplied() {
        #expect(tubi.displayName == "Tubi · Free with ads")
        #expect(netflix.displayName == "Netflix")
    }

    /// A service listed in two buckets shows the better one, so a subscription
    /// is never labelled "free with ads".
    @Test func theBetterOfferWins() {
        let both = [
            AppleWatchProvider(id: 8, name: "Netflix", offer: .ads),
            AppleWatchProvider(id: 8, name: "Netflix", offer: .subscription),
        ]
        let visible = AppleWatchProviderPolicy.visible(both, enabledProviderIDs: [8])
        #expect(visible.count == 1)
        #expect(visible.first?.offer == .subscription)
    }

    // MARK: Staying in the app

    /// "in general prefer to stay in the app" — a local or add-on source keeps
    /// Play, and the service is a quiet "also available on".
    @Test func theAppKeepsPlayWhenItCanPlayIt() {
        #expect(!AppleWatchProviderPolicy.replacesPlay(
            hasLocalOrAddonSource: true, visibleProviders: [netflix]))
    }

    /// "If they are added with no other local option play becomes the option".
    @Test func theServiceBecomesPlayOnlyWhenNothingElseCan() {
        #expect(AppleWatchProviderPolicy.replacesPlay(
            hasLocalOrAddonSource: false, visibleProviders: [netflix]))
    }

    @Test func nothingToPlayAndNoProviderOffersNothing() {
        #expect(!AppleWatchProviderPolicy.replacesPlay(
            hasLocalOrAddonSource: false, visibleProviders: []))
    }

    /// The TMDB bucket names, since the whole filter depends on them.
    @Test func theTMDBKeysAreTheOnesTMDBUses() {
        #expect(AppleWatchProviderOffer.subscription.tmdbKey == "flatrate")
        #expect(AppleWatchProviderOffer.free.tmdbKey == "free")
        #expect(AppleWatchProviderOffer.ads.tmdbKey == "ads")
        #expect(AppleWatchProviderOffer.rent.tmdbKey == "rent")
        #expect(AppleWatchProviderOffer.buy.tmdbKey == "buy")
    }
}

/// The TMDB request itself, with a stubbed loader — no network.
@Suite("Where to watch · TMDB")
struct AppleWatchProviderRequestTests {
    private func response(_ json: String, url: String) -> (Data, URLResponse) {
        (Data(json.utf8), HTTPURLResponse(
            url: URL(string: url)!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }

    // Both populated: a film resolves through `movie_results` and a show
    // through `tv_results`, and the endpoint chosen differs by kind.
    private let find = #"{"movie_results":[{"id":603}],"tv_results":[{"id":1396}]}"#
    private let providers = """
    {"results":{"US":{
      "flatrate":[{"provider_id":8,"provider_name":"Netflix","logo_path":"/n.jpg"}],
      "ads":[{"provider_id":73,"provider_name":"Tubi","logo_path":"/t.jpg"}],
      "rent":[{"provider_id":9,"provider_name":"Prime Video","logo_path":"/p.jpg"}],
      "buy":[{"provider_id":2,"provider_name":"Apple TV","logo_path":"/a.jpg"}]},
      "GB":{"flatrate":[{"provider_id":39,"provider_name":"Now","logo_path":"/now.jpg"}]}}}
    """

    private func client(_ capture: (@Sendable (URLRequest) -> Void)? = nil) -> AppleTMDBClient {
        let find = find, providers = providers
        return AppleTMDBClient { request in
            capture?(request)
            let path = request.url?.path ?? ""
            if path.contains("/find/") {
                return (Data(find.utf8), HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            return (Data(providers.utf8), HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }

    @Test func everyBucketIsDecodedIncludingPurchase() async throws {
        let configuration = try AppleTMDBConfiguration(credential: "k")
        let all = try await client().watchProviders(
            imdbID: "tt0110912", kind: .movie, region: "US", configuration: configuration)
        // Decoded, so the exclusion lives in the policy and can be tested there.
        #expect(all.contains { $0.offer == .rent })
        #expect(all.contains { $0.offer == .buy })
        // …and the policy drops them.
        #expect(AppleWatchProviderPolicy
            .visible(all, enabledProviderIDs: [8, 9, 2, 73])
            .allSatisfy { $0.offer.isOffered })
    }

    /// Availability differs by country; the wrong one is worse than none.
    @Test func theRegionDecidesTheAnswer() async throws {
        let configuration = try AppleTMDBConfiguration(credential: "k")
        let us = try await client().watchProviders(
            imdbID: "tt0110912", kind: .movie, region: "US", configuration: configuration)
        let gb = try await client().watchProviders(
            imdbID: "tt0110912", kind: .movie, region: "GB", configuration: configuration)
        #expect(us.contains { $0.name == "Netflix" })
        #expect(!gb.contains { $0.name == "Netflix" })
        #expect(gb.map(\.name) == ["Now"])
    }

    @Test func anUnknownRegionOffersNothingRatherThanGuessing() async throws {
        let configuration = try AppleTMDBConfiguration(credential: "k")
        let none = try await client().watchProviders(
            imdbID: "tt0110912", kind: .movie, region: "JP", configuration: configuration)
        #expect(none.isEmpty)
    }

    /// The series path is a different endpoint; a show must not be looked up
    /// as a film.
    @Test func aShowUsesTheTVEndpoint() async throws {
        let configuration = try AppleTMDBConfiguration(credential: "k")
        nonisolated(unsafe) var paths: [String] = []
        _ = try? await client({ paths.append($0.url?.path ?? "") }).watchProviders(
            imdbID: "tt0110912", kind: .series, region: "US", configuration: configuration)
        #expect(paths.contains { $0.contains("/tv/") && $0.hasSuffix("/watch/providers") })
    }

    @Test func aMalformedIdentifierIsRejectedBeforeAnyRequest() async {
        let configuration = try? AppleTMDBConfiguration(credential: "k")
        nonisolated(unsafe) var requests = 0
        await #expect(throws: (any Error).self) {
            try await client({ _ in requests += 1 }).watchProviders(
                imdbID: "not-an-id", kind: .movie, region: "US", configuration: configuration!)
        }
        #expect(requests == 0)
    }
}

/// The sentence under a title. It has to stay a quiet line rather than becoming
/// a paragraph, which is the whole point of the feature being "subtle".
@Suite("Also available on")
struct AppleWatchProviderRowTests {
    private func provider(_ name: String, _ offer: AppleWatchProviderOffer = .subscription) -> AppleWatchProvider {
        AppleWatchProvider(id: abs(name.hashValue % 10_000), name: name, offer: offer)
    }

    @Test func oneServiceReadsAsASentence() {
        #expect(AppleWatchProviderRow.sentence(for: [provider("Netflix")])
                == "Also available on Netflix")
    }

    @Test func twoServicesAreJoinedWithAnd() {
        #expect(AppleWatchProviderRow.sentence(for: [provider("Netflix"), provider("Max")])
                == "Also available on Netflix and Max")
    }

    @Test func threeServicesUseCommasThenAnd() {
        let names = [provider("Netflix"), provider("Max"), provider("Hulu")]
        #expect(AppleWatchProviderRow.sentence(for: names)
                == "Also available on Netflix, Max and Hulu")
    }

    /// A title on nine services must not become a paragraph.
    @Test func aLongListIsCapped() {
        let many = ["Netflix", "Max", "Hulu", "Peacock", "Paramount+"].map { provider($0) }
        #expect(AppleWatchProviderRow.sentence(for: many)
                == "Also available on Netflix, Max, Hulu and 2 more")
    }

    /// Ads are still named in the sentence — "free" must never quietly mean
    /// "free with adverts".
    @Test func adsAreNamedInTheSentence() {
        #expect(AppleWatchProviderRow.sentence(for: [provider("Tubi", .ads)])
                == "Also available on Tubi · Free with ads")
    }

    @Test func nothingProducesNoSentence() {
        #expect(AppleWatchProviderRow.sentence(for: []).isEmpty)
    }
}
