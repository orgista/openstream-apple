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
    /// The wordmark lookup is still running (`AppleHeroTitleLockup`).
    var wordmarkLookupPending: Bool? = nil
    /// How many billboards the screen rotates through, and which is showing.
    /// One (or fewer) draws no indicator: there is nothing to cycle to.
    var rotationCount: Int = 0
    var rotationIndex: Int = 0
    /// What fills the billboard's art frame. Discover passes its hero stage
    /// (the still alone: the Apple TV plays no trailer); Library passes
    /// nothing and gets the still. Either way the frame, fade and copy block
    /// are the same.
    var stage: AnyView? = nil
    /// The stage's still, measured by `AppleHomeBillboard`. With no stage
    /// (Library) the billboard measures the still it draws itself.
    var artLuminance: AppleHeroLuminanceMap? = nil
    /// Discover only (N12), after the Apple TV app: "TV Show · Thriller ·
    /// Drama" with the outlined rating instead of genres and year…
    var usesKindMetadata = false
    /// …and page dots driven by the carousel's cycle (they hold while it
    /// does) instead of the clock.
    var cycle: AppleHeroRotation.Cycle? = nil
    @ViewBuilder var actions: Actions
    @State private var loadedStill: AppleHeroLoadedStill?
    @State private var artMeasurement: AppleHeroArtMeasurement?

    private typealias M = AppleTVBillboardMetrics

    private var stillURL: URL? { item.backgroundURL ?? item.posterURL }

    /// Over bright art under the copy, the Apple TV app's fade from the
    /// leading edge sized to the copy, a deeper bottom one and a soft shadow
    /// under the text (N20). Dark art keeps the one fade.
    private var scrim: AppleHeroScrim {
        let map = artLuminance ?? AppleHeroArtMeasurement.map(artMeasurement, for: stillURL)
        let frame = CGSize(width: M.screenSize.width, height: M.artHeight)
        let region = AppleHeroCopyRegion.tv
        return .tv(tone: AppleHeroArtTone(reading: map?.reading(region: region, in: frame)),
                   copyTrailing: AppleHeroCopyRegion.trailingFraction(region, in: frame))
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let stage {
                    stage
                } else {
                    AppleCatalogArtwork(
                        url: stillURL,
                        loadingFill: AppleDesignTokens.surface,
                        onImageLoad: { [stillURL] image in
                            if let stillURL { loadedStill = AppleHeroLoadedStill(url: stillURL, image: image) }
                        }
                    )
                }
            }
                .frame(width: M.screenSize.width, height: M.artHeight)
                .clipped()
                .overlay {
                    if M.usesFade {
                        AppleHeroScrimView(scrim: scrim)
                            .animation(.easeInOut(duration: 0.4), value: scrim)
                    }
                }
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: M.copySpacing) {
                VStack(alignment: .leading, spacing: M.copySpacing) {
                    titleTreatment
                    if usesKindMetadata {
                        AppleTVBillboardKindMetadata(item: item)
                    } else if let metadataLine {
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
                }
                .appleHeroCopyShadow(scrim.copyShadow)
                actions
                    .padding(.top, 8)
                if let cycle, cycle.count > 1 {
                    AppleTVHeroCycleIndicator(cycle: cycle, index: rotationIndex)
                        .padding(.top, 4)
                } else if cycle == nil, rotationCount > 1 {
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
        .appleMeasuresHeroArt(stage == nil ? loadedStill : nil) { artMeasurement = $0 }
        .focusSection()
        .accessibilityElement(children: .contain)
    }

    /// The wordmark once it has drawn, otherwise the name — never nothing
    /// (`AppleHeroTitlePolicy`).
    private var titleTreatment: some View {
        AppleHeroTitleLockup(pageID: item.id, wordmark: wordmark, wordmarkLookupPending: wordmarkLookupPending) { url, onLoadResult in
            AppleTrimmedTitleLogo(url: url, alignment: .leading, onLoadResult: onLoadResult)
                // One view per wordmark: the logo view keeps its image while a
                // new URL loads, which left the last title's mark over the next
                // title's copy (sim finding c, 2026-09-22).
                .id(url)
                .frame(maxWidth: M.copyColumnWidth * 0.62, maxHeight: M.titleFontSize * 2.2, alignment: .leading)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(item.name)
                .accessibilityAddTraits(.isHeader)
        } name: {
            Text(item.name)
                .font(.system(size: M.titleFontSize, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(M.titleLineLimit)
                .accessibilityAddTraits(.isHeader)
        }
    }

    /// "Action · Comedy · 2024" from the item's own fields; nothing when it has
    /// none, so the block never shows a lonely separator.
    private var metadataLine: String? {
        AppleBillboardCopy.metadataLine(genres: item.genres, year: item.year, releaseInfo: item.releaseInfo)
    }
}

/// Discover's "TV Show · Thriller · Drama" and the outlined rating, as the
/// iPhone and Mac heroes draw them (`AppleBillboardCopy.phoneMetadataLine`).
private struct AppleTVBillboardKindMetadata: View {
    let item: AppleCatalogItem

    private typealias M = AppleTVBillboardMetrics

    var body: some View {
        let line = AppleBillboardCopy.phoneMetadataLine(type: item.type, genres: item.genres)
        let rating = AppleBillboardCopy.ratingBadge(item.contentRating)
        if line != nil || rating != nil {
            HStack(spacing: 14) {
                if let line {
                    Text(line)
                        .font(.system(size: M.metadataFontSize, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                }
                if let rating {
                    Text(rating)
                        .font(.system(size: M.ratingFontSize, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                        .padding(.horizontal, M.ratingHorizontalPadding)
                        .padding(.vertical, M.ratingVerticalPadding)
                        .overlay {
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .strokeBorder(.white.opacity(0.45), lineWidth: 1.5)
                        }
                        .accessibilityLabel("Rated \(rating)")
                }
            }
        }
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
/// white pill as the title page. Focus arriving from the tab bar or a row goes
/// to Play, as on Discover's hero (`AppleTVHeroPaging.entry`); Library landed
/// on Details (N41 survey).
struct AppleTVBillboardActions: View {
    var button = AppleTitlePagePolicy.HeroButton(action: .play)
    let onPlay: () -> Void
    let onDetails: () -> Void

    @FocusState private var focus: AppleTVHeroPaging.Target?
    /// Details while its page is open: focus coming back stays on it.
    @State private var returnTarget: AppleTVHeroPaging.Target?

    private typealias M = AppleTVBillboardMetrics

    var body: some View {
        HStack(spacing: M.pillGap) {
            Button(action: onPlay) {
                HStack(spacing: M.pillGlyphSpacing) {
                    Image(systemName: button.systemImage)
                        .font(.system(size: M.pillGlyphSize, weight: .semibold))
                    Text(button.title)
                }
            }
            .buttonStyle(AppleTVPillStyle(isSelected: true, minimumSize: M.pillSize, fontSize: M.pillFontSize))
            .focused($focus, equals: .play)
            .accessibilityIdentifier("home.featured.play")

            // The primary pill already is Details when nothing plays.
            if button.action != .details {
                Button {
                    returnTarget = .details
                    onDetails()
                } label: {
                    HStack(spacing: M.pillGlyphSpacing) {
                        Image(systemName: "info.circle")
                            .font(.system(size: M.pillGlyphSize, weight: .semibold))
                        Text("Details")
                    }
                }
                .buttonStyle(AppleTVPillStyle(isSelected: false, minimumSize: M.pillSize, fontSize: M.pillFontSize))
                .focused($focus, equals: .details)
                .accessibilityIdentifier("home.featured.details")
            }
        }
        .frame(width: M.actionsFocusWidth, alignment: .leading)
        .focusSection()
        .onChange(of: focus) { old, target in
            guard old == nil, let target else { return }
            let settled = AppleTVHeroPaging.entry(arriving: target, returningTo: returnTarget)
            appleTrace("billboard focus: arrived on \(target), settles on \(settled)")
            returnTarget = nil
            if settled != target { focus = settled }
        }
    }
}
#endif
