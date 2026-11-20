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
    /// The invisible paging stops beside the Discover hero's buttons
    /// (`AppleTVHeroPaging`): wide enough to be a focus target, no wider.
    static let pagingStopWidth: CGFloat = 2
    /// The hero's buttons sit in a focus section this wide (the screen inside
    /// the safe-zone gutters), so Down from any tab reaches them before the
    /// first row. The billboard's own section starts under the tab bar, and
    /// Down from Discover skipped it for a Continue Watching card (N41 survey).
    static var actionsFocusWidth: CGFloat { screenSize.width - 2 * copyLeadingInset }

    // Discover's outlined rating, after the Apple TV app (N12, same shape as
    // the iPhone and Mac heroes at tvOS sizes).
    static let ratingFontSize: CGFloat = 20
    static let ratingHorizontalPadding: CGFloat = 9
    static let ratingVerticalPadding: CGFloat = 2

    // Rotation indicator: one segment per billboard, the current one filling
    // over `AppleHeroRotation.interval` so a change is visibly coming
    // (owner 2026-09-15: "a little bar or similar … it's about to cycle").
    static let rotationSegmentHeight: CGFloat = 4
    static let rotationSegmentWidth: CGFloat = 14
    static let rotationActiveSegmentWidth: CGFloat = 48
    static let rotationSegmentSpacing: CGFloat = 8

    /// How far the first row climbs into the fade: whatever keeps its header
    /// at `firstRowTop` whatever the row spacing.
    static var rowOverlap: CGFloat { artHeight + sectionSpacing - firstRowTop }

    // Rows (`AppleMediaShelf` on tvOS). The horizontal safe area already
    // insets rows by 80, so cards start on the copy's column with no extra inset.
    static let rowHorizontalInset: CGFloat = 0
    static let rowTitleFontSize: CGFloat = 34
    /// How far a focused 400 x 600 poster grows above its row: about 20 pt
    /// on a test Apple TV (walk 9), rounded up for the shadow and a larger system scale.
    static let focusLift: CGFloat = 32
    /// Title to cards: the lift plus a clear 16. At 14 the focused card
    /// covered its own title ("Featured Shows", Apple TV walk 9).
    static var rowTitleSpacing: CGFloat { focusLift + 16 }
    static let cardGap: CGFloat = 32
    /// Cards to the next row's title: wider than `rowTitleSpacing`, so a title
    /// reads with its own row, and clear of the focused poster's caption
    /// (`focusedCaptionBottom`).
    static let sectionSpacing: CGFloat = 80
    /// Every poster on Apple TV Discover, Library and the service pages is
    /// the Featured rows' size (owner 2026-11-04: "drop small title cards").
    static let posterWidth: CGFloat = 400
    static let focusedTitleFontSize: CGFloat = 24
    static let focusedTitleGap: CGFloat = 8
    static let contentBottomInset: CGFloat = 60
    /// How far below a poster its focused title ends.
    static var focusedCaptionBottom: CGFloat {
        // One line of type is about 1.25 times its size.
        focusedTitleGap + AppleTVDetailMetrics.cardCaptionFocusDrop + focusedTitleFontSize * 1.25
    }

    /// Y of the first row's top edge in the scroll content: its header peeks
    /// over the bottom of the screen.
    static let firstRowTop: CGFloat = 904
    /// Bottom edge of the copy block (the pills) in the scroll content.
    static var copyBottom: CGFloat { artHeight - copyBottomInset }
}
