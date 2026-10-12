import Foundation

/// How the Apple TV Discover hero turns its pages with the Siri Remote, after
/// the Apple TV app: while a hero button has focus, pressing (or swiping) left
/// past the first button shows the previous page and right past the last shows
/// the next, and focus stays on the button it left. Up to the tab bar and
/// down to the rows are the focus engine's own moves; focus coming back into
/// the hero goes to Play (`entry(arriving:returningTo:)`).
///
/// The hero does it with two invisible focus stops beside its buttons
/// (`AppleHomeTVHeroActions`). They only accept focus while a hero button
/// already has it, so focus arriving from the tab bar or a row can never land
/// on one, and the moment one does take focus the page turns and focus goes
/// straight back. Reading the move command instead would be ambiguous: it
/// fires for the same press that moves focus between the buttons.
public enum AppleTVHeroPaging {
    /// What can hold focus in the hero.
    public enum Target: Hashable, Sendable {
        case play, myList, details
        /// The stops left of the first button and right of the last.
        case previousPage, nextPage
    }

    /// A page turn: how far to move, and which button takes focus back.
    public struct Turn: Equatable, Sendable {
        public let offset: Int
        public let refocus: Target
    }

    /// The turn for focus landing on `target`, or nil for a button.
    public static func turn(for target: Target?) -> Turn? {
        switch target {
        case .previousPage: Turn(offset: -1, refocus: .play)
        case .nextPage: Turn(offset: 1, refocus: .details)
        default: nil
        }
    }

    /// Whether the stops accept focus: only from inside the hero, and only
    /// when there is another page to turn to.
    public static func stopsAreFocusable(focused: Target?, pageCount: Int) -> Bool {
        focused != nil && pageCount > 1
    }

    /// Where focus arriving in the hero from outside it (`nil` before) settles.
    ///
    /// The tab bar and the rows span the screen while the buttons sit at the
    /// leading edge, so Down from a tab or Up from a card landed on whichever
    /// button was nearest, or skipped the hero for a row (N41 survey: Discover
    /// went to a Continue Watching card, Library to Details). The Apple TV
    /// app's hero takes you to its primary button; so does this one. The one
    /// exception is `returningTo`: the button that opened a page, which focus
    /// comes back to when that page is closed.
    public static func entry(arriving: Target, returningTo: Target?) -> Target {
        arriving == returningTo ? arriving : .play
    }

    /// Whether the hero's cycle holds still: only while anything in the hero
    /// has focus (the person is reading it or about to press). The Apple TV
    /// hero is a still with no trailer (`AppleTitlePagePolicy.offersTrailers`),
    /// so nothing else holds it.
    public static func cycleIsPaused(heroHasFocus: Bool) -> Bool {
        heroHasFocus
    }
}
