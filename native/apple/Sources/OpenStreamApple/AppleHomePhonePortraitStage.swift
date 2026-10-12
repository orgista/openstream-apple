import SwiftUI

/// The iPhone portrait hero's art (Discover and Library): static, no trailer.
///
/// The art and its crop are settled before anything is drawn
/// (`AppleHeroPortraitArt`): TMDB is asked first (cache, or at most
/// `lookupDeadline` of network), the chosen image is decoded, and only then
/// does it fade in over black. Once a title's art has been shown it is
/// remembered for the run, so a later TMDB answer, a page coming back round
/// the carousel, or a re-render never re-crops or swaps it in front of the
/// viewer (owner items 6 and 19).
struct AppleHomePhonePortraitStage: View {
    let item: AppleCatalogItem
    /// Called once the art is on screen: the choice, its image (for the
    /// still's luminance reading) and the wordmark the choice brought.
    var onReady: (AppleHeroPortraitDecision, CGImage?) -> Void = { _, _ in }

    @Environment(\.appleTMDBConfiguration) private var configuration
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown: Shown?

    struct Shown: Equatable {
        let decision: AppleHeroPortraitDecision
        let image: CGImage?
        var focal: CGPoint = AppleHeroPortraitArt.focalPoint
        static func == (lhs: Shown, rhs: Shown) -> Bool {
            lhs.decision == rhs.decision && lhs.image === rhs.image && lhs.focal == rhs.focal
        }
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                Color.black
                if let shown, let image = shown.image {
                    art(shown.decision.art, image: image, size: proxy.size, focal: shown.focal)
                        .transition(.opacity)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
        .accessibilityHidden(true)
        .task(id: item.mediaID) { await settle() }
    }

    @ViewBuilder
    private func art(_ art: AppleHeroPortraitArt, image: CGImage, size: CGSize, focal: CGPoint) -> some View {
        let imageSize = CGSize(width: image.width, height: image.height)
        switch art {
        case .keyArt:
            AppleHeroCroppedImage(image: image, imageSize: imageSize, size: size)
        case .backdrop:
            AppleHeroCroppedImage(image: image, imageSize: imageSize, size: size, focal: focal,
                                  subjectAnchor: CGPoint(x: 0.5, y: 0.4))
        case .posterCard:
            ZStack {
                AppleHeroCroppedImage(image: image, imageSize: imageSize, size: size, focal: CGPoint(x: 0.5, y: 0.5))
                    .blur(radius: 40)
                    .overlay(Color.black.opacity(0.35))
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size.width * 0.6)
                    .clipShape(.rect(cornerRadius: 12))
                    .offset(y: -24)
            }
            .frame(width: size.width, height: size.height)
        case .none:
            Color.black
        }
    }

    private func settle() async {
        if let remembered = AppleHeroPortraitMemory.decision(for: item.mediaID) {
            var image: CGImage?
            if let url = remembered.art.imageURL {
                image = try? await AppleRemoteImageCache.shared.image(
                    url: url, maximumPixelDimension: AppleHeroPortraitArt.pixelDimension)
            }
            let focal = await focalPoint(for: remembered.art, image: image)
            guard !Task.isCancelled else { return }
            show(Shown(decision: remembered, image: image, focal: focal), animated: false)
            return
        }
        let tmdb = await tmdbArtwork()
        guard !Task.isCancelled else { return }
        let candidates = AppleHeroPortraitArt.Candidates(item: item, tmdbPoster: tmdb?.posterURL,
                                                         tmdbBackdrop: tmdb?.backdropURL, tmdbLogo: tmdb?.logoURL)
        var failed = Set<URL>()
        while true {
            let art = AppleHeroPortraitArt.choose(candidates, failed: failed)
            let decision = AppleHeroPortraitDecision(art: art, logo: candidates.logo)
            guard let url = art.imageURL else {
                AppleHeroPortraitMemory.remember(decision, for: item.mediaID)
                AppleHeroPortraitArtTally.record(art, item: item.name)
                show(Shown(decision: decision, image: nil), animated: false)
                return
            }
            do {
                let image = try await AppleRemoteImageCache.shared.image(
                    url: url, maximumPixelDimension: AppleHeroPortraitArt.pixelDimension)
                let focal = await focalPoint(for: art, image: image)
                guard !Task.isCancelled else { return }
                AppleHeroPortraitMemory.remember(decision, for: item.mediaID)
                AppleHeroPortraitArtTally.record(art, item: item.name)
                show(Shown(decision: decision, image: image, focal: focal), animated: true)
                return
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                appleTrace("hero portrait art failed \(art.source.rawValue), trying the next (\(item.name))")
                failed.insert(url)
            }
        }
    }

    private func tmdbArtwork() async -> AppleHeroArtworkUpgrade.Artwork? {
        guard let configuration, let imdbID = AppleHeroArtworkUpgrade.upgradeableIMDBID(for: item) else { return nil }
        return await AppleHeroArtworkUpgrade.shared.artwork(
            imdbID: imdbID, kind: item.type == "series" ? .series : .movie,
            configuration: configuration, deadline: AppleHeroPortraitMemory.lookupDeadline)
    }

    private func focalPoint(for art: AppleHeroPortraitArt, image: CGImage?) async -> CGPoint {
        guard case .backdrop(let url) = art, let image else { return AppleHeroPortraitArt.focalPoint }
        return (try? await AppleHeroFocalPoint.shared.point(image: image, url: url)) ?? CGPoint(x: 0.5, y: 0.5)
    }

    private func show(_ value: Shown, animated: Bool) {
        let duration = animated && !reduceMotion ? 0.25 : 0
        withAnimation(duration > 0 ? .easeOut(duration: duration) : nil) { shown = value }
        onReady(value.decision, value.image)
        AppleLaunchReadiness.shared.markFirstScreenReady()
    }
}

/// The hero's settled choice: its art and the wordmark that came with it.
struct AppleHeroPortraitDecision: Equatable, Sendable {
    let art: AppleHeroPortraitArt
    let logo: URL?
}

/// One answer per title per run: once shown, a hero's art never changes.
@MainActor
enum AppleHeroPortraitMemory {
    /// The longest the hero waits for TMDB before choosing from what it has.
    static let lookupDeadline: Duration = .milliseconds(1_500)
    private static var decisions: [String: AppleHeroPortraitDecision] = [:]

    static func decision(for mediaID: String) -> AppleHeroPortraitDecision? { decisions[mediaID] }
    static func remember(_ decision: AppleHeroPortraitDecision, for mediaID: String) {
        if decisions[mediaID] == nil { decisions[mediaID] = decision }
    }
}

/// An image at its aspect-fill scale, placed by `AppleHeroPortraitArt.fillRect`.
struct AppleHeroCroppedImage: View {
    let image: CGImage
    let imageSize: CGSize
    let size: CGSize
    var focal: CGPoint = AppleHeroPortraitArt.focalPoint
    var subjectAnchor: CGPoint? = nil

    var body: some View {
        let rect = AppleHeroPortraitArt.fillRect(imageSize: imageSize, in: size, focal: focal, subjectAnchor: subjectAnchor)
        Image(decorative: image, scale: 1)
            .resizable()
            .interpolation(.high)
            .frame(width: rect.width, height: rect.height)
            .offset(x: rect.minX, y: rect.minY)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .clipped()
    }
}
