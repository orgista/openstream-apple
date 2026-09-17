import CoreGraphics
import Foundation
import Testing
@testable import OpenStreamApple

// Restored 2026-09-14 (Fable): this file had grown to 45 MB, the same three
// tests repeated 13,964 times with no imports, and every `swift test` on the
// machine stalled in the compiler while rendering diagnostics for it. The
// single intact copy of the three tests is kept below; nothing was removed.

@Test func compactLandscapeHeroUsesViewportHeightAndTrailerStillCoversHero() {
    let viewport = CGSize(width: 874, height: 402)
    #expect(AppleDetailMetrics.isLandscapeLayout(viewport: viewport))

    let heroHeight = AppleDetailMetrics.heroHeight(
        in: viewport,
        horizontalSizeClassIsRegular: false
    )

    // Phone landscape uses the iPad full-screen hero.
    #expect(abs(heroHeight - viewport.height * AppleDetailMetrics.landscapeHeightFraction) < 0.0001)
    #expect(heroHeight == viewport.height)

    let hero = CGSize(width: viewport.width, height: heroHeight)
    let frame = AppleTrailerPreviewLayout.playerFrame(in: hero, isLandscape: true)
    #expect(frame.width >= hero.width)
    #expect(frame.height >= hero.height)
    #expect(abs(frame.width / frame.height - 16.0 / 9.0) < 0.0001)

    let portraitViewport = CGSize(width: 402, height: 874)
    #expect(!AppleDetailMetrics.isLandscapeLayout(viewport: portraitViewport))
    #expect(
        AppleDetailMetrics.heroHeight(
            in: portraitViewport,
            horizontalSizeClassIsRegular: false
        ) == portraitViewport.width * 0.75
    )
    // iPad portrait and iPad landscape are unchanged.
    #expect(
        AppleDetailMetrics.heroHeight(
            in: CGSize(width: 834, height: 1_194),
            horizontalSizeClassIsRegular: true
        ) == min(834 * 0.75, 1_194 * AppleDetailMetrics.iPadHeightFraction)
    )
    #expect(
        AppleDetailMetrics.heroHeight(
            in: CGSize(width: 1_194, height: 834),
            horizontalSizeClassIsRegular: true
        ) == 834
    )
}

@Test func featuredHeroAndActionsKeepFixedLandscapeGeometryOnThePhone() {
    let landscapePhone = CGSize(width: 874, height: 402)
    let portraitPhone = CGSize(width: 402, height: 874)

    let landscapeHeight = AppleDetailMetrics.featuredHeroHeight(in: landscapePhone)
    #expect(landscapeHeight <= landscapePhone.height * AppleDetailMetrics.featuredHeroLandscapeHeightFraction + 0.0001)
    #expect(landscapeHeight <= (landscapePhone.width - 32) * 9 / 16 + 0.0001)

    #expect(AppleDetailMetrics.featuredHeroHeight(in: portraitPhone) == AppleDetailMetrics.featuredHeroPortraitHeight)
    #expect(AppleDetailMetrics.featuredHeroHeight(in: .zero) == AppleDetailMetrics.featuredHeroPortraitHeight)

    // The featured pills stay 140 x 36 in landscape instead of stretching.
    #expect(AppleDetailMetrics.landscapeIPadActionButtonWidth == 140)
    #expect(AppleDetailMetrics.actionButtonHeight == 36)
    #expect(
        AppleDetailMetrics.actionButtonWidth(for: .landscapeIPad, screenWidth: landscapePhone.width) == 140
    )
}

@Test func tabBarHidesOnlyInCompactLandscape() {
    #expect(OpenStreamTabBarVisibility.isHidden(
        viewport: CGSize(width: 874, height: 402),
        horizontalSizeClassIsCompact: true
    ))
    #expect(!OpenStreamTabBarVisibility.isHidden(
        viewport: CGSize(width: 402, height: 874),
        horizontalSizeClassIsCompact: true
    ))
    #expect(!OpenStreamTabBarVisibility.isHidden(
        viewport: CGSize(width: 1_194, height: 834),
        horizontalSizeClassIsCompact: false
    ))
    #expect(!OpenStreamTabBarVisibility.isHidden(
        viewport: .zero,
        horizontalSizeClassIsCompact: true
    ))
}

