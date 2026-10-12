import CoreGraphics
import Foundation
import SwiftUI
#if canImport(Vision)
import Vision
#endif

/// Where a cast or crew circle crops its photo (owner 2026-10-09: "not every
/// face sits in its circle; some are cut off"). TMDB profile photos are 2:3,
/// and the circle shows a square of them. Pinned to the top, a face low in
/// the frame lost its chin; centred, a face high in the frame lost its hair.
/// With a detected face the square is centred on it, a little low so the
/// head has room above it; without one it sits slightly below the top.
enum AppleCreditPortraitCrop {
    /// Where the face's centre sits in the square, from its top.
    static let faceCentre: CGFloat = 0.45
    /// Room kept above the top of the face, as a fraction of the square.
    static let headroom: CGFloat = 0.1
    /// With no face, how far down the spare height the square starts.
    static let defaultTopBias: CGFloat = 0.15

    /// The square to show, in pixels with a top-left origin. `face` is the
    /// face's box in the image, normalised with a top-left origin.
    static func cropRect(imageSize: CGSize, face: CGRect?) -> CGRect {
        let width = imageSize.width, height = imageSize.height
        guard width > 0, height > 0 else { return .zero }
        let side = min(width, height)
        var x = (width - side) / 2
        var y = (height - side) * defaultTopBias
        if let face, face.width > 0, face.height > 0 {
            let faceTop = face.minY * height
            let faceMidY = face.midY * height
            y = min(faceMidY - side * faceCentre, faceTop - side * headroom)
            x = face.midX * width - side / 2
        }
        x = min(max(0, x.rounded()), width - side)
        y = min(max(0, y.rounded()), height - side)
        return CGRect(x: x, y: y, width: side, height: side)
    }

    /// Vision's face box (bottom-left origin) in the top-left space `cropRect` takes.
    static func topLeftRect(fromVision box: CGRect) -> CGRect {
        CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
    }

    /// The largest box: a group photo crops to whoever fills the most of it.
    static func largest(_ boxes: [CGRect]) -> CGRect? {
        boxes.max { $0.width * $0.height < $1.width * $1.height }
    }
}

/// Finds and remembers each portrait's crop, off the main thread.
actor AppleCreditPortraitFaces {
    static let shared = AppleCreditPortraitFaces()
    private var crops: [String: CGRect] = [:]

    func cropRect(for image: CGImage, key: String) -> CGRect {
        if let cached = crops[key] { return cached }
        let size = CGSize(width: image.width, height: image.height)
        let rect = AppleCreditPortraitCrop.cropRect(imageSize: size, face: Self.face(in: image))
        if crops.count > 400 { crops.removeAll() }
        crops[key] = rect
        return rect
    }

    private static func face(in image: CGImage) -> CGRect? {
        #if canImport(Vision)
        let request = VNDetectFaceRectanglesRequest()
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            return nil
        }
        let boxes = (request.results ?? []).filter { $0.confidence > 0.5 }.map(\.boundingBox)
        return AppleCreditPortraitCrop.largest(boxes).map(AppleCreditPortraitCrop.topLeftRect(fromVision:))
        #else
        return nil
        #endif
    }
}

/// A credit portrait cropped around the face. Draws nothing until the crop
/// is known, so the circle never shows one crop and then jumps to another.
struct AppleCreditPortraitImage: View {
    let url: URL
    @Environment(\.displayScale) private var displayScale
    @State private var cropped: CGImage?
    @State private var croppedURL: URL?

    var body: some View {
        GeometryReader { geometry in
            Group {
                if let cropped, croppedURL == url {
                    Image(decorative: cropped, scale: displayScale)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .transition(.opacity)
                } else {
                    Color.clear
                }
            }
            .task(id: "\(url.absoluteString)|\(Int(geometry.size.width))") {
                await load(side: geometry.size.width)
            }
        }
        .accessibilityHidden(true)
        .accessibilityIgnoresInvertColors()
    }

    private func load(side: CGFloat) async {
        // A 2:3 photo whose short side fills the circle.
        let pixels = min(max(96, Int(side * 1.5 * displayScale)), 1_024)
        guard let image = try? await AppleRemoteImageCache.shared.image(url: url, maximumPixelDimension: pixels),
              !Task.isCancelled else { return }
        let rect = await AppleCreditPortraitFaces.shared.cropRect(for: image, key: "\(url.absoluteString)|\(image.width)x\(image.height)")
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.15)) {
            cropped = image.cropping(to: rect) ?? image
            croppedURL = url
        }
    }
}
