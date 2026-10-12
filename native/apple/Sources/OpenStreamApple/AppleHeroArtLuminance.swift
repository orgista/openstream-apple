import CoreGraphics
import Foundation
import SwiftUI
import Synchronization

/// How bright a hero's art is, measured once from the decoded still: a small
/// grid of relative luminance (0 black … 1 white, linear light, as WCAG
/// contrast is worked out) that any hero can ask about the patch its copy
/// covers (N20: "TOXIC" in light grey over a near-white backdrop, iPad
/// 2026-09-23).
///
/// Pure, so the gate can check it without a window.
public struct AppleHeroLuminanceMap: Equatable, Sendable {
    public let columns: Int
    public let rows: Int
    /// Row-major from the image's top-left corner.
    public let values: [Float]
    /// The source image's width over its height.
    public let aspectRatio: CGFloat

    public static let gridColumns = 48

    public init(columns: Int, rows: Int, values: [Float], aspectRatio: CGFloat) {
        self.columns = columns
        self.rows = rows
        self.values = values
        self.aspectRatio = aspectRatio
    }

    /// Draws the image into a 48-column grid (rows kept in proportion) and
    /// reads each cell's relative luminance. Nil for an empty image.
    public init?(image: CGImage) {
        guard image.width > 0, image.height > 0 else { return nil }
        let aspect = CGFloat(image.width) / CGFloat(image.height)
        let columns = Self.gridColumns
        let rows = min(max(Int((CGFloat(columns) / aspect).rounded()), 4), 96)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: columns, height: rows, bitsPerComponent: 8,
                                      bytesPerRow: columns * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Opaque black first: transparent pixels read as the black the hero
        // draws behind the art.
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: columns, height: rows))
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: columns, height: rows))
        guard let data = context.data else { return nil }
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        var values = [Float](repeating: 0, count: columns * rows)
        // The bitmap's first row is the image's top row.
        for index in values.indices {
            let offset = index * 4
            values[index] = Self.relativeLuminance(red: pixels[offset], green: pixels[offset + 1],
                                                   blue: pixels[offset + 2])
        }
        self.init(columns: columns, rows: rows, values: values, aspectRatio: aspect)
    }

    /// WCAG relative luminance of an sRGB colour.
    public static func relativeLuminance(red: UInt8, green: UInt8, blue: UInt8) -> Float {
        func linear(_ component: UInt8) -> Float {
            let value = Float(component) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// The art under `region` (points, from the top-left of a `frame`-sized
    /// hero), drawn as `AppleRemoteImage` draws it: scaled to fill and pinned
    /// at `anchor` — by default the frame's top-leading corner, the overhang
    /// cropped off the right or the bottom; `(0.5, 0.5)` for a centred still
    /// (the Mac hero, `AppleRemoteImage.fillAlignment`). Nil when the frame or
    /// the region is empty.
    public func reading(region: CGRect, in frame: CGSize,
                        anchor: CGPoint = .zero) -> AppleHeroLuminanceReading? {
        guard frame.width > 0, frame.height > 0, aspectRatio > 0, !values.isEmpty else { return nil }
        var clipped = region.intersection(CGRect(origin: .zero, size: frame))
        guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return nil }
        // Height of the drawn image in points; its width is that times the aspect.
        let drawnHeight = max(frame.height, frame.width / aspectRatio)
        let drawnWidth = drawnHeight * aspectRatio
        // Into the drawn image's own points: the overhang left of and above
        // the frame, which is zero when pinned top-leading.
        clipped = clipped.offsetBy(dx: (drawnWidth - frame.width) * anchor.x,
                                   dy: (drawnHeight - frame.height) * anchor.y)
        let minColumn = Int((clipped.minX / drawnWidth * CGFloat(columns)).rounded(.down))
        let maxColumn = Int((clipped.maxX / drawnWidth * CGFloat(columns)).rounded(.up))
        let minRow = Int((clipped.minY / drawnHeight * CGFloat(rows)).rounded(.down))
        let maxRow = Int((clipped.maxY / drawnHeight * CGFloat(rows)).rounded(.up))
        var samples: [Float] = []
        for row in max(minRow, 0) ..< min(max(maxRow, minRow + 1), rows) {
            for column in max(minColumn, 0) ..< min(max(maxColumn, minColumn + 1), columns) {
                samples.append(values[row * columns + column])
            }
        }
        guard !samples.isEmpty else { return nil }
        samples.sort()
        let mean = samples.reduce(0, +) / Float(samples.count)
        let upper = samples[min(Int(Float(samples.count - 1) * 0.9), samples.count - 1)]
        return AppleHeroLuminanceReading(mean: Double(mean), upper: Double(upper))
    }
}

/// The art under a hero's copy: its mean luminance and its 90th percentile,
/// so a bright patch behind the wordmark counts even on darker art.
public struct AppleHeroLuminanceReading: Equatable, Sendable {
    public var mean: Double
    public var upper: Double

    public init(mean: Double, upper: Double) {
        self.mean = mean
        self.upper = upper
    }
}

/// Whether a hero's art is bright under its copy, which decides the scrim
/// (`AppleHeroScrim`). Unknown — not measured yet, no still, or a trailer on
/// screen — draws exactly what dark art does.
public enum AppleHeroArtTone: Equatable, Sendable {
    case unknown
    case dark
    case bright

    /// Mean relative luminance at or above this is bright: mid-grey sRGB
    /// (0.5) is 0.21, so this is a patch lighter than about 58 % grey, where
    /// white type under the standard fade drops below 4.5:1.
    public static let brightMean = 0.3
    /// …or a tenth of the patch at or above this (about 76 % grey): a pale sky
    /// or a lit window right behind the wordmark.
    public static let brightUpper = 0.55

    public init(reading: AppleHeroLuminanceReading?) {
        guard let reading else { self = .unknown; return }
        self = reading.mean >= Self.brightMean || reading.upper >= Self.brightUpper ? .bright : .dark
    }

    public var isBright: Bool { self == .bright }
}

/// Luminance maps, one per art URL, measured once off the main actor and held
/// for the session. Thread-safe: a hero reads it synchronously in `body`, so
/// a page it has already measured opens with the right scrim on its first
/// frame.
public final class AppleHeroLuminanceCache: Sendable {
    public static let shared = AppleHeroLuminanceCache()

    private struct Storage {
        var maps: [URL: AppleHeroLuminanceMap] = [:]
        var order: [URL] = []
    }

    private let storage = Mutex(Storage())
    private let capacity: Int

    public init(capacity: Int = 200) {
        self.capacity = max(capacity, 1)
    }

    public func cached(for url: URL?) -> AppleHeroLuminanceMap? {
        guard let url else { return nil }
        return storage.withLock { $0.maps[url] }
    }

    /// The map for `url`, measuring `image` (the still decoded for it) only
    /// the first time the URL is seen.
    public func map(for url: URL, image: CGImage) async -> AppleHeroLuminanceMap? {
        if let cached = cached(for: url) { return cached }
        let measured = await Task.detached(priority: .utility) {
            AppleHeroLuminanceMap(image: image)
        }.value
        guard let measured else { return nil }
        return storage.withLock { storage in
            if let raced = storage.maps[url] { return raced }
            storage.maps[url] = measured
            storage.order.append(url)
            if storage.order.count > capacity {
                storage.maps[storage.order.removeFirst()] = nil
            }
            return measured
        }
    }
}

/// A hero still that has decoded, with the URL it was decoded for, so a
/// still kept on screen across a page change is never measured as the next
/// page's art.
struct AppleHeroLoadedStill: Equatable {
    let url: URL
    let image: CGImage

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.url == rhs.url && lhs.image === rhs.image
    }
}

/// The measured map for one art URL, as a hero holds it in `@State`.
struct AppleHeroArtMeasurement: Equatable {
    let url: URL
    let map: AppleHeroLuminanceMap?

    /// The map for `url`: this measurement when it is for that URL, otherwise
    /// whatever the cache already holds.
    static func map(_ measurement: Self?, for url: URL?) -> AppleHeroLuminanceMap? {
        guard let url else { return nil }
        if let measurement, measurement.url == url { return measurement.map }
        return AppleHeroLuminanceCache.shared.cached(for: url)
    }
}

extension View {
    /// Measures `still` once it has decoded (`AppleHeroLuminanceCache`) and
    /// hands back the map.
    func appleMeasuresHeroArt(_ still: AppleHeroLoadedStill?,
                              perform: @escaping (AppleHeroArtMeasurement) -> Void) -> some View {
        task(id: still) {
            guard let still else { return }
            let map = await AppleHeroLuminanceCache.shared.map(for: still.url, image: still.image)
            guard !Task.isCancelled else { return }
            perform(AppleHeroArtMeasurement(url: still.url, map: map))
        }
    }
}
