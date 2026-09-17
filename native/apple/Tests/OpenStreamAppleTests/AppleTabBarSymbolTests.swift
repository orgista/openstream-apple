import Testing
@testable import OpenStreamApple

/// Owner 2026-09-16, on seeing the Discover tab: "yeah lets not do boxes please".
///
/// Tab bars substitute the `.fill` variant of a symbol automatically, so a tab
/// icon is only ever as light as its *filled* form. `sparkles.tv.fill` loses the
/// sparkles at tab size and renders as a blank white slab, which is how a symbol
/// chosen as an outline ended up on screen as a box.
@Suite("Tab bar symbols")
struct AppleTabBarSymbolTests {
    /// Symbols that ship a `.fill` counterpart which is a solid rectangle.
    /// Picking one of these for a tab puts a box in the bar no matter how the
    /// outline version looks in the picker.
    private static let boxedWhenFilled: Set<String> = [
        "sparkles.tv", "tv", "rectangle", "rectangle.stack", "square",
        "square.grid.2x2", "play.rectangle", "film", "menucard", "text.rectangle",
    ]

    @Test func discoverUsesTheSymbolWithNoFilledCounterpart() {
        #expect(OpenStreamTab.home.systemImage == "sparkles")
    }

    @Test func noTabUsesASymbolThatBecomesABoxWhenFilled() {
        for tab in [OpenStreamTab.search, .home, .library, .live, .settings] {
            #expect(
                !Self.boxedWhenFilled.contains(tab.systemImage),
                "\(tab.title) uses '\(tab.systemImage)', whose .fill variant is a solid box"
            )
        }
    }

    @Test func everyTabStillHasATitleForAccessibility() {
        for tab in [OpenStreamTab.search, .home, .library, .live, .settings] {
            #expect(!tab.title.isEmpty)
            #expect(!tab.systemImage.isEmpty)
        }
    }
}
