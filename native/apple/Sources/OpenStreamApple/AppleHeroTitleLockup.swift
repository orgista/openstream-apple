import SwiftUI

/// A home hero's title slot: the wordmark, its slot held empty while it
/// loads, or the name when it is missing, failed or slow
/// (`AppleHeroTitlePolicy`). Each hero supplies its own
/// mark and name styling; this owns only which of the two is on screen.
struct AppleHeroTitleLockup<Mark: View, Name: View>: View {
    /// The page being shown; the loading grace restarts when it changes.
    let pageID: String
    let wordmark: URL?
    /// Whether the page's wordmark lookup is still running, for a hero that
    /// tracks it (the Discover heroes; `nil` elsewhere). While it runs a nil
    /// `wordmark` may still become one, so the slot is held empty until it
    /// does or the grace runs out; and once the name has drawn it keeps the
    /// slot, so a wordmark found later never swaps in.
    var wordmarkLookupPending: Bool? = nil
    var alignment: Alignment = .leading
    /// The wordmark view. It must call `onLoadResult` as
    /// `AppleTrimmedTitleLogo` does: true once drawn, false when it failed.
    @ViewBuilder let mark: (_ url: URL, _ onLoadResult: @escaping (Bool) -> Void) -> Mark
    @ViewBuilder let name: () -> Name

    @State private var loadedWordmark: URL?
    @State private var failedWordmark: URL?
    /// The page whose grace has run out. Keyed by page rather than a flag, so
    /// the frame a new page arrives on does not inherit the last one's.
    @State private var graceExpiredPage: String?
    /// The page whose name has been drawn; from then on it keeps the slot.
    @State private var nameShownPage: String?

    var body: some View {
        let presentation = AppleHeroTitlePolicy.presentation(
            wordmark: wordmark, loaded: loadedWordmark, failed: failedWordmark, graceExpired: graceExpiredPage == pageID,
            lookupPending: wordmarkLookupPending ?? false,
            nameShown: wordmarkLookupPending != nil && nameShownPage == pageID
        )
        ZStack(alignment: alignment) {
            if let url = presentation.wordmarkURL {
                // Holds its slot empty until the mark draws, so the lockup
                // never moves when it lands (N62).
                mark(url) { loaded in
                    if loaded { loadedWordmark = url } else { failedWordmark = url }
                }
            } else if presentation.showsName {
                name()
                    // Keyed on the page, so a carousel that reuses this view
                    // for the next page latches that page too.
                    .task(id: pageID) { nameShownPage = pageID }
            } else {
                // Held: the name's space, unseen and unread, so the copy
                // around it does not move while the lookup runs.
                name()
                    .hidden()
                    .accessibilityHidden(true)
            }
        }
        .onChange(of: pageID) { old, new in
            nameShownPage = AppleHeroTitlePolicy.nameLatch(nameShownPage, from: old, to: new)
        }
        .task(id: pageID) {
            try? await Task.sleep(for: .seconds(AppleHeroTitlePolicy.loadingGrace))
            guard !Task.isCancelled else { return }
            graceExpiredPage = pageID
        }
    }
}
