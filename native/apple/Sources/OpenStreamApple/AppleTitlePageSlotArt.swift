import CoreGraphics
import Foundation

/// The iPhone title page's header art, full bleed under the approved fade,
/// which the trailer crossfades over. Known catalog art draws immediately;
/// better metadata can replace it after decoding, while the previous image
/// stays visible.
public enum AppleTitlePageSlotArt: Equatable, Sendable {
    /// Fills the header.
    case backdrop(URL)
    /// No backdrop anywhere: the poster as a card on a blurred copy of itself.
    case posterCard(URL)

    /// Backdrops first (textless first), then posters; failed images skipped.
    public static func choose(backdrops: [URL?], posters: [URL?], failed: Set<URL> = []) -> AppleTitlePageSlotArt? {
        if let url = backdrops.lazy.compactMap({ $0 }).first(where: { !failed.contains($0) }) { return .backdrop(url) }
        if let url = posters.lazy.compactMap({ $0 }).first(where: { !failed.contains($0) }) { return .posterCard(url) }
        return nil
    }

    static func choose(item: AppleCatalogItem, details: AppleTMDBDetails? = nil,
                       fallback: AppleArtworkResolver.Artwork? = nil, failed: Set<URL> = []) -> Self? {
        choose(backdrops: [details?.textlessBackdropURL, details?.backdropURL, item.backgroundURL, fallback?.backgroundURL],
               posters: [details?.posterURL, item.posterURL, fallback?.posterURL], failed: failed)
    }

    static func landingBackdrops(item: AppleCatalogItem, details: AppleTMDBDetails,
                                remembered: AppleHeroPortraitArt?) -> [URL?] {
        let rememberedURL: URL?
        if case .backdrop(let url) = remembered { rememberedURL = url } else { rememberedURL = nil }
        return [details.textlessBackdropURL, rememberedURL, item.backgroundURL, details.backdropURL]
    }

    /// A landing page holds its first picture, but a poster fallback may become a full-bleed backdrop.
    static func landingArt(displayed: Self?, requested: Self?, candidate: Self?, failed: Set<URL>) -> Self? {
        if let displayed, !displayed.isPosterCard { return displayed }
        guard let current = [displayed, requested].compactMap({ $0 }).first(where: { !failed.contains($0.url) }) else {
            return candidate
        }
        if current.isPosterCard, let candidate, !candidate.isPosterCard { return candidate }
        return current
    }

    /// Prefer a decoded backdrop, then a decoded poster, without starting
    /// any I/O. An uncached better candidate can replace this later.
    public static func chooseCached(backdrops: [URL?], posters: [URL?],
        cachedImage: (URL) -> CGImage?) -> (art: AppleTitlePageSlotArt, image: CGImage)? {
        let candidates = backdrops.compactMap { $0 }.map(Self.backdrop)
            + posters.compactMap { $0 }.map(Self.posterCard)
        for art in candidates {
            if let image = cachedImage(art.url) { return (art, image) }
        }
        return nil
    }

    /// An answer with no art is a stable placeholder; known art never waits
    /// for a provider or a timer to become eligible.
    public static func isReady(knownArt: AppleTitlePageSlotArt?, detailsAnswered: Bool) -> Bool {
        knownArt != nil || detailsAnswered
    }

    public static func updating(_ current: AppleTitlePageSlotArt?, with candidate: AppleTitlePageSlotArt?) -> AppleTitlePageSlotArt? {
        guard let candidate else { return current }
        if let current, case .backdrop = current, case .posterCard = candidate { return current }
        return candidate
    }

    /// Keep a first usable picture while a better candidate is still loading;
    /// after a picture is displayed, obsolete completions cannot replace it.
    public static func acceptsLoadedArt(_ loaded: AppleTitlePageSlotArt,
        requested: AppleTitlePageSlotArt?, displayed: AppleTitlePageSlotArt?) -> Bool {
        loaded == requested || displayed == nil
    }

    public var url: URL {
        switch self {
        case .backdrop(let url), .posterCard(let url): url
        }
    }

    public var isPosterCard: Bool {
        if case .posterCard = self { return true }
        return false
    }

    static func heroHeight(screenHeight: CGFloat) -> CGFloat {
        max(AppleHomePhoneHeroLayout.minimumArtHeight, screenHeight * AppleHomePhoneHeroLayout.artFraction)
    }

    /// 16:9 of the width: the size of a poster card's frame.
    public static func slotHeight(width: CGFloat) -> CGFloat {
        max(0, (width * 9 / 16).rounded())
    }
}
