import Foundation

/// How the home billboard should say what it is showing.
///
/// It always drew `Text(item.name)`, which produced two different complaints
/// from the owner on the same day (2026-09-15):
///
/// - *"artwork with word mark and then the work mark is redundant"* — the
///   billboard falls back to the **poster** when a title has no backdrop, and
///   posters carry their own title treatment. Drawing our name on top of a
///   poster that already says it gives the title twice.
/// - *"the heros don't load the word mark art just text"* — the title page
///   shows a real wordmark, the billboard never could, because
///   `AppleCatalogItem` carries no logo at all and nothing asked the preview
///   assets cache for one.
///
/// Both are the same decision made once, in one place, testable without a view.
public enum AppleTVBillboardTitleTreatment: Equatable, Sendable {
    /// Draw the title's own wordmark art.
    case wordmark(URL)
    /// Draw the name as text — a clean backdrop with no wordmark available.
    case text
    /// Draw nothing: the artwork already says the title.
    case none

    /// - Parameters:
    ///   - hasBackdrop: whether a true backdrop was found. False means the view
    ///     is showing the poster instead, which already has the title on it.
    ///   - wordmark: the title's logo art, if the preview assets cache has it.
    public static func choose(hasBackdrop: Bool, wordmark: URL?) -> Self {
        // A poster speaks for itself. Anything drawn over it is a second copy
        // of the same words.
        guard hasBackdrop else { return .none }
        if let wordmark { return .wordmark(wordmark) }
        return .text
    }
}
