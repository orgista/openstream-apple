import SwiftUI

struct AppleMediaShelf<Content: View>: View {
    let title: String
    /// Optional control on the header line's trailing end (the Library's
    /// Sort menu on tvOS), so nothing has to float over the billboard.
    var accessory: AnyView? = nil
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: titleSpacing) {
            HStack(alignment: .center) {
                Text(title).font(titleFont).accessibilityAddTraits(.isHeader)
                if let accessory {
                    Spacer(minLength: 16)
                    accessory
                }
            }
            .padding(.horizontal, horizontalInset)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: cardGap, content: content)
                    .padding(.horizontal, horizontalInset).padding(.vertical, verticalBleed)
            }.scrollIndicators(AppleDesignTokens.scrollIndicatorVisibility)
        }.appleCatalogFocusSection()
    }

    // tvOS rows: a Title 3 header on the copy column, 24 pt card gaps and room
    // for the 1.06x focus lift (FEEDBACK X5). Other platforms are unchanged.
    #if os(tvOS)
    private var titleFont: Font { .system(size: AppleTVBillboardMetrics.rowTitleFontSize, weight: .semibold) }
    private var titleSpacing: CGFloat { AppleTVBillboardMetrics.rowTitleSpacing }
    private var horizontalInset: CGFloat { AppleTVBillboardMetrics.rowHorizontalInset }
    private var cardGap: CGFloat { AppleTVBillboardMetrics.cardGap }
    private var verticalBleed: CGFloat { AppleTVBillboardMetrics.rowVerticalBleed }
    #else
    private var titleFont: Font { .system(size: 17, weight: .semibold) }
    private var titleSpacing: CGFloat { 12 }
    private var horizontalInset: CGFloat { 16 }
    private var cardGap: CGFloat { 8 }
    private var verticalBleed: CGFloat { 4 }
    #endif
}

struct AppleFeaturedHero<Actions: View>: View {
    let item: AppleCatalogItem
    let viewportSize: CGSize
    /// The title's wordmark, when known. tvOS only; the other platforms' hero
    /// draws its own copy block.
    var wordmark: URL? = nil
    /// Passed straight to the tvOS billboard's rotation indicator; the other
    /// platforms' hero does not cycle.
    var rotationCount: Int = 0
    var rotationIndex: Int = 0
    @ViewBuilder var actions: Actions
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    var body: some View {
        #if os(tvOS)
        AppleTVBillboard(item: item, wordmark: wordmark, rotationCount: rotationCount, rotationIndex: rotationIndex) { actions }
        #else
        legacyHero
        #endif
    }

    #if !os(tvOS)
    private var legacyHero: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 0) {
                    AppleCatalogArtwork(url: item.backgroundURL ?? item.posterURL)
                        .frame(maxWidth: .infinity)
                        .frame(height: 220)
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
                    }
                    .padding(20)
                }
                .background(Color(white: 0.10))
            } else {
                ZStack(alignment: .bottomLeading) {
                    AppleCatalogArtwork(url: item.backgroundURL ?? item.posterURL)
                        .frame(maxWidth: .infinity)
                        .frame(height: featuredHeight)
                        .clipped()
                    // The same single bottom-to-black fade the owner approved
                    // for the Apple TV billboard (X2), for the same reason: a
                    // 6 pt text shadow is not enough over bright busy art, and
                    // "Remarkably Bright Creatures" over a lit aquarium was
                    // unreadable on iPad (2026-09-15). One fade, nowhere else.
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.85)],
                        startPoint: .init(x: 0.5, y: AppleTVBillboardMetrics.fadeStartFraction),
                        endPoint: .bottom
                    )
                    .frame(height: featuredHeight)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 10) {
                        Text(item.name)
                            .font(.largeTitle.bold())
                            .lineLimit(2)
                            .shadow(color: .black.opacity(0.6), radius: 6, y: 1)
                            .accessibilityAddTraits(.isHeader)
                        if let summary = item.summary, !summary.isEmpty {
                            Text(summary)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .frame(maxWidth: 700, alignment: .leading)
                                .shadow(color: .black.opacity(0.6), radius: 6, y: 1)
                        }
                        actions
                    }
                    .padding(24)
                }
            }
        }
        .clipShape(.rect(cornerRadius: 18))
        .accessibilityElement(children: .contain)
    }

    private var featuredHeight: CGFloat {
        #if os(visionOS)
        min(max(viewportSize.height * 0.50, 280), (max(viewportSize.width, 760) - 32) * 9 / 16)
        #else
        AppleDetailMetrics.featuredHeroHeight(in: viewportSize)
        #endif
    }
    #endif

}

struct AppleFeaturedActions<Play: View, Detail: View>: View {
    let viewportSize: CGSize
    /// Landscape on any device, so the phone keeps the fixed-size pills too.
    private var isLandscapeLayout: Bool {
        #if os(visionOS) || os(iOS)
        AppleDetailMetrics.isLandscapeLayout(viewport: viewportSize)
        #else
        false
        #endif
    }
    @ViewBuilder var playDestination: Play
    @ViewBuilder var detailDestination: Detail
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var body: some View {
        #if os(tvOS)
        AppleTVBillboardActions { playDestination } detailDestination: { detailDestination }
        #else
        legacyBody
        #endif
    }

    #if !os(tvOS)
    @ViewBuilder
    private var legacyBody: some View {
        if isLandscapeLayout {
            HStack(spacing: AppleDetailMetrics.actionButtonGap) {
                NavigationLink { playDestination } label: {
                    AppleDetailActionButtonLabel(title: "Play", glyph: .systemImage("play.fill"), kind: .play,
                                                width: AppleDetailMetrics.landscapeIPadActionButtonWidth)
                }
                .accessibilityIdentifier("home.featured.play")
                NavigationLink { detailDestination } label: {
                    AppleDetailActionButtonLabel(title: "Details", glyph: .systemImage("info.circle"), kind: .download,
                                                width: AppleDetailMetrics.landscapeIPadActionButtonWidth)
                }
                .accessibilityIdentifier("home.featured.details")
            }
            .buttonStyle(.plain)
        } else {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 12))
            : AnyLayout(HStackLayout(spacing: 12))
        // `nil` on the phone, where filling half the column is the right pill;
        // a fixed width on a tablet in portrait, where it was not.
        let buttonWidth = AppleDetailMetrics
            .featuredActionButtonWidth(portraitViewportWidth: viewportSize.width) ?? .infinity
        layout {
            NavigationLink {
                playDestination
            } label: {
                Label("Play", systemImage: "play.fill")
                    .frame(maxWidth: buttonWidth)
            }
            .buttonStyle(.brandPrimary)
            .accessibilityIdentifier("home.featured.play")

            NavigationLink {
                detailDestination
            } label: {
                Label("Details", systemImage: "info.circle")
                    .frame(maxWidth: buttonWidth)
            }
            .buttonStyle(.brandSecondary)
            .accessibilityIdentifier("home.featured.details")
        }
        .controlSize(.large)
        .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    #endif

}
