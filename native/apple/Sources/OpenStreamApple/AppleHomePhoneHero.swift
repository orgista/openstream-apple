import SwiftUI

/// Discover's hero on an iPhone in portrait, after the Apple TV app's (owner
/// 2026-09-22 with two reference screenshots, and the Figma "iOS-OpenStream"
/// frame): art edge to edge from the top of the screen, under the large
/// title, to 73 % of its height (`AppleHomePhoneHeroLayout`), fading to black
/// at the bottom; then, centred and anchored to the bottom of the art, an
/// optional "New Season" capsule, the wordmark (or, until and unless it draws,
/// the name in black-weight capitals), "TV Show · Thriller · Drama" with the rating, and the buttons,
/// with the carousel's page dots under them. iPad, landscape and every other
/// platform keep `AppleFeaturedHero`.
///
/// The copy is laid out in the flow, not overlaid: at the accessibility text
/// sizes it grows the hero downwards past the art rather than clipping the
/// buttons, and the fade has already reached black by then.
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
    /// Whether the wordmark or name is drawn (`AppleHeroPortraitArt.showsTitle`):
    /// false over a poster that already carries the title, nil while the art
    /// is still being chosen (the title's place is held, unseen, so it
    /// appears with its art rather than before it).
    var showsTitle: Bool? = true
    /// The portrait art (static on the iPhone), from `AppleHomeBillboard`.
    let stage: AnyView
    /// The still's luminance, once measured (`AppleHeroLuminanceCache`).
    var artLuminance: AppleHeroLuminanceMap? = nil
    let onOpenDetails: () -> Void
    @ViewBuilder var actions: Actions

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .largeTitle) private var titleSize: CGFloat = 48
    @State private var copyHidden = false
    @State private var artWidth: CGFloat = 0
    /// A trailer is on screen over the still, whose tone then no longer applies.
    @State private var videoIsShowing = false

    private var scrim: AppleHeroScrim {
        let region = AppleHeroCopyRegion.phone(width: artWidth, artHeight: artHeight)
        let reading = artLuminance?.reading(region: region, in: CGSize(width: artWidth, height: artHeight))
        return .phone(tone: videoIsShowing ? .unknown : AppleHeroArtTone(reading: reading))
    }

    var body: some View {
        VStack(spacing: 12) {
            // The title block is the way into the title page, as tapping the
            // hero is in the Apple TV app; Details is no longer a button of
            // its own. A tap, not a Button: a Button fires on any touch that
            // lifts inside it, so a left swipe across the title — the
            // carousel's page gesture — opened the title page instead of
            // paging (iOS 18.6 regression 2026-10-01). A tap fails once the
            // finger travels.
            VStack(spacing: 10) {
                if showsTitle != false {
                    title
                        .opacity(showsTitle == nil ? 0 : 1)
                        .animation(.easeOut(duration: 0.25), value: showsTitle)
                } else {
                    // The art says the name; VoiceOver still hears it.
                    Color.clear
                        .frame(width: 1, height: 1)
                        .accessibilityLabel(item.name)
                        .accessibilityAddTraits(.isHeader)
                }
                AppleHomePhoneHeroMetadata(item: item)
            }
            .appleHeroCopyShadow(scrim.copyShadow)
            .animation(.easeInOut(duration: 0.3), value: scrim.copyShadow)
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
        // Room for the carousel's page dots, which sit over the art.
        .padding(.bottom, AppleHomePhoneHeroLayout.copyBottomInset)
        // At the accessibility sizes the copy never rises under the large
        // title and its buttons; a taller block grows the hero downwards.
        .padding(.top, dynamicTypeSize.isAccessibilitySize ? copyFadeLine + 12 : 0)
        .frame(maxWidth: .infinity)
        .frame(minHeight: artHeight, alignment: .bottom)
        .background(alignment: .top) {
            stage
                .frame(maxWidth: .infinity)
                .frame(height: artHeight)
                .clipped()
                .onPreferenceChange(AppleHomeHeroTrailerStateKey.self) { state in
                    videoIsShowing = state.isOnScreen
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { artWidth = $0 }
                .overlay {
                    AppleHomePhoneHeroFade(scrim: scrim)
                        .allowsHitTesting(false)
                        .animation(.easeInOut(duration: 0.4), value: scrim)
                }
        }
        .background(Color.black)
        .coordinateSpace(.named(Self.coordinateSpaceName))
        .accessibilityElement(children: .contain)
    }

    private static var coordinateSpaceName: String { "AppleHomePhoneHero" }

    /// The wordmark, its slot held empty while it loads; the name in
    /// black-weight capitals when it fails, is slow or there is none, over
    /// any art (`AppleHeroTitlePolicy`).
    private var title: some View {
        AppleHeroTitleLockup(pageID: item.id, wordmark: wordmark,
                             wordmarkLookupPending: wordmarkLookupPending, alignment: .center) { url, onLoadResult in
            AppleTrimmedTitleLogo(url: url, alignment: .center, onLoadResult: onLoadResult)
                .frame(maxWidth: 280)
                .frame(height: dynamicTypeSize.isAccessibilitySize ? 120 : 96)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(item.name)
                .accessibilityAddTraits(.isHeader)
        } name: {
            Text(item.name.uppercased())
                .font(.system(size: min(max(titleSize, 42), dynamicTypeSize.isAccessibilitySize ? 64 : 58), weight: .black))
                .tracking(1)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .minimumScaleFactor(0.6)
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.8), radius: 12, y: 2)
                .accessibilityLabel(item.name)
                .accessibilityAddTraits(.isHeader)
        }
    }
}
