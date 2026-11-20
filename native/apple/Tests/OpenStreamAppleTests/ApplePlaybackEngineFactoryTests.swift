import Foundation
import Testing
@testable import OpenStreamApple

@MainActor
@Test
func factoryFallsBackToNativeWhenAetherConstructionThrows() {
    struct EngineConstructionFailure: Error {}
    let (engine, fellBack) = ApplePlaybackEngineFactory.make(preferred: .openStream) {
        throw EngineConstructionFailure()
    }
    #expect(engine.kind == .native)
    #expect(fellBack == true)
    #expect(engine is NativePlaybackEngine)
}

@MainActor
@Test
func factoryReturnsNativeWithoutFallbackWhenNativeIsPreferred() {
    let (engine, fellBack) = ApplePlaybackEngineFactory.make(preferred: .native)
    #expect(engine.kind == .native)
    #expect(fellBack == false)
    #expect(engine is NativePlaybackEngine)
}

@MainActor
@Test
func factoryReturnsAetherWithoutFallbackWhenPreferredAndConstructionSucceeds() {
    let fake = FakePlaybackEngine()
    let (engine, fellBack) = ApplePlaybackEngineFactory.make(preferred: .openStream) { fake }
    #expect(engine === (fake as any ApplePlaybackEngine))
    #expect(fellBack == false)
}
