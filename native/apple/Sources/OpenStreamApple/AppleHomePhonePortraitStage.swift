import SwiftUI

/// Holds landing artwork during loading, with decoded backdrops replacing poster fallbacks.
struct AppleHomePhonePortraitStage: View {
    let item: AppleCatalogItem
    var details: AppleTMDBDetails? = nil
    var topInset: CGFloat = 0
    var onReady: (AppleHeroPortraitArt, CGImage?) -> Void = { _, _ in }
    var onCover: ((AppleHeroPortraitCover?) -> Void)? = nil

    @Environment(\.appleTMDBConfiguration) private var configuration
    @Environment(\.displayScale) private var displayScale
    @State private var upgrade: AppleHeroArtworkUpgrade.Artwork?
    @State private var failed: Set<URL> = []
    @State private var shown: AppleTitlePageSlotArt?
    @State private var requestedArt: AppleTitlePageSlotArt?
    @State private var image: CGImage?
    @State private var size: CGSize = .zero

    private var artDetails: AppleTMDBDetails {
        AppleTMDBDetails(posterURL: details?.posterURL ?? upgrade?.titlePage?.posterURL,
            backdropURL: details?.backdropURL,
            textlessBackdropURL: details?.textlessBackdropURL ?? upgrade?.titlePage?.backdropURL)
    }

    private var backdrops: [URL?] {
        AppleTitlePageSlotArt.landingBackdrops(item: item, details: artDetails,
            remembered: AppleHeroPortraitMemory.art(for: item.mediaID))
    }

    private var art: AppleTitlePageSlotArt? {
        let candidate = AppleTitlePageSlotArt.choose(backdrops: backdrops, posters: [artDetails.posterURL, item.posterURL], failed: failed)
        return AppleTitlePageSlotArt.landingArt(displayed: shown, requested: requestedArt,
            candidate: candidate, failed: failed)
    }

    private var cachedArt: (art: AppleTitlePageSlotArt, image: CGImage)? {
        AppleTitlePageSlotArt.chooseCached(backdrops: backdrops,
            posters: [artDetails.posterURL, item.posterURL], cachedImage: { AppleRemoteImageCache.shared.cachedPlaceholderImage(url: $0) })
    }

    var body: some View {
        ApplePhoneHeroArtwork(art: art, cachedArt: cachedArt,
            onLoad: { loaded($0, art: $1, isPlaceholder: false) },
            onPlaceholder: { loaded($0, art: $1, isPlaceholder: true) },
            onFailure: { failed.insert($0.url) })
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0; reportCover() }
            .task(id: item.mediaID) { await upgradeArtwork() }
            .onChange(of: art, initial: true) { _, art in
                requestedArt = art
                guard art == nil, image == nil else { return }
                onReady(.none, nil)
                if onCover != nil { AppleLaunchReadiness.shared.markFirstScreenReady() }
            }
    }

    private func loaded(_ decoded: CGImage, art: AppleTitlePageSlotArt, isPlaceholder: Bool) {
        guard AppleTitlePageSlotArt.acceptsLoadedArt(art, requested: self.art, displayed: shown) else { return }
        if !isPlaceholder {
            AppleHeroPortraitMemory.remember(art.isPosterCard ? .posterCard(art.url) : .backdrop(art.url), for: item.mediaID)
        }
        guard shown != art || image !== decoded else { return }
        image = decoded
        shown = art
        appleTrace("hero portrait image \(art.isPosterCard ? "fallback" : "backdrop") decoded (\(item.name))")
        reportReady()
        reportCover()
        if onCover != nil {
            AppleLaunchMarks.record(.heroArt)
            AppleLaunchReadiness.shared.markFirstScreenReady()
        }
    }

    private func reportReady() {
        guard let shown else { return }
        let art: AppleHeroPortraitArt = shown.isPosterCard ? .posterCard(shown.url) : .backdrop(shown.url)
        onReady(art, image)
    }

    private func reportCover() {
        guard let onCover else { return }
        guard let shown, let image, size.width > 0, size.height > 0 else { onCover(nil); return }
        onCover(AppleHeroPortraitCover(art: shown.isPosterCard ? .posterCard(shown.url) : .backdrop(shown.url),
            image: image, size: size, focal: CGPoint(x: 0.5, y: 0.5), topInset: topInset,
            scale: displayScale, titlePageArt: shown))
    }

    private func upgradeArtwork() async {
        let imdbID = AppleHeroArtworkUpgrade.upgradeableIMDBID(for: item)
            ?? item.imdbID.flatMap { AppleMediaIdentifier.isIMDBIdentifier($0) ? $0 : nil }
        guard let configuration, let imdbID else { return }
        let artwork = await AppleHeroArtworkUpgrade.shared.artwork(
            imdbID: imdbID, kind: item.type == "series" ? .series : .movie, configuration: configuration,
            includingTitlePage: true)
        guard !Task.isCancelled else { return }
        upgrade = artwork
        if art == nil { onReady(.none, nil) }
    }
}

/// Reuses the last artwork decision when a landing page is remounted.
@MainActor
enum AppleHeroPortraitMemory {
    private static var choices: [String: AppleHeroPortraitArt] = [:]

    static func art(for mediaID: String) -> AppleHeroPortraitArt? { choices[mediaID] }
    static func remember(_ art: AppleHeroPortraitArt, for mediaID: String) {
        if choices[mediaID] == nil || (choices[mediaID]?.source != .poster
            && (art.source == .poster || art.source == .backdrop)) {
            choices[mediaID] = art
        }
    }
}

/// The portrait hero's art as the stage draws it, for the trailer's cover:
/// the still under a starting or ending trailer is these pixels, at the
/// frame's size. Rendered only when a trailer is about to play (Fable review
/// 2026-10-14: rendering it on every settle stalled the main thread inside
/// the page slide, hero or no trailer).
struct AppleHeroPortraitCover: Equatable {
    let art: AppleHeroPortraitArt
    let image: CGImage
    let size: CGSize
    let focal: CGPoint
    let topInset: CGFloat
    let scale: CGFloat
    var titlePageArt: AppleTitlePageSlotArt? = nil

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.art == rhs.art && lhs.image === rhs.image && lhs.size == rhs.size && lhs.focal == rhs.focal
            && lhs.topInset == rhs.topInset && lhs.scale == rhs.scale && lhs.titlePageArt == rhs.titlePageArt
    }

    /// Key art and backdrops are a plain crop, drawn off the main actor; the
    /// poster card's blur needs SwiftUI, so it goes through `ImageRenderer`.
    @MainActor
    func render() async -> CGImage? {
        guard size.width > 0, size.height > 0 else { return nil }
        if let titlePageArt, titlePageArt.isPosterCard {
            let renderer = ImageRenderer(content:
                AppleTitlePageDecodedSlotImage(image: image, art: titlePageArt,
                    slotHeight: AppleTitlePageSlotArt.slotHeight(width: size.width))
                    .frame(width: size.width, height: size.height)
                    .clipped()
                    .background(Color.black))
            renderer.scale = scale
            renderer.isOpaque = true
            return renderer.cgImage
        }
        let imageSize = CGSize(width: image.width, height: image.height)
        let rect: CGRect
        switch art {
        case .keyArt, .backdrop:
            rect = titlePageArt == nil ? art.imageRect(imageSize: imageSize, in: size, focal: focal)
                : AppleHeroPortraitArt.fillRect(imageSize: imageSize, in: size, focal: focal)
        case .posterCard:
            let renderer = ImageRenderer(content:
                AppleHeroPortraitArtView(art: art, image: image, size: size, focal: focal, topInset: topInset)
                    .frame(width: size.width, height: size.height)
                    .background(Color.black))
            renderer.scale = scale
            renderer.isOpaque = true
            return renderer.cgImage
        case .none:
            return nil
        }
        let (image, size, scale) = (image, size, scale)
        return await Task.detached(priority: .userInitiated) {
            Self.draw(image, in: rect, frame: size, scale: scale)
        }.value
    }

    /// `image` at `rect` (points, top-left origin) in an opaque black frame.
    nonisolated static func draw(_ image: CGImage, in rect: CGRect, frame: CGSize, scale: CGFloat) -> CGImage? {
        let width = Int((frame.width * scale).rounded())
        let height = Int((frame.height * scale).rounded())
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.scaleBy(x: scale, y: scale)
        // Core Graphics counts up from the bottom.
        context.draw(image, in: CGRect(x: rect.minX, y: frame.height - rect.maxY, width: rect.width, height: rect.height))
        return context.makeImage()
    }
}

/// One portrait hero's art at `size`: drawn on screen by the stage, and once
/// more off screen for the trailer's cover.
struct AppleHeroPortraitArtView: View {
    let art: AppleHeroPortraitArt
    let image: CGImage
    let size: CGSize
    var focal: CGPoint = AppleHeroPortraitArt.focalPoint
    var topInset: CGFloat = 0

    var body: some View {
        let imageSize = CGSize(width: image.width, height: image.height)
        switch art {
        case .keyArt, .backdrop:
            AppleHeroPositionedImage(image: image, size: size,
                                     rect: art.imageRect(imageSize: imageSize, in: size, focal: focal))
        case .posterCard:
            let card = AppleHeroPortraitArt.posterCardRect(posterAspect: imageSize.width / max(imageSize.height, 1),
                                                           in: size, topInset: topInset)
            ZStack(alignment: .topLeading) {
                AppleHeroPositionedImage(image: image, size: size,
                    rect: AppleHeroPortraitArt.fillRect(imageSize: imageSize, in: size, focal: CGPoint(x: 0.5, y: 0.5)))
                    .blur(radius: 40)
                    .overlay(Color.black.opacity(0.35))
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: card.width, height: card.height)
                    .clipShape(.rect(cornerRadius: 12))
                    .offset(x: card.minX, y: card.minY)
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .clipped()
        case .none:
            Color.black
        }
    }
}

/// The same image bounds used by the trailer cover.
struct AppleHeroPositionedImage: View {
    let image: CGImage
    let size: CGSize
    let rect: CGRect

    var body: some View {
        Image(decorative: image, scale: 1)
            .resizable()
            .interpolation(.high)
            .frame(width: rect.width, height: rect.height)
            .offset(x: rect.minX, y: rect.minY)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .clipped()
    }
}
