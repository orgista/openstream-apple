import SwiftUI

/// How many lines of the hero's summary to show at a given text size.
///
/// The hero already restacks at accessibility sizes — artwork above, text and
/// actions below — but it kept showing four lines of summary. At the largest
/// setting four lines of that type is around 460 pt, which pushed **Play and
/// Details off the bottom of the screen**: the primary action on the landing
/// screen could only be reached by scrolling.
///
/// Showing less prose as the type grows is what the system apps do; the summary
/// is the part a viewer at that setting is least likely to be reading anyway,
/// and the title and the buttons are the part they need.
public enum AppleHeroSummaryLineLimit {
    public static func lines(for size: DynamicTypeSize) -> Int {
        guard size.isAccessibilitySize else { return 3 }
        // The three largest settings are where the actions were being pushed
        // off; the first two accessibility steps still fit three lines.
        return size >= .accessibility3 ? 1 : 2
    }
}
