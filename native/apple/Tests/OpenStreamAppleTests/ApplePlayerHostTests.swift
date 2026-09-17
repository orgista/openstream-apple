import Testing
@testable import OpenStreamApple

@MainActor
@Suite struct ApplePlayerHostTests {
    @Test func interruptionsResumeOnlyPlaybackThatWasPlaying() {
        let engine = FakePlaybackEngine()
        let coordinator = ApplePlaybackCoordinator(engine: engine)
        let audio = AppleAudioSessionCoordinator()
        let host = ApplePlayerHost(coordinator: coordinator, audioSession: audio)
        coordinator.update(.paused)
        engine.phase = .paused
        audio.onInterruption?(.began)
        audio.onInterruption?(.ended(shouldResume: true))
        #expect(engine.phase == .paused)
        coordinator.update(.playing)
        engine.phase = .playing
        audio.onInterruption?(.began)
        #expect(engine.phase == .paused)
        audio.onInterruption?(.ended(shouldResume: true))
        #expect(engine.phase == .playing)
        host.teardown()
        #expect(audio.onInterruption == nil)
        host.activate()
        #expect(audio.onInterruption != nil)
        host.teardown()
        coordinator.stop()
    }
}
