import CoreGraphics
import Foundation
#if canImport(AppKit)
import AppKit
#endif
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
    // The title page's pair is the portrait pill in both orientations: at 140
    // "Download Season 1" truncated to "Download Se…" (N60 iPad walk).
    #expect(
        AppleDetailMetrics.actionButtonWidth(for: .landscapeIPad, screenWidth: landscapePhone.width)
            == AppleDetailMetrics.actionButtonWidth(for: .portraitIPad, screenWidth: landscapePhone.height)
    )
    #expect(
        AppleDetailMetrics.actionButtonWidth(for: .landscapeIPad, screenWidth: landscapePhone.width) >= 140
    )
}

#if canImport(AppKit)
/// Every title-page pill label fits its pill on both iPad orientations at the
/// default text size, measured with the label's own font; at accessibility
/// sizes the pill hugs its label instead of truncating it.
@Test func titlePagePillLabelsNeverTruncate() {
    let font = NSFont.systemFont(ofSize: AppleDetailMetrics.actionButtonLabelFontSize, weight: .semibold)
    // An SF Symbol is a little wider than its point size; allow for the widest.
    let glyphWidth = AppleDetailMetrics.actionButtonGlyphSize * 1.4
    let labels = [
        "Play", "Play Offline", "Play Trailer", "Preparing", "Loading", "Download",
        "Download Season 1", "Download Season 12", "Download Specials",
        "Downloading · 100%", "Failed · Retry",
    ]
    for layout in [AppleDetailLayout.portraitIPad, .landscapeIPad] {
        let pill = AppleDetailMetrics.actionButtonWidth(for: layout, screenWidth: 1_194)
        #expect(pill >= 140)
        for label in labels {
            let labelWidth = (label as NSString).size(withAttributes: [.font: font]).width
            let needed = AppleDetailMetrics.actionButtonWidthFitting(labelWidth: labelWidth, glyphWidth: glyphWidth)
            #expect(needed <= pill, "\(label) needs \(needed) pt, the \(layout) pill is \(pill)")
        }
        // The width that truncated it before does not fit the longest label.
        let longest = ("Download Season 12" as NSString).size(withAttributes: [.font: font]).width
        #expect(AppleDetailMetrics.actionButtonWidthFitting(labelWidth: longest, glyphWidth: glyphWidth) > 140)
        #expect(AppleDetailMetrics.actionButtonLabelFrameWidth(pill, isAccessibilitySize: false) == pill)
        #expect(AppleDetailMetrics.actionButtonLabelFrameWidth(pill, isAccessibilitySize: true) == nil)
    }
    #expect(AppleDetailMetrics.actionButtonLabelFrameWidth(nil, isAccessibilitySize: false)
        == AppleDetailMetrics.defaultActionButtonWidth)
}
#endif

@Test func onlyFullScreenPlayersAllowPhoneLandscape() {
    #expect(AppleOrientationPolicy.supportedOrientations(isPhone: true, allowsLandscape: false) == .portrait)
    #expect(AppleOrientationPolicy.supportedOrientations(isPhone: true, allowsLandscape: true) == .allButUpsideDown)
    #expect(AppleOrientationPolicy.supportedOrientations(isPhone: false, allowsLandscape: false) == .all)
    #expect(AppleOrientationPolicy.supportedOrientations(isPhone: false, allowsLandscape: true) == .all)
}
