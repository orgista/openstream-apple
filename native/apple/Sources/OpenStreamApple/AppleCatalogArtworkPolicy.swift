import CoreGraphics
import Foundation
import CryptoKit
#if os(macOS)
import AppKit
#endif

/// Ordered image attempts, shared by portrait and landscape catalog cards.
/// An HTTP/decode failure must advance to the next URL, just like a nil URL.
enum AppleCatalogArtworkPolicy {
    struct Lookup {
        private(set) var attempt = 0
        private(set) var completedAttempt: Int?

        init(suppliedArtworkFailed: Bool = false) {
            attempt = suppliedArtworkFailed ? 1 : 0
        }

        mutating func suppliedArtworkFailed() { attempt = 1 }
        mutating func complete(attempt: Int) { completedAttempt = attempt }
    }

    struct DisplayRequest: Equatable {
        let url: URL?
        let fixedPixelDimension: Int?
        let waitsForGeometry: Bool
    }

    static func configurationMarker(_ configuration: AppleTMDBConfiguration?) -> String {
        guard let configuration else { return "metadata-off" }
        return "metadata-" + SHA256.hash(data: Data(configuration.credential.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    /// Both fetch URL and decode budget are quantized, so live resizing
    /// within a bucket cannot restart the remote image's geometry-keyed task.
    static func displayRequest(url: URL?, pixels: CGSize,
                               purpose: AppleArtworkResolver.Purpose?) -> DisplayRequest {
        let serverImage = serverImageKind(url)
        guard AppleTMDBClient.isResizableArtworkURL(url) || serverImage != nil else {
            return DisplayRequest(url: url, fixedPixelDimension: nil, waitsForGeometry: false)
        }
        guard pixels.width.isFinite, pixels.height.isFinite, pixels.width > 0, pixels.height > 0 else {
            return DisplayRequest(url: nil, fixedPixelDimension: nil, waitsForGeometry: true)
        }
        if let serverImage, let url {
            return serverDisplayRequest(url: url, kind: serverImage, pixels: pixels, purpose: purpose)
        }
        var treatment = purpose ?? (pixels.width > pixels.height ? .resume : .poster)
        // The metadata client's fixed URLs identify the supported image family
        // when older callers use a portrait fallback in a landscape frame.
        let originalSize = url?.path.split(separator: "/").dropFirst(2).first
        if originalSize == "w500", treatment != .logo, treatment != .hero { treatment = .poster }
        if originalSize == "w1280", treatment == .poster { treatment = .resume }
        let pixelWidth = treatment == .poster ? min(pixels.width, pixels.height / 1.5) : pixels.width
        let bucket = treatment.size(pixelWidth: pixelWidth)
        let width = Int(bucket.dropFirst()) ?? Int(min(8192, pixels.width).rounded(.up))
        let dimension = treatment == .poster ? Int((Double(width) * 1.5).rounded(.up)) : width
        return DisplayRequest(url: AppleTMDBClient.resizedArtworkURL(url, size: bucket),
                              fixedPixelDimension: min(treatment == .hero ? 8192 : 2560, max(64, dimension)), waitsForGeometry: false)
    }

    private enum ServerImageKind { case jellyfin, plex }

    private static func serverImageKind(_ url: URL?) -> ServerImageKind? {
        guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let query = components.queryItems ?? []
        guard !query.contains(where: { ["signature", "sig", "x-amz-signature"].contains($0.name.lowercased()) }) else { return nil }
        let path = url.path.lowercased()
        if path.hasSuffix("/photo/:/transcode"), query.contains(where: { $0.name == "url" }) { return .plex }
        if path.range(of: #"/items/[^/]+/images/(primary|backdrop|logo)(/\d+)?$"#, options: .regularExpression) != nil,
           query.contains(where: { $0.name.lowercased() == "maxwidth" }) { return .jellyfin }
        return nil
    }

    private static func serverDisplayRequest(url: URL, kind: ServerImageKind, pixels: CGSize,
                                             purpose: AppleArtworkResolver.Purpose?) -> DisplayRequest {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return DisplayRequest(url: url, fixedPixelDimension: nil, waitsForGeometry: false)
        }
        let limit = purpose == .hero ? 8192 : 2560
        let boundedWidth = purpose == .poster ? min(pixels.width, pixels.height / 1.5) : pixels.width
        let pixelWidth = max(1, Int(min(CGFloat(limit), boundedWidth)))
        let step = AppleArtworkSizePolicy.serverWidthStep
        let width = pixelWidth < step ? pixelWidth : pixelWidth / step * step
        let aspect = purpose == .poster ? 1.5 : pixels.height / pixels.width
        let height = max(1, Int(min(CGFloat(limit), aspect * CGFloat(width)).rounded(.down)))
        let replacements: [URLQueryItem]
        switch kind {
        case .jellyfin:
            replacements = [.init(name: "maxWidth", value: String(width)), .init(name: "fillWidth", value: String(width)),
                            .init(name: "quality", value: "85")]
        case .plex:
            replacements = [.init(name: "width", value: String(width)), .init(name: "height", value: String(height))]
        }
        let names = Set(replacements.map { $0.name.lowercased() })
        components.queryItems = (components.queryItems ?? []).filter { !names.contains($0.name.lowercased()) } + replacements
        return DisplayRequest(url: components.url ?? url, fixedPixelDimension: max(width, height), waitsForGeometry: false)
    }

    @MainActor static var heroPixelWidth: CGFloat {
        #if os(macOS)
        let screen = NSScreen.main
        return screen.map { $0.frame.width * $0.backingScaleFactor } ?? 5120
        #else
        return 3840
        #endif
    }

    static func heroRequest(item: AppleCatalogItem, pixelWidth: CGFloat) -> DisplayRequest {
        heroRequest(url: item.backgroundURL ?? item.posterURL, backdrop: item.backgroundURL != nil, pixelWidth: pixelWidth)
    }

    /// The first hero still not in `failed`, trying the title's backdrop,
    /// the catalog's backdrop, then the poster. Nil once every one has failed.
    static func heroRequest(item: AppleCatalogItem, catalogBackdropURL: URL?, pixelWidth: CGFloat,
                            skipping failed: Set<URL>) -> DisplayRequest? {
        let stills: [(url: URL, backdrop: Bool)] = [
            item.backgroundURL.map { ($0, true) }, catalogBackdropURL.map { ($0, true) }, item.posterURL.map { ($0, false) },
        ].compactMap { $0 }
        return stills.lazy.map { heroRequest(url: $0.url, backdrop: $0.backdrop, pixelWidth: pixelWidth) }
            .first { $0.url.map { !failed.contains($0) } ?? true }
    }

    private static func heroRequest(url: URL?, backdrop: Bool, pixelWidth: CGFloat) -> DisplayRequest {
        let width = pixelWidth.isFinite && pixelWidth > 0 ? min(8192, pixelWidth) : 3840
        let request = displayRequest(url: url, pixels: CGSize(width: width, height: width * 9 / 16), purpose: backdrop ? .hero : .poster)
        let dimension = backdrop ? width : width * 1.5
        return DisplayRequest(url: request.url, fixedPixelDimension: Int(min(8192, dimension).rounded(.up)),
            waitsForGeometry: false)
    }

    #if DEBUG
    /// Correlates image attempts without recording URLs, hosts, or credentials.
    static func traceID(_ url: URL?) -> String {
        guard let url else { return "nil" }
        return SHA256.hash(data: Data(url.absoluteString.utf8)).prefix(8)
            .map { String(format: "%02x", $0) }.joined()
    }
    #endif

    static func candidates(item: AppleCatalogItem, landscape: Bool,
                           fallback: AppleArtworkResolver.Artwork? = nil) -> [URL] {
        candidates(item: item, purpose: landscape ? .resume : .poster, fallback: fallback)
    }

    static func resumeCandidates(item: AppleCatalogItem, still: URL? = nil,
                                 fallback: AppleArtworkResolver.Artwork? = nil) -> [URL] {
        var seen = Set<URL>()
        return [still, item.backgroundURL, fallback?.backgroundURL, item.posterURL, fallback?.posterURL]
            .compactMap { $0 }.filter { seen.insert($0).inserted }
    }

    static func candidates(item: AppleCatalogItem, purpose: AppleArtworkResolver.Purpose,
                           fallback: AppleArtworkResolver.Artwork? = nil) -> [URL] {
        if purpose == .logo {
            var seen = Set<URL>()
            return [item.logoURL, fallback?.logoURL].compactMap { $0 }.filter { seen.insert($0).inserted }
        }
        let landscape = purpose == .resume || purpose == .hero
        let supplied = landscape
            ? [item.backgroundURL, fallback?.backgroundURL, item.posterURL]
            : [item.posterURL, fallback?.posterURL, item.backgroundURL]
        let values = supplied.compactMap { $0 }
            + (landscape ? [fallback?.backgroundURL, fallback?.posterURL]
                         : [fallback?.posterURL, fallback?.backgroundURL]).compactMap { $0 }
        var seen = Set<URL>()
        return values.filter { seen.insert($0).inserted }
    }

    /// A poster used as a landscape fallback still needs a poster size.
    static func purpose(of url: URL?, item: AppleCatalogItem,
                        fallback: AppleArtworkResolver.Artwork?, preferred: AppleArtworkResolver.Purpose) -> AppleArtworkResolver.Purpose {
        guard let url else { return preferred }
        if url == item.backgroundURL || url == fallback?.backgroundURL {
            return preferred == .hero ? .hero : .resume
        }
        if url == item.posterURL || url == fallback?.posterURL { return .poster }
        if url == item.logoURL || url == fallback?.logoURL { return .logo }
        return preferred
    }

    /// How long a card that has run out of art waits before trying its
    /// candidates again, by how many times it already has; nil stops.
    ///
    /// A load that fails once — a timeout while a Library shelf asks for a
    /// hundred posters at once — used to latch the card to its title tile for
    /// as long as it stayed on screen: the grey tiles in Library › Movies
    /// for titles Discover showed posters for (owner, 2026-09-24).
    /// What a poster is printed on. Some "posters" are a logo on a plate —
    /// transparent, or pure black ("Law & Order", "The Chosen", N32 #16) —
    /// and on the black page the card's edge vanishes, so the logo floats.
    /// Those draw on the card's dark rounded tile, as the Apple TV app does.
    enum Plate: Equatable, Sendable { case none, transparent, black }

    /// Reads the image's border at a 12 × 18 sample. A plate is at least 85 %
    /// of the border clear or true black (a JPEG plate decodes to 0–3); a
    /// band of colour reaching the edge, as Law & Order's does, still counts.
    static func plate(of image: CGImage) -> Plate {
        let width = 12, height = 18
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return .none }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var border: [(UInt8, UInt8, UInt8, UInt8)] = []
        for y in 0 ..< height {
            for x in 0 ..< width where x == 0 || y == 0 || x == width - 1 || y == height - 1 {
                let i = (y * width + x) * 4
                border.append((data[i], data[i + 1], data[i + 2], data[i + 3]))
            }
        }
        return plate(border: border)
    }

    static func plate(border: [(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8)]) -> Plate {
        guard !border.isEmpty else { return .none }
        let needed = Double(border.count) * 0.85
        let clear = border.filter { $0.alpha < 250 }.count
        if Double(clear) >= needed { return .transparent }
        let black = border.filter { $0.alpha < 250 || max($0.red, $0.green, $0.blue) <= 8 }.count
        return Double(black) >= needed ? .black : .none
    }

    /// What a logo-on-a-plate poster is drawn over: the title's own backdrop,
    /// so the card reads as the title's art with its logo on it rather than
    /// a grey box with the name on it (N49 #20). The item's backdrop first,
    /// then a resolved one; never the image the card is already showing. Nil
    /// leaves the logo on the dark tile.
    static func plateBackdrop(item: AppleCatalogItem, fallback: AppleArtworkResolver.Artwork? = nil,
                              showing: URL?) -> URL? {
        [item.backgroundURL, fallback?.backgroundURL].compactMap { $0 }.first { $0 != showing }
    }

    /// How loaded art sits in its card. A portrait poster in a 16:9 card
    /// (a Top 10 match found by search arrives with a poster and no
    /// backdrop) was filled to the card's width and pinned to its top, so the
    /// card showed the poster's top third: a dark box for "Wonka's The Golden
    /// Ticket" (Apple TV, 2026-10-01). It is drawn whole, centred over a
    /// blurred fill of itself, instead.
    enum Framing: Equatable, Sendable {
        case fill
        /// Width over height of the poster.
        case posterInFrame(aspect: Double)
    }

    static func framing(landscapeCard: Bool, imageWidth: Int, imageHeight: Int) -> Framing {
        guard landscapeCard, imageWidth > 0, imageHeight > 0 else { return .fill }
        let aspect = Double(imageWidth) / Double(imageHeight)
        return aspect < 1 ? .posterInFrame(aspect: aspect) : .fill
    }

    static func retryDelay(afterRetries retries: Int) -> Duration? {
        switch retries {
        case 0: .seconds(3)
        case 1: .seconds(10)
        default: nil
        }
    }

    static func next(in candidates: [URL], failed: Set<URL>) -> URL? {
        candidates.first { !failed.contains($0) }
    }
}
