import Foundation

/// Discover's rows in the Apple TV app's style (N11 iPhone portrait, N13 Mac:
/// owner Figma + inspo PDF A2–A4). Pure rules; the views are in
/// `AppleDiscoverPhoneRowViews.swift`.
enum AppleDiscoverPhoneRowMetrics {
    /// Continue Watching and the other still rails (A2, Figma 248 pt).
    static let stillWidth: CGFloat = 248
    /// Top 10: two tiles and a peek of the third across a 393 pt phone (A3/A4).
    static let rankedWidth: CGFloat = 200
    /// New Releases-style poster rails (Figma 148 pt, 2:3).
    static let posterWidth: CGFloat = 148
    static let cornerRadius: CGFloat = 12
    static let cardGap: CGFloat = 12
    static let progressHeight: CGFloat = 3
}

/// The Apple TV app row style Discover's rails take, and at what size: the
/// iPhone held upright (N11) and the Mac (N13) share every rule and view; only
/// the numbers and the type sizes differ. `nil` in the environment is every
/// other screen and platform, which keep their own look.
struct AppleDiscoverRowStyle: Equatable, Sendable {
    enum Platform: Equatable, Sendable { case phone, mac }

    var platform: Platform
    var stillWidth: CGFloat
    var rankedWidth: CGFloat
    var posterWidth: CGFloat
    var horizontalInset: CGFloat
    var cardGap: CGFloat

    static let phone = Self(platform: .phone,
                            stillWidth: AppleDiscoverPhoneRowMetrics.stillWidth,
                            rankedWidth: AppleDiscoverPhoneRowMetrics.rankedWidth,
                            posterWidth: AppleDiscoverPhoneRowMetrics.posterWidth,
                            horizontalInset: 16,
                            cardGap: AppleDiscoverPhoneRowMetrics.cardGap)

    /// The Mac: tiles grow with the window, and are sized so that a whole
    /// number of them and part of the next are in view at any width (A11
    /// peek) — in a 1440 pt window about 310 pt stills, 250 pt Top 10 tiles
    /// and 176 pt posters. `inset` is the hero copy's, so the rails line up
    /// under it.
    static func mac(contentWidth: CGFloat, inset: CGFloat) -> Self {
        let available = contentWidth - inset
        func width(_ fraction: CGFloat, _ range: ClosedRange<CGFloat>) -> CGFloat {
            let preferred = min(max(contentWidth * fraction, range.lowerBound), range.upperBound)
            return AppleDiscoverMacRowMetrics.peekWidth(available: available, preferred: preferred,
                                                        gap: AppleDiscoverMacRowMetrics.cardGap, range: range)
        }
        return Self(platform: .mac,
                    stillWidth: width(0.22, 260...380),
                    rankedWidth: width(0.18, 200...320),
                    posterWidth: width(0.125, 140...230),
                    horizontalInset: inset,
                    cardGap: AppleDiscoverMacRowMetrics.cardGap)
    }
}

enum AppleDiscoverMacRowMetrics {
    static let cardGap: CGFloat = 16
    /// How much of the trailing tile shows past the last whole one.
    static let peekFraction: CGFloat = 0.3

    /// The tile width nearest `preferred` that leaves `peekFraction` of a
    /// tile at the trailing edge of `available`, within `range`. Before the
    /// window is measured it is `preferred`.
    static func peekWidth(available: CGFloat, preferred: CGFloat, gap: CGFloat,
                          range: ClosedRange<CGFloat>) -> CGFloat {
        guard available > 0, available.isFinite else { return preferred }
        let whole = max(1, ((available + gap) / (preferred + gap) - peekFraction).rounded())
        let width = (available - whole * gap) / (whole + peekFraction)
        return min(max(width, range.lowerBound), range.upperBound).rounded()
    }
}

/// Paging a Mac rail with its hover-revealed ‹ › buttons.
enum AppleRailPaging {
    struct Geometry: Equatable, Sendable {
        var offset: CGFloat = 0
        var contentWidth: CGFloat = 0
        var visibleWidth: CGFloat = 0
    }

    static func canPageBack(_ geometry: Geometry) -> Bool { geometry.offset > 1 }

    static func canPageForward(_ geometry: Geometry) -> Bool {
        geometry.offset + geometry.visibleWidth < geometry.contentWidth - 1
    }

    /// A page is most of the visible width, so the tile that was clipped at
    /// the edge is whole on the next page; never past either end.
    static func target(_ geometry: Geometry, forward: Bool) -> CGFloat {
        let page = max(geometry.visibleWidth * 0.8, 1)
        let end = max(geometry.contentWidth - geometry.visibleWidth, 0)
        return min(max(geometry.offset + (forward ? page : -page), 0), end)
    }

    /// The rail scrolls to invisible anchors laid every `anchorStep` points
    /// behind its tiles; a target rounds to the nearest one.
    static let anchorStep: CGFloat = 40

    static func anchorCount(contentWidth: CGFloat, step: CGFloat = anchorStep) -> Int {
        guard contentWidth.isFinite, contentWidth > 0, step.isFinite, step > 0 else { return 0 }
        return Int((contentWidth / step).rounded(.up))
    }

    static func anchorIndex(for offset: CGFloat, step: CGFloat = anchorStep) -> Int {
        guard offset.isFinite, offset > 0, step.isFinite, step > 0 else { return 0 }
        return Int((offset / step).rounded())
    }

    /// Paging by whole tiles when the rail knows its tile pitch (tile width
    /// plus gap): the anchors sit one pitch apart, so anchor `n` scrolled to
    /// the leading edge puts tile `n` exactly at the row's inset, under the
    /// header, as the Apple TV app's shelves land. Paging by 80 % of the
    /// width to 40 pt anchors left the first tile at an arbitrary x — 16 pt
    /// on a 43 pt inset in a 1440 pt window (N54).
    ///
    /// A page is the number of tiles wholly in view past the inset (the
    /// trailing peek is not counted, so it is whole on the next page). The
    /// last anchor is the first one at or past the scroll's end; the scroll
    /// view stops at the end, so the row finishes flush right.
    /// A rail of `tileCount` equal tiles `gap` apart, inset on both sides,
    /// is `inset·2 + count·width + (count−1)·gap` wide, so the pitch
    /// (width + gap) follows from its measured content width. Nil until the
    /// rail is measured.
    static func tilePitch(contentWidth: CGFloat, tileCount: Int, inset: CGFloat, gap: CGFloat) -> CGFloat? {
        guard tileCount > 0, contentWidth.isFinite else { return nil }
        let pitch = (contentWidth - 2 * inset + gap) / CGFloat(tileCount)
        return pitch > gap ? pitch : nil
    }

    static func tileAnchorIndex(_ geometry: Geometry, forward: Bool, pitch: CGFloat, inset: CGFloat) -> Int {
        guard pitch.isFinite, pitch > 0 else { return 0 }
        let whole = max(1, Int(((geometry.visibleWidth - inset) / pitch).rounded(.down)))
        let current = Int((max(geometry.offset, 0) / pitch).rounded())
        let end = max(geometry.contentWidth - geometry.visibleWidth, 0)
        let last = Int((end / pitch).rounded(.up))
        return min(max(current + (forward ? whole : -whole), 0), last)
    }

    /// Strings, so they can never collide with a tile's own id (Top 10 tiles
    /// are keyed by their Int rank).
    static func anchorID(_ index: Int) -> String { "openstream.rail.page.\(index)" }
}

/// The copy under and on a Continue Watching still.
enum AppleContinueWatchingCaption {
    /// "57 MIN LEFT", "1 HR 5 MIN LEFT"; nil when the length is not known, so
    /// the pill is hidden rather than guessed (DESIGN-SPEC: real time only).
    static func remainingLabel(position: Double, duration: Double) -> String? {
        guard duration.isFinite, position.isFinite, duration > 0, position >= 0, position < duration else { return nil }
        let minutes = max(1, Int((duration - position) / 60 + 0.5))
        let hours = minutes / 60
        let rest = minutes % 60
        if hours == 0 { return "\(minutes) MIN LEFT" }
        return rest == 0 ? "\(hours) HR LEFT" : "\(hours) HR \(rest) MIN LEFT"
    }

    /// Season and episode from a series part id (`tt…:1:3` → 1, 3).
    static func episode(partID: String?) -> (season: Int, episode: Int)? {
        guard let parts = partID?.split(separator: ":"), parts.count >= 3,
              let season = Int(parts[parts.count - 2]), let episode = Int(parts[parts.count - 1]),
              season >= 0, episode > 0 else { return nil }
        return (season, episode)
    }

    /// "Continue · S1, E3" for an episode, "Movie" for a film, and "Continue"
    /// for a show whose episode is not known.
    static func subtitle(type: String, partID: String?) -> String {
        if type.caseInsensitiveCompare("movie") == .orderedSame { return "Movie" }
        guard let value = episode(partID: partID) else { return "Continue" }
        return "Continue · S\(value.season), E\(value.episode)"
    }
}

/// A4 rail rhythm: consecutive rails alternate stills and posters so the feed
/// never reads as one long list.
enum AppleDiscoverRailRhythm {
    enum Shape: Equatable, Sendable { case still, poster }

    /// Indices into `shapes`, reordered so that no two neighbours share a shape
    /// while both kinds remain. The first rail stays first (Continue Watching
    /// must peek under the hero), and rails of one shape keep their order.
    static func order(_ shapes: [Shape]) -> [Int] {
        guard let first = shapes.indices.first else { return [] }
        var stills = shapes.indices.filter { shapes[$0] == .still && $0 != first }
        var posters = shapes.indices.filter { shapes[$0] == .poster && $0 != first }
        var result = [first]
        var last = shapes[first]
        while !stills.isEmpty || !posters.isEmpty {
            let takeStill = last == .poster ? !stills.isEmpty : posters.isEmpty
            let next = takeStill ? stills.removeFirst() : posters.removeFirst()
            result.append(next)
            last = shapes[next]
        }
        return result
    }
}

/// A4 note: text under a tile is clamped at a word boundary, never mid-word.
enum AppleWordClamp {
    /// The full text, then ever-shorter word prefixes ending in "…". The view
    /// shows the first one that fits its line budget.
    static func candidates(_ text: String) -> [String] {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.count > 1 else { return [text] }
        var values = [text]
        for count in stride(from: words.count - 1, through: 1, by: -1) {
            var prefix = words.prefix(count).joined(separator: " ")
            while let last = prefix.last, ",;:-–—·".contains(last) { prefix.removeLast() }
            values.append(prefix + "…")
        }
        return values
    }
}
