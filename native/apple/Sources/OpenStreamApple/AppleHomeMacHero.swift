#if os(macOS) || os(iOS)
import SwiftUI

/// Discover's hero on the Mac, after the Apple TV app on the Mac and the Figma
/// "MacOS-OpenStream" frame (owner 2026-09-23): the art or trailer edge to edge
/// across the content from the top of the Discover area, under the toolbar
/// (`AppleMacHeroLayout`); the gentle fades (`AppleMacHeroFade`); and bottom-left in a 480 pt
/// column the wordmark (or the name in black weight), "TV Show · Comedy" with
/// the rating, the synopsis when there is room, and Resume/Play with a round
/// My List button. The carousel draws the page dots over it.
///
/// The iPad's Discover hero too (N20), under the status bar and the floating
/// tab bar, with the iPhone hero's touch-sized buttons and Dynamic Type text.
struct AppleHomeMacHero<Actions: View>: View {
    let item: AppleCatalogItem
    let layout: AppleMacHeroLayout
    let wordmark: URL?
    /// The wordmark lookup is still running (`AppleHeroTitleLockup`).
    var wordmarkLookupPending: Bool? = nil
    /// The still and the inline trailer, from `AppleHomeBillboard`.
    let stage: AnyView
    /// The still's luminance, once measured (`AppleHeroLuminanceCache`).
    var artLuminance: AppleHeroLuminanceMap? = nil
    let onOpenDetails: () -> Void
    @ViewBuilder var actions: Actions
    /// The trailer has crossfaded in over the still: a bright still's tone
    /// no longer applies.
    @State private var videoIsShowing = false

    /// Bright art under the copy deepens the fades and shadows the copy; a
    /// trailer on screen is not the still, so it draws the default fade.
    private var scrim: AppleHeroScrim {
        let region = AppleHeroCopyRegion.wide(layout)
        let frame = CGSize(width: layout.contentWidth, height: layout.height)
        // The Mac still is centred (`AppleRemoteImage.fillAlignment`); the
        // iPad's is pinned top-leading.
        let anchor = layout.platform == .mac ? CGPoint(x: 0.5, y: 0.5) : .zero
        let tone = videoIsShowing ? .unknown
            : AppleHeroArtTone(reading: artLuminance?.reading(region: region, in: frame, anchor: anchor))
        return .wide(tone: tone, videoIsShowing: videoIsShowing,
                     copyTrailing: AppleHeroCopyRegion.trailingFraction(region, in: frame))
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            stage
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                .clipped()
                .onPreferenceChange(AppleHomeHeroTrailerStateKey.self) { state in
                    videoIsShowing = state.isOnScreen
                }
                .overlay {
                    // Over the art-to-video crossfade's own 0.6 s, so a
                    // bright still's deeper fade lifts with it, not before.
                    AppleHeroScrimView(scrim: scrim)
                        .animation(.easeInOut(duration: AppleTrailerArtFirstPolicy.crossfadeDuration), value: scrim)
                }
            copy
                .frame(maxWidth: AppleMacHeroLayout.copyMaxWidth, alignment: .leading)
                .padding(.leading, layout.horizontalPadding)
                .padding(.trailing, layout.horizontalPadding)
                .padding(.bottom, layout.copyBottomPadding)
        }
        .frame(maxWidth: .infinity)
        .frame(height: layout.height)
        .clipped()
        .background(Color.black)
        .accessibilityElement(children: .contain)
    }

    private var copy: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The title block is the way into the title page, as clicking the
            // hero is in the Apple TV app.
            Button(action: onOpenDetails) {
                VStack(alignment: .leading, spacing: 0) {
                    title
                        .padding(.bottom, 8)
                    AppleMacHeroMetadata(item: item)
                        .padding(.bottom, 12)
                    if layout.showsDescription, let summary = item.summary, !summary.isEmpty {
                        Text(summary)
                            .font(AppleMacHeroType.summary)
                            .foregroundStyle(.white.opacity(0.75))
                            .lineLimit(3)
                            .frame(maxWidth: AppleMacHeroLayout.descriptionMaxWidth, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .appleHeroCopyShadow(scrim.copyShadow)
                .animation(.easeInOut(duration: 0.3), value: scrim.copyShadow)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .focusable(false)
            .accessibilityElement(children: .combine)
            .accessibilityHint("Opens the title page")
            .accessibilityIdentifier("home.featured.details")
            actions
                .padding(.top, 20)
        }
    }

    /// The wordmark, its slot held empty while it loads; the name in black
    /// weight when it fails, is slow or there is none (`AppleHeroTitlePolicy`).
    private var title: some View {
        AppleHeroTitleLockup(pageID: item.id, wordmark: wordmark,
                             wordmarkLookupPending: wordmarkLookupPending, alignment: .leading) { url, onLoadResult in
            AppleTrimmedTitleLogo(url: url, alignment: .bottomLeading, onLoadResult: onLoadResult)
                .frame(width: AppleMacHeroLayout.wordmarkSize.width, height: AppleMacHeroLayout.wordmarkSize.height, alignment: .bottomLeading)
                // Drawn larger in a taller hero, but decoded at its fixed
                // slot, so a live resize never decodes the mark again.
                .scaleEffect(layout.copyScale, anchor: .bottomLeading)
                .frame(width: layout.wordmarkDrawnSize.width, height: layout.wordmarkDrawnSize.height, alignment: .bottomLeading)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(item.name)
                .accessibilityAddTraits(.isHeader)
        } name: {
            Text(item.name)
                .font(.system(size: layout.heroTitleFontSize, weight: .black))
                .tracking(-0.02 * layout.heroTitleFontSize)
                .lineLimit(2)
                .minimumScaleFactor(0.6)
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.6), radius: 10, y: 2)
                .accessibilityLabel(item.name)
                .accessibilityAddTraits(.isHeader)
        }
    }
}

/// The Mac hero's type: the Figma's fixed sizes on the Mac, the matching
/// Dynamic Type styles on the iPad.
private enum AppleMacHeroType {
    #if os(macOS)
    static let summary = Font.system(size: 14)
    static let metadata = Font.system(size: 13)
    static let rating = Font.system(size: 11, weight: .medium)
    #else
    static let summary = Font.callout
    static let metadata = Font.subheadline
    static let rating = Font.caption.weight(.medium)
    #endif
}

#if os(macOS)
extension View {
    /// Discover's and Library's scroll views on the Mac: the hero runs under
    /// the toolbar to the window's top edge with nothing drawn over it — no
    /// toolbar backing and no scroll-edge dimming (the black strip the owner
    /// saw above the hero, 2026-09-24). The tab picker and the toolbar
    /// buttons keep their own glass, which is what keeps them readable.
    func appleMacHeroUnderToolbar() -> some View {
        modifier(AppleMacHeroUnderToolbar())
    }
}

private struct AppleMacHeroUnderToolbar: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .scrollEdgeEffectHidden(true, for: .top)
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        } else {
            content
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        }
    }
}
#endif

/// "TV Show · Comedy" and the outlined rating, left-aligned under the title.
private struct AppleMacHeroMetadata: View {
    let item: AppleCatalogItem

    var body: some View {
        let line = AppleBillboardCopy.phoneMetadataLine(type: item.type, genres: item.genres)
        let rating = AppleBillboardCopy.ratingBadge(item.contentRating)
        if line != nil || rating != nil {
            HStack(spacing: 8) {
                if let line {
                    Text(line)
                        .font(AppleMacHeroType.metadata)
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(1)
                }
                if let rating {
                    Text(rating)
                        .font(AppleMacHeroType.rating)
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .overlay {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .strokeBorder(.white.opacity(0.35), lineWidth: 1)
                        }
                        .accessibilityLabel("Rated \(rating)")
                }
            }
        }
    }
}

/// One Mac or iPad hero page's still and wordmark at the sizes the page
/// decodes them, for the carousel to warm the image caches with. Never shown.
struct AppleHomeMacHeroPreload: View {
    let item: AppleCatalogItem
    let wordmark: URL?
    let layout: AppleMacHeroLayout

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            AppleRemoteImage(url: item.backgroundURL ?? item.posterURL, placeholderSystemImage: "",
                             fixedPixelDimension: AppleMacHeroLayout.stillPixelDimension)
            if let url = wordmark {
                AppleTrimmedTitleLogo(url: url, alignment: .bottomLeading)
                    .frame(width: AppleMacHeroLayout.wordmarkSize.width,
                           height: AppleMacHeroLayout.wordmarkSize.height)
            }
        }
        .frame(width: max(layout.contentWidth, 1), height: layout.height)
        .clipped()
    }
}

#if os(macOS)
/// The Mac hero's two fades (`AppleMacHeroFade`), the same over the art and
/// the trailer.
struct AppleMacHeroFadeView: View {
    var videoIsShowing = false

    var body: some View {
        AppleHeroScrimView(scrim: .wide(tone: .unknown, videoIsShowing: videoIsShowing, copyTrailing: 0))
    }
}

/// The Mac hero's buttons, after the Apple TV app on the Mac: a white capsule
/// "▶ Resume S1, E3" / "▶ Play" and a 40 pt round My List button that turns
/// into a check once the title is saved. Same label logic and actions as the
/// iPhone hero's (`AppleHomePhoneHeroActions`).
struct AppleHomeMacHeroActions: View {
    let button: AppleTitlePagePolicy.HeroButton
    /// Nil hides the My List button: the title has nothing to save it against.
    let isInList: Bool?
    let onPlay: () -> Void
    let onToggleList: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onPlay) {
                AppleHeroPrimaryButtonLabel(button: button)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
            }
            .buttonStyle(AppleMacHeroButtonStyle(kind: .primary))
            .appleHeroPrimaryButtonState(button)
            .accessibilityIdentifier("home.featured.play")

            if let isInList {
                Button(action: onToggleList) {
                    Label(isInList ? "In My List" : "Add to My List",
                          systemImage: isInList ? "checkmark" : "plus")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: AppleMacHeroLayout.listButtonSide, height: AppleMacHeroLayout.listButtonSide)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(AppleMacHeroButtonStyle(kind: .round))
                .help(isInList ? "Remove from My List" : "Add to My List")
                .accessibilityValue(isInList ? "Saved" : "Not saved")
                .accessibilityIdentifier("home.featured.my-list")
            }
        }
    }
}

/// The round mute button top-right of the Mac hero while its trailer plays.
struct AppleMacHeroMuteButton: View {
    let isMuted: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(AppleTrailerSoundBridge.accessibilityLabel(isMuted: isMuted),
                  systemImage: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .labelStyle(.iconOnly)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: AppleMacHeroLayout.muteSide, height: AppleMacHeroLayout.muteSide)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(AppleMacHeroButtonStyle(kind: .translucentRound))
        .help(AppleTrailerSoundBridge.accessibilityLabel(isMuted: isMuted))
        .accessibilityValue(AppleTrailerSoundBridge.accessibilityValue(isMuted: isMuted))
        .accessibilityIdentifier("home.featured.mute")
    }
}

/// The Mac hero's button surfaces, with the Mac's hover and pressed states:
/// a touch brighter under the pointer, a touch darker while held.
struct AppleMacHeroButtonStyle: ButtonStyle {
    enum Kind { case primary, round, translucentRound }
    let kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        Surface(kind: kind, configuration: configuration)
    }

    private struct Surface: View {
        let kind: Kind
        let configuration: Configuration
        @State private var isHovered = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .foregroundStyle(kind == .primary ? Color(white: 0.07) : .white)
                .background { background }
                .contentShape(.capsule)
                .opacity(isEnabled ? 1 : 0.5)
                .onHover { isHovered = $0 }
                .animation(.easeOut(duration: 0.12), value: isHovered)
                .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
        }

        @ViewBuilder
        private var background: some View {
            switch kind {
            case .primary:
                Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.72 : (isHovered ? 0.88 : 1)))
            case .round:
                Circle()
                    .fill(Color.white.opacity(configuration.isPressed ? 0.28 : (isHovered ? 0.2 : 0.1)))
                    .overlay { Circle().strokeBorder(.white.opacity(0.45), lineWidth: 1.5) }
            case .translucentRound:
                Circle()
                    .fill(Color.white.opacity(configuration.isPressed ? 0.32 : (isHovered ? 0.24 : 0.15)))
                    .overlay { Circle().strokeBorder(.white.opacity(0.2), lineWidth: 1) }
            }
        }
    }
}
#endif
#endif
