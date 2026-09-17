#if os(tvOS)
import SwiftUI

/// The Apple TV home hero: full-bleed art, the app's one fade, copy anchored
/// bottom-leading, content-sized pills. Discover and Library both reach it
/// through `AppleFeaturedHero`. Numbers come from `AppleTVBillboardMetrics`.
struct AppleTVBillboard<Actions: View>: View {
    let item: AppleCatalogItem
    /// The title's wordmark art, when the preview-assets cache has it. The
    /// billboard used to have no way to show one at all.
    var wordmark: URL? = nil
    /// How many billboards the screen rotates through, and which is showing.
    /// One (or fewer) draws no indicator: there is nothing to cycle to.
    var rotationCount: Int = 0
    var rotationIndex: Int = 0
    @ViewBuilder var actions: Actions

    private typealias M = AppleTVBillboardMetrics

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            AppleCatalogArtwork(
                url: item.backgroundURL ?? item.posterURL,
                loadingFill: AppleDesignTokens.surface
            )
                .frame(width: M.screenSize.width, height: M.artHeight)
                .clipped()
                .overlay {
                    if M.usesFade {
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: M.fadeStartFraction),
                                .init(color: .black, location: 1)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
                }
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: M.copySpacing) {
                titleTreatment
                if let metadataLine {
                    Text(metadataLine)
                        .font(.system(size: M.metadataFontSize, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                }
                if let summary = item.summary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
                    Text(summary)
                        .font(.system(size: M.synopsisFontSize))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(M.synopsisLineLimit)
                        .truncationMode(.tail)
                }
                actions
                    .padding(.top, 8)
                if rotationCount > 1 {
                    AppleTVHeroRotationIndicator(count: rotationCount, index: rotationIndex)
                        .padding(.top, 4)
                }
            }
            .frame(width: M.copyColumnWidth, alignment: .leading)
            .padding(.leading, M.copyLeadingInset)
            .padding(.bottom, M.copyBottomInset)
        }
        .frame(width: M.screenSize.width, height: M.artHeight, alignment: .bottomLeading)
        .background(Color.black)
        .padding(.bottom, -M.rowOverlap)
        .focusSection()
        .accessibilityElement(children: .contain)
    }

    /// The wordmark, the name, or nothing — see `AppleTVBillboardTitleTreatment`.
    @ViewBuilder
    private var titleTreatment: some View {
        switch AppleTVBillboardTitleTreatment.choose(
            hasBackdrop: item.backgroundURL != nil,
            wordmark: wordmark
        ) {
        case .wordmark(let url):
            AppleTrimmedTitleLogo(url: url, alignment: .leading) { _ in }
                .frame(maxWidth: M.copyColumnWidth * 0.62, maxHeight: M.titleFontSize * 2.2, alignment: .leading)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(item.name)
                .accessibilityAddTraits(.isHeader)
        case .text:
            Text(item.name)
                .font(.system(size: M.titleFontSize, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(M.titleLineLimit)
                .accessibilityAddTraits(.isHeader)
        case .none:
            // The poster already carries the title; a second copy is noise.
            EmptyView()
        }
    }

    /// "Action · Comedy · 2024" from the item's own fields; nothing when it has
    /// none, so the block never shows a lonely separator.
    private var metadataLine: String? {
        var parts: [String] = []
        if let genres = item.genres {
            parts += genres.prefix(2)
        }
        if let year = item.year {
            parts.append(String(year))
        } else if let release = item.releaseInfo, !release.isEmpty {
            parts.append(release)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// One segment per billboard, the current one filling over the rotation
/// interval so the change is visibly coming rather than arriving unannounced.
///
/// The fill is a local animation rather than a fast `TimelineView`: the
/// billboard's timeline ticks once per interval on purpose, and re-rendering
/// full-bleed artwork every frame to move a 4 pt bar would undo the work that
/// made this screen fast.
struct AppleTVHeroRotationIndicator: View {
    let count: Int
    let index: Int

    @State private var fill: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private typealias M = AppleTVBillboardMetrics

    var body: some View {
        HStack(spacing: M.rotationSegmentSpacing) {
            ForEach(0 ..< max(count, 0), id: \.self) { position in
                let isCurrent = position == index
                Capsule()
                    .fill(.white.opacity(0.3))
                    .frame(
                        width: isCurrent ? M.rotationActiveSegmentWidth : M.rotationSegmentWidth,
                        height: M.rotationSegmentHeight
                    )
                    .overlay(alignment: .leading) {
                        if isCurrent {
                            Capsule()
                                .fill(.white)
                                .frame(width: M.rotationActiveSegmentWidth * fill)
                        }
                    }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Featured \(index + 1) of \(count)")
        .onAppear { restart() }
        .onChange(of: index) { _, _ in restart() }
    }

    private func restart() {
        // Reduce Motion keeps the position marker but stops the sweep.
        guard !reduceMotion else { fill = 1; return }
        fill = 0
        withAnimation(.linear(duration: AppleHeroRotation.interval)) { fill = 1 }
    }
}

/// Play and Details as content-sized pills (FEEDBACK X3); Play is the same
/// white pill as the title page.
struct AppleTVBillboardActions<Play: View, Detail: View>: View {
    @ViewBuilder var playDestination: Play
    @ViewBuilder var detailDestination: Detail

    private typealias M = AppleTVBillboardMetrics

    var body: some View {
        HStack(spacing: M.pillGap) {
            NavigationLink { playDestination } label: {
                HStack(spacing: M.pillGlyphSpacing) {
                    Image(systemName: "play.fill")
                        .font(.system(size: M.pillGlyphSize, weight: .semibold))
                    Text("Play")
                }
            }
            .buttonStyle(AppleTVPillStyle(isSelected: true, minimumSize: M.pillSize, fontSize: M.pillFontSize))
            .accessibilityIdentifier("home.featured.play")

            NavigationLink { detailDestination } label: {
                HStack(spacing: M.pillGlyphSpacing) {
                    Image(systemName: "info.circle")
                        .font(.system(size: M.pillGlyphSize, weight: .semibold))
                    Text("Details")
                }
            }
            .buttonStyle(AppleTVPillStyle(isSelected: false, minimumSize: M.pillSize, fontSize: M.pillFontSize))
            .accessibilityIdentifier("home.featured.details")
        }
    }
}
#endif
