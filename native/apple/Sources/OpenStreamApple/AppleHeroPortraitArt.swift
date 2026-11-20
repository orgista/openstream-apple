import CoreGraphics
import Foundation

/// The iPhone hero prefers a portrait poster over a landscape backdrop.
/// Provider art is kept as an intact card because it may carry a printed title.
///
/// Media servers and IPTV map onto the same slots through the item: Jellyfin
/// `Primary` / Plex `thumb` / Xtream `stream_icon` are the poster, `Backdrop` /
/// `art` / `backdrop_path` the backdrop. None carries a language, so all count as titled.
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
        /// A backdrop whose language is unknown or set: treated as titled.
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

    /// The default focal point (top bias). Only backdrops use it; key art is
    /// cropped about its centre.
    public static let focalPoint = CGPoint(x: 0.5, y: 0.35)

    /// The decode budget for the hero's still, in pixels on the long side.
    public static let pixelDimension = 1_800

    /// First hit wins; an image that failed to load is skipped.
    public static func choose(_ candidates: Candidates, failed: Set<URL> = []) -> AppleHeroPortraitArt {
        func usable(_ url: URL?) -> URL? { url.flatMap { failed.contains($0) ? nil : $0 } }
        if let poster = usable(candidates.textlessPoster) { return .keyArt(poster) }
        if let poster = usable(candidates.poster) { return .posterCard(poster) }
        if let backdrop = usable(candidates.textlessBackdrop) { return .backdrop(backdrop) }
        if let backdrop = usable(candidates.backdrop) { return .posterCard(backdrop) }
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

    /// The still and trailer cover share these bounds. Unsafe crops fit whole
    /// over the same black used by the approved billboard scrim.
    public func imageRect(imageSize: CGSize, in frame: CGSize, focal: CGPoint = AppleHeroPortraitArt.focalPoint) -> CGRect {
        switch self {
        case .keyArt, .backdrop:
            let minimumVisibleWidth: CGFloat = source == .poster ? 0.95 : 0.60
            let filled = Self.fillRect(imageSize: imageSize, in: frame,
                focal: source == .poster ? CGPoint(x: 0.5, y: 0.5) : focal,
                subjectAnchor: source == .poster ? nil : CGPoint(x: 0.5, y: 0.4))
            guard imageSize.width > 0, imageSize.height > 0, filled.width > 0,
                  frame.width / filled.width < minimumVisibleWidth else { return filled }
            let scale = min(frame.width / imageSize.width, frame.height / imageSize.height)
            let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
            // Top-anchored: the scrim is clear only to 32 % of the hero height, so
            // a centred fit would sit inside the fade band.
            return CGRect(x: (frame.width - size.width) / 2, y: 0,
                          width: size.width, height: size.height)
        case .posterCard, .none:
            return .zero
        }
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

    /// What the poster card leaves clear at the bottom of the art: the
    /// metadata line, the buttons and the page dots (its title is suppressed).
    public static let posterCardBottomReserve: CGFloat = 160
    /// The card's width as a share of the screen's, when the height allows.
    public static let posterCardWidthFraction: CGFloat = 0.6
    /// The same for a titled backdrop, which is wider than it is tall.
    public static let landscapeCardWidthFraction: CGFloat = 0.9

    /// Where the card (a titled poster, or a titled backdrop) sits in a full-height hero (`frame` from the top
    /// edge of the screen): centred across, and centred between the bottom
    /// of the large title (`topInset`) and the copy, shrunk to fit there, so
    /// the poster's own title is never under the navigation bar or the buttons.
    public static func posterCardRect(posterAspect: CGFloat, in frame: CGSize, topInset: CGFloat) -> CGRect {
        guard posterAspect > 0, frame.width > 0, frame.height > 0 else { return .zero }
        let top = max(topInset, 0) + 12
        let room = max(frame.height - posterCardBottomReserve - top, 0)
        var width = frame.width * (posterAspect > 1 ? landscapeCardWidthFraction : posterCardWidthFraction)
        var height = width / posterAspect
        if height > room {
            height = room
            width = height * posterAspect
        }
        return CGRect(x: (frame.width - width) / 2, y: top + (room - height) / 2, width: width, height: height)
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
