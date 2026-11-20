import Foundation

/// What a home hero's title slot draws.
enum AppleHeroTitlePresentation: Equatable, Sendable {
    /// The wordmark: drawn, or its slot held empty while it loads, so
    /// nothing moves when it lands (owner, N62).
    case wordmark(URL)
    /// No wordmark yet, but the page's lookup for one is still running: the
    /// slot is held empty, as for a loading mark, so a mark found in time
    /// is not preceded by the name (N63: iPhone showed the name for about a
    /// second at launch, then swapped to the logo).
    case holding
    /// The name: there is no wordmark, it failed, or it did not load within
    /// the grace. The name then keeps the slot; a mark that lands later
    /// does not replace it.
    case name

    /// The wordmark the slot is loading or drawing, if any.
    var wordmarkURL: URL? {
        if case .wordmark(let url) = self { return url }
        return nil
    }

    var showsName: Bool { self == .name }
}

/// The active home-title policy, used by AppleHeroTitleLockup on every
/// platform, including AppleTVBillboardView. A poster fallback still names
/// the title; loaded logos win until the text fallback becomes sticky.
enum AppleHeroTitlePolicy {
    /// How long a page holds its wordmark's slot empty while the mark
    /// loads. Owner, N62: the hero showed the name, then swapped to the logo
    /// and the layout jumped. While the logo loads there is no title and its
    /// space stays reserved; the name stands in only when the logo is
    /// missing, fails, or has not loaded within five seconds. The page gate
    /// and the iPhone preload warm the marks, so one normally lands at once.
    static let loadingGrace: TimeInterval = 5.0

    /// - Parameters:
    ///   - wordmark: the page's wordmark URL, if it has one.
    ///   - loaded: the wordmark URL that has drawn, if any.
    ///   - failed: the wordmark URL that failed to load, if any.
    ///   - graceExpired: whether `loadingGrace` has passed since the page was shown.
    ///   - lookupPending: the page's wordmark is not known yet because the
    ///     lookup for it has not finished.
    ///   - nameShown: the name has already been on screen for this page; it
    ///     then keeps the slot, so a mark that arrives later never swaps in.
    static func presentation(
        wordmark: URL?, loaded: URL?, failed: URL?, graceExpired: Bool,
        lookupPending: Bool = false, nameShown: Bool = false
    ) -> AppleHeroTitlePresentation {
        if nameShown { return .name }
        guard let wordmark else { return lookupPending && !graceExpired ? .holding : .name }
        guard wordmark != failed else { return .name }
        if wordmark == loaded || !graceExpired { return .wordmark(wordmark) }
        return .name
    }

    /// The name latch after the hero moves from page `old` to page `new`.
    /// A latch belongs to one showing of one page: a wordmark found while
    /// the name stood in is not swapped in under the viewer, but the next
    /// time the page comes round it draws with its mark (owner 2026-09-29:
    /// heroes stayed on the name all session). Carousels that give each page
    /// its own view start clean anyway; this covers the ones that reuse it.
    static func nameLatch(_ latched: String?, from old: String, to new: String) -> String? {
        old == new ? latched : nil
    }

    /// Whether a Discover hero's wordmark lookup is still running, for every
    /// hero (iPhone, iPad, Mac, Apple TV, the rotating one): until the page's
    /// lookup has finished it holds the slot rather than drawing the name a
    /// found logo would replace (N64). A page whose mark the page gate saw
    /// fail has nothing to wait for.
    /// - Parameters:
    ///   - mediaID: the hero's media id.
    ///   - resolved: the media ids whose lookup has finished.
    ///   - wordmarkFailed: the page gate saw this page's wordmark fail.
    static func wordmarkLookupPending(mediaID: String, resolved: Set<String>, wordmarkFailed: Bool) -> Bool {
        !wordmarkFailed && !resolved.contains(mediaID)
    }

    static func phoneWordmarkLookupPending(metadataLoaded: Bool, lookupPending: Bool,
                                          validatedTaskID: String?, taskID: String) -> Bool {
        !metadataLoaded || lookupPending || validatedTaskID != taskID
    }

    @MainActor
    static func resolveWordmark(lookup: () async -> AppleHeroArtworkUpgrade.Artwork,
                                apply: (AppleHeroArtworkUpgrade.Artwork) -> Void, didResolve: () -> Void) async {
        let artwork = await lookup()
        guard !Task.isCancelled else { return }
        apply(artwork)
        didResolve()
    }
}
