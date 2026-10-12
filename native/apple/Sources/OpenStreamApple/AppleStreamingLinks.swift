import Foundation

// "Watch on <service>": when nothing in the app can play a title but a
// service the viewer added carries it, the title page's main button opens
// that title in the service's app. TMDB decides which services carry it
// (`AppleWatchProviderPolicy`); Wikidata only supplies the per-service id
// for the link (owner decision 2026-09-30). The research, link formats and
// fallback order are in specs/watch-on-service.md.

/// A streaming service OpenStream knows how to link into.
public enum AppleStreamingService: String, CaseIterable, Sendable {
    case netflix
    case disneyPlus
    case hulu
    case primeVideo
    case hboMax
    case appleTV
    case paramountPlus
    case peacock
    case crunchyroll
    case tubi
    case plutoTV

    /// The TMDB `provider_id`s for each service (US ids, plus the ad and
    /// premium tiers TMDB lists separately). An id not listed here has no
    /// Watch on button: no link we could build is better than a guess.
    public init?(tmdbProviderID: Int) {
        switch tmdbProviderID {
        case 8, 1796: self = .netflix
        case 337: self = .disneyPlus
        case 15: self = .hulu
        case 9, 119: self = .primeVideo
        case 1899, 384: self = .hboMax
        case 350, 2: self = .appleTV
        case 531, 2303, 2616: self = .paramountPlus
        case 386, 387: self = .peacock
        case 283: self = .crunchyroll
        case 73: self = .tubi
        case 300: self = .plutoTV
        default: return nil
        }
    }

    /// The name on the button. TMDB's names drift ("Amazon Prime Video",
    /// "Disney Plus"); the button says what the service calls itself.
    public var displayName: String {
        switch self {
        case .netflix: "Netflix"
        case .disneyPlus: "Disney+"
        case .hulu: "Hulu"
        case .primeVideo: "Prime Video"
        case .hboMax: "HBO Max"
        case .appleTV: "Apple TV"
        case .paramountPlus: "Paramount+"
        case .peacock: "Peacock"
        case .crunchyroll: "Crunchyroll"
        case .tubi: "Tubi"
        case .plutoTV: "Pluto TV"
        }
    }

    /// The Wikidata properties that give this service a title-level link, in
    /// the order they are tried. Paramount+ and Peacock have properties, but
    /// their links do not open the app (spec §3), so they are search-only.
    public var wikidataProperties: [AppleWikidataStreamingProperty] {
        switch self {
        case .netflix: [.netflix]
        case .disneyPlus: [.disneyPlusBrowse, .disneyPlusMovie, .disneyPlusSeries]
        case .hulu: [.huluSeries, .huluMovie]
        case .primeVideo: [.primeVideoGTI, .primeVideoASIN, .primeVideoID]
        case .hboMax: [.hboMax]
        case .appleTV: [.appleTVMovie, .appleTVShow]
        case .crunchyroll: [.crunchyrollSeries]
        case .tubi: [.tubiMovie, .tubiSeries]
        case .paramountPlus, .peacock, .plutoTV: []
        }
    }

    /// The service's in-app search, only where its app claims the search
    /// path (spec §4). Everywhere else a search link would open a browser,
    /// so the app's home is used instead.
    public func searchURL(for title: String) -> URL? {
        let query = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }
        let base: (String, String)
        switch self {
        case .netflix: base = ("https://www.netflix.com/search", "q")
        case .primeVideo: base = ("https://www.primevideo.com/search", "phrase")
        case .hboMax: base = ("https://play.hbomax.com/search", "q")
        case .appleTV: base = ("https://tv.apple.com/search", "term")
        case .peacock: base = ("https://www.peacocktv.com/watch/search", "q")
        case .disneyPlus, .hulu, .paramountPlus, .crunchyroll, .tubi, .plutoTV: return nil
        }
        var components = URLComponents(string: base.0)
        components?.queryItems = [URLQueryItem(name: base.1, value: query)]
        return components?.url
    }

    /// The service's front door, the last link before the instructions.
    public var homeURL: URL {
        let string = switch self {
        case .netflix: "https://www.netflix.com/"
        case .disneyPlus: "https://www.disneyplus.com/"
        case .hulu: "https://www.hulu.com/"
        case .primeVideo: "https://www.primevideo.com/"
        case .hboMax: "https://play.hbomax.com/"
        case .appleTV: "https://tv.apple.com/"
        case .paramountPlus: "https://www.paramountplus.com/"
        case .peacock: "https://www.peacocktv.com/"
        case .crunchyroll: "https://www.crunchyroll.com/"
        case .tubi: "https://tubitv.com/"
        case .plutoTV: "https://pluto.tv/"
        }
        return URL(string: string)!
    }
}

/// The Wikidata properties holding per-service title ids (spec §1, verified
/// 2026-09-30). Each value is checked against `pattern` before a link is
/// built from it, so a malformed edit on Wikidata can never become a URL.
public enum AppleWikidataStreamingProperty: String, CaseIterable, Sendable {
    case netflix = "P1874"
    case disneyPlusBrowse = "P13902"
    case disneyPlusMovie = "P7595"
    case disneyPlusSeries = "P7596"
    case huluMovie = "P6466"
    case huluSeries = "P6467"
    case primeVideoASIN = "P8055"
    case primeVideoGTI = "P14462"
    case primeVideoID = "P14440"
    case hboMax = "P8298"
    case appleTVMovie = "P9586"
    case appleTVShow = "P9751"
    case paramountPlus = "P13147"
    case peacock = "P11815"
    case crunchyrollSeries = "P11330"
    case tubiMovie = "P7760"
    case tubiSeries = "P7761"

    private static let uuid = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"

    var pattern: String {
        switch self {
        case .netflix: #"^\d{6,9}$"#
        case .disneyPlusBrowse: "^entity-\(Self.uuid)$"
        case .disneyPlusMovie, .disneyPlusSeries: "^[A-Za-z0-9]{12}$"
        case .huluMovie, .huluSeries: "^\(Self.uuid)$"
        case .primeVideoASIN: "^B[0-9A-Z]{9}$"
        case .primeVideoGTI: "^amzn1\\.dv\\.gti\\.\(Self.uuid)$"
        case .primeVideoID: "^[0-9A-Z]{20,32}$"
        case .hboMax: "^[a-z]+/[A-Za-z0-9:._-]+$"
        case .appleTVMovie, .appleTVShow: #"^umc\.cmc\.[a-z0-9]{20,30}$"#
        case .paramountPlus: "^[A-Za-z0-9_-]{10,40}$"
        case .peacock: "^(tv|movies)/[a-z0-9-]+$"
        case .crunchyrollSeries: "^G[A-Z0-9]{5,12}$"
        case .tubiMovie, .tubiSeries: #"^\d{3,12}$"#
        }
    }

    /// Whether `value` has this property's shape.
    public func accepts(_ value: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }

    /// The title-level link for an id, or nil for a property that is
    /// search-only or an id of the wrong shape.
    public func url(for value: String) -> URL? {
        guard accepts(value) else { return nil }
        let path: String
        switch self {
        case .netflix: path = "https://www.netflix.com/title/\(value)"
        case .disneyPlusBrowse: path = "https://www.disneyplus.com/browse/\(value)"
        case .disneyPlusMovie: path = "https://www.disneyplus.com/movies/wd/\(value)"
        case .disneyPlusSeries: path = "https://www.disneyplus.com/series/wp/\(value)"
        case .huluMovie: path = "https://www.hulu.com/movie/\(value)"
        case .huluSeries: path = "https://www.hulu.com/series/\(value)"
        // Never the amazon.com formatter: no video app claims /gp/video.
        case .primeVideoASIN, .primeVideoGTI, .primeVideoID: path = "https://www.primevideo.com/detail/\(value)"
        // Already carries its type ("show/…", "series/urn:hbo:series:…").
        case .hboMax: path = "https://play.hbomax.com/\(value)"
        case .appleTVMovie: path = "https://tv.apple.com/movie/\(value)"
        case .appleTVShow: path = "https://tv.apple.com/show/\(value)"
        case .crunchyrollSeries: path = "https://www.crunchyroll.com/series/\(value)"
        case .tubiMovie: path = "https://tubitv.com/movies/\(value)"
        case .tubiSeries: path = "https://tubitv.com/series/\(value)"
        case .paramountPlus, .peacock: return nil
        }
        guard let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) else { return nil }
        return URL(string: encoded)
    }
}

/// One title's ids, as Wikidata returned them: property ("P1874") to its
/// values. Empty means Wikidata knows the title but has no service ids, or
/// the lookup failed.
public struct AppleStreamingIDs: Codable, Equatable, Sendable {
    public var values: [String: [String]]

    public init(values: [String: [String]] = [:]) {
        self.values = values.filter { !$0.value.isEmpty }
    }

    public var isEmpty: Bool { values.isEmpty }

    /// The first value of `property` with the right shape. Values can be
    /// multi-valued (Frozen has two legacy Disney+ ids).
    public func first(_ property: AppleWikidataStreamingProperty) -> String? {
        values[property.rawValue]?.first(where: property.accepts)
    }
}

/// A link the Watch on button can open, and what kind it is.
public struct AppleWatchOnLink: Equatable, Sendable {
    public enum Kind: String, Sendable {
        /// The title's own page, from a Wikidata id.
        case title = "wikidata id"
        /// The title's tv.apple.com page, which the TV app opens.
        case appleTV = "tvapp"
        /// The service's in-app search.
        case search
        /// The service's front door.
        case home
    }

    public let url: URL
    public let kind: Kind

    public init(url: URL, kind: Kind) {
        self.url = url
        self.kind = kind
    }
}

/// The links to try for a service, best first (spec §4): the title's own
/// page → in-app search (only where the app claims it) → the service's home.
/// Never empty: home is always last. The title's tv.apple.com page is a link
/// for Apple TV only: a "Watch on Netflix" that fell back to it opened the
/// TV app instead of Netflix (iOS 18 test, 2026-10-01).
public enum AppleWatchOnLinkPolicy {
    public static func links(for service: AppleStreamingService, ids: AppleStreamingIDs, title: String) -> [AppleWatchOnLink] {
        var links: [AppleWatchOnLink] = []
        func append(_ url: URL?, _ kind: AppleWatchOnLink.Kind) {
            guard let url, !links.contains(where: { $0.url == url }) else { return }
            links.append(AppleWatchOnLink(url: url, kind: kind))
        }
        let titleURL = service.wikidataProperties.lazy
            .compactMap { property in ids.first(property).flatMap(property.url(for:)) }
            .first
        append(titleURL, service == .appleTV ? .appleTV : .title)
        // Hulu content lives in Disney+ under the same UUID (The Bear,
        // Shōgun verified): a second title link for either service.
        if service == .disneyPlus || service == .hulu {
            append(disneyPlusURL(fromHulu: ids), .title)
        }
        if service == .appleTV {
            append(appleTVTitleURL(ids), .appleTV)
        }
        append(service.searchURL(for: title), .search)
        append(service.homeURL, .home)
        return links
    }

    /// `https://www.disneyplus.com/browse/entity-<Hulu UUID>`.
    static func disneyPlusURL(fromHulu ids: AppleStreamingIDs) -> URL? {
        guard let uuid = ids.first(.huluSeries) ?? ids.first(.huluMovie) else { return nil }
        return AppleWikidataStreamingProperty.disneyPlusBrowse.url(for: "entity-\(uuid)")
    }

    /// The title's tv.apple.com page: 82 % of titles have one, and the TV
    /// app hands off to the service that carries it.
    static func appleTVTitleURL(_ ids: AppleStreamingIDs) -> URL? {
        [AppleWikidataStreamingProperty.appleTVMovie, .appleTVShow].lazy
            .compactMap { property in ids.first(property).flatMap(property.url(for:)) }
            .first
    }

    /// The VoiceOver hint when the best link is not the title's own page.
    public static func accessibilityHint(service: AppleStreamingService, links: [AppleWatchOnLink]) -> String? {
        switch links.first?.kind {
        case .search?: "Opens \(service.displayName) search"
        case .home?: "Opens \(service.displayName)"
        default: nil
        }
    }
}

/// One service on the Watch on button or menu.
public struct AppleWatchOnChoice: Equatable, Sendable, Identifiable {
    public let service: AppleStreamingService
    public let provider: AppleWatchProvider

    public var id: String { service.rawValue }
    public var title: String { "Watch on \(service.displayName)" }
}

/// What takes the place of Play.
public enum AppleWatchOnAction: Equatable, Sendable {
    /// "Watch on Netflix".
    case single(AppleWatchOnChoice)
    /// "Watch on…", the viewer's services in the order they rank.
    case menu([AppleWatchOnChoice])

    public var choices: [AppleWatchOnChoice] {
        switch self {
        case .single(let choice): [choice]
        case .menu(let choices): choices
        }
    }

    public var title: String {
        switch self {
        case .single(let choice): choice.title
        case .menu: "Watch on…"
        }
    }
}

public enum AppleWatchOnPolicy {
    /// Nil keeps the page as it is: something in the app can play (Play stays
    /// and the services are the quiet "Also available on" line), or none of
    /// the viewer's services carries the title. `visibleProviders` is
    /// `AppleWatchProviderPolicy.visible`'s output — only services the viewer
    /// added, subscription before free before ads — and that order is kept.
    public static func action(hasInAppSource: Bool, visibleProviders: [AppleWatchProvider]) -> AppleWatchOnAction? {
        guard AppleWatchProviderPolicy.replacesPlay(
            hasLocalOrAddonSource: hasInAppSource, visibleProviders: visibleProviders
        ) else { return nil }
        var seen = Set<AppleStreamingService>()
        let choices = visibleProviders.compactMap { provider -> AppleWatchOnChoice? in
            guard let service = AppleStreamingService(tmdbProviderID: provider.id),
                  seen.insert(service).inserted else { return nil }
            return AppleWatchOnChoice(service: service, provider: provider)
        }
        switch choices.count {
        case 0: return nil
        case 1: return .single(choices[0])
        default: return .menu(choices)
        }
    }

    /// One step of opening a service, tried in order until one succeeds.
    public enum Attempt: Equatable, Sendable {
        /// Opens only if an installed app claims the link
        /// (`universalLinksOnly`); fails quietly otherwise.
        case app(AppleWatchOnLink)
        /// Opens the link however the system does: the TV app for
        /// tv.apple.com, a browser for the web.
        case system(AppleWatchOnLink)
        /// Nothing opened: "Open <Service> and search for <Title>", with a QR
        /// code of `link` on the Apple TV.
        case instructions(AppleWatchOnLink?)
    }

    /// The order a tap tries things in, per platform (spec §3, §4).
    ///
    /// - iPhone, iPad, Vision Pro: each service link app-only, the Apple TV
    ///   page through the system, then the best link in the browser.
    /// - Mac: the web page (no service apps to hand off to).
    /// - Apple TV: same app-only chain, but there is no browser, so a chain
    ///   that opens nothing ends on the instructions. Never a dead button.
    public static func attempts(for links: [AppleWatchOnLink], platform: AppleUIPlatform) -> [Attempt] {
        let web = links.first(where: { $0.kind != .appleTV }) ?? links.first
        switch platform {
        case .macOS:
            return (links.first.map { [.system($0)] } ?? []) + [.instructions(web)]
        case .iOS, .visionOS, .tvOS:
            var attempts = links.map { $0.kind == .appleTV ? Attempt.system($0) : .app($0) }
            if platform != .tvOS, let first = links.first, first.kind != .appleTV {
                attempts.append(.system(first))
            }
            attempts.append(.instructions(web))
            return attempts
        }
    }

    /// The outcome of a tap: what opened, or the instructions to show.
    public enum Outcome: Equatable, Sendable {
        case opened(AppleWatchOnLink, inBrowser: Bool)
        case instructions(AppleWatchOnLink?)

        /// The trace's "(wikidata id|search|tvapp|…)".
        public var traceDetail: String {
            switch self {
            case .opened(let link, let inBrowser): inBrowser ? "\(link.kind.rawValue), browser" : link.kind.rawValue
            case .instructions: "instructions"
            }
        }
    }

    /// Runs `attempts` through `open(url, appOnly)` until one returns true.
    public static func run(
        _ attempts: [Attempt],
        open: @Sendable (URL, Bool) async -> Bool
    ) async -> Outcome {
        for attempt in attempts {
            switch attempt {
            case .app(let link):
                if await open(link.url, true) { return .opened(link, inBrowser: false) }
            case .system(let link):
                if await open(link.url, false) {
                    return .opened(link, inBrowser: link.kind != .appleTV)
                }
            case .instructions(let link):
                return .instructions(link)
            }
        }
        return .instructions(nil)
    }
}
