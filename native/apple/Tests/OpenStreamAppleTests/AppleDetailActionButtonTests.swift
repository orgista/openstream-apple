import CoreGraphics
import Testing
@testable import OpenStreamApple

@Test func detailActionButtonsShareOneFixedFrame() {
    let layouts: [(AppleDetailLayout, CGFloat, CGFloat)] = [
        (.portraitPhone, 390, 174),
        (.portraitIPad, 834, 180),
        (.landscapeIPad, 1_192, 140),
    ]

    #expect(AppleDetailMetrics.actionButtonHeight == 36)
    #expect(AppleDetailMetrics.actionButtonCornerRadius == 18)
    #expect(AppleDetailMetrics.actionButtonLabelFontSize == 15)
    #expect(AppleDetailMetrics.actionButtonGlyphSize == 13)
    #expect(AppleDetailMetrics.actionButtonHorizontalPadding == 16)
    #expect(AppleDetailMetrics.actionButtonGap == 10)
    #expect(AppleDetailMetrics.iconGlyphSize == 20)
    #expect(AppleDetailMetrics.iconLabelFontSize == 11)
    #expect(AppleDetailMetrics.iconRowHeight == 44)

    for (layout, screenWidth, expectedWidth) in layouts {
        let frames = AppleDetailMetrics.actionButtonFrames(for: layout, screenWidth: screenWidth)
        #expect(frames.play.size == frames.download.size)
        #expect(frames.play.width == expectedWidth)
        #expect(frames.play.height == AppleDetailMetrics.actionButtonHeight)
        #expect(frames.download.minX - frames.play.maxX == AppleDetailMetrics.actionButtonGap)
        #expect(AppleDetailMetrics.iconRowWidth(for: layout, screenWidth: screenWidth) == frames.download.maxX)
    }
}

@Test func detailFormatBadgesNeverRepresentDolbyAsText() {
    #expect(AppleFormatBadgeKind.resolve("4K") == .text("4K"))
    #expect(AppleFormatBadgeKind.resolve("HDR10+") == .text("HDR10+"))
    #expect(AppleFormatBadgeKind.resolve("dolby vision") == .image("dolby-vision"))
    #expect(AppleFormatBadgeKind.resolve("DV") == .image("dolby-vision"))
    #expect(AppleFormatBadgeKind.resolve("DOLBY ATMOS") == .image("dolby-atmos"))
    #expect(AppleFormatBadgeKind.resolve("DOLBY AUDIO") == .image("dolby-audio"))
    #expect(AppleFormatBadgeKind.resolve("unknown") == nil)
}

@Test func detailMetadataMatchesAppleTVOrderAndFormatting() {
    #expect(AppleTitleMetadataPresentation.textValues(
        genres: ["Sci-Fi", "Drama"],
        releaseInfo: "2026-09-04",
        runtimeMinutes: 103
    ) == ["Sci-Fi", "Sep 4, 2026", "1 hr 43 min"])
    #expect(AppleTitleMetadataPresentation.formattedRuntime(60) == "1 hr")
    #expect(AppleTitleMetadataPresentation.formattedRuntime(43) == "43 min")

    #expect(AppleTitleMetadataPresentation.orderedBadges(
        contentRating: "TV-MA",
        formatBadges: ["AD", "DOLBY ATMOS", "4K", "CC", "HDR", "SDH", "HD"],
        limit: 6
    ) == ["TV-MA", "4K", "HDR", "CC", "SDH", "AD"])
}

/// The featured hero on Discover is a different code path from the detail page,
/// and it had no tablet rule at all: every portrait viewport got the phone's
/// "fill half the column", which on the review iPad made *Play* a 367 pt capsule
/// (owner review, 2026-09-17).
@Test func featuredHeroActionsAreFixedWidthOnATabletAndFillOnAPhone() {
    // Phones fill the column, as they always did.
    for width in [320.0, 390.0, 402.0, 440.0] {
        #expect(
            AppleDetailMetrics.featuredActionButtonWidth(portraitViewportWidth: width) == nil,
            "a \(width) pt portrait viewport is a phone and should fill the column"
        )
    }
    // Every iPad portrait width takes the same pill the detail page uses.
    for width in [744.0, 834.0, 1_024.0] {
        #expect(
            AppleDetailMetrics.featuredActionButtonWidth(portraitViewportWidth: width)
                == AppleDetailMetrics.portraitIPadActionButtonWidth,
            "a \(width) pt portrait viewport is a tablet and should use the fixed pill"
        )
    }
}

/// The detail page's content column in portrait used to be the *action row*
/// width. That is right on a phone by coincidence and wrong on a tablet: the
/// review iPad squeezed the synopsis, the Episodes header and every episode row
/// into 310 pt of an 834 pt page (2026-09-17).
@Test func theDetailContentColumnFillsATabletWithoutChangingThePhone() {
    // Phone: the action row and the content column are the same thing, and the
    // number must not move.
    for width in [320.0, 390.0, 402.0, 440.0] {
        let actionColumn = AppleDetailMetrics.iconRowWidth(for: .portraitPhone, screenWidth: width)
        #expect(
            AppleDetailMetrics.portraitContentWidth(
                viewportWidth: width, actionColumnWidth: actionColumn) == actionColumn,
            "a \(width) pt phone must keep its existing column"
        )
    }
    // Tablet: the column is the readable width, not the width of two pills.
    let tabletActionColumn = AppleDetailMetrics.iconRowWidth(for: .portraitIPad, screenWidth: 834)
    #expect(tabletActionColumn == 370, "two 180 pt pills plus a 10 pt gap")
    // The bigger device must never get the smaller button: that is how
    // "Download Season" came to truncate on an iPad and not on a phone.
    #expect(
        AppleDetailMetrics.portraitIPadActionButtonWidth
            >= AppleDetailMetrics.actionButtonWidth(for: .portraitPhone, screenWidth: 402),
        "the iPad pill is narrower than the phone's"
    )
    for width in [744.0, 834.0, 1_024.0] {
        #expect(
            AppleDetailMetrics.portraitContentWidth(
                viewportWidth: width, actionColumnWidth: tabletActionColumn)
                == AppleDetailMetrics.regularContentWidth,
            "a \(width) pt tablet should read at the regular content width"
        )
    }
    // Both iPad orientations read at the same width.
    #expect(AppleDetailMetrics.regularContentWidth == 680)
}
