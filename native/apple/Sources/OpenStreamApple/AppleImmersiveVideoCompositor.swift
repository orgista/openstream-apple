#if os(visionOS)
import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo

@available(visionOS 26.0, *)
final class AppleImmersiveVideoInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = false
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let layout: AppleImmersiveVideoLayout

    init(instruction: any AVVideoCompositionInstructionProtocol, layout: AppleImmersiveVideoLayout) {
        timeRange = instruction.timeRange
        requiredSourceTrackIDs = instruction.requiredSourceTrackIDs
            ?? [NSNumber(value: instruction.passthroughTrackID)]
        self.layout = layout
    }
}

/// Projects decoded frames from the original streaming asset, including files
/// whose only VR hint is their name. Eye crops preserve each eye's orientation.
@available(visionOS 26.0, *)
final class AppleImmersiveVideoCompositor: NSObject, AVVideoCompositing {
    private let context = CIContext(options: [.cacheIntermediates: false])
    var sourcePixelBufferAttributes: [String: any Sendable]? {
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    }
    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
         kCVPixelBufferIOSurfacePropertiesKey as String: [String: Int]()]
    }

    static func tags(layout: AppleImmersiveVideoLayout, left: Bool) -> [CMTag] {
        [.stereoView(layout.isStereo ? (left ? .leftEye : .rightEye) : []),
         .projectionType(layout.projection == .halfSphere ? .halfEquirectangular : .equirectangular),
         .mediaType(.video)]
    }

    @MainActor
    static func composition(asset: AVAsset, layout: AppleImmersiveVideoLayout) async throws -> AVVideoComposition {
        var configuration = try await AVVideoComposition.Configuration(for: asset)
        configuration.customVideoCompositorClass = Self.self
        configuration.instructions = configuration.instructions.map {
            AppleImmersiveVideoInstruction(instruction: $0, layout: layout)
        }
        configuration.renderSize = layout.eyeRect(left: true, size: configuration.renderSize).size
        configuration.outputBufferDescription = layout.isStereo
            ? [tags(layout: layout, left: true), tags(layout: layout, left: false)]
            : [tags(layout: layout, left: true)]
        return AVVideoComposition(configuration: configuration)
    }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let instruction = request.videoCompositionInstruction as? AppleImmersiveVideoInstruction,
              let trackID = request.sourceTrackIDs.first,
              let source = request.sourceFrame(byTrackID: CMPersistentTrackID(truncating: trackID)) else {
            request.finish(with: NSError(domain: AVFoundationErrorDomain, code: AVError.noImageAtTime.rawValue))
            return
        }
        let layout = instruction.layout
        let image = CIImage(cvPixelBuffer: source)
        var buffers: [CMTaggedDynamicBuffer] = []
        for left in layout.isStereo ? [true, false] : [true] {
            guard let output = request.renderContext.newPixelBuffer() else {
                request.finish(with: NSError(domain: AVFoundationErrorDomain, code: AVError.outOfMemory.rawValue))
                return
            }
            context.render(layout.eyeImage(left: left, image: image), to: output)
            buffers.append(CMTaggedDynamicBuffer(tags: Self.tags(layout: layout, left: left),
                content: CVReadOnlyPixelBuffer(unsafeBuffer: output)))
        }
        request.finish(withComposedTaggedBuffers: buffers)
    }
}
#endif
