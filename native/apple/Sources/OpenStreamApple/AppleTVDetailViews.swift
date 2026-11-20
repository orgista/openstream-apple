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

/// Slides a card's name down while the card is focused, so the lifted art
/// (`appleTVCardArtworkFocus`) never covers it, as the Apple TV app does.
struct AppleTVCardCaptionFocus: ViewModifier {
    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .offset(y: isFocused ? AppleTVDetailMetrics.cardCaptionFocusDrop : 0)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: isFocused)
    }
}

/// A poster's title that appears under it only while it is focused, dropping
/// clear of the lifted art like `AppleTVCardCaptionFocus`.
struct AppleTVFocusedCaption: ViewModifier {
    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(isFocused ? 1 : 0)
            .offset(y: isFocused ? AppleTVDetailMetrics.cardCaptionFocusDrop : 0)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: isFocused)
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

/// A 16:9 episode card, 400x225, with the title (Body 29) and the episode's
/// number, date and runtime (Caption 1 25) under it, and a tick on the still
/// once watched. An episode with no still, or one that fails, shows the
/// show's backdrop rather than a grey box (`AppleEpisodeStillPolicy`, as on
/// the other platforms).
struct AppleTVEpisodeCard: View {
    let episode: AppleMediaEpisode
    let subtitle: String
    let isSelected: Bool
    let isWatched: Bool
    let seriesBackdropURL: URL?
    let action: () -> Void

    @State private var stillFailed = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                AppleRemoteImage(url: AppleEpisodeStillPolicy.url(still: episode.thumbnailURL, stillFailed: stillFailed,
                                                                  seriesBackdrop: seriesBackdropURL),
                                 placeholderSystemImage: "play.fill",
                                 onFailure: { stillFailed = true })
                    .onChange(of: episode.thumbnailURL) { stillFailed = false }
                    .frame(
                        width: AppleTVDetailMetrics.episodeCardSize.width,
                        height: AppleTVDetailMetrics.episodeCardSize.height
                    )
                    .background(Color.white.opacity(0.09))
                    .overlay(alignment: .bottomTrailing) {
                        if isWatched {
                            Image(systemName: "checkmark.circle.fill")
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.black, .white)
                                .font(.system(size: 36))
                                .padding(14)
                        }
                    }
                    .appleTVCardArtworkFocus(cornerRadius: AppleTVDetailMetrics.cardCornerRadius)
                VStack(alignment: .leading, spacing: 12) {
                    Text(episode.title.isEmpty ? episode.displayTitle : episode.title)
                        .font(.system(size: AppleTVDetailMetrics.episodeTitleFontSize, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: AppleTVDetailMetrics.episodeSubtitleFontSize))
                        .foregroundStyle(AppleDesignTokens.textSecondary)
                        .lineLimit(1)
                }
                .modifier(AppleTVCardCaptionFocus())
            }
            .frame(width: AppleTVDetailMetrics.episodeCardSize.width, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Play \(episode.displayTitle)")
        .accessibilityValue(isWatched ? "Watched" : "")
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
                .overlay(alignment: .topLeading) {
                    if AppleDiscCatalog.shared.contains(item) { AppleDiscBadge() }
                }
                .appleTVCardArtworkFocus(cornerRadius: AppleTVDetailMetrics.cardCornerRadius)
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
                .modifier(AppleTVCardCaptionFocus())
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.name)
        .accessibilityValue(item.releaseInfo ?? "")
    }
}

/// The synopsis, as plain text with no tile behind it: a grey box when
/// focused was the owner's "clean up the description a bit" (2026-09-14).
/// On a movie page it is a focus stop, dimmed at rest and full white when
/// focused: focus moves geometrically, so a page with nothing focusable
/// under the title row could never scroll and the synopsis sat below the
/// screen (build 20 B4: Rampage, y = 1062 of 1080). A series page has
/// Episodes there, and Down from Play goes straight to them (owner
/// 2026-09-14), so `isFocusable` is false.
struct AppleTVFocusableParagraph: View {
    let text: String
    var isFocusable = true
    @FocusState private var isFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Text(text)
            .font(.system(size: AppleTVDetailMetrics.synopsisFontSize))
            .foregroundStyle(.white.opacity(isFocused || !isFocusable ? 1 : AppleTVDetailMetrics.synopsisRestingOpacity))
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: AppleTVDetailMetrics.synopsisColumnWidth, alignment: .leading)
            .focusable(isFocusable)
            .focusEffectDisabled()
            .focused($isFocused)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: isFocused)
            .accessibilityIdentifier("detail.synopsis")
    }
}

/// One person on the Cast & Crew row: the shared portrait, lifted while
/// focused. Nothing opens from it; it is a focus stop so the remote can walk
/// the row and the page scrolls to it.
struct AppleTVCreditCard: View {
    let person: AppleCreditPerson
    @FocusState private var isFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        AppleTitlePageCreditPortrait(person: person, side: AppleTVDetailMetrics.creditPortraitSide)
            .scaleEffect(isFocused ? AppleTVDetailMetrics.creditFocusScale : 1)
            .focusable()
            .focusEffectDisabled()
            .focused($isFocused)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: isFocused)
            .accessibilityLabel([person.name, person.role].compactMap(\.self).joined(separator: ", "))
            .accessibilityIdentifier("detail.cast.person")
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
