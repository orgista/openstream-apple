import SwiftUI

struct AppleMediaShelf<Content: View>: View {
    let title: String
    /// Optional control on the header line's trailing end (the Library's
    /// Sort menu on tvOS), so nothing has to float over the billboard.
    var accessory: AnyView? = nil
    var onOpen: (() -> Void)? = nil
    var header: AnyView? = nil
    var headingIdentifier: String = ""
    @ViewBuilder var content: () -> Content
    @Environment(\.appleDiscoverRows) private var rowStyle
    #if DEBUG
    @State private var reviewScrollPosition = ScrollPosition()
    #endif
    var body: some View {
        VStack(alignment: .leading, spacing: titleSpacing) {
            HStack(alignment: .center) {
                if let header {
                    header
                } else if let onOpen {
                    Button(action: onOpen) {
                        AppleShelfHeading(title: title)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier(headingIdentifier)
                } else {
                    Text(title).font(titleFont).accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier(headingIdentifier)
                }
                if let accessory {
                    Spacer(minLength: 16)
                    accessory
                }
            }
            .padding(.horizontal, horizontalInset)
            #if os(macOS)
            if rowStyle?.platform == .mac {
                macRail
            } else {
                railScrollView
            }
            #else
            railScrollView
            #endif
        }.appleCatalogFocusSection()
    }

    private var rail: some View {
        LazyHStack(alignment: .top, spacing: cardGap, content: content)
            .appleShelfSnapTargets()
            #if os(iOS)
            // The inset is the scroll view's content margin on iOS, where
            // the tiles snap to it (`AppleShelfSnapping`).
            .padding(.vertical, verticalBleed)
            #else
            .padding(.horizontal, horizontalInset).padding(.vertical, verticalBleed)
            #endif
    }

    #if os(macOS)
    /// The Mac rail, told how many tiles it has so its ‹ › buttons can page
    /// by whole tiles (`AppleRailPaging.tilePitch`).
    private var macRail: some View {
        Group(subviews: content()) { tiles in
            AppleMacRail(tileCount: tiles.count, inset: horizontalInset, gap: cardGap) {
                LazyHStack(alignment: .top, spacing: cardGap) {
                    ForEach(tiles) { $0 }
                }
                .padding(.horizontal, horizontalInset).padding(.vertical, verticalBleed)
            }
        }
    }
    #endif

    private var railScrollView: some View {
        ScrollView(.horizontal) {
            rail
        }
        #if os(iOS)
        .contentMargins(.horizontal, horizontalInset, for: .scrollContent)
        #endif
        .appleShelfTileSnapping()
        .scrollIndicators(.never)
        #if DEBUG
        .scrollPosition($reviewScrollPosition)
        .task {
            // Headless artwork review; launch arguments never change saved preferences.
            guard UserDefaults.standard.string(forKey: "OpenStreamReviewShelf") == title else { return }
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            reviewScrollPosition.scrollTo(x: UserDefaults.standard.double(forKey: "OpenStreamReviewShelfX"))
        }
        #endif
    }

    // tvOS retains its safe-area gutter and room for the focus lift.
    #if os(tvOS)
    private var titleFont: Font { .system(size: AppleTVBillboardMetrics.rowTitleFontSize, weight: .bold) }
    private var titleSpacing: CGFloat { AppleTVBillboardMetrics.rowTitleSpacing }
    private var horizontalInset: CGFloat { AppleTVBillboardMetrics.rowHorizontalInset }
    private var cardGap: CGFloat { AppleTVBillboardMetrics.cardGap }
    private var verticalBleed: CGFloat { AppleTVBillboardMetrics.rowVerticalBleed }
    #else
    // Discover on the iPhone (N11) and the Mac (N13): the row style's header
    // and card gap, per the Figma; the trailing tile stays clipped (A11),
    // and on iOS a flick lands a whole tile on the inset (N65). The Mac's
    // rails start under the hero copy and leave room above and below for the
    // hover lift.
    private var titleFont: Font { rowStyle?.headerFont ?? .title.bold() }
    private var titleSpacing: CGFloat { rowStyle?.headerSpacing ?? 12 }
    private var horizontalInset: CGFloat { rowStyle?.horizontalInset ?? 16 }
    private var cardGap: CGFloat { rowStyle?.cardGap ?? 8 }
    private var verticalBleed: CGFloat { rowStyle?.platform == .mac ? 12 : 4 }
    #endif
}

struct AppleFeaturedHero<Actions: View>: View {
    let item: AppleCatalogItem
    let viewportSize: CGSize
    /// The title's wordmark, when the preview-assets cache has one. Every
    /// platform's hero uses it: the lockup over the art is the shape the owner
    /// asked for on the iPad as well as the Apple TV (2026-09-18 references).
    var wordmark: URL? = nil
    /// The wordmark lookup is still running (`AppleHeroTitleLockup`).
    var wordmarkLookupPending: Bool? = nil
    /// How many heroes the screen rotates through, and which is showing. One
    /// (or fewer) draws no indicator: there is nothing to cycle to.
    var rotationCount: Int = 0
    var rotationIndex: Int = 0
    /// What fills the art frame. Discover passes a stage that can swap the
    /// still for an inline trailer; Library passes nothing and gets the still.
    /// Either way the frame, the one fade and the copy block are the same.
    var stage: AnyView? = nil
    /// The stage's still, measured by `AppleHomeBillboard`. With no stage the
    /// hero measures the still it draws itself.
    var artLuminance: AppleHeroLuminanceMap? = nil
    @ViewBuilder var actions: Actions
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    var body: some View {
        #if os(tvOS)
        AppleTVBillboard(item: item, wordmark: wordmark, rotationCount: rotationCount,
                         rotationIndex: rotationIndex, stage: stage, artLuminance: artLuminance) { actions }
        #else
        legacyHero
        #endif
    }

    #if !os(tvOS)
    @State private var loadedStill: AppleHeroLoadedStill?
    @State private var artMeasurement: AppleHeroArtMeasurement?

    private var stillURL: URL? { item.backgroundURL ?? item.posterURL }

    /// Over bright art under the copy, a fade sized to the copy block from
    /// the leading edge, a deeper bottom one and a shadow under the text.
    private var scrim: AppleHeroScrim {
        let map = artLuminance ?? AppleHeroArtMeasurement.map(artMeasurement, for: stillURL)
        let frame = CGSize(width: max(viewportSize.width - 32, 0), height: featuredHeight)
        let region = AppleHeroCopyRegion.featured(frame: frame, copyWidth: min(700, copyColumnWidth))
        return .featured(tone: AppleHeroArtTone(reading: map?.reading(region: region, in: frame)),
                         copyTrailing: AppleHeroCopyRegion.trailingFraction(region, in: frame))
    }

    private var legacyHero: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 0) {
                    art
                        .frame(maxWidth: .infinity)
                        .frame(height: AppleFeaturedHeroMetrics.accessibilityArtHeight)
                        .clipped()

                    VStack(alignment: .leading, spacing: 14) {
                        Text(item.name)
                            .font(.title2.bold())
                            .fixedSize(horizontal: false, vertical: true)
                            .shadow(color: .black.opacity(0.6), radius: 6, y: 1)
                            .accessibilityAddTraits(.isHeader)
                        if let summary = item.summary, !summary.isEmpty {
                            Text(summary)
                                .foregroundStyle(.secondary)
                                .lineLimit(AppleHeroSummaryLineLimit.lines(for: dynamicTypeSize))
                                .fixedSize(horizontal: false, vertical: true)
                                .shadow(color: .black.opacity(0.6), radius: 6, y: 1)
                        }
                        actions
                        pageIndicator
                    }
                    .padding(20)
                }
                .background(Color(white: 0.10))
            } else {
                // The copy is an overlay on the art, not a sibling in a ZStack:
                // an overlay is offered its host's size and can never widen it.
                art
                    .frame(maxWidth: .infinity)
                    .frame(height: featuredHeight)
                    .clipped()
                    // The same single bottom-to-black fade the owner approved
                    // for the Apple TV billboard (X2), for the same reason: a
                    // 6 pt text shadow is not enough over bright busy art, and
                    // "Remarkably Bright Creatures" over a lit aquarium was
                    // unreadable on iPad (2026-09-15). One fade, nowhere else.
                    //
                    // Over bright art it deepens and gains a leading fade
                    // sized to the copy (N20, `AppleHeroScrim.featured`).
                    .overlay {
                        AppleHeroScrimView(scrim: scrim)
                            .animation(.easeInOut(duration: 0.4), value: scrim)
                    }
                    .overlay(alignment: .bottomLeading) {
                        VStack(alignment: .leading, spacing: 10) {
                            VStack(alignment: .leading, spacing: 10) {
                                titleTreatment
                                if let metadataLine {
                                    Text(metadataLine)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(.white.opacity(0.75))
                                        .lineLimit(1)
                                        .shadow(color: .black.opacity(0.6), radius: 6, y: 1)
                                }
                                if let summary = item.summary, !summary.isEmpty {
                                    // White at 90 %, the same as the Apple TV
                                    // billboard, not `.secondary`: a hierarchical
                                    // grey over bright art disappears, and "TOXIC"
                                    // sits on a white backdrop (2026-09-20). The fade
                                    // covers the bottom of the frame, and over
                                    // bright art the copy's side too (N20).
                                    Text(summary)
                                        .foregroundStyle(.white.opacity(0.9))
                                        .lineLimit(2)
                                        .frame(maxWidth: min(700, copyColumnWidth), alignment: .leading)
                                        .shadow(color: .black.opacity(0.6), radius: 6, y: 1)
                                }
                            }
                            .appleHeroCopyShadow(scrim.copyShadow)
                            actions
                            pageIndicator
                        }
                        // Measured, not inferred. A `maxWidth` only clamps when
                        // the proposal is finite, and the copy column inside the
                        // hero was being sized against an unbounded proposal:
                        // the synopsis took its full 700 pt on a 393 pt iPhone
                        // and pushed Details past the right edge (2026-09-20).
                        // The hero's own width is known, so use it.
                        .frame(width: copyColumnWidth, alignment: .leading)
                        .padding(24)
                    }
            }
        }
        .clipShape(.rect(cornerRadius: 18))
        .appleMeasuresHeroArt(stage == nil ? loadedStill : nil) { artMeasurement = $0 }
        .accessibilityElement(children: .contain)
    }

    /// The inline trailer when Discover supplies one, otherwise the still.
    @ViewBuilder
    private var art: some View {
        if let stage {
            stage
        } else {
            AppleCatalogArtwork(url: stillURL, onImageLoad: { [stillURL] image in
                if let stillURL { loadedStill = AppleHeroLoadedStill(url: stillURL, image: image) }
            })
        }
    }

    /// The wordmark lockup when it has drawn, otherwise the name — never
    /// nothing, as on the Apple TV billboard (`AppleHeroTitlePolicy`).
    private var titleTreatment: some View {
        AppleHeroTitleLockup(pageID: item.id, wordmark: wordmark, wordmarkLookupPending: wordmarkLookupPending) { url, onLoadResult in
            // A definite height, not `maxHeight`: the wordmark is drawn inside
            // a GeometryReader, and in a scroll view an upper bound leaves the
            // height proposal unresolved, which collapsed the mark to a few
            // illegible points (2026-09-20).
            AppleTrimmedTitleLogo(url: url, alignment: .leading, onLoadResult: onLoadResult)
                // One view per wordmark: the logo view keeps its image while a
                // new URL loads, which left the last title's mark over the next
                // title's copy (iPad, 2026-09-22) — as on the Apple TV.
                .id(url)
                .frame(maxWidth: wordmarkWidth, alignment: .leading)
                .frame(height: wordmarkHeight)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(item.name)
                .accessibilityAddTraits(.isHeader)
        } name: {
            Text(item.name)
                .font(.largeTitle.bold())
                .lineLimit(2)
                .shadow(color: .black.opacity(0.6), radius: 6, y: 1)
                .accessibilityAddTraits(.isHeader)
        }
    }

    @ViewBuilder
    private var pageIndicator: some View {
        if rotationCount > 1 {
            AppleHomeHeroPageIndicator(count: rotationCount, index: rotationIndex)
                .padding(.top, 2)
        }
    }

    private var metadataLine: String? {
        AppleBillboardCopy.metadataLine(genres: item.genres, year: item.year, releaseInfo: item.releaseInfo)
    }

    private var wordmarkWidth: CGFloat {
        AppleFeaturedHeroMetrics.wordmarkSize(viewport: viewportSize).width
    }

    private var copyColumnWidth: CGFloat {
        AppleFeaturedHeroMetrics.copyColumnWidth(viewport: viewportSize)
    }

    private var wordmarkHeight: CGFloat {
        AppleFeaturedHeroMetrics.wordmarkSize(viewport: viewportSize).height
    }

    private var featuredHeight: CGFloat {
        AppleFeaturedHeroMetrics.artHeight(viewport: viewportSize)
    }
    #endif

}

struct AppleFeaturedActions: View {
    let viewportSize: CGSize
    let button: AppleTitlePagePolicy.HeroButton
    /// Landscape on any device, so the phone keeps the fixed-size pills too.
    private var isLandscapeLayout: Bool {
        #if os(visionOS) || os(iOS)
        AppleDetailMetrics.isLandscapeLayout(viewport: viewportSize)
        #else
        false
        #endif
    }
    let onPlay: () -> Void
    let onDetails: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var body: some View {
        #if os(tvOS)
        AppleTVBillboardActions(button: button, onPlay: onPlay, onDetails: onDetails)
        #else
        legacyBody
        #endif
    }

    #if !os(tvOS)
    /// The primary button already is Details when nothing plays.
    private var showsDetailsButton: Bool { button.action != .details }

    @ViewBuilder
    private var legacyBody: some View {
        if isLandscapeLayout {
            HStack(spacing: AppleDetailMetrics.actionButtonGap) {
                Button(action: onPlay) {
                    AppleDetailActionButtonLabel(title: button.title,
                                                glyph: .systemImage(button.systemImage),
                                                kind: .play,
                                                width: AppleDetailMetrics.landscapeIPadActionButtonWidth)
                }
                .appleHeroPrimaryButtonState(button)
                .accessibilityIdentifier("home.featured.play")
                if showsDetailsButton {
                    Button(action: onDetails) {
                        AppleDetailActionButtonLabel(title: "Details", glyph: .systemImage("info.circle"), kind: .download,
                                                    width: AppleDetailMetrics.landscapeIPadActionButtonWidth)
                    }
                    .accessibilityIdentifier("home.featured.details")
                }
            }
            .buttonStyle(.plain)
        } else {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 12))
            : AnyLayout(HStackLayout(spacing: 12))
        let buttonWidth = Self.buttonMaxWidth(portraitViewportWidth: viewportSize.width,
                                              isAccessibilitySize: dynamicTypeSize.isAccessibilitySize)
        layout {
            Button(action: onPlay) {
                AppleHeroPrimaryButtonLabel(button: button)
                    .frame(maxWidth: buttonWidth)
            }
            .buttonStyle(.brandPrimary)
            .appleHeroPrimaryButtonState(button)
            .accessibilityIdentifier("home.featured.play")

            if showsDetailsButton {
                Button(action: onDetails) {
                    Label("Details", systemImage: "info.circle")
                        .frame(maxWidth: buttonWidth)
                }
                .buttonStyle(.brandSecondary)
                .accessibilityIdentifier("home.featured.details")
            }
        }
        .controlSize(.large)
        .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The widest a portrait hero button may grow. Unbounded on the phone,
    /// where filling half the column is the right pill; a fixed width on a
    /// tablet, where it was not — except at the accessibility sizes, where
    /// the buttons are stacked and the fixed width broke "Resume" and
    /// "Details" in the middle of the word (N49, iPad at AX XL).
    static func buttonMaxWidth(portraitViewportWidth width: CGFloat, isAccessibilitySize: Bool) -> CGFloat {
        guard !isAccessibilitySize else { return .infinity }
        return AppleDetailMetrics.featuredActionButtonWidth(portraitViewportWidth: width) ?? .infinity
    }
    #endif

}
