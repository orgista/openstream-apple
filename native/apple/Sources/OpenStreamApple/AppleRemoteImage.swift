import Foundation
import CoreGraphics
import ImageIO
import SwiftUI

enum AppleRemoteImageContentMode: Equatable {
    case fill
    case fit
}

/// A bounded, memory-cached remote image that decodes near its rendered size.
/// Poster catalogs otherwise retain full 1000×1500 source images for every
/// 160-point card, which is especially costly on Apple TV.
struct AppleRemoteImage: View {
    let url: URL?
    var contentMode: AppleRemoteImageContentMode = .fill
    var placeholderSystemImage = "film"
    /// Called on the main actor once the image has decoded, so a caller can
    /// react to its pixel size (e.g. treat a wide wordmark differently).
    var onLoad: ((CGImage) -> Void)? = nil
    /// Called on the main actor when there is nothing to show (no URL, or the
    /// fetch/decode failed), so a caller can draw its own placeholder.
    var onFailure: (() -> Void)? = nil
    /// The surface drawn while the image is in flight.
    ///
    /// The default is deliberately almost invisible, which is right for a
    /// poster in a shelf. It is wrong for a full-bleed billboard: at 2.5% white
    /// over black the hero is a void, and the title, synopsis and pills sit on
    /// nothing until the art lands (owner's recurring "GUI with no content",
    /// seen again 2026-09-15). A hero passes a real surface instead.
    var loadingFill: Color = .white.opacity(0.025)

    @Environment(\.displayScale) private var displayScale
    @State private var image: CGImage?
    @State private var failed = false

    var body: some View {
        GeometryReader { geometry in
            Group {
                if let image {
                    rendered(image)
                } else if failed {
                    placeholder
                } else {
                    // Keep the surrounding layout quiet while remote art is
                    // loading. A spinner inside every poster reads as a
                    // boxed loading state and makes the detail page jump when
                    // the image arrives.
                    loadingFill
                }
            }
            .task(id: loadIdentity(url: url, size: geometry.size)) {
                image = nil
                failed = false
                guard let url else {
                    failed = true
                    onFailure?()
                    return
                }
                let maximumDimension = max(64, Int(max(geometry.size.width, geometry.size.height) * displayScale))
                do {
                    let loaded = try await AppleRemoteImageCache.shared.image(
                        url: url,
                        maximumPixelDimension: min(maximumDimension, 2_560)
                    )
                    image = loaded
                    onLoad?(loaded)
                } catch is CancellationError {
                    return
                } catch {
                    failed = true
                    onFailure?()
                }
            }
        }
        .accessibilityHidden(true)
        .accessibilityIgnoresInvertColors()
    }

    @ViewBuilder
    private func rendered(_ image: CGImage) -> some View {
        let value = Image(decorative: image, scale: displayScale)
            .resizable()
        if contentMode == .fill {
            value.scaledToFill()
        } else {
            value.scaledToFit()
        }
    }

    private var placeholder: some View {
        ZStack {
            Color.clear
            Image(systemName: placeholderSystemImage)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
        }
    }

    private func loadIdentity(url: URL?, size: CGSize) -> String {
        "\(url?.absoluteString ?? "")|\(Int(size.width))x\(Int(size.height))@\(displayScale)"
    }
}

/// Renders a title wordmark from its decoded alpha bounds rather than its
/// source canvas. Metahub logos often contain asymmetric transparent padding;
/// cropping that padding keeps the visible mark optically centered.
struct AppleTrimmedTitleLogo: View {
    let url: URL
    /// Where the wordmark sits inside the slot it is given.
    ///
    /// `scaledToFit` leaves slack on one axis, and this view used to centre the
    /// artwork in that slack unconditionally — which overrode the
    /// `alignment: .leading` its callers asked for and left the Discover
    /// billboard's wordmark indented ~190 pt while the metadata line, synopsis
    /// and Play button under it were flush at the safe inset. It is declared
    /// before `onLoadResult` so callers keep trailing-closure syntax.
    var alignment: Alignment = .center
    /// Reports `true` once the wordmark is on screen, `false` when the fetch or
    /// decode failed, so callers can fall back to a text title instead of
    /// showing nothing.
    var onLoadResult: (Bool) -> Void = { _ in }

    @Environment(\.displayScale) private var displayScale
    @State private var image: CGImage?
    @State private var reportedResult: Bool?

    var body: some View {
        GeometryReader { geometry in
            Group {
                if let image {
                    Image(decorative: image, scale: displayScale)
                        .resizable()
                        .scaledToFit()
                        .frame(width: geometry.size.width, height: geometry.size.height, alignment: alignment)
                        .frame(maxWidth: .infinity, alignment: alignment)
                } else {
                    Color.clear
                }
            }
            .task(id: "\(url.absoluteString)|\(Int(geometry.size.width))x\(Int(geometry.size.height))@\(displayScale)") {
                guard !Task.isCancelled else { return }
                do {
                    let decoded = try await AppleRemoteImageCache.shared.image(
                        url: url,
                        maximumPixelDimension: min(2_560, max(256, Int(max(geometry.size.width, geometry.size.height) * displayScale * 4)))
                    )
                    guard !Task.isCancelled else { return }
                    image = AppleRemoteImageDecoder.trimmedToAlphaBounds(decoded)
                    report(image != nil)
                } catch is CancellationError {
                    return
                } catch {
                    image = nil
                    report(false)
                }
            }
        }
        .accessibilityHidden(true)
        .accessibilityIgnoresInvertColors()
    }

    private func report(_ loaded: Bool) {
        guard reportedResult != loaded else { return }
        reportedResult = loaded
        onLoadResult(loaded)
    }
}

actor AppleRemoteImageCache {
    static let shared = AppleRemoteImageCache()

    typealias Loader = @Sendable (URL, Int) async throws -> CGImage

    private final class Entry {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    private let cache = NSCache<NSString, Entry>()
    private var inFlight: [NSString: Task<CGImage, any Error>] = [:]
    private let loader: Loader

    init(loader: @escaping Loader = AppleRemoteImageCache.load) {
        self.loader = loader
        cache.countLimit = 300
        cache.totalCostLimit = 160 * 1_024 * 1_024
    }

    func image(url: URL, maximumPixelDimension: Int) async throws -> CGImage {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              url.user == nil,
              url.password == nil else {
            throw URLError(.unsupportedURL)
        }
        let key = "\(url.absoluteString)|\(maximumPixelDimension)" as NSString
        if let cached = cache.object(forKey: key) { return cached.image }
        if let task = inFlight[key] { return try await task.value }

        let task = Task<CGImage, any Error> { try await loader(url, maximumPixelDimension) }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        let decoded = try await task.value
        cache.setObject(
            Entry(decoded),
            forKey: key,
            cost: decoded.bytesPerRow * decoded.height
        )
        return decoded
    }

    private static func load(url: URL, maximumPixelDimension: Int) async throws -> CGImage {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await AppleBoundedHTTPDataLoader.load(
            request,
            maximumBytes: 12 * 1_024 * 1_024
        )
        guard let http = response as? HTTPURLResponse,
              (200 ... 299).contains(http.statusCode) else {
            throw URLError(.cannotDecodeContentData)
        }
        return try await Task.detached(priority: .utility) {
            try AppleRemoteImageDecoder.downsample(
                data: data,
                maximumPixelDimension: maximumPixelDimension
            )
        }.value
    }
}

enum AppleRemoteImageDecoder {
    static func downsample(data: Data, maximumPixelDimension: Int) throws -> CGImage {
        guard maximumPixelDimension > 0,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maximumPixelDimension,
                  kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary) else {
            throw URLError(.cannotDecodeContentData)
        }
        return image
    }

    static func trimmedToAlphaBounds(_ image: CGImage, minimumAlpha: UInt8 = 8) -> CGImage? {
        guard image.width > 1, image.height > 1 else { return image }

        let width = image.width
        let height = image.height
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let buffer = context.data?.assumingMemoryBound(to: UInt8.self) else {
            return image
        }

        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1
        for y in 0..<height {
            for x in 0..<width where buffer[(y * width + x) * 4 + 3] >= minimumAlpha {
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }

        guard maxX >= minX, maxY >= minY else { return image }
        return image.cropping(to: CGRect(
            x: minX,
            y: minY,
            width: maxX - minX + 1,
            height: maxY - minY + 1
        )) ?? image
    }
}

enum AppleTransparentPNGLogoValidator {
    private static let pngSignature: [UInt8] = [
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
    ]

    /// The size the wordmark views ask the cache for. Validating at the same
    /// size means the validator and the view share one download instead of
    /// fetching the same PNG twice in a row, which was most of the 1.6 s a
    /// content page took to show its wordmark (measured 2026-09-15).
    static let validationPixelDimension = 2_560

    static func isValid(url: URL) async -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              url.user == nil,
              url.password == nil else { return false }

        do {
            // Through the shared cache: this is the fetch `AppleTrimmedTitleLogo`
            // is about to make, so it is warm by the time the view asks.
            let image = try await AppleRemoteImageCache.shared.image(
                url: url,
                maximumPixelDimension: validationPixelDimension
            )
            return await Task.detached(priority: .utility) {
                hasTransparentEdges(in: image)
            }.value
        } catch is CancellationError {
            return false
        } catch {
            return false
        }
    }

    /// Edge transparency straight off a decoded image. A JPEG decodes fully
    /// opaque, so it fails these samples without needing the PNG signature
    /// check the data-based version does.
    static func hasTransparentEdges(in image: CGImage) -> Bool {
        guard image.width >= 2, image.height >= 2 else { return false }
        guard let buffer = premultipliedRGBA(image) else { return false }
        return samplesAreTransparent(buffer.pixels, width: image.width, height: image.height)
    }

    /// A logo is only safe to place over the hero when it is a PNG and its
    /// decoded corners and edge midpoints contain real transparency. Sampling
    /// the decoded pixels rejects JPEGs and PNGs with an opaque plate.
    static func hasTransparentEdges(in data: Data) -> Bool {
        guard data.starts(with: pngSignature),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return false }
        return hasTransparentEdges(in: image)
    }

    /// Draws `image` into a premultiplied RGBA buffer, keeping the context
    /// alive for as long as the pixels are read.
    private static func premultipliedRGBA(_ image: CGImage) -> (context: CGContext, pixels: UnsafeMutablePointer<UInt8>)? {
        guard let context = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: image.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return (context, pixels)
    }

    /// The four corners and the four edge midpoints. Leaves room for
    /// anti-aliased edge pixels while still rejecting an opaque background or
    /// a card behind the wordmark.
    private static func samplesAreTransparent(_ pixels: UnsafeMutablePointer<UInt8>, width: Int, height: Int) -> Bool {
        let midpointX = width / 2
        let midpointY = height / 2
        let samples = [
            (0, 0), (width - 1, 0), (0, height - 1), (width - 1, height - 1),
            (midpointX, 0), (midpointX, height - 1), (0, midpointY), (width - 1, midpointY),
        ]
        return samples.allSatisfy { x, y in pixels[(y * width + x) * 4 + 3] < 250 }
    }
}
