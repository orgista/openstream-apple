import CoreGraphics
import Testing
@testable import OpenStreamApple

@Suite("Catalog card progress bar inset")
struct AppleCatalogCardMetricsTests {
    /// N58: on Apple TV a bar on the art's bottom edge vanished from the
    /// focused card, so it sits inside the art, clear of every edge.
    @Test func appleTVBarSitsInsideTheArtwork() {
        let inset = AppleCatalogCardMetrics.progressBarInset(isTV: true)
        #expect(inset.horizontal > 0)
        #expect(inset.bottom > 0)
        #expect(inset.bottom < 20)
    }

    @Test func otherPlatformsKeepTheEdgeBar() {
        let inset = AppleCatalogCardMetrics.progressBarInset(isTV: false)
        #expect(inset.horizontal == 0)
        #expect(inset.bottom == 0)
    }
}

@Suite("Artwork progress bar on bright art")
struct AppleArtworkProgressBarContrastTests {
    /// The backing is black, so on black art the track is what it always was.
    @Test func darkArtLooksTheSame() {
        let backed = AppleDesignTokens.artworkProgressTrackLevel(overArt: 0)
        let bare = AppleDesignTokens.artworkProgressTrackLevel(overArt: 0, backed: false)
        #expect(abs(backed - bare) < 0.0001)
    }

    /// N60: on a near-white still the track sat at about half grey and read
    /// as part of the picture. With the backing it is clearly darker than the
    /// art and than the white fill.
    @Test func whiteArtTrackReads() {
        let bare = AppleDesignTokens.artworkProgressTrackLevel(overArt: 1, backed: false)
        let backed = AppleDesignTokens.artworkProgressTrackLevel(overArt: 1)
        #expect(backed < bare - 0.15)
        #expect(backed < 0.45)
        #expect(AppleDesignTokens.artworkProgressBackingOutset > 0)
        #expect(AppleDesignTokens.artworkProgressBackingOutset <= 1.5)
    }
}
