import Foundation
import Observation
import AetherEngine

/// Where a disc item starts: its own menu (Play Disc) or straight into the
/// main feature (Skip to Movie).
///
public enum AppleDiscPlaybackStart: String, Equatable, Sendable {
    case menu
    case mainTitle

    /// Explicit Titles row choices bypass navigation; nil lets the engine
    /// choose the main title when starting without menus.
    public static func engineTitleID(start: Self?, titleID: Int?) -> Int? { titleID }

    /// The line traced when a disc load starts.
    public static func traceLine(start: Self, titleID: Int?) -> String {
        if let titleID { return "disc start title \(titleID)" }
        switch start {
        case .menu: return "disc start menu"
        case .mainTitle: return "disc start main title"
        }
    }
}

/// What a disc image holds, as far as its menus go. DVD menus (IFO and the
/// DVD virtual machine) play; Blu-ray and UHD menus (HDMV, BD-J) do not: BD-J
/// needs a Java runtime, and Infuse does not offer them either. A Blu-ray
/// plays its main feature, with no "Play Disc" or "Skip to Movie" wording.
public enum AppleDiscFormat: String, Equatable, Sendable {
    case dvd
    case bluRay

    public var supportsMenu: Bool { self == .dvd }
}

/// One disc start: the start choice and, from the Titles row, the title.
public struct AppleDiscPlaybackChoice: Equatable, Sendable {
    public var start: AppleDiscPlaybackStart
    public var titleID: Int?
    public var format: AppleDiscFormat

    /// A Blu-ray asked for its menu starts at the main feature instead.
    public init(start: AppleDiscPlaybackStart, titleID: Int? = nil, format: AppleDiscFormat = .dvd) {
        self.start = format.supportsMenu ? start : .mainTitle
        self.titleID = titleID
        self.format = format
    }

    /// The `discTitleID` handed to `AetherEngine.load`.
    public var engineTitleID: Int? { AppleDiscPlaybackStart.engineTitleID(start: start, titleID: titleID) }

    /// The title to open when the disc's titles are already known: the
    /// chosen one, or for a Blu-ray's main feature the policy's pick when it
    /// is not the engine's own (id 0).
    func engineTitleID(knownTitles: [AppleDiscTitle]) -> Int? {
        engineTitleID ?? replacementMainTitleID(for: knownTitles)
    }

    /// The main feature to switch to once the engine has listed the titles,
    /// or nil to keep the one it opened.
    func replacementMainTitleID(for titles: [AppleDiscTitle]) -> Int? {
        guard format == .bluRay, start == .mainTitle, titleID == nil,
              let pick = AppleDiscMainTitlePolicy.mainTitleID(titles), pick != 0 else { return nil }
        return pick
    }
    public var engineStartMode: DVDStartMode { titleID == nil && start == .menu ? .menu : .mainTitle }
    public var traceLine: String {
        let line = AppleDiscPlaybackStart.traceLine(start: start, titleID: titleID)
        guard format == .bluRay, titleID == nil else { return line }
        return line + " (Blu-ray: disc menus are not supported, playing the main feature)"
    }
}

/// Which library files are disc images: an ISO (or a raw UDF image), or a
/// file inside a DVD `VIDEO_TS` / Blu-ray `BDMV` folder.
public enum AppleDiscImagePolicy {
    /// Image extensions the library scanners pick up beside the video files.
    /// The engine opens these through its disc adapter (`DiscReader`).
    public static let scannedExtensions: Set<String> = ["iso"]
    static let imageExtensions: Set<String> = ["iso", "udf"]
    static let folderNames: Set<String> = ["VIDEO_TS", "BDMV"]

    /// Plain string work: the library asks this of every file when its
    /// titles change, and building a URL per path cost ~110 ms of main thread
    /// for 1,472 files on an Apple TV 4K (2026-10-16).
    public static func isDiscImage(path: String) -> Bool {
        let components = path.split(separator: "/")
        guard let name = components.last else { return false }
        if let dot = name.lastIndex(of: "."), dot != name.startIndex,
           imageExtensions.contains(name[name.index(after: dot)...].lowercased()) { return true }
        return components.dropLast().contains { folderNames.contains($0.uppercased()) }
    }

    public static func isDiscImage(_ item: AppleLibraryItem) -> Bool {
        isDiscImage(path: item.relativePath) || isDiscImage(path: item.url.path)
    }

    /// The largest DVD (DVD-9) holds 8.5 GB; an image past this is a Blu-ray.
    static let dvdMaximumBytes: Int64 = 9_000_000_000
    /// Release-name words that only Blu-ray and UHD images carry.
    static let bluRayNameTokens: Set<String> = ["BLURAY", "BDMV", "UHD", "BDREMUX", "BD25", "BD50", "BD66", "BD100"]

    /// Blu-ray or DVD, before the engine has read the image: a `BDMV` folder,
    /// a Blu-ray release name, or a size no DVD reaches. Anything else is a
    /// DVD, whose menu the engine opens or falls back from on its own.
    public static func format(path: String, sizeBytes: Int64 = 0) -> AppleDiscFormat {
        let url = URL(fileURLWithPath: path)
        let folders = url.pathComponents.dropLast().map { $0.uppercased() }
        if folders.contains("BDMV") { return .bluRay }
        if folders.contains("VIDEO_TS") { return .dvd }
        let words = url.deletingPathExtension().lastPathComponent.uppercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        let joinedPairs = zip(words, words.dropFirst()).map { $0 + $1 }
        if words.contains(where: bluRayNameTokens.contains) || joinedPairs.contains("BLURAY") { return .bluRay }
        return sizeBytes > dvdMaximumBytes ? .bluRay : .dvd
    }

    public static func format(_ item: AppleLibraryItem) -> AppleDiscFormat {
        let named = format(path: item.relativePath, sizeBytes: item.sizeBytes)
        return named == .bluRay ? named : format(path: item.url.path, sizeBytes: item.sizeBytes)
    }
}

/// A title on a disc, as the Titles row lists it.
public struct AppleDiscTitle: Identifiable, Equatable, Sendable {
    public let id: Int
    public let durationSeconds: Double
    public let chapterCount: Int

    public init(id: Int, durationSeconds: Double, chapterCount: Int) {
        self.id = id
        self.durationSeconds = durationSeconds
        self.chapterCount = chapterCount
    }

    /// Set by `AppleDiscTitleList` on the title it leads with.
    var isMainFeature = false

    /// "Main Feature" for the title played as the film, else "Title 4".
    public var name: String { isMainFeature ? "Main Feature" : "Title \(id + 1)" }

    /// "1 hr 42 min", "12 min", "45 sec".
    public var durationLabel: String {
        let seconds = Int(durationSeconds.rounded())
        guard seconds >= 60 else { return "\(max(seconds, 0)) sec" }
        return AppleTitleMetadataPresentation.formattedRuntime(seconds / 60)
    }

    /// "1 hr 42 min · 24 chapters"; a title with one chapter or none gives
    /// its length alone.
    public var detailLabel: String {
        chapterCount > 1 ? "\(durationLabel) · \(chapterCount) chapters" : durationLabel
    }

    /// Whether two engine titles are one title the disc lists twice: the same
    /// length within `tolerance` and the same chapters. Obfuscated Blu-rays
    /// list hundreds of playlists that differ only in clip order.
    func duplicates(_ other: Self, tolerance: Double = 2) -> Bool {
        abs(durationSeconds - other.durationSeconds) <= tolerance && chapterCount == other.chapterCount
    }
}

/// Which Blu-ray title is the film. The engine has dropped short and
/// repeated-clip decoy playlists and made the longest title id 0. libbluray's
/// guess, which Infuse plays (REA 2026-10-17), puts chapters ahead of length:
/// between two playlists over half an hour, one with chapters beats one with
/// none (or one) when their counts differ by more than five. Otherwise the
/// engine's pick stands. libbluray then compares video and audio streams,
/// which the engine (07afad62) does not read from the playlists.
enum AppleDiscMainTitlePolicy {
    static let longTitleSeconds: Double = 30 * 60
    static let chapterGap = 5

    /// The main feature's id; nil for no titles.
    static func mainTitleID(_ titles: [AppleDiscTitle]) -> Int? {
        let ordered = titles.sorted { $0.id < $1.id }
        guard var best = ordered.first else { return nil }
        for title in ordered.dropFirst() where prefers(title, over: best) { best = title }
        return best.id
    }

    static func prefers(_ title: AppleDiscTitle, over best: AppleDiscTitle) -> Bool {
        title.durationSeconds > longTitleSeconds && best.durationSeconds > longTitleSeconds
            && min(title.chapterCount, best.chapterCount) < 2
            && title.chapterCount - best.chapterCount > chapterGap
    }
}

/// The disc's Titles row: the main feature first, each title once, nothing
/// under two minutes (logos, trailers, menu stubs), and a short list, with the
/// rest behind a More card so the row stays finite on the remote.
public struct AppleDiscTitleList: Equatable, Sendable {
    /// Titles shown before More; the first is the main feature.
    public let visible: [AppleDiscTitle]
    /// Titles More reveals.
    public let more: [AppleDiscTitle]

    public static let minimumSeconds: Double = 120
    public static let visibleLimit = 6
    public static let moreLimit = 24

    public var isEmpty: Bool { visible.isEmpty }
    public var all: [AppleDiscTitle] { visible + more }

    public init(visible: [AppleDiscTitle] = [], more: [AppleDiscTitle] = []) {
        self.visible = visible
        self.more = more
    }

    /// `titles` in the engine's order: longest first. The main feature
    /// (`AppleDiscMainTitlePolicy`, else id 0) leads even when a longer
    /// playlist exists. No row for a disc with a single title worth listing.
    public init(_ titles: [AppleDiscTitle]) {
        let mainID = AppleDiscMainTitlePolicy.mainTitleID(titles) ?? 0
        var main = titles.first { $0.id == mainID }
        main?.isMainFeature = true
        let ordered = (main.map { [$0] } ?? []) + titles.filter { $0.id != mainID }
            .sorted { $0.durationSeconds == $1.durationSeconds ? $0.id < $1.id : $0.durationSeconds > $1.durationSeconds }
        var kept: [AppleDiscTitle] = []
        for title in ordered where title.durationSeconds >= Self.minimumSeconds {
            if !kept.contains(where: { $0.duplicates(title) }) { kept.append(title) }
        }
        guard kept.count > 1 else { self.init(); return }
        self.init(visible: Array(kept.prefix(Self.visibleLimit)),
                  more: Array(kept.dropFirst(Self.visibleLimit).prefix(Self.moreLimit)))
    }
}

/// The disc items the app knows about, for the poster badge and the title
/// page: a set of catalog keys (filled by `AppleLocalLibraryStore`) and the
/// titles each disc file was found to hold.
@MainActor @Observable
public final class AppleDiscCatalog {
    public static let shared = AppleDiscCatalog()

    public private(set) var keys: Set<String> = []
    public private(set) var titles: [URL: [AppleDiscTitle]] = [:]
    /// What the engine's read of a local image found it to be.
    public private(set) var formats: [URL: AppleDiscFormat] = [:]

    public init() {}

    func replaceKeys(_ newKeys: Set<String>) {
        guard newKeys != keys else { return }
        keys = newKeys
    }

    func record(_ discTitles: [AppleDiscTitle], for fileURL: URL) {
        guard !discTitles.isEmpty, titles[fileURL] != discTitles else { return }
        titles[fileURL] = discTitles
    }

    func record(_ format: AppleDiscFormat, for fileURL: URL) {
        guard formats[fileURL] != format else { return }
        formats[fileURL] = format
    }

    /// Blu-ray or DVD: the engine's read of the image when there was one,
    /// else its name, folder and size (`AppleDiscImagePolicy.format`).
    public func format(for file: AppleLibraryItem) -> AppleDiscFormat {
        formats[file.url] ?? AppleDiscImagePolicy.format(file)
    }

    /// Whether a poster for `item` gets the disc badge.
    public func contains(_ item: AppleCatalogItem) -> Bool {
        guard !keys.isEmpty else { return false }
        return keys.contains(item.id) || keys.contains(Self.matchKey(item))
    }

    /// The same identity `AppleLocalLibraryStore.matches` uses: the IMDb id,
    /// or the folded name and year.
    nonisolated static func matchKey(_ item: AppleCatalogItem) -> String {
        if item.mediaID.hasPrefix("tt") { return "\(item.type):\(item.mediaID)" }
        let folded = item.name
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
        return "\(item.type):\(folded):\((item.releaseInfo ?? "").prefix(4))"
    }
}
