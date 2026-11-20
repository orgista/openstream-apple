import Foundation
import Testing
@testable import OpenStreamApple

@Suite("Display criteria ownership")
struct AppleDisplayCriteriaPolicyTests {
    @Test func exactlyOneWriterPerEngine() {
        #expect(AppleDisplayCriteriaPolicy.automaticAVKitMatching(engine: .native))
        #expect(!AppleDisplayCriteriaPolicy.automaticAVKitMatching(engine: .openStream))
    }
    @Test(arguments: [false, true])
    func aetherKeepsContentMatchingForLiveAndVOD(isLive: Bool) {
        let request = ApplePlaybackRequest(url: URL(string: "https://fixture.example/video.m3u8")!, isLive: isLive,
            mediaID: "fixture", sourceKind: isLive ? .liveTV : .files)
        #expect(!AetherPlaybackEngine.loadOptions(for: request, headers: [:]).suppressDisplayCriteria)
    }
}
