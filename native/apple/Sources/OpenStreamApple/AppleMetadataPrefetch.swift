import Foundation

/// Preview assets — the wordmark URL and the trailer keys — keyed by title.
///
/// Nothing cached these, so every content page asked the add-on from scratch:
/// measured at **1357 ms** on the owner's Apple TV, which is 95 % of the wait
/// before a wordmark appears (the art itself draws in ~67 ms once the URL is
/// known). A cache lets the home screen fetch, while the viewer is still
/// deciding, what the content page would otherwise wait for.
public actor AppleStremioPreviewAssetsCache {
    public static let shared = AppleStremioPreviewAssetsCache()

    public struct Entry: Sendable, Equatable {
        public let assets: AppleStremioPreviewAssets?
        public let storedAt: Date
    }

    /// A title's wordmark and trailers do not change while the app is open.
    public static let successLifetime: TimeInterval = 30 * 60
    /// A miss is usually a slow add-on rather than a title with no artwork, so
    /// it expires quickly and the next visit asks again.
    public static let failureLifetime: TimeInterval = 2 * 60
    /// Enough for a few screens of browsing without holding the whole catalog.
    public static let limit = 300

    private var entries: [String: Entry] = [:]

    public init() {}

    public nonisolated static func key(type: String, mediaID: String) -> String {
        "\(type.lowercased())\u{1f}\(mediaID)"
    }

    /// The cached entry, or nil when there is nothing usable — either never
    /// fetched or expired.
    public func entry(for key: String, now: Date = .now) -> Entry? {
        guard let entry = entries[key] else { return nil }
        let lifetime = entry.assets == nil ? Self.failureLifetime : Self.successLifetime
        guard now.timeIntervalSince(entry.storedAt) < lifetime else {
            entries[key] = nil
            return nil
        }
        return entry
    }

    public func store(_ assets: AppleStremioPreviewAssets?, for key: String, now: Date = .now) {
        if entries.count >= Self.limit, entries[key] == nil { evictOldest() }
        entries[key] = Entry(assets: assets, storedAt: now)
    }

    public func removeAll() { entries.removeAll() }

    public var count: Int { entries.count }

    private func evictOldest() {
        guard let oldest = entries.min(by: { $0.value.storedAt < $1.value.storedAt })?.key else { return }
        entries[oldest] = nil
    }
}

/// Fetches preview assets for the titles a viewer is one press away from, so
/// the content page finds them already cached (owner 2026-09-14: "can we
/// preload metadata like wordmark art so that it loads basically instantly
/// when opening a content page").
public enum AppleMetadataPrefetcher: Sendable {
    /// The billboard rotates through five candidates and each is one Play or
    /// Details press from a content page; beyond that the guesses get weak and
    /// the requests stop being free.
    public static let maximumTitles = 5
    /// Add-ons are someone else's server. A handful at a time, never a burst.
    public static let maximumConcurrent = 2

    public struct Title: Sendable, Equatable {
        public let type: String
        public let mediaID: String

        public init(type: String, mediaID: String) {
            self.type = type
            self.mediaID = mediaID
        }
    }

    /// Which titles are worth fetching: deduplicated, capped, and with blanks
    /// dropped. Pure, so the choice can be asserted without a network.
    public static func targets(_ titles: [Title], limit: Int = maximumTitles) -> [Title] {
        var seen = Set<String>()
        var result: [Title] = []
        for title in titles where !title.mediaID.isEmpty && !title.type.isEmpty {
            guard seen.insert(AppleStremioPreviewAssetsCache.key(type: title.type, mediaID: title.mediaID)).inserted
            else { continue }
            result.append(title)
            if result.count == limit { break }
        }
        return result
    }

    /// Warms the cache. Cancellation-aware and best-effort: a title that fails
    /// simply is not cached, and the content page falls back to fetching it.
    public static func warm(
        _ titles: [Title],
        sources: [AppleSource],
        preferredSourceID: AppleSource.ID? = nil,
        client: AppleStremioMetadataClient = AppleStremioMetadataClient()
    ) async {
        let wanted = targets(titles)
        guard !wanted.isEmpty else { return }
        #if DEBUG
        AppleLaunchClock.mark("meta.warm.\(wanted.map(\.mediaID).joined(separator: ","))")
        #endif
        var index = 0
        while index < wanted.count {
            if Task.isCancelled { return }
            let slice = wanted[index ..< min(index + maximumConcurrent, wanted.count)]
            await withTaskGroup(of: Void.self) { group in
                for title in slice {
                    group.addTask {
                        // `previewAssets` fills the cache itself, so this is
                        // just "ask for it early".
                        _ = await client.previewAssets(
                            sources: sources,
                            preferredSourceID: preferredSourceID,
                            type: title.type,
                            mediaID: title.mediaID
                        )
                    }
                }
            }
            index += maximumConcurrent
        }
    }
}
