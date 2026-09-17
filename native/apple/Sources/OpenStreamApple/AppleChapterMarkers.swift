import Foundation

/// One chapter from a stream's own metadata.
public struct AppleChapter: Equatable, Sendable {
    public let title: String
    public let start: Double
    public let end: Double

    public init(title: String, start: Double, end: Double) {
        self.title = title
        self.start = start
        self.end = end
    }

    public var duration: Double { max(0, end - start) }

    public func contains(_ position: Double) -> Bool {
        position >= start && position < end
    }
}

/// Finding the opening sequence in a stream's chapter list, so the player can
/// offer to skip it.
///
/// This reads the markers the file already carries — Matroska chapters and the
/// MPEG-4 family's chapter tracks, which AVFoundation surfaces as timed
/// metadata groups. It never guesses from position and never compares episodes
/// to each other: audio fingerprinting across a season is the accurate way to
/// do this and is far too heavy for an Apple TV, so it is a separate decision
/// the owner has parked (2026-09-15).
///
/// The consequence is honest and worth stating: **content without chapter
/// markers gets no Skip Intro button**, and that is most content. What this
/// does cover, it covers exactly.
public enum AppleChapterMarkers: Sendable {
    /// Chapter names that mean "the opening", matched whole rather than as a
    /// substring.
    ///
    /// Substring matching would catch "Introduction", which in a documentary is
    /// the first *chapter of the programme* — skipping it would skip content
    /// the viewer wanted. A short exact vocabulary is worth more than a clever
    /// one that occasionally eats the first scene.
    static let introTitles: Set<String> = [
        "intro", "intro sequence", "opening", "opening credits", "opening titles",
        "opening sequence", "main titles", "title sequence", "titles", "theme",
        "theme song", "op",
    ]

    /// An opening has to be long enough to be worth a button and short enough
    /// that it is plainly not the programme.
    static let minimumDuration: Double = 5
    static let maximumDuration: Double = 300
    /// …and no more than this share of the runtime, which catches a
    /// mislabelled single-chapter file.
    static let maximumDurationFraction: Double = 0.25

    /// The opening sequence, or nil when the stream has no chapter that names
    /// one. `duration` is the programme's runtime; nil skips the fraction test.
    public static func intro(in chapters: [AppleChapter], duration: Double? = nil) -> AppleChapter? {
        chapters.first { chapter in
            guard introTitles.contains(normalized(chapter.title)) else { return false }
            guard chapter.duration >= minimumDuration, chapter.duration <= maximumDuration else { return false }
            if let duration, duration > 0, chapter.duration > duration * maximumDurationFraction { return false }
            return true
        }
    }

    /// Whether the Skip Intro button belongs on screen right now.
    ///
    /// `hasSkipped` is sticky for the rest of the item: once the viewer has
    /// skipped, seeking back into the opening must not put the button up again
    /// and invite a loop.
    public static func shouldOfferSkip(
        position: Double,
        intro: AppleChapter?,
        hasSkipped: Bool = false
    ) -> Bool {
        guard !hasSkipped, let intro else { return false }
        return intro.contains(position)
    }

    /// Where Skip Intro seeks to — the first frame after the opening.
    public static func skipDestination(intro: AppleChapter) -> Double {
        intro.end
    }

    /// Lowercased, punctuation removed, whitespace collapsed: "Opening
    /// Credits", "opening-credits" and "OPENING  CREDITS" are one name.
    static func normalized(_ value: String) -> String {
        let folded = value.folding(options: [.caseInsensitive, .diacriticInsensitive],
                                   locale: Locale(identifier: "en_US_POSIX"))
        let cleaned = folded.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        return String(cleaned).split(separator: " ").joined(separator: " ")
    }
}
