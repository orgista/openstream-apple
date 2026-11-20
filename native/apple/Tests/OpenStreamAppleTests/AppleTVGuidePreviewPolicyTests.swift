import Foundation
import Testing
@testable import OpenStreamApple

/// Owner 2026-09-14: "live is still slow and there is no preview of the
/// channel". A preview is a second live connection, so the rules about when
/// one may start are worth asserting on their own.
@Suite("Guide channel preview")
struct AppleTVGuidePreviewPolicyTests {
    @Test func aFocusedChannelPreviews() {
        #expect(AppleTVGuidePreviewPolicy.target(focusedChannelID: "cbs", isEnabled: true) == "cbs")
    }

    @Test func aFocusedProgrammePreviewsItsChannel() {
        #expect(AppleTVGuidePreviewPolicy.target(
            focusedChannelID: nil, focusedCellChannelID: "fox", isEnabled: true) == "fox")
    }

    @Test func theRailWinsOverTheTimeline() {
        #expect(AppleTVGuidePreviewPolicy.target(
            focusedChannelID: "cbs", focusedCellChannelID: "fox", isEnabled: true) == "cbs")
    }

    @Test func nothingPreviewsFromTheChipsOrSearch() {
        #expect(AppleTVGuidePreviewPolicy.target(focusedChannelID: nil, isEnabled: true) == nil)
        #expect(AppleTVGuidePreviewPolicy.target(focusedChannelID: "", isEnabled: true) == nil)
    }

    /// A viewer who turned trailer autoplay off does not want a guide that
    /// plays by itself either, so the two share one switch.
    @Test func autoplayOffMeansNoPreview() {
        #expect(AppleTVGuidePreviewPolicy.target(focusedChannelID: "cbs", isEnabled: false) == nil)
    }

    @Test func nothingPreviewsBehindTheFullScreenPlayer() {
        #expect(AppleTVGuidePreviewPolicy.target(
            focusedChannelID: "cbs", isEnabled: true, isPlayerOpen: true) == nil)
    }

    /// Long enough that running the rail never opens a stream per row.
    @Test func theDwellIsLongEnoughToScrollPast() {
        #expect(AppleTVGuidePreviewPolicy.dwell >= .milliseconds(800))
        #expect(AppleTVGuidePreviewPolicy.dwell <= .seconds(2))
    }
}

#if os(tvOS) || os(macOS)
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct AppleTVChannelPreviewTests {
    private func channel(_ id: String) throws -> AppleIPTVChannel {
        AppleIPTVChannel(id: id, sourceID: UUID(), name: id,
            streamURL: try #require(URL(string: "https://fixture.example/\(id).ts")))
    }

    @Test func stopDuringDwellNeverOpensTheProvider() async throws {
        let clock = ManualClock()
        var engineCreations = 0
        let preview = AppleTVChannelPreview(clock: clock) {
            engineCreations += 1
            return FakePlaybackEngine()
        }
        preview.show(try channel("a"))
        let pending = try #require(preview.startTask)
        await clock.waitForSleeps(1)
        preview.stop()
        #expect(clock.pendingSleepers == 0)
        clock.advance(by: AppleTVGuidePreviewPolicy.dwell)
        await pending.value
        #expect(engineCreations == 0)
        #expect(preview.engine == nil)
        #expect(preview.channelID == nil)
    }

    @Test func stopDuringLoadClosesThePreviewBeforeFullScreenPlayback() async throws {
        let clock = ManualClock()
        let engine = FakePlaybackEngine()
        var finish: CheckedContinuation<Void, Never>?
        engine.loadHandler = { _ in await withCheckedContinuation { finish = $0 } }
        let preview = AppleTVChannelPreview(clock: clock) { engine }
        preview.show(try channel("a"))
        let pending = try #require(preview.startTask)
        await clock.waitForSleeps(1)
        clock.advance(by: AppleTVGuidePreviewPolicy.dwell)
        await waitFor("preview load started") { finish != nil }
        let completion = try #require(finish)
        preview.stop()
        #expect(engine.stopCount == 1)
        #expect(preview.engine == nil)
        completion.resume()
        await pending.value
        #expect(engine.phase == .idle)
        #expect(preview.channelID == nil)
    }

    @Test func repeatedFocusDoesNotRestartAnOpeningPreview() async throws {
        let clock = ManualClock()
        let engine = FakePlaybackEngine()
        var finish: CheckedContinuation<Void, Never>?
        var engineCreations = 0
        engine.loadHandler = { _ in await withCheckedContinuation { finish = $0 } }
        let preview = AppleTVChannelPreview(clock: clock) {
            engineCreations += 1
            return engine
        }
        let channel = try channel("a")
        preview.show(channel)
        let pending = try #require(preview.startTask)
        await clock.waitForSleeps(1)
        clock.advance(by: AppleTVGuidePreviewPolicy.dwell)
        await waitFor("preview load started") { finish != nil }
        let completion = try #require(finish)
        preview.show(channel)
        #expect(engine.stopCount == 0)
        completion.resume()
        await pending.value
        #expect(engineCreations == 1)
        #expect(preview.channelID == channel.id)
        preview.stop()
    }

    @Test func supersededLoadFailureCannotStopTheNewPreview() async throws {
        let clock = ManualClock()
        let first = FakePlaybackEngine()
        let second = FakePlaybackEngine()
        var finish: CheckedContinuation<Void, any Error>?
        var engineCreations = 0
        first.loadHandler = { _ in try await withCheckedThrowingContinuation { finish = $0 } }
        let preview = AppleTVChannelPreview(clock: clock) {
            engineCreations += 1
            return engineCreations == 1 ? first : second
        }
        preview.show(try channel("a"))
        let old = try #require(preview.startTask)
        await clock.waitForSleeps(1)
        clock.advance(by: AppleTVGuidePreviewPolicy.dwell)
        await waitFor("first preview load started") { finish != nil }
        let completion = try #require(finish)
        preview.show(try channel("b"))
        let current = try #require(preview.startTask)
        await clock.waitForSleeps(2)
        clock.advance(by: AppleTVGuidePreviewPolicy.dwell)
        await current.value
        completion.resume(throwing: URLError(.cannotConnectToHost))
        await old.value
        #expect(first.stopCount == 1)
        #expect(second.stopCount == 0)
        #expect(second.phase == .playing)
        #expect(preview.engine === second)
        #expect(preview.channelID == "b")
        preview.stop()
    }

    @Test func failedPreviewStaysLatchedUntilFocusMovesAndBackoffExpires() async throws {
        let clock = ManualClock()
        let first = FakePlaybackEngine()
        first.failOnLoad = .init(kind: .network, message: "Fixture offline")
        let second = FakePlaybackEngine()
        var engineCreations = 0
        let preview = AppleTVChannelPreview(clock: clock) {
            engineCreations += 1
            return engineCreations == 1 ? first : second
        }
        let channel = try channel("a")
        preview.show(channel)
        let failed = try #require(preview.startTask)
        await clock.waitForSleeps(1)
        clock.advance(by: AppleTVGuidePreviewPolicy.dwell)
        await failed.value
        let revision = preview.revision
        for _ in 0..<10 { preview.show(channel) }
        #expect(preview.startTask == nil)
        #expect(engineCreations == 1)
        #expect(preview.revision == revision)
        #expect(preview.engine == nil)
        preview.stop()
        preview.show(channel)
        let retry = try #require(preview.startTask)
        await clock.waitForSleeps(2)
        clock.advance(by: AppleTVGuidePreviewPolicy.dwell)
        #expect(engineCreations == 1)
        clock.advance(by: AppleTVGuidePreviewPolicy.failureBackoff)
        await retry.value
        #expect(engineCreations == 2)
        #expect(preview.engine === second)
        #expect(preview.channelID == channel.id)
        preview.stop()
    }

    @Test func anotherFailureReplacesThePreviousChannelsBackoff() async throws {
        let clock = ManualClock()
        var engineCreations = 0
        let preview = AppleTVChannelPreview(clock: clock) {
            engineCreations += 1
            let engine = FakePlaybackEngine()
            engine.failOnLoad = .init(kind: .network, message: "Fixture offline")
            return engine
        }
        for (index, id) in ["a", "b", "a"].enumerated() {
            preview.show(try channel(id))
            let pending = try #require(preview.startTask)
            await clock.waitForSleeps(index + 1)
            clock.advance(by: AppleTVGuidePreviewPolicy.dwell)
            await waitFor("preview attempt \(index + 1)") { engineCreations == index + 1 }
            if index == 2 { clock.advance(by: AppleTVGuidePreviewPolicy.failureBackoff) }
            await pending.value
        }
        #expect(engineCreations == 3)
        preview.stop()
    }
}
#endif
