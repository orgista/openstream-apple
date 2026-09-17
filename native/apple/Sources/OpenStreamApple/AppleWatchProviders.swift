import Foundation

/// How a title is available on a service.
///
/// TMDB splits its `watch/providers` response into exactly these buckets, which
/// is why the owner's rule — "subscription and free-with-ads only, never
/// purchase" — is a filter here rather than a guess.
public enum AppleWatchProviderOffer: String, Sendable, CaseIterable {
    /// Included with a subscription.
    case subscription
    /// Free, no advertising.
    case free
    /// Free, with advertising.
    case ads
    /// Rental. Never offered.
    case rent
    /// Purchase. Never offered.
    case buy

    /// TMDB's own key for each bucket.
    var tmdbKey: String {
        switch self {
        case .subscription: "flatrate"
        case .free: "free"
        case .ads: "ads"
        case .rent: "rent"
        case .buy: "buy"
        }
    }

    /// Whether OpenStream will ever surface this.
    ///
    /// Rent and buy are excluded by policy, not by omission: the owner asked
    /// for it explicitly ("not purchase options cause prime does that a lot"),
    /// and it is the one thing the aggregators cannot do, because rental
    /// affiliate revenue is their business model.
    public var isOffered: Bool {
        switch self {
        case .subscription, .free, .ads: true
        case .rent, .buy: false
        }
    }

    /// Said plainly, so "free" never quietly means "free with adverts".
    public var label: String? {
        switch self {
        case .subscription: nil
        case .free: "Free"
        case .ads: "Free with ads"
        case .rent, .buy: nil
        }
    }
}

/// One way to watch a title.
public struct AppleWatchProvider: Equatable, Sendable, Identifiable {
    public let id: Int
    public let name: String
    public let offer: AppleWatchProviderOffer
    public let logoPath: String?

    public init(id: Int, name: String, offer: AppleWatchProviderOffer, logoPath: String? = nil) {
        self.id = id
        self.name = name
        self.offer = offer
        self.logoPath = logoPath
    }

    /// "Netflix", or "Tubi · Free with ads".
    public var displayName: String {
        guard let label = offer.label else { return name }
        return "\(name) · \(label)"
    }
}

/// What the title page is allowed to show, from everything TMDB returned.
///
/// The rules are the owner's, 2026-09-16:
/// - opt-in: nothing appears until a service has been added
/// - only services the viewer is actually signed into
/// - subscription and free-with-ads only, never rent or buy
/// - say which it is, rather than implying a clean stream
/// - the app stays the default; this is "also available on", not a second Play
public enum AppleWatchProviderPolicy: Sendable {
    /// Filters and orders what to show.
    ///
    /// `enabledProviderIDs` is what the viewer has added and signed into. An
    /// empty set shows **nothing** — the feature is off until they opt in, so a
    /// fresh install never advertises services at somebody.
    public static func visible(
        _ providers: [AppleWatchProvider],
        enabledProviderIDs: Set<Int>
    ) -> [AppleWatchProvider] {
        guard !enabledProviderIDs.isEmpty else { return [] }
        var seen = Set<Int>()
        return providers
            .filter { $0.offer.isOffered && enabledProviderIDs.contains($0.id) }
            // A service can appear in more than one bucket; the better offer
            // wins so a subscription is never shown as "free with ads".
            .sorted { rank($0.offer) < rank($1.offer) }
            .filter { seen.insert($0.id).inserted }
    }

    private static func rank(_ offer: AppleWatchProviderOffer) -> Int {
        switch offer {
        case .subscription: 0
        case .free: 1
        case .ads: 2
        case .rent, .buy: 3
        }
    }

    /// Whether the external option should replace Play.
    ///
    /// Only when there is nothing to play in the app: no local file, no add-on
    /// stream. Otherwise the app stays the default and the service is a quiet
    /// "also available on" (owner: "in general prefer to stay in the app").
    public static func replacesPlay(hasLocalOrAddonSource: Bool, visibleProviders: [AppleWatchProvider]) -> Bool {
        !hasLocalOrAddonSource && !visibleProviders.isEmpty
    }
}


// MARK: - TMDB decoding

/// Decodes TMDB's `watch/providers` response.
///
/// The response is keyed by country, and availability genuinely differs by
/// region — a title on Netflix in the US may be nowhere in the UK. Showing the
/// wrong region's answer is worse than showing none, so the region is required
/// rather than defaulted.
public enum AppleWatchProviderResponse: Sendable {
    public struct Envelope: Decodable, Sendable {
        public let results: [String: Region]?
    }

    public struct Region: Decodable, Sendable {
        public let flatrate: [Entry]?
        public let free: [Entry]?
        public let ads: [Entry]?
        public let rent: [Entry]?
        public let buy: [Entry]?
    }

    public struct Entry: Decodable, Sendable {
        public let provider_id: Int
        public let provider_name: String
        public let logo_path: String?
    }

    /// Everything the region offers, including rent and buy.
    ///
    /// The purchase buckets are decoded rather than dropped here on purpose:
    /// `AppleWatchProviderPolicy` is the single place that decides what is
    /// shown, so the exclusion is visible in one rule with a test on it rather
    /// than hidden in a parser.
    public static func providers(in envelope: Envelope, region: String) -> [AppleWatchProvider] {
        guard let region = envelope.results?[region.uppercased()] else { return [] }
        let buckets: [(AppleWatchProviderOffer, [Entry]?)] = [
            (.subscription, region.flatrate),
            (.free, region.free),
            (.ads, region.ads),
            (.rent, region.rent),
            (.buy, region.buy),
        ]
        return buckets.flatMap { offer, entries in
            (entries ?? []).map {
                AppleWatchProvider(
                    id: $0.provider_id,
                    name: $0.provider_name,
                    offer: offer,
                    logoPath: $0.logo_path
                )
            }
        }
    }

    /// The viewer's region, for the lookup. TMDB keys on ISO 3166-1 alpha-2.
    public static func currentRegion(locale: Locale = .current) -> String {
        locale.region?.identifier.uppercased() ?? "US"
    }
}


// MARK: - The services a viewer can choose from

public extension AppleWatchProviderResponse {
    /// TMDB's list of every service operating in a region, for the settings
    /// screen to offer.
    struct DirectoryEnvelope: Decodable, Sendable {
        public let results: [DirectoryEntry]?
    }

    struct DirectoryEntry: Decodable, Sendable {
        public let provider_id: Int
        public let provider_name: String
        public let logo_path: String?
        public let display_priority: Int?
    }

    /// Ordered as TMDB ranks them for the region, so the services a viewer is
    /// most likely to have appear first rather than alphabetically.
    static func directory(in envelope: DirectoryEnvelope) -> [AppleWatchProvider] {
        (envelope.results ?? [])
            .sorted { ($0.display_priority ?? .max) < ($1.display_priority ?? .max) }
            .map {
                AppleWatchProvider(
                    id: $0.provider_id,
                    name: $0.provider_name,
                    // A directory entry is a service, not an offer for a
                    // particular title; `.subscription` is the placeholder and
                    // is never shown as a label.
                    offer: .subscription,
                    logoPath: $0.logo_path
                )
            }
    }
}
