import Foundation
import OSLog
import TVServices

/// The shelf failing is invisible from the outside: tvOS silently falls back
/// to the static Top Shelf image, which looks like a design choice rather than
/// a bug. Every exit from `loadTopShelfContent` says why, into
/// `log stream --predicate 'subsystem == "com.orgista.openstream.topshelf"'`.
private let log = Logger(subsystem: "com.orgista.openstream.topshelf", category: "content")

final class TopShelfProvider: TVTopShelfContentProvider {
    private struct Snapshot: Decodable {
        struct Item: Decodable {
            let id: String
            let title: String
            let artworkURL: URL?
            let displayURL: URL
            let playURL: URL?
            /// The 16:9 backdrop; absent in older snapshots and for titles
            /// with no landscape art.
            let landscapeArtworkURL: URL?
            /// The carousel's details; absent in older snapshots.
            let summary: String?
            let genre: String?
            let year: Int?
            let durationSeconds: Double?
            /// The page's picture the app drew, wordmark included: a file in
            /// Library/Caches/topshelf-art. Absent in older snapshots.
            let shelfImage: String?
            let previewVideoURL: URL?
            /// The page's trailer the app saved from the user's server: a
            /// file in Library/Caches/topshelf-trailers. Absent in older
            /// snapshots.
            let shelfVideo: String?
            /// The row poster the app saved from the viewer's own server: a
            /// file in Library/Caches/topshelf-art. Absent in older snapshots.
            let shelfPoster: String?
        }

        let version: Int
        let continueWatching: [Item]
        // Decoded for forward compatibility with the app's snapshot writer,
        // but not rendered.
        let recentlyAdded: [Item]
        let favorites: [Item]
        /// The servers' recently added titles: the "Recently Added" row.
        let topPicks: [Item]
        let favoriteChannels: [Item]
        /// The Home hero's pages, in its order. Absent in older snapshots.
        let heroes: [Item]

        private enum CodingKeys: String, CodingKey {
            case version, continueWatching, recentlyAdded, favorites, topPicks, favoriteChannels, heroes
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decode(Int.self, forKey: .version)
            continueWatching = try container.decode([Item].self, forKey: .continueWatching)
            recentlyAdded = try container.decode([Item].self, forKey: .recentlyAdded)
            favorites = try container.decode([Item].self, forKey: .favorites)
            favoriteChannels = try container.decodeIfPresent([Item].self, forKey: .favoriteChannels) ?? []
            topPicks = try container.decodeIfPresent([Item].self, forKey: .topPicks) ?? []
            heroes = try container.decodeIfPresent([Item].self, forKey: .heroes) ?? []
        }
    }

    override func loadTopShelfContent(completionHandler: @escaping ((any TVTopShelfContent)?) -> Void) {
        guard let root = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.orgista.openstream"
        ) else {
            log.error("no app group container — check the extension's entitlement")
            completionHandler(nil)
            return
        }
        // Apple TV hardware only lets the app write the group container's
        // Library/Caches (513 at the top level); the top level is a fallback
        // for snapshots written by older builds.
        let url = root.appending(path: "Library/Caches/topshelf-v1.json")
        let legacyURL = root.appending(path: "topshelf-v1.json")
        guard let data = (try? Data(contentsOf: url)) ?? (try? Data(contentsOf: legacyURL)) else {
            log.error("no snapshot at \(url.path, privacy: .public) — the app has not published one")
            completionHandler(nil)
            return
        }
        guard data.count <= 1_000_000,
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              snapshot.version == 1 else {
            log.error("snapshot unreadable — \(data.count) bytes")
            completionHandler(nil)
            return
        }

        // The Apple TV app's shelf: full-screen pictures, the Home hero's
        // pages then Continue Watching, no progress bars. Mirrors
        // AppleTopShelfContentBuilder.carouselItems(for:) in OpenStreamApple.
        let art = root.appending(path: "Library/Caches/topshelf-art", directoryHint: .isDirectory)
        let trailers = root.appending(path: "Library/Caches/topshelf-trailers", directoryHint: .isDirectory)
        let carousel = carouselItems(snapshot, art: art, trailers: trailers)
        if !carousel.isEmpty {
            let drawn = carousel.filter { $0.imageURL(for: .screenScale2x)?.isFileURL == true }.count
            let videos = carousel.filter { $0.previewVideoURL != nil }.count
            log.info("serving carousel of \(carousel.count) (\(drawn) drawn, \(videos) with trailers): heroes=\(snapshot.heroes.count) continueWatching=\(snapshot.continueWatching.count) recentlyAdded=\(snapshot.topPicks.count)")
            completionHandler(TVTopShelfCarouselContent(style: .details, items: carousel))
            return
        }

        // No title has a backdrop to fill the screen: the rows, as before —
        // mirrors AppleTopShelfContentBuilder.sections(for:) and
        // AppleTopShelfSection.imageURL(for:art:).
        let sections = [
            collection(title: "Continue Watching", values: snapshot.continueWatching, art: art),
            collection(title: "Favorite channels", values: snapshot.favoriteChannels, art: art),
            collection(title: "Recently Added", values: snapshot.topPicks, art: art),
        ].compactMap { $0 }
        let shapes = sections.map { $0.items.first?.imageShape == .hdtv ? "hdtv" : "poster" }.joined(separator: ",")
        log.info("serving \(sections.count) section(s): continueWatching=\(snapshot.continueWatching.count) recentlyAdded=\(snapshot.topPicks.count) shapes=\(shapes, privacy: .public)")
        completionHandler(sections.isEmpty ? nil : TVTopShelfSectionedContent(sections: sections))
    }

    private func carouselItems(_ snapshot: Snapshot, art: URL, trailers: URL) -> [TVTopShelfCarouselItem] {
        var seen = Set<String>()
        let resumed = Set(snapshot.continueWatching.map(\.id))
        let continued: [(String?, Snapshot.Item)] = snapshot.continueWatching.map { ("Continue Watching", $0) }
        let pages: [(String?, Snapshot.Item)] = snapshot.heroes.isEmpty
            ? continued + snapshot.topPicks.map { ("Recently Added", $0) }
            : snapshot.heroes.map { (resumed.contains($0.id) ? "Continue Watching" : nil, $0) } + continued
        return Array(pages.compactMap { context, value -> TVTopShelfCarouselItem? in
            // The picture the app drew (from the viewer's own server too),
            // else a public backdrop.
            guard let imageURL = Self.drawnImageURL(value.shelfImage, in: art)
                    ?? value.landscapeArtworkURL.flatMap(Self.systemImageURL),
                  seen.insert(value.id).inserted else { return nil }
            let item = TVTopShelfCarouselItem(identifier: value.id)
            item.contextTitle = context
            item.title = String(value.title.prefix(200))
            item.summary = value.summary
            item.genre = value.genre
            if let duration = value.durationSeconds { item.duration = duration }
            if let year = value.year {
                item.creationDate = DateComponents(calendar: Calendar(identifier: .gregorian), year: year, month: 1, day: 1).date
            }
            item.displayAction = TVTopShelfAction(url: value.displayURL)
            if let playURL = value.playURL { item.playAction = TVTopShelfAction(url: playURL) }
            item.setImageURL(imageURL, for: [.screenScale1x, .screenScale2x])
            if let video = Self.savedVideoURL(value.shelfVideo, in: trailers) {
                item.previewVideoURL = video
            } else if let video = value.previewVideoURL, video.scheme?.lowercased() == "https" {
                item.previewVideoURL = video
            }
            return item
        }.prefix(12))
    }

    private static func systemImageURL(_ url: URL) -> URL? {
        ["https", "http"].contains(url.scheme?.lowercased()) && url.user == nil && url.password == nil ? url : nil
    }

    /// The app's drawn picture, when the file is there; a bare file name only.
    private static func drawnImageURL(_ name: String?, in directory: URL) -> URL? {
        guard let name, !name.contains("/"), name.hasSuffix(".jpg") else { return nil }
        let url = directory.appending(path: name, directoryHint: .notDirectory)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// The app's saved trailer, when the file is there; a bare file name
    /// with a video extension only (mirrors AppleTopShelfTrailerPolicy).
    private static func savedVideoURL(_ name: String?, in directory: URL) -> URL? {
        guard let name, !name.contains("/"), !name.hasPrefix("."),
              ["mp4", "m4v", "mov"].contains((name as NSString).pathExtension.lowercased()) else { return nil }
        let url = directory.appending(path: name, directoryHint: .notDirectory)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func collection(title: String, values: [Snapshot.Item], art: URL) -> TVTopShelfItemCollection<TVTopShelfSectionedItem>? {
        let values = values.prefix(20)
        // 16:9 tiles like the Apple TV app's, but only when every tile has a
        // backdrop — a row takes one shape, and a poster stretched to 16:9 is
        // worse than posters. Mirrors AppleTopShelfSection.imageShape.
        let landscape = values.allSatisfy { $0.landscapeArtworkURL != nil }
        let items = values.map { value in
            let item = TVTopShelfSectionedItem(identifier: value.id)
            item.title = String(value.title.prefix(200))
            item.imageShape = landscape ? .hdtv : .poster
            item.displayAction = TVTopShelfAction(url: value.displayURL)
            if let playURL = value.playURL { item.playAction = TVTopShelfAction(url: playURL) }
            // In a poster row the poster the app saved comes first: its art is
            // on the viewer's own server, which the shelf may not fetch.
            if let imageURL = landscape ? value.landscapeArtworkURL.flatMap(Self.systemImageURL)
                : Self.drawnImageURL(value.shelfPoster, in: art)
                    ?? (value.artworkURL ?? value.landscapeArtworkURL).flatMap(Self.systemImageURL) {
                item.setImageURL(imageURL, for: [.screenScale1x, .screenScale2x])
            }
            return item
        }
        guard !items.isEmpty else { return nil }
        let collection = TVTopShelfItemCollection(items: items)
        collection.title = title
        return collection
    }
}
