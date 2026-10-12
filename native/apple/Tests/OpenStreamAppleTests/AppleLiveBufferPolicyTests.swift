import Foundation
import Testing
@testable import OpenStreamApple

struct AppleLiveBufferPolicyTests {
    @Test func presetsAreBoundedAndAutomaticPreservesEngineDefaults() {
        #expect(AppleLiveBufferPreference.automatic.forwardBufferDuration(isLive: true) == 0)
        #expect(AppleLiveBufferPreference.automatic.forwardBufferSegments(isLive: true) == nil)
        #expect(AppleLiveBufferPreference.lowLatency.forwardBufferDuration(isLive: true) == 2)
        #expect(AppleLiveBufferPreference.lowLatency.forwardBufferSegments(isLive: true) == 4)
        #expect(AppleLiveBufferPreference.stable.forwardBufferDuration(isLive: true) == 20)
        #expect(AppleLiveBufferPreference.stable.forwardBufferSegments(isLive: true) == 20)
    }

    @Test(arguments: AppleLiveBufferPreference.allCases)
    func moviesKeepTheirExistingBuffer(preference: AppleLiveBufferPreference) {
        #expect(preference.forwardBufferDuration(isLive: false) == 0)
        #expect(preference.forwardBufferSegments(isLive: false) == nil)
    }

    @Test func missingOrInvalidSavedChoiceFallsBackToAutomatic() throws {
        let name = "live-buffer-tests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(AppleLiveBufferPreference.stored(in: defaults) == .automatic)
        defaults.set("invalid", forKey: AppleLiveBufferPreference.defaultsKey)
        #expect(AppleLiveBufferPreference.stored(in: defaults) == .automatic)
        defaults.set("stable", forKey: AppleLiveBufferPreference.defaultsKey)
        #expect(AppleLiveBufferPreference.stored(in: defaults) == .stable)
    }
}
