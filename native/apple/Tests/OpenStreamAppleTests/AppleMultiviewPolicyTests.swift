import AVFoundation
import CoreGraphics
import Foundation
import Testing
@testable import OpenStreamApple

@Suite("Multiview policies")
struct AppleMultiviewPolicyTests {
    @Test func providerLimitCountsOnlyThatProvidersTilesAndExcludesAReplacement() {
        let first = UUID(), second = UUID()
        let sources = ["a": first, "b": first, "c": second]
        #expect(AppleMultiviewPolicy.providerLimitReached(sourceID: first, sources: sources, limits: [first: 2]))
        #expect(!AppleMultiviewPolicy.providerLimitReached(sourceID: first, sources: sources,
                                                         limits: [first: 2], replacing: "a"))
        #expect(!AppleMultiviewPolicy.providerLimitReached(sourceID: second, sources: sources, limits: [first: 2]))
        #expect(!AppleMultiviewPolicy.providerLimitReached(sourceID: first, sources: sources, limits: [first: 0]))
    }

    @Test func fullscreenPausesCompanionsAndBackRetainsEveryChannel() {
        var state = AppleMultiviewPolicy.Session(channels: ["a", "b", "c"])
        #expect(state.pausedChannelIDs.isEmpty)
        state.select("b")
        #expect(state.pausedChannelIDs == ["a", "c"])
        state.select("c")
        #expect(state.pausedChannelIDs == ["a", "b"])
        _ = state.back()
        #expect(state.pausedChannelIDs.isEmpty)
        #expect(state.channels == ["a", "b", "c"])
    }

    @Test(arguments: [2, 3, 4])
    func layoutsAreInsideCanvasAndDoNotOverlap(count: Int) {
        #expect(AppleMultiviewPolicy.frames(count: count, layout: .grid, size: .zero).isEmpty)
        #expect(AppleMultiviewPolicy.frames(count: count, layout: .bigAndSmalls, size: CGSize(width: 100, height: 0)).isEmpty)
        for layout in AppleMultiviewPolicy.Layout.allCases {
            let canvas = CGRect(x: 0, y: 0, width: 1920, height: 1080)
            let frames = AppleMultiviewPolicy.frames(count: count, layout: layout, size: canvas.size)
            #expect(frames.count == count)
            for (index, frame) in frames.enumerated() {
                #expect(canvas.contains(frame))
                #expect(frame.width > 0 && frame.height > 0)
                for other in frames.dropFirst(index + 1) {
                    #expect(!frame.intersects(other))
                }
            }
        }
    }

    @Test func conventionalLayouts() {
        let two = AppleMultiviewPolicy.frames(count: 2, layout: .grid, size: CGSize(width: 200, height: 100), gap: 0)
        #expect(two == [CGRect(x: 0, y: 0, width: 100, height: 100), CGRect(x: 100, y: 0, width: 100, height: 100)])
        let three = AppleMultiviewPolicy.frames(count: 3, layout: .grid, size: CGSize(width: 300, height: 200), gap: 0)
        #expect(three[0].width == 200 && three[0].height == 200)
        #expect(three[1].height == 100 && three[2].minY == 100)
        #expect(AppleMultiviewPolicy.frames(count: 4, layout: .grid, size: CGSize(width: 200, height: 100), gap: 0).allSatisfy { $0.size == CGSize(width: 100, height: 50) })
        #expect(AppleMultiviewPolicy.frames(count: 0, layout: .grid, size: .zero).isEmpty)
    }

    @Test func focusPromotionSwapAndBackPreserveSession() {
        var state = AppleMultiviewPolicy.Session(channels: ["a", "b", "c", "d"])
        state.focus("c")
        state.promote("b")
        #expect(state.audioID == "c" && state.bigID == "b")
        state.select("c")
        #expect(state.fullScreenID == "c")
        let result1 = state.back()
        #expect(result1 == nil)
        #expect(state.fullScreenID == nil && state.audioID == "c" && state.bigID == "b")
        let result2 = state.replace("c", with: "e")
        #expect(result2)
        #expect(state.audioID == "e")
        let result3 = state.replace("e", with: "a")
        #expect(!result3)
        let result4 = state.back()
        #expect(result4 == "e")
    }

    @Test func limitsAndRemoval() {
        var state = AppleMultiviewPolicy.Session(channels: ["a", "a", "b"])
        #expect(state.channels == ["a", "b"])
        let result5 = state.add("c", thermal: .nominal)
        #expect(result5 == nil)
        let result6 = state.add("d", thermal: .nominal)
        #expect(result6 == nil)
        let result7 = state.add("e", thermal: .nominal)
        #expect(result7 == .full)
        state.focus("c")
        let result8 = state.remove("c")
        #expect(result8 == nil)
        #expect(state.audioID == "a")
        let result9 = state.remove("d")
        #expect(result9 == nil)
        let result10 = state.remove("b")
        #expect(result10 == "a")
        #expect(state.channels == ["a"])
    }

    @Test func thermalRefusalAndOldestNonAudioShedding() {
        var state = AppleMultiviewPolicy.Session(channels: ["a", "b", "c"])
        let result11 = state.add("d", thermal: .serious)
        #expect(result11 == .thermal)
        let result12 = state.add("d", thermal: .critical)
        #expect(result12 == .thermal)
        state.focus("a")
        let result13 = state.shed(thermal: .serious)
        #expect(result13 == nil)
        let result14 = state.shed(thermal: .critical)
        #expect(result14 == "b")
        #expect(state.audioID == "a" && state.channels == ["a", "c"])
    }

    @MainActor
    @Test func nativeTileMuteAndQualityHintsSurviveReload() async throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/out/mp4-h264-aac.mp4")
        let engine = NativePlaybackEngine()
        defer { engine.stop() }
        engine.multiviewMuted = true
        engine.multiviewQualityLimited = true
        let request = ApplePlaybackRequest(url: url, autoplay: false, mediaID: "multiview-policy-fixture", sourceKind: .files)
        for _ in 0..<2 {
            try await engine.load(request)
            let player = try #require(engine.avPlayer)
            let item = try #require(player.currentItem)
            #expect(player.isMuted)
            #expect(item.preferredMaximumResolution == CGSize(width: 1280, height: 720))
            #expect(item.preferredPeakBitRate == 3_000_000)
            engine.stop()
        }
        try await engine.load(request)
        engine.multiviewQualityLimited = false
        #expect(engine.avPlayer?.currentItem?.preferredMaximumResolution == .zero)
        #expect(engine.avPlayer?.currentItem?.preferredPeakBitRate == 0)
    }

    @Test func failuresDoNotExposeDiagnostics() {
        #expect(AppleMultiviewPolicy.message(for: .init(kind: .network, message: "HTTP 429", httpStatus: 429)) == "Your provider allows fewer streams at once")
        #expect(AppleMultiviewPolicy.message(for: .init(kind: .player, message: "Maximum connections exceeded")) == "Your provider allows fewer streams at once")
        #expect(AppleMultiviewPolicy.message(for: .init(kind: .unsupportedMedia, message: "decoder")) == "This channel can't play in Multiview")
    }
}
