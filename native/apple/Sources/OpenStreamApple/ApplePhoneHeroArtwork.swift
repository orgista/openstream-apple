import SwiftUI

/// Shared by the iPhone landing hero and title page; a decoded still stays up during an upgrade.
struct ApplePhoneHeroArtwork: View {
    let art: AppleTitlePageSlotArt?
    var cachedArt: (art: AppleTitlePageSlotArt, image: CGImage)? = nil
    var isReadyForLoadResult = true
    var onLoad: (CGImage, AppleTitlePageSlotArt) -> Void = { _, _ in }
    var onPlaceholder: ((CGImage, AppleTitlePageSlotArt) -> Void)? = nil
    var onFailure: (AppleTitlePageSlotArt) -> Void = { _ in }

    @State private var displayed: AppleTitlePageSlotArt?
    @State private var image: CGImage?
    @State private var reportedArt: AppleTitlePageSlotArt?
    @State private var reportedImage: CGImage?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                if let image, let displayed {
                    AppleTitlePageDecodedSlotImage(image: image, art: displayed,
                        slotHeight: AppleTitlePageSlotArt.slotHeight(width: geometry.size.width))
                } else if let placeholder {
                    AppleTitlePageDecodedSlotImage(image: placeholder.image, art: placeholder.art,
                        slotHeight: AppleTitlePageSlotArt.slotHeight(width: geometry.size.width))
                        .onAppear { showPlaceholder(placeholder) }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .accessibilityHidden(true)
        .task(id: art) { await load() }
        .onChange(of: isReadyForLoadResult) { reportLoadedImage() }
    }

    private var placeholder: (art: AppleTitlePageSlotArt, image: CGImage)? {
        if let art, let image = AppleRemoteImageCache.shared.cachedPlaceholderImage(url: art.url) {
            return (art, image)
        }
        return cachedArt
    }

    private func showPlaceholder(_ placeholder: (art: AppleTitlePageSlotArt, image: CGImage)) {
        guard image == nil else { return }
        displayed = placeholder.art
        image = placeholder.image
        if let onPlaceholder {
            onPlaceholder(placeholder.image, placeholder.art)
        } else {
            reportLoadedImage()
        }
    }

    private func reportLoadedImage() {
        guard isReadyForLoadResult, let image, let displayed,
              reportedArt != displayed || reportedImage !== image else { return }
        reportedArt = displayed
        reportedImage = image
        onLoad(image, displayed)
    }

    private func load() async {
        guard let art else { return }
        do {
            let decoded = try await AppleRemoteImageCache.shared.image(
                url: art.url, maximumPixelDimension: AppleHeroPortraitArt.pixelDimension, priority: .foreground)
            guard !Task.isCancelled else { return }
            displayed = art
            image = decoded
            reportLoadedImage()
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            onFailure(art)
        }
    }
}
