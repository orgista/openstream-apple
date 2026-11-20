import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Poster artwork for the Home Screen widgets.
///
/// A WidgetKit view is rendered once, synchronously, into a static snapshot:
/// anything still in flight when that snapshot is taken never appears. The
/// Continue Watching widget used `AsyncImage`, whose fetch always resolves
/// after the snapshot has been captured, so every tile drew the grey fallback
/// under a real title (owner's home screen, 2026-09-20). The bytes therefore
/// have to be resolved in the timeline provider, before the entry exists —
/// which is what this file is for.

/// Sizing and naming rules for those thumbnails. Pure, so the gate covers them.
public enum AppleWidgetArtworkPolicy {
    /// A widget extension is killed at a far lower memory ceiling than the app,
    /// and every visible poster is resident at once, so the longest edge is
    /// capped hard rather than decoded at whatever size the CDN served.
    public static let ceilingPixels = 480
    /// Below this a poster is mush; a tiny widget still gets a usable image.
    public static let floorPixels = 64

    /// The longest edge worth decoding for one poster in a widget
    /// `widthInPoints` wide showing `columns` posters side by side.
    public static func pixelSize(widthInPoints: Double, columns: Int, scale: Double) -> Int {
        let columns = max(1, columns)
        let scale = scale > 0 ? scale : 1
        // Posters are 2:3, so the tall edge is what drives the decode.
        let longestEdge = (max(0, widthInPoints) / Double(columns)) * 1.5 * scale
        guard longestEdge.isFinite else { return floorPixels }
        return min(ceilingPixels, max(floorPixels, Int(longestEdge.rounded())))
    }

    /// Cache file name. The pixel size is part of it because the same poster is
    /// wanted at one size on a small widget and another on a large one.
    public static func fileName(for url: URL, pixelSize: Int) -> String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "\(hex)-\(pixelSize).jpg"
    }
}

/// Decodes remote artwork straight to the size the widget draws it at.
public enum AppleWidgetArtworkThumbnail {
    /// Encoded bytes no larger than `pixelSize` on the longest edge, or nil when
    /// the data is not an image. ImageIO decodes the thumbnail directly, so a
    /// 1000×1500 poster is never resident at full resolution in the extension.
    public static func thumbnail(from data: Data, pixelSize: Int, isWordmark: Bool = false) -> Data? {
        guard pixelSize > 0,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: pixelSize,
                  kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary) else {
            return nil
        }
        guard !isWordmark || AppleTransparentPNGLogoValidator.hasTransparentEdges(in: image) else { return nil }
        let output = isWordmark ? (AppleRemoteImageDecoder.trimmedToAlphaBounds(image) ?? image) : image
        return encode(output, preservingAlpha: isWordmark)
    }

    /// The pixel dimensions of encoded image data, without decoding the pixels.
    public static func pixelSize(ofEncoded data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            return nil
        }
        return (width, height)
    }

    /// Posters use JPEG; wordmarks keep their alpha channel in PNG.
    private static func encode(_ image: CGImage, preservingAlpha: Bool) -> Data? {
        let buffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            buffer, (preservingAlpha ? UTType.png : .jpeg).identifier as CFString, 1, nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: 0.8,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return buffer as Data
    }
}

/// Supplies those thumbnails to the widget, cache first.
///
/// The app's own artwork cache (`AppleArtworkDiskCache`) lives under the app's
/// Caches directory, which a widget extension cannot reach — so it is not
/// reusable here. The thumbnails live in the shared app group instead, beside
/// the snapshot the widget already reads, which means a poster is fetched once
/// and every later timeline reload draws it without touching the network.
public struct AppleWidgetArtworkStore: Sendable {
    public typealias Fetch = @Sendable (URL) async throws -> Data

    public static let directoryName = "widget-artwork"
    /// Thumbnails are tens of kilobytes each; this holds a few hundred.
    public static let maximumCacheBytes = 8 * 1_024 * 1_024
    /// How many posters are fetched at once. A widget has a small time budget
    /// and a smaller memory one.
    public static let maximumConcurrentFetches = 3

    private let containerProvider: @Sendable () -> URL?
    private let fetch: Fetch

    public init(
        containerProvider: @escaping @Sendable () -> URL? = {
            FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: AppleTopShelfSnapshotWriter.appGroup
            )
        },
        fetch: @escaping Fetch = AppleWidgetArtworkStore.download
    ) {
        self.containerProvider = containerProvider
        self.fetch = fetch
    }

    /// Thumbnails for the items a widget is about to draw, keyed by item id.
    /// An item whose artwork is missing, unsafe, or unreachable is simply
    /// absent from the result; the widget draws its brand mark for that tile.
    public func thumbnails(
        for items: [AppleTopShelfSnapshot.Item],
        pixelSize: Int
    ) async -> [String: Data] {
        var results: [String: Data] = [:]
        await withTaskGroup(of: (String, Data)?.self) { group in
            var running = 0
            for item in items {
                if running >= Self.maximumConcurrentFetches, let finished = await group.next() {
                    running -= 1
                    if let finished { results[finished.0] = finished.1 }
                }
                running += 1
                group.addTask {
                    guard let data = await thumbnail(for: item.artworkURL, pixelSize: pixelSize) else {
                        return nil
                    }
                    return (item.id, data)
                }
            }
            for await finished in group {
                if let finished { results[finished.0] = finished.1 }
            }
        }
        return results
    }

    /// Cache first, then the network. `AppleSystemArtworkPolicy` is the same
    /// gate Top Shelf and Spotlight go through — a widget is another process
    /// outside the app's sandbox, so nothing looser belongs here.
    public func thumbnail(for url: URL?, pixelSize: Int) async -> Data? {
        guard let url = AppleSystemArtworkPolicy.publicURL(url) else { return nil }
        let pixelSize = min(
            AppleWidgetArtworkPolicy.ceilingPixels,
            max(AppleWidgetArtworkPolicy.floorPixels, pixelSize)
        )
        let file = cacheURL(for: url, pixelSize: pixelSize)
        if let file, let cached = try? Data(contentsOf: file), !cached.isEmpty {
            // Keep eviction honest about what is still being drawn.
            try? FileManager.default.setAttributes(
                [.modificationDate: Date()], ofItemAtPath: file.path
            )
            return cached
        }
        guard let data = try? await fetch(url),
              let thumbnail = AppleWidgetArtworkThumbnail.thumbnail(from: data, pixelSize: pixelSize) else {
            return nil
        }
        if let file { store(thumbnail, at: file) }
        return thumbnail
    }

    private func cacheURL(for url: URL, pixelSize: Int) -> URL? {
        guard let root = containerProvider() else { return nil }
        return root
            .appending(path: Self.directoryName, directoryHint: .isDirectory)
            .appending(path: AppleWidgetArtworkPolicy.fileName(for: url, pixelSize: pixelSize))
    }

    private func store(_ data: Data, at file: URL) {
        let directory = file.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Not `.completeFileProtection…`: a widget is rendered before first
        // unlock, and an unreadable poster there is the bug this file fixes.
        // The bytes are a public poster the CDN serves to anyone.
        do {
            try data.write(to: file, options: .atomic)
        } catch {
            return
        }
        trim(directory)
    }

    private func trim(_ directory: URL) {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys
        ) else { return }
        var entries: [(name: String, bytes: Int, modified: Date)] = []
        for file in files {
            guard let values = try? file.resourceValues(forKeys: Set(keys)),
                  let bytes = values.fileSize,
                  let modified = values.contentModificationDate else { continue }
            entries.append((file.lastPathComponent, bytes, modified))
        }
        for name in AppleArtworkDiskCachePolicy.evictionOrder(entries, limit: Self.maximumCacheBytes) {
            try? FileManager.default.removeItem(at: directory.appending(path: name))
        }
    }

    /// The bounded loader the rest of the app uses, with a timeout short enough
    /// to fit inside a widget refresh and redirects pinned to https.
    public static func download(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        let (data, response) = try await AppleBoundedHTTPDataLoader.load(
            request,
            maximumBytes: 6 * 1_024 * 1_024,
            redirectPolicy: .secureHTTPOnly
        )
        guard let http = response as? HTTPURLResponse,
              (200 ... 299).contains(http.statusCode) else {
            throw URLError(.cannotDecodeContentData)
        }
        return data
    }
}

public struct AppleWidgetHeroArtwork: Codable, Equatable, Sendable {
    public let itemID: String
    public let backdropFile: String?
    public let wordmarkFile: String?
}

/// Only the app writes these bounded images; the extension reads them without networking.
public actor AppleWidgetHeroArtworkStore {
    public static let backdropPixels = 1_600
    public static let wordmarkPixels = 600
    private static let directoryName = "widget-hero"
    private let fetch: AppleWidgetArtworkStore.Fetch
    private var failedFiles: Set<URL> = []

    public init(fetch: @escaping AppleWidgetArtworkStore.Fetch = AppleWidgetArtworkStore.download) {
        self.fetch = fetch
    }

    public func prepare(itemID: String, backdrop: URL?, wordmark: URL?, in root: URL) async -> AppleWidgetHeroArtwork {
        let backdropFile = await write(backdrop, pixels: Self.backdropPixels, in: root)
        let wordmarkFile = await write(wordmark, pixels: Self.wordmarkPixels, isWordmark: true, in: root)
        return AppleWidgetHeroArtwork(itemID: itemID, backdropFile: backdropFile, wordmarkFile: wordmarkFile)
    }

    public static func read(_ name: String?, in root: URL) -> Data? {
        guard let name, name == URL(fileURLWithPath: name).lastPathComponent,
              ["png", "jpg"].contains(URL(fileURLWithPath: name).pathExtension) else { return nil }
        return try? Data(contentsOf: directory(in: root).appending(path: name))
    }

    public static func removeAll(in root: URL) {
        try? FileManager.default.removeItem(at: directory(in: root))
    }

    private static func directory(in root: URL) -> URL {
        root.appending(path: "Library/Caches", directoryHint: .isDirectory)
            .appending(path: directoryName, directoryHint: .isDirectory)
    }

    public nonisolated func removeUnused(in root: URL, keeping artwork: AppleWidgetHeroArtwork) {
        let directory = Self.directory(in: root)
        let kept = Set([artwork.backdropFile, artwork.wordmarkFile].compactMap { $0 })
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: nil) else { return }
        for file in files where !kept.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func write(_ url: URL?, pixels: Int, isWordmark: Bool = false, in root: URL) async -> String? {
        guard let url = AppleSystemArtworkPolicy.publicURL(url) else { return nil }
        let name = AppleWidgetArtworkPolicy.fileName(for: url, pixelSize: pixels)
            .replacingOccurrences(of: ".jpg", with: isWordmark ? ".png" : ".jpg")
        let directory = Self.directory(in: root)
        let file = directory.appending(path: name)
        if FileManager.default.fileExists(atPath: file.path) { return name }
        guard !failedFiles.contains(file) else { return nil }
        let data: Data
        do {
            data = try await fetch(url)
        } catch {
            if !(error is CancellationError), !Task.isCancelled { failedFiles.insert(file) }
            return nil
        }
        guard !Task.isCancelled else { return nil }
        guard let thumbnail = AppleWidgetArtworkThumbnail.thumbnail(from: data, pixelSize: pixels,
            isWordmark: isWordmark) else {
            failedFiles.insert(file)
            return nil
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try thumbnail.write(to: file, options: .atomic)
            return name
        } catch {
            return nil
        }
    }
}
