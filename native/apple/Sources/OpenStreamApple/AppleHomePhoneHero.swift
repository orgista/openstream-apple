import SwiftUI

/// The title-page hero with landing actions and room below its art for page dots.
struct AppleHomePhoneHero<Actions: View>: View {
    let item: AppleCatalogItem
    /// From the top edge of the screen: the hero is drawn pulled up under the
    /// navigation bar by `AppleHomePhoneHeroLayout.topOverlap`.
    let artHeight: CGFloat
    /// Where the copy has faded out, from the top of the screen:
    /// `AppleHomePhoneHeroLayout.topInset`.
    let copyFadeLine: CGFloat
    let wordmark: URL?
    /// The wordmark lookup is still running (`AppleHeroTitleLockup`).
    var wordmarkLookupPending: Bool? = nil
    let stage: AnyView
    let onOpenDetails: () -> Void
    @ViewBuilder var actions: Actions

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.appleHeroSideBleed) private var sideBleed
    @State private var copyHidden = false
    var body: some View {
        VStack(spacing: 12) {
            // The title block is the way into the title page, as tapping the
            // hero is in the Apple TV app; Details is no longer a button of
            // its own. A tap, not a Button: a Button fires on any touch that
            // lifts inside it, so a left swipe across the title — the
            // carousel's page gesture — opened the title page instead of
            // paging (iOS 18.6 regression 2026-10-01). A tap fails once the
            // finger travels.
            VStack(spacing: 12) {
                title
                AppleHomePhoneHeroMetadata(item: item)
            }
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
            .onTapGesture(perform: onOpenDetails)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default, onOpenDetails)
            .accessibilityHint("Opens the title page")
            .accessibilityIdentifier("home.featured.details")
            actions
                .padding(.top, 4)
        }
        // Chrome over art: past accessibility 2 the wordmark, the metadata
        // and the buttons outgrew the hero and rose into the large title and
        // its buttons (iPhone 27 v2 re-run, AX-XXXL).
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        // Faded out is gone: no taps and no VoiceOver on buttons nobody can
        // see. The action runs only when the copy crosses the fade line, so
        // scrolling still costs no per-frame state change.
        .allowsHitTesting(!copyHidden)
        .accessibilityHidden(copyHidden)
        .onGeometryChange(for: Bool.self) { [copyFadeLine, space = Self.coordinateSpaceName] proxy in
            AppleHomePhoneHeroLayout.copyIsHidden(
                copyTop: AppleHomePhoneHeroLayout.screenTop(scrollViewMinY: proxy.frame(in: .scrollView).minY,
                                                            topInset: copyFadeLine),
                restingTop: proxy.frame(in: .named(space)).minY,
                fadeLine: copyFadeLine)
        } action: { hidden in
            copyHidden = hidden
        }
        // Read from the copy's own place in the scroll view, so scrolling
        // costs no state change and no body pass. The hero starts at the top
        // edge of the screen, so where the copy sits inside it is where it
        // rests on screen before any scroll.
        .visualEffect { [copyFadeLine, space = Self.coordinateSpaceName] content, proxy in
            content.opacity(AppleHomePhoneHeroLayout.copyOpacity(
                copyTop: AppleHomePhoneHeroLayout.screenTop(scrollViewMinY: proxy.frame(in: .scrollView).minY,
                                                            topInset: copyFadeLine),
                restingTop: proxy.frame(in: .named(space)).minY,
                fadeLine: copyFadeLine))
        }
        .padding(.horizontal, 20)
        // The art runs under the side safe areas; the copy stays centred beside them.
        .padding(.leading, sideBleed.leading)
        .padding(.trailing, sideBleed.trailing)
        // Room for the carousel's page dots, which sit over the art.
        .padding(.bottom, AppleHomePhoneHeroLayout.copyBottomInset)
        // At the accessibility sizes the copy never rises under the large
        // title and its buttons; a taller block grows the hero downwards.
        .padding(.top, dynamicTypeSize.isAccessibilitySize ? copyFadeLine + 12 : 0)
        .frame(maxWidth: .infinity)
        .frame(minHeight: artHeight + AppleHomePhoneHeroLayout.footerHeight, alignment: .bottom)
        .background(alignment: .top) {
            stage
                .frame(maxWidth: .infinity)
                .frame(height: artHeight)
                .clipped()
                .overlay {
                    AppleHomePhoneHeroFade()
                        .allowsHitTesting(false)
                }
        }
        .background(Color.black)
        .coordinateSpace(.named(Self.coordinateSpaceName))
        .accessibilityElement(children: .contain)
    }

    private static var coordinateSpaceName: String { "AppleHomePhoneHero" }

    /// The wordmark, its slot held empty while it loads; the name in
    /// the title's own casing when it fails, is slow or there is none, over
    /// any art (`AppleHeroTitlePolicy`).
    private var title: some View {
        AppleHeroTitleLockup(pageID: item.id, wordmark: wordmark,
                             wordmarkLookupPending: wordmarkLookupPending, alignment: .center) { url, onLoadResult in
            ApplePhoneHeroTitle(name: item.name, presentation: .logo, logoURL: url, onLoad: onLoadResult)
        } name: {
            ApplePhoneHeroTitle(name: item.name, presentation: .text)
        }
    }
}
