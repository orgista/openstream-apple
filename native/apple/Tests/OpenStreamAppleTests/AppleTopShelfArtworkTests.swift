import CoreGraphics
import Foundation
import ImageIO
import Synchronization
import Testing
import UniformTypeIdentifiers
@testable import OpenStreamApple

/// Top Shelf round 2 (owner 2026-10-16): the carousel follows the Home hero,
/// and each page's picture is drawn by the app with the title's wordmark in it.
@Suite("Top Shelf artwork")
struct AppleTopShelfArtworkTests {
    private func item(_ id: String, backdrop: Bool = true) -> AppleTopShelfSnapshot.Item {
        .init(id: id, title: id.uppercased(), kind: "movie", artworkURL: nil,
              displayURL: URL(string: "openstream://media/\(id)?action=display")!,
              playURL: URL(string: "openstream://media/\(id)?action=play"),
              landscapeArtworkURL: backdrop ? URL(string: "https://image.tmdb.org/t/p/original/\(id).jpg") : nil)
    }

    private static func png(width: Int, height: Int, opaque: CGRect? = nil) -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(opaque ?? CGRect(x: 0, y: 0, width: width, height: height))
        let buffer = NSMutableData()
        let destination = CGImageDestinationCreateWithData(buffer, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return buffer as Data
    }

    @Test("Hero pages come first in the hero's order, then Continue Watching, each title once")
    func heroOrder() {
        let snapshot = AppleTopShelfSnapshot(version: 1, generatedAt: .now,
            continueWatching: [item("resume"), item("other")], recentlyAdded: [], favorites: [],
            topPicks: [item("pick")], heroes: [item("lead"), item("resume"), item("bare", backdrop: false)])
        let pages = AppleTopShelfContentBuilder.carouselItems(for: snapshot)
        #expect(pages.map(\.item.id) == ["lead", "resume", "other"])
        #expect(pages.map(\.contextTitle) == [nil, "Continue Watching", "Continue Watching"])
    }

    @Test("The backdrop covers the 16:9 canvas and the wordmark sits in its box, leading")
    func layout() {
        let square = AppleTopShelfArtworkLayout.fillRect(for: CGSize(width: 1000, height: 1000))
        #expect(square.width == 1920 && square.height == 1920 && square.minY == -420)
        let wide = AppleTopShelfArtworkLayout.wordmarkRect(for: CGSize(width: 2000, height: 400))
        #expect(wide.minX == AppleTopShelfArtworkLayout.leadingInset)
        #expect(wide.width == AppleTopShelfArtworkLayout.wordmarkBox.width && wide.height == 120)
        let tall = AppleTopShelfArtworkLayout.wordmarkRect(for: CGSize(width: 300, height: 300))
        #expect(tall.height == AppleTopShelfArtworkLayout.wordmarkBox.height && tall.width == tall.height)
    }

    @Test("File names change with the wordmark")
    func names() {
        let backdrop = URL(string: "https://image.tmdb.org/t/p/original/a.jpg")!
        let logo = URL(string: "https://image.tmdb.org/t/p/original/a.png")!
        let plain = AppleTopShelfArtworkLayout.fileName(backdrop: backdrop, wordmark: nil)
        #expect(plain == AppleTopShelfArtworkLayout.fileName(backdrop: backdrop, wordmark: nil))
        #expect(plain != AppleTopShelfArtworkLayout.fileName(backdrop: backdrop, wordmark: logo))
        #expect(plain.hasSuffix(".jpg") && !plain.contains("/"))
    }

    @Test("The writer draws a 1920×1080 picture per page, keeps the wordmark's absence honest and clears old files")
    func writerDrawsPictures() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "openstream-topshelf-art-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let backdropData = Self.png(width: 1280, height: 720)
        let logoData = Self.png(width: 800, height: 400, opaque: CGRect(x: 100, y: 100, width: 600, height: 200))
        let store = AppleTopShelfArtworkStore { url in
            if url.path.hasSuffix("missing.png") { throw URLError(.timedOut) }
            return url.pathExtension == "png" ? logoData : backdropData
        }
        let directory = AppleTopShelfArtworkStore.directory(in: root)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: directory.appending(path: "stale.jpg"))

        let backdrop = URL(string: "https://image.tmdb.org/t/p/original/hero-textless.jpg")!
        let logo = URL(string: "https://image.tmdb.org/t/p/original/hero.png")!
        let missing = URL(string: "https://image.tmdb.org/t/p/original/missing.png")!
        let heroes = [
            AppleTopShelfHero(item: item("lead"), backdropURL: backdrop, wordmarkURL: logo),
            AppleTopShelfHero(item: item("second"), backdropURL: backdrop, wordmarkURL: missing),
        ]
        let writer = AppleTopShelfSnapshotWriter(containerProvider: { root }, artwork: store)
        try await writer.write(records: [], heroes: heroes, enabled: true)
        let written = try #require(AppleTopShelfSnapshotReader(containerProvider: { root }).read())

        #expect(written.heroes.map(\.id) == ["lead", "second"])
        #expect(written.heroes[0].shelfImage == AppleTopShelfArtworkLayout.fileName(backdrop: backdrop, wordmark: logo))
        #expect(written.heroes[1].shelfImage == AppleTopShelfArtworkLayout.fileName(backdrop: backdrop, wordmark: nil))
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(Set(files) == Set(written.heroes.compactMap(\.shelfImage)))
        let picture = try Data(contentsOf: directory.appending(path: try #require(written.heroes[0].shelfImage)))
        let size = try #require(AppleWidgetArtworkThumbnail.pixelSize(ofEncoded: picture))
        #expect(size.width == 1920 && size.height == 1080)

        try await writer.write(records: [], enabled: false)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    /// A server-only Apple TV with nothing in progress still gets a shelf:
    /// the servers' recently added titles, with the posters the app saved
    /// from the server over plain http; the snapshot names files, never the
    /// server's address.
    @Test("Recently Added fills the shelf from media servers, with the app's copies of LAN art")
    func recentlyAddedFromAServerOverHTTP() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "openstream-topshelf-recent-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let server = AppleSource(kind: .mediaServer, name: "Fixture Jellyfin", url: URL(string: "http://192.168.1.20:8096")!)
        let share = AppleSource(kind: .nas, name: "Share", url: URL(string: "smb://fixture.example/share")!)
        let posterData = Self.png(width: 400, height: 600)
        let store = AppleTopShelfArtworkStore { url in
            guard url.host == "192.168.1.20" else { throw URLError(.cannotFindHost) }
            return posterData
        }
        let movie = AppleCatalogItem(mediaID: "jf:movie-1", type: "movie", name: "Fixture Movie",
                                     posterURL: URL(string: "http://192.168.1.20:8096/Items/movie-1/Images/Primary"),
                                     backgroundURL: URL(string: "http://192.168.1.20:8096/Items/movie-1/Images/Backdrop"))
        let fromServer = AppleMediaIngestion.catalogRecord(instanceID: server.id, item: movie)
        let fromShare = AppleMediaIngestion.catalogRecord(instanceID: share.id,
            item: AppleCatalogItem(mediaID: "share-1", type: "movie", name: "Share Movie"))
        let writer = AppleTopShelfSnapshotWriter(containerProvider: { root }, artwork: store)

        try await writer.write(records: [fromServer, fromShare], sources: [server, share], enabled: true)

        let written = try #require(AppleTopShelfSnapshotReader(containerProvider: { root }).read())
        #expect(written.continueWatching.isEmpty)
        let row = try #require(AppleTopShelfContentBuilder.sections(for: written).first)
        #expect(row.title == "Recently Added")
        #expect(row.items.map(\.id) == [fromServer.id])
        let directory = AppleTopShelfArtworkStore.directory(in: root)
        let poster = try #require(row.imageURL(for: row.items[0], art: directory))
        #expect(poster.isFileURL)
        #expect(FileManager.default.fileExists(atPath: poster.path))
        let page = try #require(AppleTopShelfContentBuilder.carouselItems(for: written).first)
        #expect(page.item.id == fromServer.id && page.contextTitle == "Recently Added")
        let picture = try #require(page.item.shelfImage)
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: picture).path))
        let json = String(decoding: try JSONEncoder().encode(written), as: UTF8.self)
        #expect(!json.contains("192.168.1.20"))
    }

    /// The shelf is written before any server art is fetched, so a slow or
    /// offline server delays only its own pictures.
    @Test("The snapshot is on disk before the server's art is fetched")
    func snapshotBeforeServerArt() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "openstream-topshelf-first-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let server = AppleSource(kind: .mediaServer, name: "Fixture Jellyfin", url: URL(string: "http://192.168.1.20:8096")!)
        let movie = AppleCatalogItem(mediaID: "jf:movie-1", type: "movie", name: "Fixture Movie",
                                     posterURL: URL(string: "http://192.168.1.20:8096/Items/movie-1/Images/Primary"))
        let record = AppleMediaIngestion.catalogRecord(instanceID: server.id, item: movie)
        let reader = AppleTopShelfSnapshotReader(containerProvider: { root })
        let posterData = Self.png(width: 400, height: 600)
        let shownWhileFetching = Mutex<[String]?>(nil)
        let store = AppleTopShelfArtworkStore { _ in
            shownWhileFetching.withLock { $0 = reader.read()?.topPicks.map(\.id) }
            return posterData
        }
        let writer = AppleTopShelfSnapshotWriter(containerProvider: { root }, artwork: store)

        try await writer.write(records: [record], sources: [server], enabled: true)

        #expect(shownWhileFetching.withLock { $0 } == [record.id])
        #expect(try #require(reader.read()).topPicks.first?.shelfPoster != nil)
    }

    @Test("A trailer is a direct https video file, never YouTube")
    func trailers() {
        #expect(AppleTopShelfTrailerPolicy.previewVideoURL(URL(string: "https://cdn.example.com/t/a.mp4")) != nil)
        #expect(AppleTopShelfTrailerPolicy.previewVideoURL(URL(string: "https://cdn.example.com/t/a.m3u8")) != nil)
        #expect(AppleTopShelfTrailerPolicy.previewVideoURL(URL(string: "http://cdn.example.com/t/a.mp4")) == nil)
        #expect(AppleTopShelfTrailerPolicy.previewVideoURL(URL(string: "https://www.youtube.com/watch.mp4")) == nil)
        #expect(AppleTopShelfTrailerPolicy.previewVideoURL(URL(string: "https://cdn.example.com/t/a.mp4?token=1")) == nil)
        #expect(AppleTopShelfTrailerPolicy.previewVideoURL(URL(string: "https://cdn.example.com/watch?v=abc")) == nil)
    }

    @Test func unavailableArtworkDoesNotRepublishAnUnchangedCachedTrailer() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = AppleTopShelfTrailerPolicy.directory(in: root)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let trailer = AppleServerTrailer(url: try #require(URL(string: "https://fixture.example/trailer.mp4")),
            title: "Lead", durationSeconds: 60, isFile: true)
        let name = AppleTopShelfTrailerPolicy.fileName(mediaID: "lead", trailer: trailer)
        try Data("fixture".utf8).write(to: directory.appending(path: name))
        let hero = AppleTopShelfHero(item: item("lead"), backdropURL: nil, wordmarkURL: nil,
            trailerQuery: .init(mediaID: "lead", title: "Lead", year: 2020, isSeries: false))
        let changes = Mutex(0)
        let artworkFetches = Mutex(0)
        let writer = AppleTopShelfSnapshotWriter(containerProvider: { root },
            snapshotLocation: { AppleTopShelfSnapshotWriter.snapshotURL(in: $0) },
            artwork: AppleTopShelfArtworkStore { _ in
                artworkFetches.withLock { $0 += 1 }
                throw URLError(.notConnectedToInternet)
            },
            trailerFiles: AppleTopShelfTrailerFiles(resolve: { _ in nil }),
            trailerDownloads: AppleTopShelfTrailerDownloads(), didChange: { changes.withLock { $0 += 1 } })
        try await writer.write(records: [], heroes: [hero], enabled: true)
        let original = try Data(contentsOf: AppleTopShelfSnapshotWriter.snapshotURL(in: root))
        let previousChanges = changes.withLock { $0 }
        let previousFetches = artworkFetches.withLock { $0 }
        #expect(previousChanges == 1)
        #expect(previousFetches > 0)

        for _ in 0..<20 {
            #expect(try await writer.write(records: [], heroes: [hero], enabled: true) == false)
        }
        #expect(changes.withLock { $0 } == previousChanges)
        #expect(artworkFetches.withLock { $0 } == previousFetches)
        #expect(try Data(contentsOf: AppleTopShelfSnapshotWriter.snapshotURL(in: root)) == original)
        #expect(AppleTopShelfSnapshotReader(containerProvider: { root }).read()?.heroes.first?.shelfVideo == name)
    }

    @Test(.timeLimit(.minutes(1)))
    func cancelledStagingInvalidatesThePreviousInputCache() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        defer {
            started.continuation.finish()
            release.continuation.finish()
        }
        let image = Self.png(width: 64, height: 96)
        let writer = AppleTopShelfSnapshotWriter(containerProvider: { root }, artwork: AppleTopShelfArtworkStore { url in
            if url.lastPathComponent == "changed.jpg" {
                started.continuation.yield()
                for await _ in release.stream { break }
            }
            return image
        })
        let original = AppleMediaRecord(canonicalID: "lead", kind: .movie, title: "Original",
            artworkURL: try #require(URL(string: "http://fixture.example/original.jpg")),
            availability: [.init(instanceID: UUID(), capability: .direct, itemReference: "lead")])
        #expect(try await writer.write(records: [original], enabled: true))
        var changed = original
        changed.title = "Changed"
        changed.artworkURL = try #require(URL(string: "http://fixture.example/changed.jpg"))
        let writing = Task { try await writer.write(records: [changed], enabled: true) }
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
        #expect(AppleTopShelfSnapshotReader(containerProvider: { root }).read()?.topPicks.first?.title == "Changed")
        writing.cancel()
        release.continuation.yield()
        await #expect(throws: CancellationError.self) { try await writing.value }
        #expect(try await writer.write(records: [original], enabled: true))
        #expect(AppleTopShelfSnapshotReader(containerProvider: { root }).read()?.topPicks.first?.title == "Original")
    }

    @Test func widgetStagingKeepsThePreviousGenerationUntilArtworkChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let record = AppleMediaRecord(canonicalID: "lead", kind: .movie, title: "Lead",
            availability: [.init(instanceID: UUID(), capability: .direct, itemReference: "lead")], progress: 0.5)
        let reader = AppleTopShelfSnapshotReader(containerProvider: { root })
        let staged = Mutex<[AppleTopShelfSnapshot]>([])
        let changes = Mutex(0)
        let image = Self.png(width: 64, height: 36)
        let widgetArtwork = AppleWidgetHeroArtworkStore { _ in
            let snapshot = try #require(reader.read())
            staged.withLock { $0.append(snapshot) }
            #expect(changes.withLock { $0 } == staged.withLock { $0.count } - 1)
            return image
        }
        func writer() -> AppleTopShelfSnapshotWriter {
            AppleTopShelfSnapshotWriter(containerProvider: { root },
                snapshotLocation: { AppleTopShelfSnapshotWriter.snapshotURL(in: $0) },
                artwork: nil, trailerFiles: nil, widgetArtwork: widgetArtwork,
                didChange: { changes.withLock { $0 += 1 } })
        }
        let hero = AppleTopShelfHero(item: item(record.id),
            backdropURL: try #require(URL(string: "https://fixture.example/first.jpg")), wordmarkURL: nil)
        #expect(try await writer().write(records: [record], heroes: [hero], enabled: true))
        let first = try #require(reader.read())
        #expect(first.widgetHero?.backdropFile != nil)
        #expect(staged.withLock { $0.first?.widgetHero } == nil)

        let changedHero = AppleTopShelfHero(item: hero.item,
            backdropURL: try #require(URL(string: "https://fixture.example/second.jpg")), wordmarkURL: nil)
        #expect(try await writer().write(records: [record], heroes: [changedHero], enabled: true))
        let second = try #require(reader.read())
        #expect(staged.withLock { $0.count } == 2)
        #expect(staged.withLock { $0.last?.generatedAt } == first.generatedAt)
        #expect(staged.withLock { $0.last?.widgetHero } == first.widgetHero)
        #expect(second.widgetHero?.backdropFile != first.widgetHero?.backdropFile)
        #expect(changes.withLock { $0 } == 2)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func widgetArtworkCannotReplaceANewerSnapshotOrOptOut(optOut: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        defer {
            started.continuation.finish()
            release.continuation.finish()
        }
        let image = Self.png(width: 64, height: 36)
        let changes = Mutex(0)
        let writer = AppleTopShelfSnapshotWriter(containerProvider: { root },
            snapshotLocation: { AppleTopShelfSnapshotWriter.snapshotURL(in: $0) },
            artwork: nil, trailerFiles: nil, widgetArtwork: AppleWidgetHeroArtworkStore { _ in
                started.continuation.yield()
                for await _ in release.stream { break }
                return image
            }, didChange: { changes.withLock { $0 += 1 } })
        let record = AppleMediaRecord(canonicalID: "lead", kind: .movie, title: "Lead",
            backdropURL: try #require(URL(string: "https://fixture.example/lead.jpg")),
            availability: [.init(instanceID: UUID(), capability: .direct, itemReference: "lead")], progress: 0.5)
        let writing = Task { try await writer.write(records: [record], enabled: true) }
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
        let replacement = AppleTopShelfSnapshot(version: 1, generatedAt: .distantFuture,
            continueWatching: [], recentlyAdded: [], favorites: [])
        if optOut {
            #expect(try await writer.write(records: [], enabled: false))
        } else {
            #expect(try await writer.save(replacement, to: AppleTopShelfSnapshotWriter.snapshotURL(in: root)))
        }
        release.continuation.yield()
        #expect(try await writing.value == false)
        #expect(changes.withLock { $0 } == 1)
        #expect(AppleTopShelfSnapshotReader(containerProvider: { root }).read() == (optOut ? nil : replacement))
    }

    @Test(arguments: [false, true])
    func interimTrailersExcludeAnUnshownHero(leadingArtworkFails: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let directory = AppleTopShelfTrailerPolicy.directory(in: root)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let trailer = AppleServerTrailer(url: try #require(URL(string: "https://fixture.example/trailer.mp4")),
            title: "Fixture", durationSeconds: 60, isFile: true)
        let heroes = (0...AppleTopShelfContentBuilder.carouselLimit).map { index in
            let id = "hero-\(index)"
            return AppleTopShelfHero(item: item(id, backdrop: !leadingArtworkFails || index != 0),
                backdropURL: leadingArtworkFails && index == 0 ? URL(string: "http://fixture.example/lead.jpg") : nil,
                wordmarkURL: nil,
                trailerQuery: .init(mediaID: id, title: id, year: nil, isSeries: false))
        }
        for hero in heroes {
            let name = AppleTopShelfTrailerPolicy.fileName(mediaID: hero.item.id, trailer: trailer)
            try Data("fixture".utf8).write(to: directory.appending(path: name))
        }
        let reader = AppleTopShelfSnapshotReader(containerProvider: { root })
        let notifications = Mutex<[AppleTopShelfSnapshot]>([])
        let writer = AppleTopShelfSnapshotWriter(containerProvider: { root },
            snapshotLocation: { AppleTopShelfSnapshotWriter.snapshotURL(in: $0) },
            artwork: AppleTopShelfArtworkStore { _ in throw URLError(.notConnectedToInternet) },
            trailerFiles: AppleTopShelfTrailerFiles(resolve: { _ in nil }),
            trailerDownloads: AppleTopShelfTrailerDownloads(), didChange: {
                if let snapshot = reader.read() { notifications.withLock { $0.append(snapshot) } }
            })
        #expect(try await writer.write(records: [], heroes: heroes, enabled: true))
        let published = notifications.withLock { $0 }
        let final = try #require(reader.read())
        let kept = Set(final.heroes.compactMap(\.shelfVideo))
        #expect(published.count == (leadingArtworkFails ? 2 : 1))
        #expect(published.allSatisfy { Set($0.heroes.compactMap(\.shelfVideo)).isSubset(of: kept) })
        #expect(kept.count == AppleTopShelfContentBuilder.carouselLimit)
        let hidden = try #require(leadingArtworkFails ? heroes.first : heroes.last)
        let unshown = AppleTopShelfTrailerPolicy.fileName(mediaID: hidden.item.id, trailer: trailer)
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: unshown).path))
    }
}
