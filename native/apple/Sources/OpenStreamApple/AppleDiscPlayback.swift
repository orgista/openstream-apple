import Foundation
import Observation

/// Where a disc item starts: its own menu (Play Disc) or straight into the
/// main feature (Skip to Movie).
///
/// The engine has no menu API yet, so both play the main title today. Every
/// disc start still goes through this one value down to
/// `AetherPlaybackEngine`, so wiring the engine's menu option later is the
/// single line in `engineTitleID`.
public enum AppleDiscPlaybackStart: String, Equatable, Sendable {
    case menu
    case mainTitle

    /// The disc title the engine opens: an explicit title (the Titles row)
    /// wins; otherwise nil, which is the engine's main title. `.menu` maps
    /// to the main title until the engine's menu option exists.
    public static func engineTitleID(start: Self?, titleID: Int?) -> Int? {
        if let titleID { return titleID }
        switch start {
        case .menu?: return nil // engine menu API pending: main title
        case .mainTitle?, nil: return nil
        }
    }

    /// The line traced when a disc load starts.
    public static func traceLine(start: Self, titleID: Int?) -> String {
        if let titleID { return "disc start title \(titleID)" }
        switch start {
        case .menu: return "disc start menu → main title (engine menu pending)"
        case .mainTitle: return "disc start main title"
        }
    }
}

/// One disc start: the start choice and, from the Titles row, the title.
public struct AppleDiscPlaybackChoice: Equatable, Sendable {
    public var start: AppleDiscPlaybackStart
    public var titleID: Int?

    public init(start: AppleDiscPlaybackStart, titleID: Int? = nil) {
        self.start = start
        self.titleID = titleID
    }

    /// The `discTitleID` handed to `AetherEngine.load`.
    public var engineTitleID: Int? { AppleDiscPlaybackStart.engineTitleID(start: start, titleID: titleID) }
    public var traceLine: String { AppleDiscPlaybackStart.traceLine(start: start, titleID: titleID) }
}

/// Which library files are disc images: an ISO (or a raw UDF image), or a
/// file inside a DVD `VIDEO_TS` / Blu-ray `BDMV` folder.
public enum AppleDiscImagePolicy {
    /// Image extensions the library scanners pick up beside the video files.
    /// The engine opens these through its disc adapter (`DiscReader`).
    public static let scannedExtensions: Set<String> = ["iso"]
    static let imageExtensions: Set<String> = ["iso", "udf"]
    static let folderNames: Set<String> = ["VIDEO_TS", "BDMV"]

    public static func isDiscImage(path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        if imageExtensions.contains(url.pathExtension.lowercased()) { return true }
        return url.pathComponents.dropLast().contains { folderNames.contains($0.uppercased()) }
    }

    public static func isDiscImage(_ item: AppleLibraryItem) -> Bool {
        isDiscImage(path: item.relativePath) || isDiscImage(path: item.url.path)
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

    /// "Title 1".
    public var name: String { "Title \(id + 1)" }

    /// "1 hr 42 min", "12 min", "45 sec".
    public var durationLabel: String {
        let seconds = Int(durationSeconds.rounded())
        guard seconds >= 60 else { return "\(max(seconds, 0)) sec" }
        return AppleTitleMetadataPresentation.formattedRuntime(seconds / 60)
    }

    /// The titles worth a row: longest first (the engine's order, id 0 is
    /// the main feature), nothing under a few seconds (menu stubs, logos),
    /// and no row at all for a disc with a single title.
    public static func rowTitles(_ titles: [Self], minimumSeconds: Double = 5) -> [Self] {
        let kept = titles.filter { $0.durationSeconds >= minimumSeconds }
            .sorted { $0.durationSeconds == $1.durationSeconds ? $0.id < $1.id : $0.durationSeconds > $1.durationSeconds }
        return kept.count > 1 ? kept : []
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

    public init() {}

    func replaceKeys(_ newKeys: Set<String>) {
        guard newKeys != keys else { return }
        keys = newKeys
    }

    func record(_ discTitles: [AppleDiscTitle], for fileURL: URL) {
        guard !discTitles.isEmpty, titles[fileURL] != discTitles else { return }
        titles[fileURL] = discTitles
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
