import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The full-screen Top Shelf page's picture, drawn by the app: tvOS gives a
/// carousel item one image and no logo field, so the title's wordmark (the
/// one the Home hero draws) is painted into a 1920×1080 copy of the backdrop,
/// bottom left as the Apple TV app places it (owner 2026-10-16: "no
/// wordmark"). The page then always gets an exact 16:9 local file instead of
/// whatever size the CDN serves.
enum AppleTopShelfArtworkLayout {
    static let canvas = CGSize(width: 1920, height: 1080)
    /// The tvOS safe zone's leading inset, where the system starts its own
    /// copy under the picture.
    static let leadingInset: CGFloat = 90
    /// About the billboard's wordmark slot (`AppleTVBillboard`).
    static let wordmarkBox = CGSize(width: 600, height: 140)
    /// From the bottom edge to the wordmark's foot (measured on a test Apple TV,
    /// 2026-10-16): the band 600–740 pt down the screen sits above the
    /// collapsed shelf's "Swipe up" line and app row, and below the paging
    /// chevrons full screen draws at mid-height.
    static let wordmarkBottom: CGFloat = 340
    /// A soft shadow behind the wordmark keeps it legible on bright art;
    /// owner rule: no scrims or gradients over artwork.
    static let wordmarkShadowBlur: CGFloat = 28
    static let wordmarkShadowOpacity: CGFloat = 0.6
    static let jpegQuality: CGFloat = 0.82
    /// Bumped whenever the drawing changes, so cached pages are redrawn.
    static let version = 3

    /// The backdrop scaled to cover the canvas, centred.
    static func fillRect(for image: CGSize) -> CGRect {
        guard image.width > 0, image.height > 0 else { return CGRect(origin: .zero, size: canvas) }
        let scale = max(canvas.width / image.width, canvas.height / image.height)
        let size = CGSize(width: image.width * scale, height: image.height * scale)
        return CGRect(x: (canvas.width - size.width) / 2, y: (canvas.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    /// The wordmark fitted inside its box, leading aligned, its foot on
    /// `wordmarkBottom`. Core Graphics coordinates (origin bottom left).
    static func wordmarkRect(for image: CGSize) -> CGRect {
        guard image.width > 0, image.height > 0 else { return .zero }
        let scale = min(wordmarkBox.width / image.width, wordmarkBox.height / image.height)
        return CGRect(x: leadingInset, y: wordmarkBottom,
                      width: (image.width * scale).rounded(), height: (image.height * scale).rounded())
    }

    /// One file per backdrop and wordmark pair; a page that loses or gains
    /// its wordmark gets a new name, so the system never shows a stale copy.
    static func fileName(backdrop: URL, wordmark: URL?) -> String {
        let input = "\(version)|\(backdrop.absoluteString)|\(wordmark?.absoluteString ?? "")"
        let hex = SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
        return "\(hex).jpg"
    }

    /// The JPEG the shelf shows, or nil when the backdrop cannot be drawn.
    static func render(backdrop: CGImage, wordmark: CGImage?) -> Data? {
        let width = Int(canvas.width), height = Int(canvas.height)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(backdrop, in: fillRect(for: CGSize(width: backdrop.width, height: backdrop.height)))
        if let wordmark {
            context.setShadow(offset: .zero, blur: wordmarkShadowBlur,
                              color: CGColor(gray: 0, alpha: wordmarkShadowOpacity))
            context.draw(wordmark, in: wordmarkRect(for: CGSize(width: wordmark.width, height: wordmark.height)))
        }
        return context.makeImage().flatMap(jpeg)
    }

    /// A row poster saved from the viewer's own server; named by its address,
    /// which never leaves the app.
    static func posterFileName(_ url: URL) -> String {
        let hex = SHA256.hash(data: Data("poster|\(url.absoluteString)".utf8)).map { String(format: "%02x", $0) }.joined()
        return "poster-\(hex).jpg"
    }

    static func jpeg(_ image: CGImage) -> Data? {
        let buffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(buffer, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image,
                                   [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? buffer as Data : nil
    }
}

/// Draws and keeps the shelf's pictures in the app group's Library/Caches
/// (the only place Apple TV hardware lets the app write; the extension reads
/// it too), at most one per carousel page.
public struct AppleTopShelfArtworkStore: Sendable {
    public typealias Fetch = @Sendable (URL) async throws -> Data

    public static let directoryName = "topshelf-art"
    /// Pages drawn at once: each holds a decoded backdrop.
    static let maximumConcurrent = 3

    private let fetch: Fetch

    public init(fetch: @escaping Fetch = AppleWidgetArtworkStore.download) {
        self.fetch = fetch
    }

    public static func directory(in root: URL) -> URL {
        root.appending(path: "Library/Caches", directoryHint: .isDirectory)
            .appending(path: directoryName, directoryHint: .isDirectory)
    }

    /// The file name of each page's picture, by item id. A page whose
    /// backdrop cannot be fetched is absent and keeps the remote backdrop.
    func pictures(for pages: [(id: String, backdrop: URL, wordmark: URL?)], in directory: URL) async -> [String: String] {
        await files(for: pages.map { page in (page.id, { await picture(backdrop: page.backdrop, wordmark: page.wordmark, in: directory) }) },
                    in: directory)
    }

    /// The rows' posters whose art lives on the viewer's own server (a LAN
    /// host or plain http, which a system surface must not be handed): a copy
    /// saved here, by item id, so the snapshot names a file and never the
    /// address. An item whose poster cannot be fetched is absent.
    func posters(for items: [(id: String, url: URL)], in directory: URL) async -> [String: String] {
        await files(for: items.map { item in (item.id, { await poster(item.url, in: directory) }) }, in: directory)
    }

    /// The pictures and posters already saved, by item id, found without
    /// fetching anything: what a publish can show before any server answers.
    func saved(pages: [(id: String, backdrop: URL, wordmark: URL?)], posters: [(id: String, url: URL)],
               in directory: URL) -> (pictures: [String: String], posters: [String: String]) {
        func existing(_ id: String, _ names: [String]) -> (String, String)? {
            names.first { FileManager.default.fileExists(atPath: directory.appending(path: $0).path) }.map { (id, $0) }
        }
        let pictures = pages.compactMap { page in
            existing(page.id, [AppleTopShelfArtworkLayout.fileName(backdrop: page.backdrop, wordmark: page.wordmark),
                               AppleTopShelfArtworkLayout.fileName(backdrop: page.backdrop, wordmark: nil)])
        }
        let saved = posters.compactMap { existing($0.id, [AppleTopShelfArtworkLayout.posterFileName($0.url)]) }
        return (Dictionary(pictures, uniquingKeysWith: { first, _ in first }),
                Dictionary(saved, uniquingKeysWith: { first, _ in first }))
    }

    private func files(for jobs: [(id: String, make: @Sendable () async -> String?)], in directory: URL) async -> [String: String] {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var names: [String: String] = [:]
        await withTaskGroup(of: (String, String?).self) { group in
            var running = 0
            for job in jobs {
                if running >= Self.maximumConcurrent, let (id, name) = await group.next() {
                    running -= 1
                    names[id] = name
                }
                running += 1
                group.addTask { (job.id, await job.make()) }
            }
            for await (id, name) in group { names[id] = name }
        }
        return names
    }

    private func poster(_ url: URL, in directory: URL) async -> String? {
        let name = AppleTopShelfArtworkLayout.posterFileName(url)
        if FileManager.default.fileExists(atPath: directory.appending(path: name).path) { return name }
        guard let data = try? await fetch(url),
              let image = try? AppleRemoteImageDecoder.downsample(data: data, maximumPixelDimension: 800),
              let jpeg = AppleTopShelfArtworkLayout.jpeg(image),
              (try? jpeg.write(to: directory.appending(path: name), options: .atomic)) != nil else { return nil }
        return name
    }

    /// Deletes every picture no page uses any more.
    func removeAll(in directory: URL, except kept: Set<String>) {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for file in files where !kept.contains(file) {
            try? FileManager.default.removeItem(at: directory.appending(path: file))
        }
    }

    /// A wordmark that will not load leaves the plain backdrop under its own
    /// name, so the next publish tries the wordmark again.
    private func picture(backdrop: URL, wordmark: URL?, in directory: URL) async -> String? {
        let wanted = AppleTopShelfArtworkLayout.fileName(backdrop: backdrop, wordmark: wordmark)
        if FileManager.default.fileExists(atPath: directory.appending(path: wanted).path) { return wanted }
        guard let backdropData = try? await fetch(backdrop),
              let backdropImage = try? AppleRemoteImageDecoder.downsample(data: backdropData, maximumPixelDimension: 2_560)
        else { return nil }
        var logo: CGImage?
        if let wordmark,
           let data = try? await fetch(AppleTMDBClient.resizedArtworkURL(wordmark, size: "w500") ?? wordmark),
           let decoded = try? AppleRemoteImageDecoder.downsample(data: data, maximumPixelDimension: 1_240) {
            logo = AppleRemoteImageDecoder.trimmedToAlphaBounds(decoded)
        }
        let name = logo == nil ? AppleTopShelfArtworkLayout.fileName(backdrop: backdrop, wordmark: nil) : wanted
        if FileManager.default.fileExists(atPath: directory.appending(path: name).path) { return name }
        guard let data = AppleTopShelfArtworkLayout.render(backdrop: backdropImage, wordmark: logo),
              (try? data.write(to: directory.appending(path: name), options: .atomic)) != nil else { return nil }
        return name
    }
}
