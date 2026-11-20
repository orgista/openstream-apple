import Foundation
import Testing
@testable import OpenStreamApple

@Suite("Catch-up failures")
struct AppleIPTVCatchUpFailureTests {
    @Test(arguments: [403, 404])
    func unavailableArchivesAreTerminal(status: Int) {
        let request = ApplePlaybackRequest(url: URL(string: "https://fixture.example/archive")!, isLive: false,
            mediaID: "a#catchup-123", sourceKind: .liveTV)
        let failure = ApplePlaybackFailure(kind: .network, message: "provider", httpStatus: status)
        let result = AppleIPTVCatchUp.unavailableFailure(for: failure, request: request)
        #expect(result?.kind == .unavailable)
        #expect(result?.userMessage == "Catch-up isn't available for this programme")
        #expect(result?.httpStatus == status)
    }

    @Test func liveAndVODKeepTheirOwnFailurePolicies() {
        let failure = ApplePlaybackFailure(kind: .authentication, message: "provider", httpStatus: 403)
        let live = ApplePlaybackRequest(url: URL(string: "https://fixture.example/live")!, isLive: true, mediaID: "a", sourceKind: .liveTV)
        #expect(AppleIPTVCatchUp.unavailableFailure(for: failure, request: live) == nil)
        var archive = live
        archive.isLive = false
        archive.mediaID = "a#catchup-123"
        #expect(AppleIPTVCatchUp.unavailableFailure(for: .init(kind: .network, message: "temporary", httpStatus: 500), request: archive) == nil)
    }
}
