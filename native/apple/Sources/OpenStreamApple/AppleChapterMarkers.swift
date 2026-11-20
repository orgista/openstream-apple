import Foundation

/// Only approved embedded chapter transports are represented here.
public enum AppleChapterSource: Equatable, Sendable {
    case embeddedContainer
    case embeddedAVFoundation
}

public struct AppleChapterProvenance: Equatable, Sendable {
    public let source: AppleChapterSource
    /// Opaque identity for this loaded media version, never a transport URL.
    public let mediaVersion: UUID?

    public init(source: AppleChapterSource, mediaVersion: UUID? = nil) {
        self.source = source
        self.mediaVersion = mediaVersion
    }
}

/// Created only after finite, ordered bounds and the current runtime are checked.
public struct AppleChapterValidatedTiming: Equatable, Sendable {
    public let start: Double
    public let end: Double
    public let mediaDuration: Double?
    fileprivate init(start: Double, end: Double, mediaDuration: Double?) {
        self.start = start
        self.end = end
        self.mediaDuration = mediaDuration
    }
}

public struct AppleValidatedChapter: Equatable, Sendable {
    public let chapter: AppleChapter
    public let timing: AppleChapterValidatedTiming
    fileprivate init(chapter: AppleChapter, timing: AppleChapterValidatedTiming) {
        self.chapter = chapter
        self.timing = timing
    }
}

/// One chapter from a stream's own metadata.
public struct AppleChapter: Equatable, Sendable {
    public let title: String
    public let start: Double
    public let end: Double
    public let provenance: AppleChapterProvenance

    public init(title: String, start: Double, end: Double,
                provenance: AppleChapterProvenance = .init(source: .embeddedContainer)) {
        self.provenance = provenance
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
    /// Chapter starts as fractions of the runtime, for marks on the
    /// scrubber. The first chapter's start is the scrubber's own left end and
    /// gets no mark; starts outside the runtime and duplicates are dropped.
    /// Empty until the runtime is known.
    public static func validated(
        _ chapters: [AppleChapter], duration: Double?, mediaVersion: UUID? = nil
    ) -> [AppleValidatedChapter] {
        if let duration, !duration.isFinite || duration <= 0 { return [] }
        var starts = Set<Double>()
        return chapters.compactMap { chapter in
            guard chapter.provenance.mediaVersion == mediaVersion,
                  chapter.start.isFinite, chapter.end.isFinite,
                  chapter.start >= 0, chapter.end > chapter.start,
                  duration.map({ chapter.end <= $0 }) ?? true,
                  starts.insert(chapter.start).inserted else { return nil }
            return AppleValidatedChapter(chapter: chapter, timing: .init(
                start: chapter.start, end: chapter.end, mediaDuration: duration))
        }.sorted { $0.timing.start < $1.timing.start }
    }

    public static func scrubberFractions(chapters: [AppleChapter], duration: Double?, mediaVersion: UUID? = nil) -> [Double] {
        guard let duration, duration.isFinite, duration > 0 else { return [] }
        var seen = Set<Int>()
        return validated(chapters, duration: duration, mediaVersion: mediaVersion)
            .map { $0.timing.start / duration }
            .filter { $0.isFinite && $0 > 0.001 && $0 < 0.999 }
            .sorted()
            .filter { seen.insert(Int(($0 * 10_000).rounded())).inserted }
    }

    public static func intro(in chapters: [AppleChapter], duration: Double? = nil, mediaVersion: UUID? = nil) -> AppleChapter? {
        validated(chapters, duration: duration, mediaVersion: mediaVersion).map(\.chapter).first { chapter in
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
    public static func skipDestination(
        intro: AppleChapter, duration: Double?, mediaVersion: UUID? = nil
    ) -> Double? {
        guard duration != nil else { return nil }
        return validated([intro], duration: duration, mediaVersion: mediaVersion).first?.timing.end
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
