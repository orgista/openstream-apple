#if DEBUG
import AVFoundation
#if os(visionOS) && targetEnvironment(simulator)
import UIKit
#endif

@MainActor
enum AppleDebugVideoFrameProbe {
    struct AVPlayerReading {
        private static let frameTimeTolerance = 2.0
        private var item: AVPlayerItem?
        private var cachedEvidence: AppleVideoFrameEvidence?
        private var pausedPosition: Double?

        mutating func value(item: AVPlayerItem?, evidence: AppleVideoFrameEvidence?, isPaused: Bool,
                            position: Double) -> String {
            if item !== self.item {
                self.item = item
                cachedEvidence = nil
                pausedPosition = nil
            }
            guard item != nil else { return "waiting for decoded video" }
            if isPaused, let pausedPosition, position != pausedPosition { cachedEvidence = nil }
            pausedPosition = isPaused ? position : nil
            if let evidence { cachedEvidence = evidence }
            guard let cachedEvidence, position.isFinite,
                  abs(cachedEvidence.itemTime - position) < Self.frameTimeTolerance else {
                cachedEvidence = nil
                return "waiting for decoded video"
            }
            return isPaused ? cachedEvidence.accessibilityValue : "ready=1"
        }
    }

    #if os(visionOS) && targetEnvironment(simulator)
    static func run(engine: any ApplePlaybackEngine, scene: () -> UIWindowScene?,
                    receive: (String) -> Void) async {
        guard UserDefaults.standard.bool(forKey: "OpenStreamProbeVideoFrames") else { return }
        var item: AVPlayerItem?
        var output: AVPlayerItemVideoOutput?
        var reading = AVPlayerReading()
        defer {
            if let item, let output { item.remove(output) }
        }
        while !Task.isCancelled {
            let current = engine.avPlayer?.currentItem
            if current !== item {
                if let item, let output { item.remove(output) }
                item = current
                output = current.map { item in
                    let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
                    ])
                    item.add(output)
                    return output
                }
                receive(reading.value(item: current, evidence: nil, isPaused: engine.phase == .paused,
                                      position: current?.currentTime().seconds ?? 0))
            }
            if let item, let output {
                let time = item.currentTime()
                var displayed = CMTime.invalid
                var evidence: AppleVideoFrameEvidence?
                if let pixels = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: &displayed) {
                    evidence = AppleVideoFrameEvidence(pixelBuffer: pixels, itemTime: displayed.seconds,
                                                       playbackTime: time.seconds)
                }
                receive(reading.value(item: item, evidence: evidence, isPaused: engine.phase == .paused,
                                      position: time.seconds))
            } else if engine.route == .surface {
                let windows = scene()?.windows ?? []
                let layers = windows.reversed().flatMap { displayLayers(in: $0.layer) }
                let aether = (engine as? AetherPlaybackEngine)?.aetherEngine
                let frames = aether?.softwareHostFramesEnqueued ?? 0
                let ready = aether?.hasFirstFrameReadyForDisplay == true && layers.contains { $0.isReadyForDisplay }
                var reading = ready ? "ready=1"
                    : "waiting phase=\(engine.phase) windows=\(windows.count) layers=\(layers.count) enqueued=\(frames) engineReady=\(aether?.hasFirstFrameReadyForDisplay == true) ready=0"
                // The renderer only exposes its displayed buffer while paused.
                if engine.phase == .paused {
                    for layer in layers {
                        guard let pixels = layer.sampleBufferRenderer.displayedPixelBuffer() else {
                            reading += " renderer=\(layer.sampleBufferRenderer.status.rawValue) rate=\(CMTimebaseGetRate(layer.sampleBufferRenderer.timebase))"
                            continue
                        }
                        if let evidence = AppleVideoFrameEvidence(pixelBuffer: pixels,
                            itemTime: CMTimebaseGetTime(layer.sampleBufferRenderer.timebase).seconds,
                            playbackTime: engine.position) {
                            reading = evidence.accessibilityValue
                            break
                        }
                        reading += " pixelFormat=\(CVPixelBufferGetPixelFormatType(pixels))"
                    }
                }
                receive(reading)
            }
            do { try await Task.sleep(for: .milliseconds(200)) }
            catch { return }
        }
    }

    private static func displayLayers(in layer: CALayer) -> [AVSampleBufferDisplayLayer] {
        guard !layer.isHidden, layer.opacity > 0 else { return [] }
        if let display = layer as? AVSampleBufferDisplayLayer, !display.bounds.isEmpty { return [display] }
        return (layer.sublayers ?? []).reversed().flatMap { displayLayers(in: $0) }
    }
    #endif
}
#endif
