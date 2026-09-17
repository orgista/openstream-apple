import CoreGraphics
import Foundation

/// Apple TV home billboard (the Discover and Library hero): a full-bleed
/// backdrop across the top of the screen, copy anchored bottom-leading in the
/// HIG safe zone, content-sized pills, and the first row climbing into the
/// fade so the page reads as one surface (FEEDBACK X1–X3, X6). Every number
/// lives here so tests can assert the layout without a view.
enum AppleTVBillboardMetrics {
    static let screenSize = CGSize(width: 1920, height: 1080)

    // Art: 91 % of the screen, cropped edge to edge, under the top safe area.
    //
    // It was 65 %, which left a whole row of cards sitting under the hero and
    // nothing to scroll for. The owner asked for the hero to "take more of the
    // screen" and Continue Watching to move "until you scroll down"
    // (2026-09-15), and the reference apps they filmed do exactly that: the
    // billboard fills the screen and the first row only peeks over the bottom
    // edge. At 980 the row header lands at 908, leaving about 170 pt showing.
    static let artHeight: CGFloat = 980

    /// The one fade in the app (owner rule exception, FEEDBACK X2): clear at
    /// `fadeStartFraction` of the art, black at its bottom edge, so the copy
    /// and the overlapping first row sit on dark ground whatever the art is.
    static let usesFade = true
    static let fadeStartFraction: CGFloat = 0.35

    // Copy block: safe-zone leading inset, bottom edge above the first row.
    static let copyLeadingInset: CGFloat = 80
    // Clears the peeking first row, whose header now sits at 908.
    static let copyBottomInset: CGFloat = 140
    static let copyColumnWidth: CGFloat = 900
    static let copySpacing: CGFloat = 20
    static let titleFontSize: CGFloat = 64
    static let titleLineLimit = 2
    static let metadataFontSize: CGFloat = 29
    static let synopsisFontSize: CGFloat = 28
    static let synopsisLineLimit = 1

    // Pills: content-sized, same height and type as the title page's Play.
    static let pillSize = CGSize(width: 200, height: 66)
    static let pillFontSize: CGFloat = 31
    static let pillGlyphSize: CGFloat = 28
    static let pillGlyphSpacing: CGFloat = 12
    static let pillGap: CGFloat = 24

    // Rotation indicator: one segment per billboard, the current one filling
    // over `AppleHeroRotation.interval` so a change is visibly coming
    // (owner 2026-09-15: "a little bar or similar … it's about to cycle").
    static let rotationSegmentHeight: CGFloat = 4
    static let rotationSegmentWidth: CGFloat = 14
    static let rotationActiveSegmentWidth: CGFloat = 48
    static let rotationSegmentSpacing: CGFloat = 8

    /// How far the first row climbs into the fade.
    static let rowOverlap: CGFloat = 120

    // Rows (`AppleMediaShelf` on tvOS). The horizontal safe area already
    // insets rows by 80, so cards start on the copy's column with no extra inset.
    static let rowHorizontalInset: CGFloat = 0
    static let rowTitleFontSize: CGFloat = 31
    static let rowTitleSpacing: CGFloat = 16
    static let cardGap: CGFloat = 24
    static let rowVerticalBleed: CGFloat = 20
    static let sectionSpacing: CGFloat = 48
    static let contentBottomInset: CGFloat = 60

    /// Y of the first row's top edge in the scroll content.
    static var firstRowTop: CGFloat { artHeight - rowOverlap + sectionSpacing }
    /// Bottom edge of the copy block (the pills) in the scroll content.
    static var copyBottom: CGFloat { artHeight - copyBottomInset }
}
