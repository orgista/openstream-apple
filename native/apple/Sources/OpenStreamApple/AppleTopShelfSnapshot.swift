import Foundation

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
    }

    public let version: Int
    public let generatedAt: Date
    public let continueWatching: [Item]
    public let recentlyAdded: [Item]
    public let favorites: [Item]
    /// Up to 10 items from the first non-empty catalog shelf (e.g. Cinemeta
    /// Popular), shown on Top Shelf when the user has sources configured but
    /// nothing in progress. Defaults to empty so snapshots written before
    /// this field existed still decode.
    public let topPicks: [Item]

    public init(
        version: Int,
        generatedAt: Date,
        continueWatching: [Item],
        recentlyAdded: [Item],
        favorites: [Item],
        topPicks: [Item] = []
    ) {
        self.version = version
        self.generatedAt = generatedAt
        self.continueWatching = continueWatching
        self.recentlyAdded = recentlyAdded
        self.favorites = favorites
        self.topPicks = topPicks
    }

    private enum CodingKeys: String, CodingKey {
        case version, generatedAt, continueWatching, recentlyAdded, favorites, topPicks
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        generatedAt = try container.decode(Date.self, forKey: .generatedAt)
        continueWatching = try container.decode([Item].self, forKey: .continueWatching)
        recentlyAdded = try container.decode([Item].self, forKey: .recentlyAdded)
        favorites = try container.decode([Item].self, forKey: .favorites)
        topPicks = try container.decodeIfPresent([Item].self, forKey: .topPicks) ?? []
    }
}

/// Plain, TVServices-free mirror of the section list `TopShelfProvider`
/// renders. Kept here so the ordering/emptiness rules are covered by
/// `swift test` — TVServices is unavailable outside tvOS, so the provider
/// extension cannot be unit tested directly. `TopShelfProvider` mirrors this
/// logic when it builds `TVTopShelfSectionedContent`; keep the two in sync.
public struct AppleTopShelfSection: Equatable, Sendable {
    public let title: String
    public let items: [AppleTopShelfSnapshot.Item]
}

public enum AppleTopShelfContentBuilder {
    /// Continue Watching first (when non-empty), then Top Picks. Returns an
    /// empty array when there is nothing to show at all — the provider
    /// should return `nil` for that result.
    public static func sections(for snapshot: AppleTopShelfSnapshot) -> [AppleTopShelfSection] {
        [
            snapshot.continueWatching.isEmpty ? nil : AppleTopShelfSection(
                title: "Continue Watching", items: snapshot.continueWatching
            ),
            snapshot.topPicks.isEmpty ? nil : AppleTopShelfSection(
                title: "Top Picks", items: snapshot.topPicks
            ),
        ].compactMap { $0 }
    }
}

/// Only system-owned projections receive remote URLs from this narrow list.
/// Arbitrary add-on artwork may carry credentials in its path or query, so it
/// remains available in-app but is never handed to Spotlight or Top Shelf.
/// Which artwork URLs may be handed to a system surface — the Top Shelf and
/// the widgets, which fetch them from their own processes.
///
/// This used to be a two-host allowlist (`image.tmdb.org`,
/// `images.metahub.space`). That silently emptied the shelf: add-ons serve
/// posters from whatever CDN they like, and on the owner's library the
/// in-progress titles came from `images.justwatch.com` and
/// `api.ratingposterdb.com`, so **every** Continue Watching tile published
/// without artwork while Top Picks — which happen to come from Cinemeta, i.e.
/// metahub — looked fine. A fixed allowlist cannot track what add-ons use, so
/// the rule is now about what is *safe* to hand to another process rather than
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
              // and no add-on CDN seen in the wild needs one to serve an image.
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
        let url = root.appending(path: AppleTopShelfSnapshotWriter.filename)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(AppleTopShelfSnapshot.self, from: data)
    }
}

public actor AppleTopShelfSnapshotWriter {
    public static let shared = AppleTopShelfSnapshotWriter()
    public static let appGroup = "group.com.orgista.openstream"
    public static let filename = "topshelf-v1.json"

    private let containerProvider: @Sendable () -> URL?

    public init(containerProvider: @escaping @Sendable () -> URL? = {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    }) {
        self.containerProvider = containerProvider
    }

    public func write(
        records: [AppleMediaRecord],
        sections: [AppleCatalogSection] = [],
        enabled: Bool
    ) throws {
        guard let root = containerProvider() else { return }
        let url = root.appending(path: Self.filename)
        guard enabled else {
            try? FileManager.default.removeItem(at: url)
            notify()
            return
        }

        let eligible = records.filter { !$0.availability.isEmpty && !$0.isPrivate }
        let continued = eligible.filter { ($0.progress ?? 0) > 0 && ($0.progress ?? 1) < 0.95 }
            .sorted { ($0.progress ?? 0) > ($1.progress ?? 0) }
        let favorites = eligible.filter(\.isFavorite).sorted { $0.title < $1.title }
        let recent = eligible.sorted { $0.lastVerified > $1.lastVerified }
        let snapshot = AppleTopShelfSnapshot(
            version: 1,
            generatedAt: .now,
            continueWatching: Array(continued.prefix(12)).map(Self.item),
            recentlyAdded: Array(recent.prefix(20)).map(Self.item),
            favorites: Array(favorites.prefix(12)).map(Self.item),
            topPicks: Self.topPicks(from: sections)
        )
        let data = try JSONEncoder().encode(snapshot)
        #if os(iOS) || os(tvOS) || os(visionOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        #else
        try data.write(to: url, options: .atomic)
        #endif
        notify()
    }

    /// The first non-empty catalog shelf, e.g. Cinemeta Popular for a fresh
    /// Stremio source. Ids are derived the same way `AppleMediaIngestion`
    /// would ingest the item, so the deep link resolves once the app has
    /// indexed the catalog.
    private static func topPicks(from sections: [AppleCatalogSection]) -> [AppleTopShelfSnapshot.Item] {
        guard let shelf = sections.first(where: { !$0.items.isEmpty }) else { return [] }
        return shelf.items.prefix(10).map { topPickItem(sourceID: shelf.sourceID, item: $0) }
    }

    private static func topPickItem(sourceID: AppleSource.ID, item: AppleCatalogItem) -> AppleTopShelfSnapshot.Item {
        let record = AppleMediaIngestion.catalogRecord(instanceID: sourceID, item: item)
        let display = URL(string: "openstream://media/\(record.id)?action=display")!
        let play = URL(string: "openstream://media/\(record.id)?action=play")
        return .init(
            id: record.id,
            title: record.title,
            kind: record.kind.rawValue,
            artworkURL: AppleSystemArtworkPolicy.publicURL(item.posterURL)
                ?? AppleSystemArtworkPolicy.publicURL(item.backgroundURL),
            displayURL: display,
            playURL: play
        )
    }

    private static func item(_ record: AppleMediaRecord) -> AppleTopShelfSnapshot.Item {
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
            playURL: play
        )
    }

    private func notify() {
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
