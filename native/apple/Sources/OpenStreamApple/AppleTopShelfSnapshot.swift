import CryptoKit
import Foundation
import Observation

#if os(tvOS)
import TVServices
#endif

#if os(iOS) || os(visionOS)
import WidgetKit
#endif

public struct AppleTopShelfSnapshot: Codable, Equatable, Sendable {
    public struct Item: Codable, Equatable, Sendable {
        public let id: String
        public let title: String
        public let kind: String
        public let artworkURL: URL?
        public let displayURL: URL
        public let playURL: URL?
        /// How far in, 0–1, for a title in Continue Watching; nil elsewhere.
        /// The Top Shelf draws it as the bar under the tile, as the Apple TV
        /// app does. Snapshots written before this field decode it as nil.
        public let progress: Double?
        /// The title's 16:9 backdrop — the art its Continue Watching card
        /// shows — so the Top Shelf can draw landscape tiles as the Apple TV
        /// app does. `artworkURL` stays the poster for a row that cannot go
        /// landscape. Snapshots written before this field decode it as nil.
        public let landscapeArtworkURL: URL?
        /// What the full-screen Top Shelf carousel writes under the title, as
        /// the Apple TV app does: the synopsis, the first genre, the year and
        /// the running time. Absent in older snapshots and when unknown.
        public let summary: String?
        public let genre: String?
        public let year: Int?
        public let durationSeconds: Double?
        /// The carousel page's picture the app drew (`AppleTopShelfArtworkStore`):
        /// a file name in the group's Library/Caches/topshelf-art. Nil keeps
        /// the remote backdrop.
        public let shelfImage: String?
        /// A public trailer file the carousel may play behind the page
        /// (`AppleTopShelfTrailerPolicy`).
        public let previewVideoURL: URL?
        /// The page's trailer the app saved from the user's server
        /// (`AppleTopShelfTrailerFiles`): a file name in the group's
        /// Library/Caches/topshelf-trailers. Its URL carries a token, so the
        /// file goes on the shelf and the URL never does.
        public let shelfVideo: String?
        /// The row poster the app saved from the viewer's own server
        /// (`AppleTopShelfArtworkStore.posters`): a file name in the group's
        /// Library/Caches/topshelf-art, for art `artworkURL` may not carry
        /// (a LAN host or plain http). Absent in older snapshots.
        public let shelfPoster: String?

        public init(id: String, title: String, kind: String, artworkURL: URL?, displayURL: URL, playURL: URL?,
                    progress: Double? = nil, landscapeArtworkURL: URL? = nil,
                    summary: String? = nil, genre: String? = nil, year: Int? = nil, durationSeconds: Double? = nil,
                    shelfImage: String? = nil, previewVideoURL: URL? = nil, shelfVideo: String? = nil,
                    shelfPoster: String? = nil) {
            self.id = id
            self.title = title
            self.kind = kind
            self.artworkURL = artworkURL
            self.displayURL = displayURL
            self.playURL = playURL
            self.progress = progress
            self.landscapeArtworkURL = landscapeArtworkURL
            self.summary = summary.map { String($0.prefix(600)) }
            self.genre = genre.map { String($0.prefix(60)) }
            self.year = year
            self.durationSeconds = durationSeconds.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            self.shelfImage = shelfImage
            self.previewVideoURL = AppleTopShelfTrailerPolicy.previewVideoURL(previewVideoURL)
            self.shelfVideo = AppleTopShelfTrailerPolicy.shelfVideo(shelfVideo)
            self.shelfPoster = shelfPoster
        }

        public var remainingMinutes: Int? {
            guard let progress, progress.isFinite, (0...1).contains(progress),
                  let durationSeconds, durationSeconds.isFinite, durationSeconds > 0 else { return nil }
            return Int(exactly: ceil((durationSeconds - durationSeconds * progress) / 60))
        }

        func withShelfImage(_ name: String?) -> Item {
            .init(id: id, title: title, kind: kind, artworkURL: artworkURL, displayURL: displayURL, playURL: playURL,
                  progress: progress, landscapeArtworkURL: landscapeArtworkURL, summary: summary, genre: genre,
                  year: year, durationSeconds: durationSeconds, shelfImage: name, previewVideoURL: previewVideoURL,
                  shelfVideo: shelfVideo, shelfPoster: shelfPoster)
        }

        func withShelfVideo(_ name: String?) -> Item {
            .init(id: id, title: title, kind: kind, artworkURL: artworkURL, displayURL: displayURL, playURL: playURL,
                  progress: progress, landscapeArtworkURL: landscapeArtworkURL, summary: summary, genre: genre,
                  year: year, durationSeconds: durationSeconds, shelfImage: shelfImage, previewVideoURL: previewVideoURL,
                  shelfVideo: name, shelfPoster: shelfPoster)
        }

        func withShelfPoster(_ name: String?) -> Item {
            .init(id: id, title: title, kind: kind, artworkURL: artworkURL, displayURL: displayURL, playURL: playURL,
                  progress: progress, landscapeArtworkURL: landscapeArtworkURL, summary: summary, genre: genre,
                  year: year, durationSeconds: durationSeconds, shelfImage: shelfImage, previewVideoURL: previewVideoURL,
                  shelfVideo: shelfVideo, shelfPoster: name)
        }
    }

    public var widgetHero: AppleWidgetHeroArtwork?

    public let version: Int
    public let generatedAt: Date
    public let continueWatching: [Item]
    public let recentlyAdded: [Item]
    public let favorites: [Item]
    /// The Top Shelf's second row, "Recently Added": the titles media
    /// servers added last, so a server-only Apple TV with nothing in progress
    /// still has a shelf. Defaults to empty so snapshots written before this
    /// field existed still decode.
    public let topPicks: [Item]
    public let favoriteChannels: [Item]
    public let recentChannels: [Item]
    /// The Home hero carousel's pages, in its order: the Top Shelf carousel
    /// shows the same titles (owner 2026-10-16). Empty in older snapshots and
    /// before Home has drawn.
    public let heroes: [Item]

    public init(
        version: Int,
        generatedAt: Date,
        continueWatching: [Item],
        recentlyAdded: [Item],
        favorites: [Item],
        topPicks: [Item] = [],
        favoriteChannels: [Item] = [],
        recentChannels: [Item] = [],
        heroes: [Item] = [],
        widgetHero: AppleWidgetHeroArtwork? = nil
    ) {
        self.widgetHero = widgetHero
        self.version = version
        self.generatedAt = generatedAt
        self.continueWatching = continueWatching
        self.recentlyAdded = recentlyAdded
        self.favorites = favorites
        self.topPicks = topPicks
        self.favoriteChannels = favoriteChannels
        self.recentChannels = recentChannels
        self.heroes = heroes
    }

    private enum CodingKeys: String, CodingKey {
        case version, generatedAt, continueWatching, recentlyAdded, favorites, topPicks, favoriteChannels, recentChannels,
             heroes, widgetHero
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        widgetHero = try container.decodeIfPresent(AppleWidgetHeroArtwork.self, forKey: .widgetHero)
        version = try container.decode(Int.self, forKey: .version)
        generatedAt = try container.decode(Date.self, forKey: .generatedAt)
        continueWatching = try container.decode([Item].self, forKey: .continueWatching)
        recentlyAdded = try container.decode([Item].self, forKey: .recentlyAdded)
        favorites = try container.decode([Item].self, forKey: .favorites)
        favoriteChannels = try container.decodeIfPresent([Item].self, forKey: .favoriteChannels) ?? []
        recentChannels = try container.decodeIfPresent([Item].self, forKey: .recentChannels) ?? []
        topPicks = try container.decodeIfPresent([Item].self, forKey: .topPicks) ?? []
        heroes = try container.decodeIfPresent([Item].self, forKey: .heroes) ?? []
    }

    /// The same snapshot with each listed item's carousel picture, by item id.
    func withShelfImages(_ names: [String: String]) -> AppleTopShelfSnapshot {
        carouselPages { $0.withShelfImage(names[$0.id]) }
    }

    /// The same snapshot with each row item's saved poster, by item id.
    func withShelfPosters(_ names: [String: String]) -> AppleTopShelfSnapshot {
        carouselPages { $0.withShelfPoster(names[$0.id]) }
    }

    /// The same snapshot with each carousel page's saved trailer, by item id.
    func withShelfVideos(_ names: [String: String]) -> AppleTopShelfSnapshot {
        carouselPages { $0.withShelfVideo(names[$0.id]) }
    }

    private func carouselPages(_ change: (Item) -> Item) -> AppleTopShelfSnapshot {
        AppleTopShelfSnapshot(version: version, generatedAt: generatedAt, continueWatching: continueWatching.map(change),
                              recentlyAdded: recentlyAdded, favorites: favorites, topPicks: topPicks.map(change),
                              favoriteChannels: favoriteChannels, recentChannels: recentChannels,
                              heroes: heroes.map(change), widgetHero: widgetHero)
    }

    func contentFingerprint() throws -> SHA256.Digest {
        let content = AppleTopShelfSnapshot(version: version, generatedAt: .distantPast,
            continueWatching: continueWatching, recentlyAdded: recentlyAdded, favorites: favorites,
            topPicks: topPicks, favoriteChannels: favoriteChannels, recentChannels: recentChannels,
            heroes: heroes, widgetHero: widgetHero)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return SHA256.hash(data: try encoder.encode(content))
    }
}

/// Which trailer the full-screen carousel may play behind a page: a direct
/// video file over https, never a YouTube page (the system player cannot
/// open one), or the copy the app saved of the title's trailer on the
/// user's server (`AppleTopShelfTrailerFiles`): a server URL carries the
/// user's token, so only the file reaches the shelf.
enum AppleTopShelfTrailerPolicy {
    static let fileExtensions: Set<String> = ["mp4", "m4v", "mov", "m3u8"]
    static let savedExtensions: Set<String> = ["mp4", "m4v", "mov"]
    static let directoryName = "topshelf-trailers"

    static func directory(in root: URL) -> URL {
        root.appending(path: "Library/Caches", directoryHint: .isDirectory)
            .appending(path: directoryName, directoryHint: .isDirectory)
    }

    /// A saved trailer's name: a bare file name with a video extension.
    static func shelfVideo(_ name: String?) -> String? {
        guard let name, !name.isEmpty, !name.contains("/"), !name.hasPrefix("."),
              savedExtensions.contains((name as NSString).pathExtension.lowercased()) else { return nil }
        return name
    }

    /// One name per title, from nothing secret: the server's URL (and its
    /// token) is not part of it.
    static func fileName(mediaID: String, trailer: AppleServerTrailer) -> String {
        let ext = trailer.url.pathExtension.lowercased()
        return "\(stem(mediaID: mediaID)).\(savedExtensions.contains(ext) ? ext : "mp4")"
    }

    /// The title's saved trailer in `directory`, whatever its extension.
    static func savedFile(mediaID: String, in directory: URL) -> String? {
        let stem = stem(mediaID: mediaID)
        return savedExtensions.sorted().map { "\(stem).\($0)" }
            .first { FileManager.default.fileExists(atPath: directory.appending(path: $0).path) }
    }

    private static func stem(mediaID: String) -> String {
        SHA256.hash(data: Data(mediaID.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func previewVideoURL(_ url: URL?) -> URL? {
        guard let url = AppleSystemArtworkPolicy.publicURL(url),
              let host = url.host?.lowercased(),
              !["youtube.com", "youtu.be", "youtube-nocookie.com"].contains(where: { host == $0 || host.hasSuffix(".\($0)") }),
              fileExtensions.contains(url.pathExtension.lowercased()) else { return nil }
        return url
    }
}

/// One page of the Home hero carousel as the Top Shelf mirrors it: the item
/// it publishes, plus the art the billboard draws, which only the app
/// fetches (for the page's picture) and which never enters the snapshot.
public struct AppleTopShelfHero: Equatable, Sendable {
    public let item: AppleTopShelfSnapshot.Item
    public let backdropURL: URL?
    public let wordmarkURL: URL?
    /// What finds the page's trailer on the user's server.
    let trailerQuery: AppleServerTrailerQuery?

    init(item: AppleTopShelfSnapshot.Item, backdropURL: URL?, wordmarkURL: URL?, trailerQuery: AppleServerTrailerQuery? = nil) {
        self.item = item
        self.backdropURL = backdropURL
        self.wordmarkURL = wordmarkURL
        self.trailerQuery = trailerQuery
    }

    /// The hero page for a title the billboard shows: `item` already carries
    /// the billboard's textless backdrop and wordmark when they have arrived.
    public static func page(record: AppleMediaRecord, item: AppleCatalogItem, wordmark: URL?) -> AppleTopShelfHero {
        AppleTopShelfHero(item: AppleTopShelfSnapshotWriter.catalogItem(id: record.id, title: record.title,
                                                                        kind: record.kind.rawValue, item: item),
                          backdropURL: item.backgroundURL, wordmarkURL: wordmark,
                          trailerQuery: AppleServerTrailerQuery(item: item))
    }
}

/// Where Home hands its hero pages to the Top Shelf publisher. Home decides
/// the pages (`AppleDiscoverView`); the root view republishes when they move.
@MainActor
@Observable
public final class AppleTopShelfHeroFeed {
    public static let shared = AppleTopShelfHeroFeed()
    public private(set) var heroes: [AppleTopShelfHero] = []

    public func update(_ heroes: [AppleTopShelfHero]) {
        if heroes != self.heroes { self.heroes = heroes }
    }
}

/// Plain, TVServices-free mirror of the section list `TopShelfProvider`
/// renders. Kept here so the ordering/emptiness rules are covered by
/// `swift test` — TVServices is unavailable outside tvOS, so the provider
/// extension cannot be unit tested directly. `TopShelfProvider` mirrors this
/// logic when it builds `TVTopShelfSectionedContent`; keep the two in sync.
public struct AppleTopShelfSection: Equatable, Sendable {
    public enum ImageShape: Equatable, Sendable { case poster, hdtv }

    public let title: String
    public let items: [AppleTopShelfSnapshot.Item]

    /// One shape per row, as the system draws it: 16:9 only when every tile
    /// has landscape art, since a poster stretched into a 16:9 tile is worse
    /// than a row of posters.
    public var imageShape: ImageShape {
        items.allSatisfy { $0.landscapeArtworkURL != nil } ? .hdtv : .poster
    }

    /// The picture a tile shows in this row's shape; in a poster row, the
    /// poster the app saved (`shelfPoster`, in `art`) comes first.
    public func imageURL(for item: AppleTopShelfSnapshot.Item, art: URL? = nil) -> URL? {
        switch imageShape {
        case .hdtv: item.landscapeArtworkURL
        case .poster: item.shelfPoster.flatMap { art?.appending(path: $0) } ?? item.artworkURL ?? item.landscapeArtworkURL
        }
    }
}

/// One page of the full-screen Top Shelf carousel, the Apple TV app's shelf:
/// the 16:9 picture edge to edge with the title's wordmark in it, the context
/// ("Continue Watching") over the title, the details under it, Play and More
/// Info. No progress bar (owner 2026-10-15). Plain mirror of the
/// `TVTopShelfCarouselItem` `TopShelfProvider` builds; keep the two in sync.
public struct AppleTopShelfCarouselItem: Equatable, Sendable {
    /// Nil for a hero page that is not a resume: the Home hero names none.
    public let contextTitle: String?
    public let item: AppleTopShelfSnapshot.Item

    /// The remote backdrop, never a poster stretched to 16:9; the page shows
    /// `item.shelfImage` instead once the app has drawn it.
    public var imageURL: URL? { item.landscapeArtworkURL }
}

public enum AppleTopShelfContentBuilder {
    /// The carousel holds this many pages at most.
    public static let carouselLimit = 12
    static let continueWatchingTitle = "Continue Watching"
    static let recentlyAddedTitle = "Recently Added"

    /// The Home hero's pages in its order, then Continue Watching (owner
    /// 2026-10-16: "sync through heros"); before Home has drawn, Continue
    /// Watching then Recently Added. Each title once, only titles with a
    /// picture to fill the screen. Empty when no title has one: the provider then
    /// serves the rows (`sections(for:)`).
    public static func carouselItems(for snapshot: AppleTopShelfSnapshot) -> [AppleTopShelfCarouselItem] {
        carouselItems(for: snapshot) { $0.landscapeArtworkURL != nil || $0.shelfImage != nil }
    }

    /// The same pages, each kept when `drawable` says it has a picture: a
    /// public backdrop, or one the app drew from the viewer's own server
    /// (`shelfImage`), whose address the snapshot never carries.
    static func carouselItems(for snapshot: AppleTopShelfSnapshot,
                              drawable: (AppleTopShelfSnapshot.Item) -> Bool) -> [AppleTopShelfCarouselItem] {
        var seen = Set<String>()
        let resumed = Set(snapshot.continueWatching.map(\.id))
        let continued = snapshot.continueWatching.map { AppleTopShelfCarouselItem(contextTitle: continueWatchingTitle, item: $0) }
        let pages = snapshot.heroes.isEmpty
            ? continued + snapshot.topPicks.map { AppleTopShelfCarouselItem(contextTitle: recentlyAddedTitle, item: $0) }
            : snapshot.heroes.map {
                AppleTopShelfCarouselItem(contextTitle: resumed.contains($0.id) ? continueWatchingTitle : nil, item: $0)
            } + continued
        return Array(pages.filter { drawable($0.item) && seen.insert($0.item.id).inserted }.prefix(carouselLimit))
    }

    /// Continue Watching first (when non-empty), then Recently Added. Returns an
    /// empty array when there is nothing to show at all — the provider
    /// should return `nil` for that result.
    public static func sections(for snapshot: AppleTopShelfSnapshot) -> [AppleTopShelfSection] {
        [
            snapshot.continueWatching.isEmpty ? nil : AppleTopShelfSection(
                title: "Continue Watching", items: snapshot.continueWatching
            ),
            snapshot.favoriteChannels.isEmpty ? nil : AppleTopShelfSection(
                title: "Favorite channels", items: snapshot.favoriteChannels
            ),
            snapshot.topPicks.isEmpty ? nil : AppleTopShelfSection(
                title: recentlyAddedTitle, items: snapshot.topPicks
            ),
        ].compactMap { $0 }
    }
}

/// Artwork may carry credentials in its path or query; such a URL stays
/// in-app and is never handed to Spotlight or Top Shelf.
/// Which artwork URLs may be handed to a system surface — the Top Shelf and
/// the widgets, which fetch them from their own processes.
///
/// This used to be a two-host allowlist (`image.tmdb.org` and one other image
/// service). That silently emptied the shelf: posters come
/// from whatever CDN a source uses, so **every** Continue Watching tile
/// published without artwork. A fixed allowlist cannot track that, so the
/// rule is now about what is *safe* to hand to another process rather than
/// who is serving it.
///
/// A private host is still refused: a NAS or `.local` poster is unreachable
/// from the extension anyway, and publishing one would leak an internal
/// hostname into a system surface.
enum AppleSystemArtworkPolicy {
    /// Hosts that never belong in a system surface.
    private static func isPrivateHost(_ host: String) -> Bool {
        if host == "localhost" || host.hasSuffix(".local") || host.hasSuffix(".internal") {
            return true
        }
        // An IP literal is either a private address or a host with no name to
        // verify; neither belongs on the shelf.
        if host.allSatisfy({ $0.isNumber || $0 == "." }) { return true }
        if host.contains(":") { return true }   // IPv6 literal
        // A bare name with no dot is a LAN name, not a public CDN.
        return !host.contains(".")
    }

    static func publicURL(_ value: URL?) -> URL? {
        guard let value,
              value.scheme?.lowercased() == "https",
              value.user == nil,
              value.password == nil,
              // A poster URL carrying a token must not reach a system surface,
              // and no image CDN seen in the wild needs one to serve an image.
              value.query == nil,
              value.fragment == nil,
              let host = value.host?.lowercased(),
              !host.isEmpty,
              !isPrivateHost(host) else {
            return nil
        }
        return value
    }
}

/// Reads the snapshot the app writes into the shared app group.
///
/// The Top Shelf provider and the iOS/iPadOS widgets are separate processes
/// with no access to the app's own container, so this file is the only thing
/// they can see. Kept beside the writer so the two cannot drift.
public struct AppleTopShelfSnapshotReader: Sendable {
    private let containerProvider: @Sendable () -> URL?

    public init(containerProvider: @escaping @Sendable () -> URL? = {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppleTopShelfSnapshotWriter.appGroup
        )
    }) {
        self.containerProvider = containerProvider
    }

    /// The snapshot, or nil when the app has not written one yet, the group
    /// container is unavailable, or the file is unreadable. A widget draws its
    /// empty state from nil rather than failing.
    public func read() -> AppleTopShelfSnapshot? {
        guard let root = containerProvider() else { return nil }
        let url = AppleTopShelfSnapshotWriter.snapshotURL(in: root)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(AppleTopShelfSnapshot.self, from: data)
    }
}

public actor AppleTopShelfSnapshotWriter {
    public enum WriteError: Error, Sendable {
        case containerUnavailable
    }

    public static let shared = AppleTopShelfSnapshotWriter()
    /// The shared container every system surface reads through.
    ///
    /// macOS needs the team-id prefix and the other platforms must not have
    /// it. On iOS and tvOS an app group is a bare `group.…` identifier; a
    /// sandboxed Mac app's group container is named
    /// `<TeamID>.group.…` and `containerURL(forSecurityApplicationGroupIdentifier:)`
    /// hands back a path under `~/Library/Group Containers/` that only that
    /// exact string resolves to. Asking for the unprefixed form returned a URL
    /// that then failed every read and write with EPERM — `NSCocoaErrorDomain
    /// 513` on write, `257` on a directory listing (measured inside the
    /// sandboxed app, 2026-09-21), which is why the `guard let root` at the
    /// call sites never caught it.
    ///
    /// The prefix is written out here rather than read from the build: this is
    /// a package constant with no `$(TeamIdentifierPrefix)` to expand, and the
    /// entitlement that grants it (`Apps/Shared/OpenStreamMacOS.entitlements`)
    /// does use the build setting, so the two cannot disagree silently — a
    /// mismatch fails to launch.
    public static let appGroup: String = {
        #if os(macOS)
        "2VQ74PD5YG.group.com.orgista.openstream"
        #else
        "group.com.orgista.openstream"
        #endif
    }()
    public static let filename = "topshelf-v1.json"

    /// Where the snapshot lives inside the group container. Apple TV hardware
    /// refuses writes to the container's top level (NSCocoaErrorDomain 513 on
    /// Apple TV 4K, 2026-10-13; the simulator allows it), so on tvOS it goes in
    /// the container's Library/Caches, which the Top Shelf extension reads too.
    public static func snapshotURL(in root: URL) -> URL {
        #if os(tvOS)
        root.appending(path: "Library/Caches", directoryHint: .isDirectory).appending(path: filename)
        #else
        root.appending(path: filename)
        #endif
    }

    private let containerProvider: @Sendable () -> URL?
    private let snapshotLocation: @Sendable (URL) -> URL
    /// Draws the carousel pages' pictures; only the Apple TV has a Top Shelf.
    private let artwork: AppleTopShelfArtworkStore?
    /// Saves the hero pages' server trailers; only the Apple TV has a Top Shelf.
    private let trailerFiles: AppleTopShelfTrailerFiles?
    private let trailerDownloads: AppleTopShelfTrailerDownloads
    private let widgetArtwork: AppleWidgetHeroArtworkStore?
    private let didChange: @Sendable () -> Void
    private var notificationPending = false
    private struct Inputs: Equatable {
        let content: SHA256.Digest
        let heroes: [AppleTopShelfHero]
        let artworkURLs: [[URL?]]
    }
    private var lastInputs: Inputs?

    public init(containerProvider: @escaping @Sendable () -> URL? = {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    }, snapshotLocation: @escaping @Sendable (URL) -> URL = { snapshotURL(in: $0) },
       artwork: AppleTopShelfArtworkStore? = defaultArtwork) {
        self.init(containerProvider: containerProvider, snapshotLocation: snapshotLocation, artwork: artwork,
                  trailerFiles: Self.defaultTrailerFiles)
    }

    init(containerProvider: @escaping @Sendable () -> URL?, snapshotLocation: @escaping @Sendable (URL) -> URL,
         artwork: AppleTopShelfArtworkStore?, trailerFiles: AppleTopShelfTrailerFiles?,
         widgetArtwork: AppleWidgetHeroArtworkStore? = defaultWidgetArtwork,
         trailerDownloads: AppleTopShelfTrailerDownloads = .shared,
         didChange: @escaping @Sendable () -> Void = { AppleTopShelfSnapshotWriter.notify() }) {
        self.containerProvider = containerProvider
        self.snapshotLocation = snapshotLocation
        self.artwork = artwork
        self.trailerFiles = trailerFiles
        self.widgetArtwork = widgetArtwork
        self.trailerDownloads = trailerDownloads
        self.didChange = didChange
    }

    static var defaultWidgetArtwork: AppleWidgetHeroArtworkStore? {
        #if os(iOS)
        AppleWidgetHeroArtworkStore()
        #else
        nil
        #endif
    }

    static var defaultTrailerFiles: AppleTopShelfTrailerFiles? {
        #if os(tvOS)
        AppleTopShelfTrailerFiles()
        #else
        nil
        #endif
    }

    public static var defaultArtwork: AppleTopShelfArtworkStore? {
        #if os(tvOS)
        AppleTopShelfArtworkStore()
        #else
        nil
        #endif
    }

    /// - Parameters:
    ///   - sources: When given, Continue Watching lists only what can open its
    ///     own page or carries an item id for an enabled media server. Nil treats
    ///     every record as openable.
    ///   - watchedAt: When each record was last watched, by record id —
    ///     Continue Watching is most recent first, as on Discover. A record
    ///     missing here falls back to its `lastVerified`.
    ///   - savedProgress: The playback store's entry for each record, by
    ///     record id; the bar follows it as Discover's does
    ///     (`AppleContinueWatchingResolver.progress`). Nil keeps each
    ///     record's own `progress`.
    ///   - libraryContinueWatching: Files and shares in progress, as Discover
    ///     lists them. Private records: they join Continue Watching only.
    @discardableResult
    public func write(
        records: [AppleMediaRecord],
        sources: [AppleSource]? = nil,
        libraryContinueWatching: [AppleMediaRecord] = [],
        watchedAt: [String: Date] = [:],
        savedProgress: [String: ApplePlaybackProgress]? = nil,
        activity: [String: ApplePlaybackProgress] = [:],
        successorAvailable: Set<String> = [],
        removedAt: [String: Date] = [:],
        favoriteChannels: [AppleTopShelfSnapshot.Item] = [],
        recentChannels: [AppleTopShelfSnapshot.Item] = [],
        heroes: [AppleTopShelfHero] = [],
        enabled: Bool
    ) async throws -> Bool {
        try Task.checkCancellation()
        guard let root = containerProvider() else { throw WriteError.containerUnavailable }
        let url = snapshotLocation(root)
        #if os(tvOS)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        #endif
        guard enabled else {
            let locations = Set([url, root.appending(path: Self.filename)])
            let changed = locations.contains { FileManager.default.fileExists(atPath: $0.path) }
            lastInputs = nil
            AppleWidgetHeroArtworkStore.removeAll(in: root)
            await trailerDownloads.cancel()
            try Task.checkCancellation()
            try? FileManager.default.removeItem(at: AppleTopShelfArtworkStore.directory(in: root))
            try? FileManager.default.removeItem(at: AppleTopShelfTrailerPolicy.directory(in: root))
            // The extension can still read a snapshot left by older builds at the root.
            for location in locations {
                do {
                    try FileManager.default.removeItem(at: location)
                } catch let error as CocoaError where error.code == .fileNoSuchFile {
                    // An already absent snapshot is a completed opt-out.
                }
            }
            notificationPending = false
            if changed { didChange() }
            return changed
        }

        let eligible = records.filter { !$0.availability.isEmpty && !$0.isPrivate }
        let continued = AppleContinueWatchingResolver.inProgress(eligible + libraryContinueWatching,
            saved: { savedProgress?[$0.id] }, activity: { activity[$0.id] },
            successorAvailable: { successorAvailable.contains($0.id) }, removedAt: { removedAt[$0.id] }) {
                activity[$0.id]?.updatedAt ?? watchedAt[$0.id] ?? $0.lastVerified
            }
        let favorites = eligible.filter(\.isFavorite).sorted { $0.title < $1.title }
        let recent = eligible.sorted { $0.lastVerified > $1.lastVerified }
        let servers = Set((sources ?? []).filter { $0.kind == .mediaServer && $0.isEnabled }.map(\.id))
        let shownContinued = Array(continued.filter { record in
            sources == nil || AppleContinueWatchingResolver.isOpenable(record)
                || record.availability.contains { servers.contains($0.instanceID) && $0.serverItemID?.isEmpty == false }
        }.prefix(AppleContinueWatchingResolver.maximumCount))
        let shownRecent = Self.recentlyAddedFromServers(recent, sources: sources,
                                                        excluding: Set(shownContinued.map(\.id)))
        var snapshot = AppleTopShelfSnapshot(
            version: 1,
            generatedAt: .now,
            continueWatching: shownContinued.map { record in
                Self.item(record, progress: savedProgress.map {
                    AppleContinueWatchingResolver.progress(isSeries: record.kind == .series,
                        saved: $0[record.id], recordProgress: record.progress)
                } ?? record.progress,
                          landscapeArtworkURL: AppleSystemArtworkPolicy.publicURL(record.backdropURL))
            },
            recentlyAdded: Array(recent.prefix(20)).map { Self.item($0) },
            favorites: Array(favorites.prefix(12)).map { Self.item($0) },
            topPicks: shownRecent.map { Self.item($0) },
            favoriteChannels: favoriteChannels, recentChannels: recentChannels,
            heroes: heroes.map(\.item)
        )
        let inputs = Inputs(content: try snapshot.contentFingerprint(), heroes: heroes,
            artworkURLs: (shownContinued + shownRecent).map { [$0.backdropURL, $0.artworkURL] })
        if lastInputs == inputs, !notificationPending, FileManager.default.fileExists(atPath: url.path) {
            return false
        }
        lastInputs = nil

        var art: [String: (backdrop: URL?, wordmark: URL?)] = [:]
        for record in shownContinued + shownRecent {
            guard let backdrop = record.backdropURL, ["http", "https"].contains(backdrop.scheme?.lowercased() ?? "")
            else { continue }
            art[record.id] = (backdrop, nil)
        }
        for hero in heroes { art[hero.item.id] = (hero.backdropURL, hero.wordmarkURL) }
        let potentialPages = AppleTopShelfContentBuilder.carouselItems(for: snapshot) {
            $0.landscapeArtworkURL != nil || $0.shelfImage != nil || (artwork != nil && art[$0.id]?.backdrop != nil)
        }
        let potentialIDs = Set(potentialPages.map(\.item.id))
        let trailerPages = heroes.compactMap { hero in
            hero.trailerQuery.flatMap { potentialIDs.contains(hero.item.id) ? (id: hero.item.id, query: $0) : nil }
        }
        let trailerDirectory = AppleTopShelfTrailerPolicy.directory(in: root)
        if let trailerFiles {
            let cached = await trailerFiles.plan(for: trailerPages, in: trailerDirectory, cachedOnly: true)
            let shown = Set(AppleTopShelfContentBuilder.carouselItems(for: snapshot).map(\.item.id))
            // Reserve the final carousel's slots and size budget before staging cached trailers.
            snapshot = snapshot.withShelfVideos(cached.saved.filter { shown.contains($0.key) })
        }
        var published = false
        if let widgetArtwork {
            let previous = (try? Data(contentsOf: url)).flatMap {
                try? JSONDecoder().decode(AppleTopShelfSnapshot.self, from: $0)
            }
            if let hero = previous?.widgetHero, hero.itemID == snapshot.continueWatching.first?.id {
                snapshot.widgetHero = hero
            }
            try Task.checkCancellation()
            let staged = try save(snapshot, to: url, notify: false)
            let generation = staged ? snapshot.generatedAt : previous?.generatedAt
            if let first = snapshot.continueWatching.first {
                let hero = heroes.first { $0.item.id == first.id }
                snapshot.widgetHero = await widgetArtwork.prepare(itemID: first.id,
                    backdrop: hero?.backdropURL ?? first.landscapeArtworkURL,
                    wordmark: hero?.wordmarkURL, in: root)
                try Task.checkCancellation()
                // A newer publish or opt-out may have replaced the snapshot during the fetch.
                guard let current = try? JSONDecoder().decode(AppleTopShelfSnapshot.self, from: Data(contentsOf: url)),
                      current.generatedAt == generation else { return false }
                if let widgetHero = snapshot.widgetHero { widgetArtwork.removeUnused(in: root, keeping: widgetHero) }
            } else {
                AppleWidgetHeroArtworkStore.removeAll(in: root)
            }
        }
        if let artwork {
            let pages = potentialPages.compactMap { page -> (id: String, backdrop: URL, wordmark: URL?)? in
                let source = art[page.item.id]
                guard let backdrop = source?.backdrop ?? page.imageURL else { return nil }
                return (page.item.id, backdrop, source.flatMap(\.wordmark))
            }
            let directory = AppleTopShelfArtworkStore.directory(in: root)
            let posterItems = Self.serverPosters(shownContinued + shownRecent)
            let saved = artwork.saved(pages: pages, posters: posterItems, in: directory)
            if saved.pictures.count < pages.count || saved.posters.count < posterItems.count {
                // The shelf goes out now with the art already saved; a slow or
                // offline server must not hold Continue Watching back.
                try Task.checkCancellation()
                published = try save(snapshot.withShelfImages(saved.pictures).withShelfPosters(saved.posters), to: url)
            }
            let names = await artwork.pictures(for: pages, in: directory)
            let posters = await artwork.posters(for: posterItems, in: directory)
            // A newer publish is already on its way and will draw the rest.
            try Task.checkCancellation()
            artwork.removeAll(in: directory, except: Set(names.values).union(posters.values))
            snapshot = snapshot.withShelfImages(names).withShelfPosters(posters)
        }
        // The trailers already saved go out with this snapshot; the rest are
        // fetched apart from it (`AppleTopShelfTrailerDownloads`) and added to
        // whatever snapshot is current when they land.
        guard let trailerFiles else {
            published = try save(snapshot, to: url) || published
            lastInputs = inputs
            return published
        }
        let shown = Set(AppleTopShelfContentBuilder.carouselItems(for: snapshot).map(\.item.id))
        let pages = heroes.compactMap { hero in
            hero.trailerQuery.flatMap { shown.contains(hero.item.id) ? (id: hero.item.id, query: $0) : nil }
        }
        let plan = await trailerFiles.plan(for: pages, in: trailerDirectory)
        try Task.checkCancellation()
        trailerFiles.removeAll(in: trailerDirectory, except: plan.wanted)
        published = try save(snapshot.withShelfVideos(plan.saved), to: url) || published
        await trailerDownloads.fetch(plan, with: trailerFiles, in: trailerDirectory) { [self] fetched in
            try? await addShelfVideos(fetched, at: url)
        }
        try Task.checkCancellation()
        lastInputs = inputs
        return published
    }

    /// Adds newly saved trailers to the snapshot on disk, for the pages it
    /// still shows.
    private func addShelfVideos(_ names: [String: String], at url: URL) throws {
        let current = try JSONDecoder().decode(AppleTopShelfSnapshot.self, from: Data(contentsOf: url))
        let videos = Dictionary((current.heroes + current.continueWatching + current.topPicks).compactMap { item in
            item.shelfVideo.map { (item.id, $0) }
        }, uniquingKeysWith: { first, _ in first }).merging(names) { $1 }
        try save(current.withShelfVideos(videos), to: url)
    }

    @discardableResult
    func save(_ snapshot: AppleTopShelfSnapshot, to url: URL, notify: Bool = true) throws -> Bool {
        let previous = (try? Data(contentsOf: url)).flatMap {
            try? JSONDecoder().decode(AppleTopShelfSnapshot.self, from: $0)
        }
        let changed = try previous?.contentFingerprint() != snapshot.contentFingerprint()
        if changed {
            let data = try JSONEncoder().encode(snapshot)
            #if os(iOS) || os(visionOS)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
            #else
            // The tvOS extension opens the file separately, including while the app is inactive.
            try data.write(to: url, options: .atomic)
            #endif
            notificationPending = true
        }
        if notify && notificationPending {
            notificationPending = false
            didChange()
            return true
        }
        return changed
    }

    /// The Top Shelf's "Recently Added" row: movies and shows from media
    /// servers, newest first, minus what Continue Watching already shows.
    /// Without `sources` every record counts as a server's.
    static func recentlyAddedFromServers(_ recent: [AppleMediaRecord], sources: [AppleSource]?,
                                         excluding shown: Set<String>) -> [AppleMediaRecord] {
        let servers = sources.map { Set($0.filter { $0.kind == .mediaServer }.map(\.id)) }
        return Array(recent.filter { record in
            [.movie, .series].contains(record.kind) && !shown.contains(record.id)
                && (servers.map { ids in record.availability.contains { ids.contains($0.instanceID) } } ?? true)
        }.prefix(20))
    }

    /// Posters a system surface may not fetch itself (a LAN host or plain
    /// http, often the viewer's own server): the app saves a copy instead.
    static func serverPosters(_ records: [AppleMediaRecord]) -> [(id: String, url: URL)] {
        records.compactMap { record in
            guard let url = record.artworkURL, AppleSystemArtworkPolicy.publicURL(url) == nil,
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
            return (record.id, url)
        }
    }

    /// A title's page, for the Home hero.
    static func catalogItem(id: String, title: String, kind: String, item: AppleCatalogItem) -> AppleTopShelfSnapshot.Item {
        let display = URL(string: "openstream://media/\(id)?action=display")!
        let play = URL(string: "openstream://media/\(id)?action=play")
        return .init(
            id: id,
            title: title,
            kind: kind,
            artworkURL: AppleSystemArtworkPolicy.publicURL(item.posterURL)
                ?? AppleSystemArtworkPolicy.publicURL(item.backgroundURL),
            displayURL: display,
            playURL: play,
            landscapeArtworkURL: landscapeURL(for: item),
            summary: item.summary,
            genre: item.genres?.first,
            year: year(of: item),
            durationSeconds: item.runtimeMinutes.map { Double($0 * 60) }
        )
    }

    private static func year(of item: AppleCatalogItem) -> Int? {
        item.year ?? item.releaseInfo.flatMap { Int($0.prefix(4)) }
    }

    /// The card's landscape art (`AppleCatalogArtworkPolicy`, landscape):
    /// the title's backdrop. An episode still would win over it, as on the
    /// title page (`AppleEpisodeStillPolicy`), but a snapshot record is a
    /// title, never an episode, so there is no still to offer. The
    /// image-service fallback the card also tries is left out: its URL
    /// carries the IMDb id, which the snapshot deliberately never contains.
    private static func landscapeURL(for item: AppleCatalogItem) -> URL? {
        AppleSystemArtworkPolicy.publicURL(item.backgroundURL)
    }

    private static func item(_ record: AppleMediaRecord, progress: Double? = nil,
                             landscapeArtworkURL: URL? = nil) -> AppleTopShelfSnapshot.Item {
        let display = URL(string: "openstream://media/\(record.id)?action=display")!
        let play = record.availability.count == 1
            ? URL(string: "openstream://media/\(record.id)?action=play")
            : nil
        return .init(
            id: record.id,
            title: record.title,
            kind: record.kind.rawValue,
            artworkURL: AppleSystemArtworkPolicy.publicURL(record.artworkURL),
            displayURL: display,
            playURL: play,
            progress: progress.map { min(max($0, 0), 1) },
            landscapeArtworkURL: landscapeArtworkURL,
            summary: record.summary,
            year: record.year
        )
    }

    static func notify() {
        #if os(tvOS)
        TVTopShelfContentProvider.topShelfContentDidChange()
        #endif
        #if os(iOS)
        // The same snapshot backs the iOS/iPadOS widgets, so a write has to
        // wake their timelines too. Without this a widget shows whatever it
        // rendered last until the system happens to refresh it.
        WidgetCenter.shared.reloadAllTimelines()
        #elseif os(visionOS)
        // `WidgetCenter` arrived on visionOS in 26.0 and this target deploys to
        // 2.0, so the unguarded call did not compile — which is why the whole
        // visionOS target had been failing to build (found 2026-09-17, the first
        // time anything in this audit built it). Gated rather than dropped, so
        // the reload still happens on a visionOS that has widgets.
        if #available(visionOS 26.0, *) {
            WidgetCenter.shared.reloadAllTimelines()
        }
        #endif
    }
}

/// What a Continue Watching widget should say when it has nothing to draw.
///
/// The two empty cases are not the same thing and used to read identically:
/// the widget said "Nothing in progress" whether the viewer had genuinely
/// finished everything *or* the app had never published a snapshot at all —
/// which on iPhone it never did, because the writers were `#if os(tvOS)` and
/// because publishing is opt-in under Privacy › Apple Services. Telling
/// someone with four half-watched shows that nothing is in progress is simply
/// untrue, and it hides the one setting that would fix it.
public enum AppleWidgetEmptyState: Equatable, Sendable {
    /// A snapshot exists and really is empty.
    case nothingInProgress
    /// No snapshot at all: not published, or the group container is unreadable.
    case notPublished

    public static func state(hasSnapshot: Bool) -> AppleWidgetEmptyState {
        hasSnapshot ? .nothingInProgress : .notPublished
    }

    /// Short enough for the small widget, and true in both cases.
    public var message: String {
        switch self {
        case .nothingInProgress: "Nothing in progress"
        case .notPublished: "Off in Settings › Privacy"
        }
    }
}
