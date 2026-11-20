import Foundation

/// How Live Search takes its pushed page down on iPhone, iPad, Mac and Vision Pro.
enum AppleLiveSearchExit: Equatable {
    /// Pop the page now: its field is not active.
    case pop
    /// End the field, then pop once it has gone (`AppleSearchEndObserver`).
    case endFieldFirst

    /// After `isSearching` turns false the field is still collapsing. Observed on
    /// iPadOS 26.x: a pop asked for during that animation was dropped.
    static let fieldCollapse = Duration.milliseconds(350)
    /// The page pops by then even if the field never reports its end (it was never
    /// focused, or the system kept it), so a pick can't leave Search stuck open.
    static let deadline = Duration.seconds(1)

    /// What a request to leave does. Nil when there is nothing to do: the page is not
    /// shown, or it is already leaving and `deadline` bounds the wait.
    static func next(isShown: Bool, fieldPresented: Bool, isLeaving: Bool) -> AppleLiveSearchExit? {
        guard isShown, !isLeaving else { return nil }
        return fieldPresented ? .endFieldFirst : .pop
    }
}
