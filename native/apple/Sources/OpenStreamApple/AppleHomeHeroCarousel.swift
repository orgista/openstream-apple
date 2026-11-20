import SwiftUI

/// One platform selector and page gate for both home tabs. Callers own content and actions.
struct AppleHomeHeroCarousel<Page: View>: View {
    let pageIDs: [String]
    let items: [AppleCatalogItem]
    let wordmarks: [URL?]
    let viewportSize: CGSize
    let phoneLayout: AppleHomePhoneHeroLayout
    let wideLayout: AppleMacHeroLayout
    @ViewBuilder let page: (Int, Bool, AppleHomePresentationPolicy.Hero, Int, Int, AppleHomeTVHeroContext?) -> Page
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rotatingCycle = AppleHeroRotation.Cycle(count: 0)
    @State private var rotatingHeroIsVisible = false
    @State private var rotatingTrailer = AppleHomeHeroTrailerStateKey.Value()
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.appleIsLargeLayout) private var isLargeLayout
    @Environment(\.appleUsesPadLandingChrome) private var usesPadLandingChrome

    var presentation: AppleHomePresentationPolicy.Hero {
        Self.presentation(viewport: viewportSize, compact: horizontalSizeClass == .compact,
                          accessibility: dynamicTypeSize.isAccessibilitySize, isLargeLayout: isLargeLayout)
    }

    static func presentation(viewport: CGSize, compact: Bool, accessibility: Bool,
                             isLargeLayout: Bool) -> AppleHomePresentationPolicy.Hero {
        #if os(macOS)
        let platform = AppleHomePresentationPolicy.Platform.mac
        #elseif os(tvOS)
        let platform = AppleHomePresentationPolicy.Platform.tv
        #elseif os(iOS)
        let platform = AppleHomePresentationPolicy.Platform.iOS
        #else
        let platform = AppleHomePresentationPolicy.Platform.vision
        #endif
        return AppleHomePresentationPolicy.hero(platform: platform, compact: compact,
            landscape: AppleDetailMetrics.isLandscapeLayout(viewport: viewport),
            accessibility: accessibility, isLargeLayout: isLargeLayout)
    }

    private var art: [AppleHeroPageArt] {
        items.indices.map { index in
            AppleHeroPageArt(id: items[index].mediaID, backdrop: items[index].backgroundURL ?? items[index].posterURL,
                             wordmark: dynamicTypeSize.isAccessibilitySize && presentation != .tv ? nil : wordmarks[index])
        }
    }

    private var slots: AppleHeroPageSlots {
        #if os(tvOS)
        AppleHeroPageSlots(backdropWidth: AppleTVBillboardMetrics.screenSize.width,
            backdropHeight: AppleTVBillboardMetrics.artHeight,
            wordmark: CGSize(width: AppleTVBillboardMetrics.copyColumnWidth * 0.62,
                             height: AppleTVBillboardMetrics.titleFontSize * 2.2))
        #else
        AppleHeroPageSlots(backdropWidth: nil,
            backdropHeight: dynamicTypeSize.isAccessibilitySize ? AppleFeaturedHeroMetrics.accessibilityArtHeight
                : AppleFeaturedHeroMetrics.artHeight(viewport: viewportSize),
            wordmark: AppleFeaturedHeroMetrics.wordmarkSize(viewport: viewportSize))
        #endif
    }

    var body: some View {
        Group {
            #if os(macOS)
            AppleHomeMacHeroCarousel(pageIDs: pageIDs, layout: wideLayout) { index in
                page(index, false, .mac, 0, 0, nil)
            } preload: { index in
                AppleHomeMacHeroPreload(item: items[index], wordmark: wordmarks[index], layout: wideLayout)
            }
            .padding(.top, -wideLayout.topOverlap)
            #elseif os(tvOS)
            AppleHomeTVHeroCarousel(pages: art, slots: slots) { index, failed, context in
                page(index, failed, .tv, items.count, index, context)
            }
            .padding(.horizontal, -AppleTVChromeMetrics.horizontalSafeInset)
            #elseif os(iOS) || os(visionOS)
            if presentation == .phone || presentation == .pad {
                AppleHomePhoneHeroCarousel(pageIDs: pageIDs,
                    dotsCentreInset: presentation == .pad ? AppleMacHeroLayout.padDotsCentreInset : AppleHomePhoneHeroLayout.dotsCentreInset) { index in
                    page(index, false, presentation, 0, 0, nil)
                }
                .padding(.top, presentation == .pad ? -wideLayout.topOverlap : -phoneLayout.topOverlap)
                .padding(.bottom, presentation == .phone ? -AppleHomePhoneHeroLayout.trailingOverlap : 0)
            } else {
                rotatingHero
            }
            #else
            rotatingHero
            #endif
        }
        #if os(iOS)
        .modifier(ApplePhoneLandingHeroReader(isUnderPhoneChrome: presentation == .phone
            || (presentation == .pad && !usesPadLandingChrome)))
        #endif
    }
    #if !os(macOS) && !os(tvOS)
    private var rotatingHero: some View {
        Group {
            if let index = rotatingCycle.pages(available: items.count)?.shown {
                AppleHeroPageGate(pages: art, requested: index, slots: slots) { shown, failed in
                    page(shown, failed, .rotating, items.count, shown, nil)
                        .environment(\.appleRotatingHeroCycle, rotatingCycle.indicator(showing: shown))
                } onPresent: { shown in
                    if shown == rotatingCycle.index { rotatingCycle.didPresent(at: .now) }
                }
                .padding(.horizontal, 16)
            }
        }
        .onChange(of: pageIDs, initial: true) { _, _ in
            rotatingCycle = AppleHeroRotation.Cycle(count: pageIDs.count)
            rotatingCycle.waitForPresentation()
            holdRotatingHero()
        }
        .appleHeroVisibility { visible in
            rotatingHeroIsVisible = visible
            holdRotatingHero()
        }
        .onPreferenceChange(AppleHomeHeroTrailerStateKey.self) { state in
            let event = state.cycleEvent(after: rotatingTrailer)
            rotatingTrailer = state
            if let event { rotatingCycle.handle(event, at: .now) }
            holdRotatingHero()
        }
        .onChange(of: reduceMotion) { holdRotatingHero() }
        .task(id: rotatingCycle) {
            guard let due = rotatingCycle.dueDate else { return }
            do { try await Task.sleep(for: .seconds(max(due.timeIntervalSinceNow, 0))) } catch { return }
            if rotatingCycle.advanceIfDue(at: .now) { rotatingCycle.waitForPresentation() }
        }
    }
    private func holdRotatingHero() {
        if reduceMotion || !rotatingHeroIsVisible || rotatingTrailer.isPlaying { rotatingCycle.pause(at: .now) }
        else { rotatingCycle.resume(at: .now) }
    }
    #endif

}

extension EnvironmentValues {
    /// The rotating hero's cycle, for its page dots (`AppleHomeHeroPageIndicator`).
    @Entry var appleRotatingHeroCycle: AppleHeroRotation.Cycle?
}
