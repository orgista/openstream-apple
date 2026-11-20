import CoreGraphics
import Foundation
import Vision

/// Computes the backdrop's crop before the view publishes its image.
actor AppleHeroFocalPoint {
    static let shared = AppleHeroFocalPoint()
    private let cache: AppleArtworkDiskCache
    private static let variant = "focal-v1"

    init(cache: AppleArtworkDiskCache = .shared) { self.cache = cache }

    func point(image: CGImage, url: URL) async throws -> CGPoint {
        try Task.checkCancellation()
        if let data = await cache.data(for: url, variant: Self.variant),
           let values = try? JSONDecoder().decode([Double].self, from: data), values.count == 2,
           values.allSatisfy({ $0.isFinite && (0...1).contains($0) }) {
            return CGPoint(x: values[0], y: values[1])
        }
        let handler = VNImageRequestHandler(cgImage: image)
        let faces = VNDetectFaceRectanglesRequest()
        try? handler.perform([faces])
        try Task.checkCancellation()
        let faceBounds = faces.results?.map(\.boundingBox) ?? []
        var salientBounds: [CGRect] = []
        if faceBounds.isEmpty {
            let saliency = VNGenerateAttentionBasedSaliencyImageRequest()
            try? handler.perform([saliency])
            salientBounds = saliency.results?.first?.salientObjects?.map(\.boundingBox) ?? []
        }
        try Task.checkCancellation()
        let point = Self.choose(faces: faceBounds, salientRegions: salientBounds)
        if let data = try? JSONEncoder().encode([Double(point.x), Double(point.y)]) {
            await cache.store(data, for: url, variant: Self.variant)
        }
        return point
    }

    /// Vision uses a bottom-left origin; rendering uses top-left. The largest
    /// face has twice the weight, while the remaining faces retain influence.
    nonisolated static func choose(faces: [CGRect], salientRegions: [CGRect]) -> CGPoint {
        let faces = faces.filter(valid)
        if let largest = faces.indices.max(by: {
            faces[$0].width * faces[$0].height < faces[$1].width * faces[$1].height
        }) {
            var x: CGFloat = 0, y: CGFloat = 0, total: CGFloat = 0
            for (index, bounds) in faces.enumerated() {
                let weight: CGFloat = index == largest ? 2 : 1
                x += bounds.midX * weight
                y += bounds.midY * weight
                total += weight
            }
            return topLeftPoint(x: x / total, y: y / total)
        }
        let union = salientRegions.filter(valid).reduce(CGRect.null) { $0.union($1) }
        guard !union.isNull else { return CGPoint(x: 0.5, y: 0.5) }
        return topLeftPoint(x: union.midX, y: union.midY)
    }

    nonisolated private static func valid(_ rect: CGRect) -> Bool {
        !rect.isEmpty && !rect.isInfinite && rect.midX.isFinite && rect.midY.isFinite
    }

    nonisolated private static func topLeftPoint(x: CGFloat, y: CGFloat) -> CGPoint {
        CGPoint(x: min(max(x, 0), 1), y: min(max(1 - y, 0), 1))
    }
}
