import SwiftUI

// The title page's content, one view type per layout (N45).
//
// Opening a title page for the first time stalled the main thread while the
// Swift runtime built type metadata for `AppleCatalogItemDetailView`'s body:
// one nested type holding every layout's views, the iPhone's and the iPad's
// included on the Mac, under ~45 modifiers (67–74 ms on the Mac, N36). A
// view type of its own ends that nesting: its body's types are only built
// when that body runs, so a layout that is not on screen costs nothing, and
// the page's modifiers wrap a short type name rather than the whole page.
//
// Each view takes the page itself and draws one of its layouts, so the
// state, environment and helpers stay where they are; only the type the
// runtime has to build changes.

/// The scroll view's content: the layout for this platform and size.
struct AppleTitlePageScrollContent: View {
    let page: AppleCatalogItemDetailView

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if page.usesPhoneTitlePage {
                AppleTitlePagePhoneContent(page: page)
            } else if page.usesMacTitlePage {
                #if os(macOS)
                AppleTitlePageMacContent(page: page)
                #endif
            } else {
                AppleTitlePageRegularContent(page: page)
            }
        }
        .padding(.bottom)
    }
}

/// The iPhone title page in portrait.
struct AppleTitlePagePhoneContent: View {
    let page: AppleCatalogItemDetailView

    var body: some View { page.phoneTitlePage }
}

#if os(macOS)
/// The Mac title page.
struct AppleTitlePageMacContent: View {
    let page: AppleCatalogItemDetailView

    var body: some View { page.macTitlePage }
}
#endif

#if os(tvOS)
/// The Apple TV title page's backdrop and title block. The page keeps the
/// focus rules (`tvOSDetailLayout`); the buttons in here bind to its focus.
struct AppleTitlePageTVHero: View {
    let page: AppleCatalogItemDetailView

    var body: some View { page.tvOSHero }
}

/// The Apple TV title page below the fold: episodes and More Like This.
struct AppleTitlePageTVBelowFold: View {
    let page: AppleCatalogItemDetailView

    var body: some View { page.tvOSBelowFold }
}
#endif

/// The iPad, landscape and Vision title page.
struct AppleTitlePageRegularContent: View {
    let page: AppleCatalogItemDetailView

    var body: some View { page.regularTitlePage }
}
