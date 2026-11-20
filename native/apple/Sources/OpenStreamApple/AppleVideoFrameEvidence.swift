#if DEBUG
import CoreVideo

struct AppleVideoFrameEvidence {
    private static let blackChannelCeiling: UInt8 = 16
    private static let sampleColumns = 32
    private static let sampleRows = 18

    let itemTime: Double
    let playbackTime: Double
    let nonBlackFraction: Double
    let width: Int
    let height: Int

    init?(pixelBuffer: CVPixelBuffer, itemTime: Double, playbackTime: Double) {
        guard itemTime.isFinite, playbackTime.isFinite,
              CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let isBGRA: Bool
        let address: UnsafeMutableRawPointer?
        let rowBytes: Int
        switch CVPixelBufferGetPixelFormatType(pixelBuffer) {
        case kCVPixelFormatType_32BGRA:
            isBGRA = true
            address = CVPixelBufferGetBaseAddress(pixelBuffer)
            rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_420YpCbCr8Planar, kCVPixelFormatType_420YpCbCr8PlanarFullRange:
            isBGRA = false
            address = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)
            rowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        default: return nil
        }
        guard let bytes = address?.assumingMemoryBound(to: UInt8.self) else { return nil }
        width = CVPixelBufferGetWidth(pixelBuffer)
        height = CVPixelBufferGetHeight(pixelBuffer)
        var sampled = 0
        var nonBlack = 0
        for y in stride(from: 0, to: height, by: max(1, height / Self.sampleRows)) {
            for x in stride(from: 0, to: width, by: max(1, width / Self.sampleColumns)) {
                let offset = y * rowBytes + x * (isBGRA ? 4 : 1)
                let level = isBGRA ? max(bytes[offset], bytes[offset + 1], bytes[offset + 2]) : bytes[offset]
                if level > Self.blackChannelCeiling { nonBlack += 1 }
                sampled += 1
            }
        }
        nonBlackFraction = Double(nonBlack) / Double(sampled)
        self.itemTime = itemTime
        self.playbackTime = playbackTime
    }

    var accessibilityValue: String {
        "frame=\(itemTime);position=\(playbackTime);nonblack=\(nonBlackFraction);width=\(width);height=\(height)"
    }
}
#endif
