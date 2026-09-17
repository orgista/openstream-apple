import AVFoundation
import Foundation
import Testing
@testable import OpenStreamApple

@Suite struct AppleSharePlayPlaybackTests {
    @Test func sharedTimingAccountsForLateArrivalAndDoesNotAdvanceBeforeTheAnchor() {
        let timing = AppleSharedPlaybackTiming(itemTime: 30, hostTime: 100, rate: 2)
        #expect(timing.position(at: 98) == 30)
        #expect(timing.position(at: 100) == 30)
        #expect(timing.position(at: 103) == 36)
        for value in [Double.nan, .infinity, -.infinity] {
            #expect(timing.position(at: value) == nil)
            #expect(AppleSharedPlaybackTiming(itemTime: value, hostTime: 100, rate: 1).position(at: 100) == nil)
        }
        #expect(AppleSharedPlaybackTiming(itemTime: -1, hostTime: 100, rate: 1).position(at: 100) == nil)
        #expect(AppleSharedPlaybackTiming(itemTime: 0, hostTime: 100, rate: 0).position(at: 100) == nil)
    }

    @Test func racingDeadlineAndCommandCompletionAcknowledgeExactlyOnce() async {
        let counter = SharePlayCompletionCounter()
        let completion = AppleSharedCommandCompletion { counter.increment() }
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<100 { group.addTask { completion.finish() } }
        }
        #expect(counter.value == 1)
        #expect(completion.isFinished)
    }

    @MainActor @Test func nativePlaybackUsesTheSharedIdentityInsteadOfTheAssetURL() {
        let engine = SharePlayTestEngine()
        engine.route = .avPlayer
        let item = AVPlayerItem(asset: AVMutableComposition())
        engine.avPlayer = AVPlayer(playerItem: item)
        let owner = ApplePlaybackCoordinator(engine: engine)
        let binding = AppleSharePlayPlaybackBinding(owner: owner, identifier: "openstream.live.fixture")
        #expect(engine.avPlayer?.playbackCoordinator.delegate?.playbackCoordinator?(engine.avPlayer!.playbackCoordinator, identifierFor: item) == "openstream.live.fixture")
        #expect(owner.sharedPlayback === binding)
        binding.invalidate(keepPlaying: true)
        #expect(owner.sharedPlayback == nil)
        #expect(engine.avPlayer?.currentItem === item)
        #expect(engine.avPlayer?.playbackCoordinator.delegate?.playbackCoordinator?(engine.avPlayer!.playbackCoordinator, identifierFor: item) == "openstream.live.fixture")
        owner.stop()
    }

    @MainActor @Test func replacedNativeBindingRemovesTheOldItemWithoutStoppingTheNewPlayer() {
        let engine = SharePlayTestEngine()
        engine.route = .avPlayer
        let oldPlayer = AVPlayer(playerItem: AVPlayerItem(asset: AVMutableComposition()))
        engine.avPlayer = oldPlayer
        let owner = ApplePlaybackCoordinator(engine: engine)
        let binding = AppleSharePlayPlaybackBinding(owner: owner, identifier: "old")
        let newItem = AVPlayerItem(asset: AVMutableComposition())
        engine.avPlayer = AVPlayer(playerItem: newItem)
        #expect(!binding.matches(owner: owner, identifier: "old"))
        binding.invalidate()
        #expect(oldPlayer.currentItem == nil)
        #expect(engine.avPlayer?.currentItem === newItem)
        owner.stop()
    }

    @MainActor @Test func customPlaybackCommandsReachTheEngineAndLeavingRestoresLocalControls() async throws {
        let engine = SharePlayTestEngine()
        let owner = ApplePlaybackCoordinator(engine: engine)
        let binding = AppleSharePlayPlaybackBinding(owner: owner, identifier: "openstream.live.fixture", createsDelegatingCoordinator: false)
        let now = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        await receive(.play(.init(itemTime: 10, hostTime: now, rate: 1)), on: binding)
        #expect(engine.rate == 1)
        #expect(engine.position >= 10 && engine.position < 11)
        await receive(.pause(prepare: false, rate: 1), on: binding)
        #expect(engine.rate == 0)
        await receive(.seek(25, prepare: false, rate: 1), on: binding)
        #expect(abs(engine.position - 25) < 0.01)
        #expect(engine.phase == .paused)
        binding.invalidate(keepPlaying: true)
        #expect(owner.sharedPlayback == nil)
        owner.userPlay()
        #expect(engine.phase == .playing)
        owner.stop()
    }

    @MainActor @Test func replacingAnItemOnTheSamePlayerPreservesTheReplacement() {
        let engine = SharePlayTestEngine()
        engine.route = .avPlayer
        let player = AVPlayer(playerItem: AVPlayerItem(asset: AVMutableComposition()))
        engine.avPlayer = player
        let owner = ApplePlaybackCoordinator(engine: engine)
        let binding = AppleSharePlayPlaybackBinding(owner: owner, identifier: "fixture")
        let replacement = AVPlayerItem(asset: AVMutableComposition())
        player.replaceCurrentItem(with: replacement)
        #expect(!binding.matches(owner: owner, identifier: "fixture"))
        binding.invalidate()
        #expect(player.currentItem === replacement)
        owner.stop()
    }

    @MainActor @Test func unsupportedSharedSpeedExplainsRecoveryAndAcceptsNormalSpeed() async {
        let engine = SharePlayTestEngine()
        let owner = ApplePlaybackCoordinator(engine: engine)
        let binding = AppleSharePlayPlaybackBinding(owner: owner, identifier: "fixture", createsDelegatingCoordinator: false)
        let now = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        await receive(.play(.init(itemTime: 0, hostTime: now, rate: 20)), on: binding)
        guard case .waiting(let message) = owner.phase else {
            Issue.record("Unsupported speed must explain how to resume.")
            binding.invalidate(keepPlaying: true)
            return
        }
        #expect(message?.contains("normal speed") == true)
        #expect(engine.rate == 0)
        binding.refreshReadiness()
        #expect(owner.phase == .waiting(message))
        await receive(.play(.init(itemTime: 10, hostTime: now, rate: 1)), on: binding)
        #expect(engine.rate == 1)
        binding.invalidate(keepPlaying: true)
        owner.stop()
    }

    @MainActor @Test func staleCommandsAreAcknowledgedWithoutChangingTheCurrentChannel() async {
        let engine = SharePlayTestEngine()
        let owner = ApplePlaybackCoordinator(engine: engine)
        let binding = AppleSharePlayPlaybackBinding(owner: owner, identifier: "new-channel", createsDelegatingCoordinator: false)
        await withCheckedContinuation { continuation in
            binding.receive(.seek(70, prepare: false, rate: 1), identifier: "old-channel") { continuation.resume() }
        }
        #expect(engine.position == 0)
        binding.invalidate(keepPlaying: true)
        owner.stop()
    }

    @MainActor @Test func changingSharedChannelsPausesTheOldCustomPlayback() {
        let engine = SharePlayTestEngine()
        let owner = ApplePlaybackCoordinator(engine: engine)
        let binding = AppleSharePlayPlaybackBinding(owner: owner, identifier: "old-channel", createsDelegatingCoordinator: false)
        engine.play()
        binding.invalidate()
        #expect(engine.phase == .paused)
        #expect(engine.rate == 0)
        #expect(owner.sharedPlayback == nil)
        owner.stop()
    }

    @MainActor @Test func expiredCommandIsAcknowledgedOnceAndCannotResumeAfterLeaving() async throws {
        let engine = SharePlayTestEngine()
        var finishSeek: CheckedContinuation<Void, Never>?
        engine.seekHandler = { _ in await withCheckedContinuation { finishSeek = $0 } }
        let owner = ApplePlaybackCoordinator(engine: engine)
        let binding = AppleSharePlayPlaybackBinding(owner: owner, identifier: "fixture", createsDelegatingCoordinator: false)
        let counter = SharePlayCompletionCounter()
        let command = Task { @MainActor in
            await withCheckedContinuation { continuation in
                let timing = AppleSharedPlaybackTiming(itemTime: 20, hostTime: CMClockGetTime(CMClockGetHostTimeClock()).seconds, rate: 1)
                binding.receive(.play(timing), identifier: "fixture", deadline: Date().addingTimeInterval(0.2)) {
                    counter.increment()
                    continuation.resume()
                }
            }
        }
        let seekDeadline = ContinuousClock.now.advanced(by: .seconds(1))
        while finishSeek == nil, ContinuousClock.now < seekDeadline { await Task.yield() }
        let finish = try #require(finishSeek)
        await command.value
        #expect(counter.value == 1)
        binding.invalidate(keepPlaying: true)
        finish.resume()
        try await Task.sleep(for: .milliseconds(30))
        #expect(counter.value == 1)
        #expect(engine.rate == 0)
        owner.stop()
    }

    @MainActor private func receive(_ command: AppleSharedPlaybackCommand, on binding: AppleSharePlayPlaybackBinding) async {
        await withCheckedContinuation { continuation in
            binding.receive(command, identifier: binding.identifier) { continuation.resume() }
        }
    }
}

private final class SharePlayCompletionCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

@MainActor private final class SharePlayTestEngine: ApplePlaybackEngine {
    let kind: ApplePlaybackEngineKind = .native
    var phase: ApplePlaybackEnginePhase = .paused
    var route: ApplePlaybackPresentationRoute = .surface
    var position: Double = 0
    var duration: Double? = 120
    var audioTracks: [ApplePlaybackTrack] = []
    var subtitleTracks: [ApplePlaybackTrack] = []
    var subtitleCues: [AppleSubtitleCue] = []
    var failure: ApplePlaybackFailure?
    var avPlayer: AVPlayer?
    var events: AsyncStream<ApplePlaybackEngineEvent> { AsyncStream { $0.finish() } }
    var rate: Float = 0
    var seekHandler: (@MainActor (Double) async -> Void)?
    func load(_ request: ApplePlaybackRequest) async throws { phase = .playing }
    func play() { rate = 1; phase = .playing }
    func pause() { rate = 0; phase = .paused }
    func stop() { rate = 0; phase = .idle }
    func setPlaybackRate(_ rate: Float) { self.rate = rate; phase = rate == 0 ? .paused : .playing }
    func seek(to seconds: Double) async { await seekHandler?(seconds); position = seconds }
    func selectAudioTrack(id: Int) {}
    func selectSubtitleTrack(id: Int?) {}
}
