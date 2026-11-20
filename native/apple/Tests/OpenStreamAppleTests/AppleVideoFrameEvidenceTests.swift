#if DEBUG
import AVFoundation
import CoreVideo
import Testing
@testable import OpenStreamApple

struct AppleVideoFrameEvidenceTests {
    @MainActor
    @Test func pausedProbeRepublishesTheLastDecodedFrameWithoutANewBuffer() throws {
        let item = AVPlayerItem(url: URL(fileURLWithPath: "/tmp/fixture.mp4"))
        let evidence = try frameEvidence(time: 12)
        var probe = AppleDebugVideoFrameProbe.AVPlayerReading()
        let playing = probe.value(item: item, evidence: evidence, isPaused: false, position: 12)
        #expect(playing == "ready=1")
        let stillPlaying = probe.value(item: item, evidence: nil, isPaused: false, position: 12)
        #expect(stillPlaying == "ready=1")
        for _ in 0..<3 {
            let paused = probe.value(item: item, evidence: nil, isPaused: true, position: 12)
            #expect(paused == evidence.accessibilityValue)
        }
    }

    @MainActor
    @Test func pausedProbeUsesTheNewDecodedFrameAfterASeek() throws {
        let item = AVPlayerItem(url: URL(fileURLWithPath: "/tmp/fixture.mp4"))
        let first = try frameEvidence(time: 12)
        let sought = try frameEvidence(time: 450)
        var probe = AppleDebugVideoFrameProbe.AVPlayerReading()
        _ = probe.value(item: item, evidence: first, isPaused: false, position: 12)
        let waiting = probe.value(item: item, evidence: nil, isPaused: true, position: 450)
        #expect(waiting == "waiting for decoded video")
        let afterSeek = probe.value(item: item, evidence: sought, isPaused: true, position: 450)
        #expect(afterSeek == sought.accessibilityValue)
        let paused = probe.value(item: item, evidence: nil, isPaused: true, position: 450)
        #expect(paused == sought.accessibilityValue)
    }

    @MainActor
    @Test(arguments: [12.25, 450, Double.nan, Double.infinity])
    func pausedProbeDropsMismatchedEvidenceWithoutResurrectingIt(position: Double) throws {
        let item = AVPlayerItem(url: URL(fileURLWithPath: "/tmp/fixture.mp4"))
        let evidence = try frameEvidence(time: 12)
        var probe = AppleDebugVideoFrameProbe.AVPlayerReading()
        _ = probe.value(item: item, evidence: evidence, isPaused: true, position: 12)
        let stale = probe.value(item: item, evidence: nil, isPaused: true, position: position)
        #expect(stale == "waiting for decoded video")
        let returned = probe.value(item: item, evidence: nil, isPaused: true, position: 12)
        #expect(returned == "waiting for decoded video")
        let wrongFrame = probe.value(item: item, evidence: evidence, isPaused: true, position: 450)
        #expect(wrongFrame == "waiting for decoded video")
    }

    @MainActor
    @Test func probeNeverReusesEvidenceFromAReplacedOrRemovedItem() throws {
        let first = AVPlayerItem(url: URL(fileURLWithPath: "/tmp/fixture.mp4"))
        let replacement = AVPlayerItem(url: URL(fileURLWithPath: "/tmp/replacement.mp4"))
        let evidence = try frameEvidence(time: 12)
        var probe = AppleDebugVideoFrameProbe.AVPlayerReading()
        _ = probe.value(item: first, evidence: evidence, isPaused: false, position: 12)
        let replaced = probe.value(item: replacement, evidence: nil, isPaused: true, position: 12)
        #expect(replaced == "waiting for decoded video")
        _ = probe.value(item: replacement, evidence: evidence, isPaused: false, position: 12)
        let removed = probe.value(item: nil, evidence: nil, isPaused: true, position: 12)
        #expect(removed == "waiting for decoded video")
        let reinserted = probe.value(item: replacement, evidence: nil, isPaused: true, position: 12)
        #expect(reinserted == "waiting for decoded video")
    }

    private func frameEvidence(time: Double) throws -> AppleVideoFrameEvidence {
        let buffer = try pixelBuffer(width: 5, height: 3)
        do {
            CVPixelBufferLockBaseAddress(buffer, [])
            defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
            let bytes = try #require(CVPixelBufferGetBaseAddress(buffer))
            bytes.initializeMemory(as: UInt8.self, repeating: 255,
                                   count: CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer))
        }
        return try #require(AppleVideoFrameEvidence(pixelBuffer: buffer, itemTime: time, playbackTime: time))
    }

    @Test(arguments: [(UInt8(0), 0.0), (16, 0.0), (17, 1.0), (255, 1.0)])
    func measuresDecodedPixelsWithoutCountingAlpha(_ value: UInt8, expected: Double) throws {
        let buffer = try pixelBuffer(width: 5, height: 3)
        CVPixelBufferLockBaseAddress(buffer, [])
        let bytes = try #require(CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self))
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<3 {
            for x in 0..<5 {
                let offset = y * rowBytes + x * 4
                bytes[offset] = value
                bytes[offset + 1] = 0
                bytes[offset + 2] = 0
                bytes[offset + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        let frame = try #require(AppleVideoFrameEvidence(pixelBuffer: buffer, itemTime: 450, playbackTime: 450))
        #expect(frame.nonBlackFraction == expected)
        #expect(frame.width == 5)
        #expect(frame.height == 3)
        #expect(frame.itemTime == 450)
    }

    @Test func respectsPaddedRowsAndCountsOnlyPicturePixels() throws {
        let buffer = try pixelBuffer(width: 5, height: 3)
        CVPixelBufferLockBaseAddress(buffer, [])
        let bytes = try #require(CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self))
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<3 {
            for offset in 0..<rowBytes { bytes[y * rowBytes + offset] = 255 }
            for x in 0..<5 {
                let value: UInt8 = x < 2 ? 255 : 0
                for component in 0..<3 { bytes[y * rowBytes + x * 4 + component] = value }
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        let frame = try #require(AppleVideoFrameEvidence(pixelBuffer: buffer, itemTime: 12, playbackTime: 12))
        #expect(abs(frame.nonBlackFraction - 0.4) < 0.001)
    }

    @Test(arguments: [(UInt8(16), 0.0), (235, 1.0)])
    func measuresTheDisplayedYUVLuminancePlane(_ value: UInt8, expected: Double) throws {
        var created: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 8, 4,
                                        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &created)
        try #require(status == kCVReturnSuccess)
        let buffer = try #require(created)
        CVPixelBufferLockBaseAddress(buffer, [])
        let bytes = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, 0)?.assumingMemoryBound(to: UInt8.self))
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        for y in 0..<4 {
            for x in 0..<8 { bytes[y * rowBytes + x] = value }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        let frame = try #require(AppleVideoFrameEvidence(pixelBuffer: buffer, itemTime: 450, playbackTime: 450))
        #expect(frame.nonBlackFraction == expected)
    }

    private func pixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
        try #require(status == kCVReturnSuccess)
        return try #require(buffer)
    }
}
#endif
