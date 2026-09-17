#if os(tvOS)
import SwiftUI

// tvOS-only pieces of the Apple TV title page (FEEDBACK plan task 5). The
// page itself lives in `AppleCatalogItemDetailView.tvOSDetailLayout`; these are
// the focusable leaves it composes. Nothing here compiles on other platforms.

extension VerticalAlignment {
    private enum AppleTVControlCenter: AlignmentID {
        static func defaultValue(in context: ViewDimensions) -> CGFloat {
            context[VerticalAlignment.center]
        }
    }

    /// Lines the Play pill up with the *discs* of the icon buttons beside it,
    /// not with their whole stack.
    ///
    /// `My List` and `Rate` are a disc with a word underneath, so centring the
    /// stack against the pill put the label at the pill's middle and pushed
    /// both discs visibly above it — the owner's "these buttons are not
    /// aligned, play my list etc" (2026-09-15). This guide reports the disc's
    /// centre instead, so the row reads as one line of controls with the
    /// labels hanging below, the way the reference layout does it.
    static let appleTVControlCenter = VerticalAlignment(AppleTVControlCenter.self)
}

/// A 38 pt glyph over a Caption 2 label in a 120 pt cell. Focus turns the disc
/// behind the glyph white with a black glyph; the label stays white.
struct AppleTVDetailIconLabel: View {
    let title: String
    let systemImage: String

    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: AppleTVDetailMetrics.iconLabelSpacing) {
            // Focus is the filled disc and nothing else. The ring this used to
            // draw sat 7 pt outside an 80 pt disc with only 8 pt of room above
            // the label, so it covered the word underneath it — the owner's
            // "My List and Rate need work, Netflix does it way cleaner"
            // (2026-09-14). No ring, no glow, per the standing tvOS rules.
            Image(systemName: systemImage)
                .font(.system(size: AppleTVDetailMetrics.iconGlyphSize, weight: .medium))
                .foregroundStyle(isFocused ? Color.black : Color.white)
                .frame(width: AppleTVDetailMetrics.iconDiscSize, height: AppleTVDetailMetrics.iconDiscSize)
                .background(Color.white.opacity(isFocused ? 1 : 0.16), in: Circle())
                .scaleEffect(reduceMotion ? 1 : (isFocused ? AppleTVDetailMetrics.focusScale : 1))
            Text(title)
                .font(.system(size: AppleTVDetailMetrics.iconLabelFontSize, weight: .semibold))
                .foregroundStyle(isFocused ? Color.white : AppleDesignTokens.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(width: AppleTVDetailMetrics.iconCellWidth)
        // The disc is the first element, so its centre sits half a disc down
        // from the stack's top.
        .alignmentGuide(.appleTVControlCenter) { _ in AppleTVDetailMetrics.iconDiscSize / 2 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isFocused)
    }
}

/// Lifts a card when focused. The ring is drawn by the card around its
/// artwork only, so the name below never looks boxed.
struct AppleTVDetailCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyledBody(configuration: configuration)
    }

    private struct StyledBody: View {
        @Environment(\.isFocused) private var isFocused
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        let configuration: ButtonStyleConfiguration

        var body: some View {
            configuration.label
                .scaleEffect(reduceMotion ? 1 : (isFocused ? AppleTVDetailMetrics.focusScale : 1))
                .shadow(color: .black.opacity(isFocused ? 0.5 : 0), radius: 24, y: 12)
                .opacity(configuration.isPressed ? 0.8 : 1)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isFocused)
        }
    }
}

/// Draws only the label: tvOS's stock plain style still lifts and brightens a
/// focused button, which put a light box behind the My List and Rate discs
/// ("a box over a circle", owner 16:25). Controls that draw their own focus
/// state use this instead.
struct AppleTVBareButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

/// Rounded artwork with the focus ring the title page uses on every card.
private struct AppleTVDetailFocusRing: ViewModifier {
    @Environment(\.isFocused) private var isFocused

    func body(content: Content) -> some View {
        content
            .clipShape(RoundedRectangle(cornerRadius: AppleTVDetailMetrics.cardCornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: AppleTVDetailMetrics.cardCornerRadius, style: .continuous)
                    .stroke(.white.opacity(isFocused ? 0.95 : 0), lineWidth: AppleTVDetailMetrics.focusRingWidth)
            }
    }
}

/// A 16:9 episode card, 400x225, with the title (Body 29) and the episode's
/// number, date and runtime (Caption 1 25) under it.
struct AppleTVEpisodeCard: View {
    let episode: AppleStremioEpisode
    let subtitle: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                AppleRemoteImage(url: episode.thumbnailURL, placeholderSystemImage: "play.fill")
                    .frame(
                        width: AppleTVDetailMetrics.episodeCardSize.width,
                        height: AppleTVDetailMetrics.episodeCardSize.height
                    )
                    .background(Color.white.opacity(0.09))
                    .modifier(AppleTVDetailFocusRing())
                Text(episode.title.isEmpty ? episode.displayTitle : episode.title)
                    .font(.system(size: AppleTVDetailMetrics.episodeTitleFontSize, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: AppleTVDetailMetrics.episodeSubtitleFontSize))
                    .foregroundStyle(AppleDesignTokens.textSecondary)
                    .lineLimit(1)
            }
            .frame(width: AppleTVDetailMetrics.episodeCardSize.width, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(AppleTVDetailCardStyle())
        .accessibilityLabel("Play \(episode.displayTitle)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A 260x390 poster with a Caption 1 name for the More Like This shelf.
struct AppleTVPosterCard: View {
    let item: AppleCatalogItem

    @Environment(\.appleTMDBConfiguration) private var metadataConfiguration
    @State private var fallbackArtwork: AppleArtworkResolver.Artwork?

    private var posterURL: URL? {
        item.posterURL ?? fallbackArtwork?.posterURL ?? item.backgroundURL
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AppleCatalogArtwork(url: posterURL)
                .frame(width: AppleTVDetailMetrics.posterSize.width, height: AppleTVDetailMetrics.posterSize.height)
                .modifier(AppleTVDetailFocusRing())
                .task(id: item.id) {
                    guard item.posterURL == nil else { return }
                    fallbackArtwork = await AppleArtworkResolver.shared.resolve(
                        mediaID: item.mediaID,
                        type: item.type,
                        existingPosterURL: item.posterURL,
                        existingBackgroundURL: item.backgroundURL,
                        configuration: metadataConfiguration
                    )
                }
            Text(item.name)
                .font(.system(size: AppleTVDetailMetrics.posterNameFontSize, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .frame(width: AppleTVDetailMetrics.posterSize.width, alignment: .leading)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.name)
        .accessibilityValue(item.releaseInfo ?? "")
    }
}

/// The synopsis, as plain text. It used to be a focus stop that drew a grey
/// tile behind itself when focused — the box in the owner's capture
/// (2026-09-14, "clean up the description a bit"). A paragraph is not a
/// control: there is nothing to do with it, so it takes no focus and draws no
/// container, and Down from Play goes to the episodes like the reference apps.
struct AppleTVFocusableParagraph: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: AppleTVDetailMetrics.synopsisFontSize))
            .foregroundStyle(.white)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: AppleTVDetailMetrics.synopsisColumnWidth, alignment: .leading)
    }
}

/// Headline 38 shelf title at the safe-zone inset.
struct AppleTVShelfTitle: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: AppleTVDetailMetrics.shelfTitleFontSize, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, AppleTVDetailMetrics.overlayLeadingInset)
            .accessibilityAddTraits(.isHeader)
    }
}
#endif
