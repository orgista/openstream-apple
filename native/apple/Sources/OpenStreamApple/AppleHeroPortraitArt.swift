import CoreGraphics
import Foundation

/// What the iPhone's portrait hero (Discover and Library) draws, chosen once,
/// before anything is shown, and never changed while the page is up (owner
/// items 6 and 19, spec `live-hero-redesign-2026-10-09` §4.2, Mythos §2.7).
///
/// Order, first hit wins:
/// 1. **Key art**: TMDB's textless (`null`-language) poster, with the wordmark
///    or the name drawn over it.
/// 2. **Backdrop**: the textless backdrop, else whatever backdrop the item
///    has, cropped with a fixed top bias (`focalPoint`).
/// 3. **Poster card**: the item's own poster (which is assumed to carry its
///    title) on a blurred copy of itself. The text title is then suppressed
///    so the name never appears twice. Last resort; every hit is traced.
/// 4. Nothing: the name over black (`AppleHeroTitlePolicy`).
///
/// Media servers and IPTV map onto the same slots through the item:
/// Jellyfin `Primary` / Plex `thumb` / Xtream `stream_icon` are the poster,
/// Jellyfin `Backdrop` / Plex `art` / Xtream `backdrop_path` the backdrop,
/// Jellyfin `Logo` / Plex `clearLogo` the wordmark. Their posters have no
/// language, so they count as titled.
public enum AppleHeroPortraitArt: Equatable, Sendable {
    case keyArt(URL)
    case backdrop(URL)
    case posterCard(URL)
    case none

    /// Every image a hero could draw, by kind.
    public struct Candidates: Equatable, Sendable {
        public var textlessPoster: URL?
        /// A poster whose language is unknown or set: treated as titled.
        public var poster: URL?
        public var textlessBackdrop: URL?
        public var backdrop: URL?
        public var logo: URL?

        public init(textlessPoster: URL? = nil, poster: URL? = nil, textlessBackdrop: URL? = nil,
                    backdrop: URL? = nil, logo: URL? = nil) {
            self.textlessPoster = textlessPoster
            self.poster = poster
            self.textlessBackdrop = textlessBackdrop
            self.backdrop = backdrop
            self.logo = logo
        }

        /// A catalog, library, media-server or IPTV item, plus TMDB's answer
        /// when the item has an IMDB id and TMDB is configured.
        public init(item: AppleCatalogItem, tmdbPoster: URL? = nil, tmdbBackdrop: URL? = nil, tmdbLogo: URL? = nil) {
            self.init(textlessPoster: tmdbPoster, poster: item.posterURL, textlessBackdrop: tmdbBackdrop,
                      backdrop: item.backgroundURL, logo: tmdbLogo ?? item.logoURL)
        }
    }

    /// For the trace and the hit-rate tally.
    public enum Source: String, Sendable {
        case poster, backdrop, fallback, none
    }

    /// The iPhone's portrait hero never autoplays a trailer (owner default,
    /// Mythos §4.2): trailers play on the title page's 16:9 header. iPad,
    /// Mac and Apple TV keep their hero trailers.
    public static let phoneHeroPlaysTrailers = false

    /// Constant top bias for slice 1 (a Vision focal point is slice 2).
    public static let focalPoint = CGPoint(x: 0.5, y: 0.35)

    /// The decode budget for the hero's still, in pixels on the long side.
    public static let pixelDimension = 1_800

    /// First hit wins; an image that failed to load is skipped.
    public static func choose(_ candidates: Candidates, failed: Set<URL> = []) -> AppleHeroPortraitArt {
        func usable(_ url: URL?) -> URL? { url.flatMap { failed.contains($0) ? nil : $0 } }
        if let poster = usable(candidates.textlessPoster) { return .keyArt(poster) }
        if let backdrop = usable(candidates.textlessBackdrop) ?? usable(candidates.backdrop) { return .backdrop(backdrop) }
        if let poster = usable(candidates.poster) { return .posterCard(poster) }
        return .none
    }

    public var imageURL: URL? {
        switch self {
        case .keyArt(let url), .backdrop(let url), .posterCard(let url): url
        case .none: nil
        }
    }

    public var source: Source {
        switch self {
        case .keyArt: .poster
        case .backdrop: .backdrop
        case .posterCard: .fallback
        case .none: .none
        }
    }

    /// False when the art already says the name (a titled poster): the hero
    /// then keeps only its metadata line and buttons, so the title never
    /// shows twice. Wordmark and text title alike are suppressed.
    public var showsTitle: Bool {
        if case .posterCard = self { return false }
        return true
    }

    /// The image's aspect-fill rect in a frame of `frame`, placed so that
    /// `focal` (normalised in the image) sits as close to the same place in
    /// the frame as the image's edges allow. Never leaves a gap.
    public static func fillRect(imageSize: CGSize, in frame: CGSize, focal: CGPoint = focalPoint,
                                subjectAnchor: CGPoint? = nil) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, frame.width > 0, frame.height > 0 else {
            return CGRect(origin: .zero, size: frame)
        }
        let scale = max(frame.width / imageSize.width, frame.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let overflowX = size.width - frame.width
        let overflowY = size.height - frame.height
        let x: CGFloat, y: CGFloat
        if let subjectAnchor {
            x = min(0, max(-overflowX, frame.width * subjectAnchor.x - size.width * focal.x))
            y = min(0, max(-overflowY, frame.height * subjectAnchor.y - size.height * focal.y))
        } else {
            x = -overflowX * min(max(focal.x, 0), 1)
            y = -overflowY * min(max(focal.y, 0), 1)
        }
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }
}

/// How often each art source has been drawn this run, for the trace
/// (owner: log how often the poster-card fallback is hit).
@MainActor
enum AppleHeroPortraitArtTally {
    private(set) static var counts: [AppleHeroPortraitArt.Source: Int] = [:]

    static func record(_ art: AppleHeroPortraitArt, item: String) {
        counts[art.source, default: 0] += 1
        let summary = [AppleHeroPortraitArt.Source.poster, .backdrop, .fallback, .none]
            .map { "\($0.rawValue)=\(counts[$0] ?? 0)" }.joined(separator: " ")
        appleTrace("hero portrait art \(art.source.rawValue) (\(item)) tally \(summary)")
    }
}
