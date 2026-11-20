import Foundation

/// The small outlined capsule over the iPhone hero's title ("New Season",
/// "New Episode"). Only ever drawn from the title's own episode list; a title
/// with no recent episode gets no badge rather than a made-up one.
///
/// No hero or title page draws it any more: the owner asked, more than once,
/// for the "New Episode" pill to go (2026-09-26). The rule stays, tested, in
/// case it comes back; `Episode` and `releaseDate` are still read elsewhere.
public enum AppleHeroBadge: String, Equatable, Sendable {
    case newSeason
    case newEpisode

    /// How long an episode counts as new.
    public static let window: TimeInterval = 14 * 24 * 60 * 60

    public var title: String {
        switch self {
        case .newSeason: "New Season"
        case .newEpisode: "New Episode"
        }
    }

    /// One aired (or announced) episode, as the title's metadata lists it.
    public struct Episode: Equatable, Hashable, Sendable {
        public let season: Int
        public let episode: Int
        public let released: Date

        public init(season: Int, episode: Int, released: Date) {
            self.season = season
            self.episode = episode
            self.released = released
        }
    }

    /// The badge for a title, or nil. A series whose newest aired episode came
    /// out within `window` is "New Season" when that episode opens a season
    /// after the first, "New Episode" when it is later in a season. A series
    /// premiere, specials (season 0), films and episodes still to come get
    /// nothing.
    public static func select(type: String, episodes: [Episode], now: Date, window: TimeInterval = window) -> AppleHeroBadge? {
        guard type.lowercased() == "series" else { return nil }
        let aired = episodes.filter { $0.season > 0 && $0.episode > 0 && $0.released <= now }
        guard let latest = aired.max(by: { lhs, rhs in
            (lhs.released, lhs.season, lhs.episode) < (rhs.released, rhs.season, rhs.episode)
        }), now.timeIntervalSince(latest.released) <= window else { return nil }
        if latest.episode == 1 { return latest.season > 1 ? .newSeason : nil }
        return .newEpisode
    }

    /// Reads a `released` value ("2026-09-18T00:00:00.000Z", with or
    /// without the fraction, or a bare "2026-09-18").
    public static func releaseDate(_ value: String?) -> Date? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        if let date = try? Date(value, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) {
            return date
        }
        if let date = try? Date(value, strategy: Date.ISO8601FormatStyle()) { return date }
        return try? Date(String(value.prefix(10)), strategy: Date.ISO8601FormatStyle().year().month().day())
    }
}
